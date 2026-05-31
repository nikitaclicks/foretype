import AppKit
import ApplicationServices

/// Polls the system focus on a timer (default 50 ms), rebuilds a `FocusSnapshot`
/// each tick, and publishes one only when the resolved state *meaningfully*
/// changes — by identity or by content/geometry (doc 03). The monotonic
/// `changeSequence` disambiguates recycled `elementHash` values so a stale model
/// result is always detectable downstream (doc 05).
///
/// Polling, not AX-notification subscription: AX observer delivery is unreliable
/// and inconsistent across host apps; a steady poll gives a single, predictable
/// change source with bounded staleness, and any transient mis-read self-heals
/// within one interval.
@MainActor
final class FocusWatcher: FocusProviding {

    // MARK: FocusProviding

    private(set) var current: FocusSnapshot?

    let snapshots: AsyncStream<FocusSnapshot>
    private let continuation: AsyncStream<FocusSnapshot>.Continuation

    func refreshNow() {
        poll()
    }

    // MARK: State

    private var timer: Timer?
    private var pollInterval: TimeInterval = 0.050
    /// Monotonic counter incremented on every genuine focus *identity* change.
    private var changeSequence: UInt64 = 0
    /// Identity (minus changeSequence) of the last element we treated as focused,
    /// used to decide whether identity changed.
    private var lastElementHash: Int?
    private var lastPID: pid_t?
    /// Structural signature (role|subrole|x|y|width) of the last focused element,
    /// used to recognize the same logical field across `CFHash` churn (doc 03).
    private var lastSignature: String?
    /// Consecutive polls that resolved to no usable field while a supported field
    /// was still current. Lets us ride through Chromium's focus "bounce" (the
    /// system focused element flip-flops between the editable node and its web
    /// area on alternating polls) instead of tearing the session down each tick.
    private var missStreak = 0
    /// How many consecutive unusable polls to tolerate before accepting focus
    /// loss (≈ ticks × pollInterval). The bounce never misses twice in a row, so a
    /// small window absorbs it while a genuine focus change still lands promptly.
    private let focusGraceTicks = 4
    /// Apps we've already opted into exposing their full AX tree, so we set
    /// `AXManualAccessibility` once per app rather than on every poll.
    private var enhancedAccessibilityPIDs: Set<pid_t> = []

