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

    /// Read-only settings access for the cheap per-tick gate (global toggle +
    /// app rules). Lets the watcher avoid issuing ANY cross-process AX IPC for an
    /// app/state where completion is impossible (doc 03; perf: see `pollDiag`).
    private let settings: SettingsProviding

    // Adaptive cadence (doc 03 polling, made demand-driven). The poll runs at one of
    // three intervals depending on the last tick's outcome, so heavy AX resolution —
    // and the IPC load it puts on the *frontmost* app — only happens when it can pay
    // off. `currentInterval` is the live timer period; the others are the targets.
    /// Live timer period.
    private var currentInterval: TimeInterval = 0.050
    /// Fast: a supported field is focused (caret tracking while typing). User-tunable
    /// via `setPollInterval`; this is the "20 Hz" cadence the design assumed.
    private var fastInterval: TimeInterval = 0.050
    /// Medium: an eligible app is frontmost but no supported field yet — poll often
    /// enough to notice a field appearing, without hammering.
    private let mediumInterval: TimeInterval = 0.220
    /// Idle: gate failed (feature off, not trusted, or app disabled by rule). No
    /// heavy AX work at all; just a slow heartbeat to notice the gate re-opening.
    private let idleInterval: TimeInterval = 0.500

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
    /// `AXManualAccessibility` once per app rather than on every poll. Pruned when an
    /// app terminates (see `terminationObserver`) so it can't grow unbounded across a
    /// long session of app switches.
    private var enhancedAccessibilityPIDs: Set<pid_t> = []
    /// Token for the app-termination observer that prunes `enhancedAccessibilityPIDs`.
    private var terminationObserver: NSObjectProtocol?

    // MARK: Diagnostics (Phase A — `pollDiag`)
    /// Accumulators for the once-per-second poll summary. Bookkeeping is a couple of
    /// adds per tick (negligible); the file write at the window boundary is gated on
    /// the `pollDiag` UserDefaults flag, so a normal run pays nothing but the math.
    private var diagWindowStart: ContinuousClock.Instant?
    private var diagTicks = 0
    private var diagDurationTotalMS = 0.0
    private var diagDurationMaxMS = 0.0
    private var diagAXCallsAtWindowStart = 0

    init(settings: SettingsProviding) {
        self.settings = settings
        var cont: AsyncStream<FocusSnapshot>.Continuation!
        self.snapshots = AsyncStream { cont = $0 }
        self.continuation = cont

        // Prune the enhanced-AX opt-in set when an app quits, so it tracks live apps
        // rather than accumulating dead PIDs across a long session.
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            MainActor.assumeIsolated {
                self?.enhancedAccessibilityPIDs.remove(app.processIdentifier)
            }
        }
    }

    deinit {
        if let token = terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    // MARK: Lifecycle

    func start() {
        stop()
        scheduleTimer()
        // Immediate first read so we don't wait a full interval after start.
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setPollInterval(milliseconds: Int) {
        let clamped = min(500, max(10, milliseconds))
        let newFast = TimeInterval(clamped) / 1000.0
        // If we're currently in fast mode, apply the new cadence immediately;
        // otherwise it takes effect the next time a supported field is focused.
        let wasFast = abs(currentInterval - fastInterval) < 0.0001
        fastInterval = newFast
        if timer != nil, wasFast { setCadence(fastInterval) }
    }

    /// (Re)install the repeating timer at `currentInterval`. Safe to call from
    /// within the firing timer's own callback (we invalidate first).
    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        t.tolerance = currentInterval * 0.2
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    /// Switch the poll cadence, rescheduling the timer only when it actually changes
    /// (so a steady state never churns timers — `start()` invalidates first anyway).
    private func setCadence(_ desired: TimeInterval) {
        guard abs(desired - currentInterval) > 0.0001 else { return }
        currentInterval = desired
        if timer != nil { scheduleTimer() }
    }

    /// Cheap precondition check — NO cross-process AX IPC. Mirrors the fundamental
    /// preconditions in `AvailabilityEvaluator` (trust + global toggle + app rule)
    /// so we can skip the expensive focus/caret resolution entirely for an app or
    /// state where completion is impossible. `isTrusted()` and `frontmostApp()` are
    /// local (TCC check / NSWorkspace), not AX tree reads.
    private func passesCheapGate() -> Bool {
        guard AccessibilityBridge.isTrusted() else { return false }
        let current = settings.current
        guard current.isEnabled else { return false }
        let bundleID = AccessibilityBridge.frontmostApp()?.bundleID ?? ""
        return AppRuleEvaluator.isEnabled(bundleID: bundleID, settings: current)
    }

    /// Clear focus once on transition to "nothing usable". Shared by the gated-off
    /// and no-snapshot paths.
    private func clearFocusIfNeeded() {
        guard current != nil else { return }
        current = nil
        lastElementHash = nil
        lastPID = nil
        lastSignature = nil
        // FocusProviding has no "nil event" channel; the coordinator reads `current`
        // on its own ticks / focus stream. We simply clear.
    }

    // MARK: Poll

    /// Opt an app into exposing its full AX tree the first time we see it
    /// frontmost (Chromium/Electron need this; native apps ignore it).
    private func ensureEnhancedAccessibility(pid: pid_t, bundleID: String) {
        guard pid > 0, !enhancedAccessibilityPIDs.contains(pid) else { return }
        enhancedAccessibilityPIDs.insert(pid)
        AccessibilityBridge.enableEnhancedAccessibility(pid: pid, bundleID: bundleID)
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
        let tickStart = ContinuousClock().now
        defer { recordPollDiag(tickStart: tickStart) }

        // Cheap gate first: for a disabled feature / disabled app / no AX trust we do
        // NO heavy AX resolution and issue zero IPC into the frontmost app — just
        // idle and wait for the gate to re-open. This is the bulk of the perf win.
        guard passesCheapGate() else {
            clearFocusIfNeeded()
            setCadence(idleInterval)
            return
        }

        guard let snapshot = buildSnapshot() else {
            clearFocusIfNeeded()
            // Eligible app, nothing usable focused yet: poll at medium so a field
            // that appears is picked up promptly, without 20 Hz hammering.
            setCadence(mediumInterval)
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

        // Fast only while a supported field is active (caret tracking while typing);
        // otherwise medium — an eligible app with an unsupported/secure field doesn't
        // need 20 Hz.
        setCadence(snapshot.capability == .supported ? fastInterval : mediumInterval)
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
            ensureEnhancedAccessibility(pid: pid, bundleID: app?.bundleID ?? "")
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

    // MARK: Diagnostics (Phase A)

    /// Accumulate per-tick timing and, once a ~1 s window elapses, flush a summary to
    /// `/tmp/foretype-polldiag.log` (gated on the `pollDiag` UserDefaults flag, like
    /// `ghostDiag`). Captures the AX-IPC traffic the poll generates so we can confirm
    /// whether system lag tracks poll activity, and later prove the gating cut it.
    private func recordPollDiag(tickStart: ContinuousClock.Instant) {
        let now = ContinuousClock().now
        let tickMS = Self.milliseconds(tickStart.duration(to: now))

        if diagWindowStart == nil {
            diagWindowStart = tickStart
            diagAXCallsAtWindowStart = AccessibilityBridge.axCallCount
        }
        diagTicks += 1
        diagDurationTotalMS += tickMS
        diagDurationMaxMS = max(diagDurationMaxMS, tickMS)

        guard let windowStart = diagWindowStart else { return }
        let windowSeconds = Self.milliseconds(windowStart.duration(to: now)) / 1000.0
        guard windowSeconds >= 1.0 else { return }

        // Window elapsed: emit (if enabled) and reset.
        if UserDefaults.standard.bool(forKey: "pollDiag") {
            let axCalls = AccessibilityBridge.axCallCount &- diagAXCallsAtWindowStart
            let callsPerSec = Double(axCalls) / windowSeconds
            let avgTickMS = diagTicks > 0 ? diagDurationTotalMS / Double(diagTicks) : 0
            let bundle = AccessibilityBridge.frontmostApp()?.bundleID ?? "?"
            let supported = current?.capability == .supported
            let line = String(
                format: "axCalls/s=%.0f ticks/s=%.0f avgTickMs=%.2f maxTickMs=%.2f interval=%.0fms frontmost=%@ supported=%@\n",
                callsPerSec, Double(diagTicks) / windowSeconds, avgTickMS,
                diagDurationMaxMS, currentInterval * 1000.0, bundle, supported ? "Y" : "N"
            )
            if let data = line.data(using: .utf8) {
                let url = URL(fileURLWithPath: "/tmp/foretype-polldiag.log")
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile(); handle.write(data); try? handle.close()
                } else {
                    try? data.write(to: url)
                }
            }
        }

        diagWindowStart = now
        diagAXCallsAtWindowStart = AccessibilityBridge.axCallCount
        diagTicks = 0
        diagDurationTotalMS = 0
        diagDurationMaxMS = 0
    }

    /// `Duration` → milliseconds (1 ms == 1e15 attoseconds).
    private static func milliseconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000.0 + Double(c.attoseconds) / 1e15
    }
}
