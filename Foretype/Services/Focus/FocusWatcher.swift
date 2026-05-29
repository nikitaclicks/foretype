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

    private func poll() {
        guard let snapshot = buildSnapshot() else {
            // Nothing usable focused. Publish the transition to nil only once.
            if current != nil {
                current = nil
                lastElementHash = nil
                lastPID = nil
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
    /// focused. Determines identity (incl. changeSequence) and capability.
    private func buildSnapshot() -> FocusSnapshot? {
        guard AccessibilityBridge.isTrusted() else { return nil }
        guard let focused = AccessibilityBridge.systemFocusedElement() else { return nil }

        let app = AccessibilityBridge.frontmostApp()
        let bundleID = app?.bundleID ?? ""
        let pid = app?.pid ?? 0
        let appName = app?.name ?? ""

        let elementHash = AccessibilityBridge.hash(focused)

        // Decide identity change: a different element hash or pid is a new field.
        let identityChanged = (elementHash != lastElementHash) || (pid != lastPID)
        if identityChanged {
            changeSequence &+= 1
            lastElementHash = elementHash
            lastPID = pid
        }
        let identity = FocusIdentity(
            bundleID: bundleID,
            pid: pid,
            elementHash: elementHash,
            changeSequence: changeSequence
        )

        // Resolve the editable element + text.
        guard let resolution = FocusResolver.resolve(focused: focused) else {
            // Focused, but no usable editable element found.
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

        // Resolve caret geometry. Correctness-or-nothing: must reach >= derived.
        let caret = CaretGeometryResolver.resolve(element: resolution.element, selection: resolution.selection)
        let capability: FocusCapability
        if let caret, caret.quality != .estimated {
            capability = .supported
        } else {
            // No caret, or only estimated — not trustworthy enough.
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
            isSecure: false,
            capability: capability
        )
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
        if caretMovedMeaningfully(prev.caret, snapshot.caret) { return true }
        return false
    }

    private func caretMovedMeaningfully(_ a: CaretGeometry?, _ b: CaretGeometry?) -> Bool {
        switch (a, b) {
        case (nil, nil): return false
        case (nil, _), (_, nil): return true
        case let (x?, y?):
            if x.quality != y.quality { return true }
            let dx = abs(x.rect.origin.x - y.rect.origin.x)
            let dy = abs(x.rect.origin.y - y.rect.origin.y)
            let dh = abs(x.rect.height - y.rect.height)
            return dx > 1.0 || dy > 1.0 || dh > 1.0
        }
    }
}
