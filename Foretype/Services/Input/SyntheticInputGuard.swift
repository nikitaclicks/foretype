import Foundation

/// Breaks the feedback loop between `TextInserter` and `KeyboardTap` (docs 04 &
/// 09). When Foretype inserts a completion it synthesizes keyboard events that
/// would otherwise re-enter the tap as `textMutation` and trigger a new
/// prediction for text the app just typed.
///
/// Count-based (not boolean) so multi-character chunks are each accounted for
/// and a stray real keystroke landing mid-insertion is not swallowed. The guard
/// self-clears after a short window so a missed match can never suppress genuine
/// keystrokes indefinitely.
@MainActor
final class SyntheticInputGuard {
    /// How long a registered expectation stays valid. After this the pending
    /// count is discarded so real keystrokes are never suppressed.
    private let window: TimeInterval

    private var pending: Int = 0
    private var expiry: Date = .distantPast

    init(window: TimeInterval = 0.5) {
        self.window = window
    }

    /// Register that `count` synthetic key-down events are about to be posted.
    /// Adds to any still-valid pending counter and (re)arms the expiry window.
    func expect(count: Int) {
        guard count > 0 else { return }
        clearIfExpired()
        pending += count
        expiry = Date().addingTimeInterval(window)
    }

    /// Consulted by the tap for each incoming event. Returns true (and consumes
    /// one expected event) when a synthetic event is still pending within the
    /// window; otherwise false. Self-clears on expiry.
    func shouldSuppress() -> Bool {
        clearIfExpired()
        guard pending > 0 else { return false }
        pending -= 1
        if pending == 0 {
            expiry = .distantPast
        }
        return true
    }

    private func clearIfExpired() {
        if pending > 0 && Date() >= expiry {
            pending = 0
            expiry = .distantPast
        }
    }
}