    init() {
        var cont: AsyncStream<FocusSnapshot>.Continuation!
        self.snapshots = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    // MARK: Lifecycle

    func start() {
        stop()
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        t.tolerance = pollInterval * 0.2
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
        // Immediate first read so we don't wait a full interval after start.
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setPollInterval(milliseconds: Int) {
        let clamped = min(500, max(10, milliseconds))
        pollInterval = TimeInterval(clamped) / 1000.0
        // Restart the timer if running so the new cadence takes effect.
        if timer != nil {
            start()
        }
    }

    // MARK: Poll

    /// Opt an app into exposing its full AX tree the first time we see it
    /// frontmost (Chromium/Electron need this; native apps ignore it).
    private func ensureEnhancedAccessibility(pid: pid_t) {
        guard pid > 0, !enhancedAccessibilityPIDs.contains(pid) else { return }
        enhancedAccessibilityPIDs.insert(pid)
        AccessibilityBridge.enableEnhancedAccessibility(pid: pid)
    }

    /// A stable structural signature for `element`, used to recognize the same
    /// logical field across `CFHash` churn. Uses role + subrole + frame origin and
    /// width (NOT height — editors grow vertically while staying the same field).
    /// Rounded to whole points to tolerate sub-pixel jitter. Returns nil when the
    /// element exposes no frame to anchor on.
    private func focusSignature(of element: AXUIElement) -> String? {
        guard let frame = AccessibilityBridge.frame(element) else { return nil }
        let role = AccessibilityBridge.string(element, kAXRoleAttribute) ?? ""
        let subrole = AccessibilityBridge.string(element, kAXSubroleAttribute) ?? ""
        let x = Int(frame.origin.x.rounded())
        let y = Int(frame.origin.y.rounded())
        let w = Int(frame.size.width.rounded())
        return "\(role)|\(subrole)|\(x)|\(y)|\(w)"
    }

    private func poll() {
        guard let snapshot = buildSnapshot() else {
            // Nothing usable focused. Publish the transition to nil only once.
            if current != nil {
                current = nil
                lastElementHash = nil
                lastPID = nil
                lastSignature = nil
                // Note: FocusProviding has no "nil event" channel; the coordinator
                // reads `current` on its own ticks / focus stream. We simply clear.
            }
            return
        }

        if shouldPublish(snapshot) {
            current = snapshot
            continuation.yield(snapshot)
        } else {
            // Keep `current` fresh even when not re-publishing (geometry may drift
            // imperceptibly); cheap and avoids serving a stale rect on refreshNow.
            current = snapshot
        }
    }

    /// Build a snapshot from the live AX tree, or nil when nothing usable is
    /// focused. Determines identity (incl. changeSequence) and capability, and
    /// applies focus hysteresis to absorb Chromium's focus bounce (doc 03).
    private func buildSnapshot() -> FocusSnapshot? {
        guard AccessibilityBridge.isTrusted() else { return nil }

        let app = AccessibilityBridge.frontmostApp()

        // Opt the frontmost app into exposing its full AX tree before resolving
        // focus. Chromium/Electron web fields are invisible to AX otherwise, so
        // this must happen even when no element resolves yet (the tree mounts a
        // beat later and a subsequent poll then sees the real field).
        if let pid = app?.pid {
            ensureEnhancedAccessibility(pid: pid)
        }

        let bundleID = app?.bundleID ?? ""
        let pid = app?.pid ?? 0
        let appName = app?.name ?? ""

        // No focused element at all: ride through a transient miss if we just had
        // a supported field in this same app, else clear (nil → poll() resets).
        guard let focused = AccessibilityBridge.systemFocusedElement() else {
            return rideThroughMiss(pid: pid)
        }

        let elementHash = AccessibilityBridge.hash(focused)
        let signature = focusSignature(of: focused)

        // Decide identity change. A different pid, or a different hash whose
        // structural signature ALSO differs, is a new field. A hash that churned
        // while the signature held steady is the same field re-issued by the host
        // (e.g. a Chromium contenteditable re-rendered) — keep the prior identity.
        let seq = FocusIdentitySequencer.resolve(
            hash: elementHash,
            pid: pid,
            signature: signature,
            prior: .init(hash: lastElementHash, pid: lastPID, signature: lastSignature)
        )
        // Tentative: the candidate carries the bumped sequence, but we only COMMIT
        // it (mutate stored identity state) when we actually accept this read.
        let effectiveChangeSequence = changeSequence &+ (seq.identityChanged ? 1 : 0)
        let identity = FocusIdentity(
            bundleID: bundleID,
            pid: pid,
            elementHash: seq.stableHash,
            changeSequence: effectiveChangeSequence
        )

        let candidate = makeCandidate(focused: focused, identity: identity, appName: appName)

        // A usable field, or a hard block (secure), is honored IMMEDIATELY — we
        // must never keep showing ghost text once focus moves onto a password
        // field, so blocked reads are not smoothed.
        let isBlocked: Bool = {
            if case .blocked = candidate.capability { return true }
            return candidate.isSecure
        }()
        if candidate.capability == .supported || isBlocked {
            commitIdentity(seq: seq, pid: pid, signature: signature)
            missStreak = 0
            return candidate
        }

        // Unsupported read (e.g. Chromium focus bounce to the web area). If we just
        // had a supported field in this same app, ride through it: re-serve the
        // last good snapshot without disturbing identity state.
        if let current, current.capability == .supported,
           current.identity.pid == pid, missStreak < focusGraceTicks {
            missStreak += 1
            return current
        }

        // Grace exhausted (or a different app): accept the unsupported state.
        commitIdentity(seq: seq, pid: pid, signature: signature)
        missStreak = 0
        return candidate
    }

    /// Build the `FocusSnapshot` for a focused element, without committing any
    /// identity state. Pure-ish: only AX reads, no stored-state mutation.
    private func makeCandidate(focused: AXUIElement, identity: FocusIdentity, appName: String) -> FocusSnapshot {
        // Resolve the editable element + text.
        guard let resolution = FocusResolver.resolve(focused: focused) else {
            return FocusSnapshot(
                identity: identity,
                appName: appName,
                role: AccessibilityBridge.string(focused, kAXRoleAttribute) ?? "",
                subrole: AccessibilityBridge.string(focused, kAXSubroleAttribute),
                precedingText: "",
                trailingText: "",
                selection: NSRange(location: 0, length: 0),
                caret: nil,
                isSecure: false,
                capability: .unsupported(reason: "No usable editable element")
            )
        }

        // Secure field: blocked, never read text or geometry.
        if resolution.isSecure {
            return FocusSnapshot(
                identity: identity,
                appName: appName,
                role: resolution.role,
                subrole: resolution.subrole,
                precedingText: "",
                trailingText: "",
                selection: NSRange(location: 0, length: 0),
                caret: nil,
                isSecure: true,
                capability: .blocked(reason: "Secure field")
            )
        }

        let fieldRect = AccessibilityBridge.frame(resolution.element)
            .flatMap { AccessibilityBridge.axRectToCocoa($0) }
        let caret = CaretGeometryResolver.resolve(element: resolution.element, selection: resolution.selection)

        // Correctness-or-nothing: only a caret of at least `derived` quality makes
        // a field supported (doc 03). Web hosts reach this via the text-marker path.
        let capability: FocusCapability
        if let caret, caret.quality != .estimated {
            capability = .supported
        } else {
            capability = .unsupported(reason: "Caret geometry unavailable")
        }

        return FocusSnapshot(
            identity: identity,
            appName: appName,
            role: resolution.role,
            subrole: resolution.subrole,
            precedingText: resolution.precedingText,
            trailingText: resolution.trailingText,
            selection: resolution.selection,
            caret: caret,
            fieldRect: fieldRect,
            isSecure: false,
            capability: capability
        )
    }

    /// Handle a poll where no element is focused. Rides through a transient miss
    /// (returns the last good snapshot) when a supported field in the same app was
    /// current, else returns nil so `poll()` clears focus.
    private func rideThroughMiss(pid: pid_t) -> FocusSnapshot? {
        if let current, current.capability == .supported,
           current.identity.pid == pid, missStreak < focusGraceTicks {
            missStreak += 1
            return current
        }
        missStreak = 0
        return nil
    }

    /// Commit the identity decision into stored state (called only when accepting
    /// a read, so a ridden-through poll never advances `changeSequence`).
    private func commitIdentity(seq: FocusIdentitySequencer.Result, pid: pid_t, signature: String?) {
        if seq.identityChanged {
            changeSequence &+= 1
            lastElementHash = seq.stableHash
            lastPID = pid
        }
        lastSignature = signature
    }

    /// Publish only on a *meaningful* change: identity, capability, text content,
    /// selection, or a non-trivial caret-rect move. Avoids churn from identical
    /// re-reads while still repositioning on real caret motion.
    private func shouldPublish(_ snapshot: FocusSnapshot) -> Bool {
        guard let prev = current else { return true }
        if prev.identity != snapshot.identity { return true }
        if prev.capability != snapshot.capability { return true }
        if prev.precedingText != snapshot.precedingText { return true }
        if prev.trailingText != snapshot.trailingText { return true }
        if prev.selection != snapshot.selection { return true }
        if rectMovedMeaningfully(prev.fieldRect, snapshot.fieldRect) { return true }
        return false
    }

    /// Republish when the anchor (field) rect moves/resizes enough to matter, so
    /// the overlay follows a window the user drags or resizes.
    private func rectMovedMeaningfully(_ a: CGRect?, _ b: CGRect?) -> Bool {
        switch (a, b) {
        case (nil, nil): return false
        case (nil, _), (_, nil): return true
        case let (x?, y?):
            return abs(x.minX - y.minX) > 1.0
                || abs(x.minY - y.minY) > 1.0
                || abs(x.width - y.width) > 1.0
                || abs(x.height - y.height) > 1.0
        }
    }
}
