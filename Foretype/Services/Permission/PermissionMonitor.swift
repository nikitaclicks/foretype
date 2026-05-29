import Foundation
import ApplicationServices
import CoreGraphics
import AppKit

/// Owns the two macOS privacy permissions Foretype needs — Accessibility and
/// Input Monitoring — and is the sole source of truth for their grant state
/// (doc 02). Other services observe it rather than calling the OS checks
/// themselves.
///
/// Grant state is polled on a ~2 s timer using the *preflight / non-prompting*
/// checks (`AXIsProcessTrusted()`, `CGPreflightListenEventAccess()`), so a grant
/// made directly in System Settings is picked up within one interval without
/// nagging the user. A `changes` event is emitted whenever either grant flips.
@MainActor
final class PermissionMonitor: ObservableObject, PermissionProviding {
    @Published private(set) var accessibilityGranted: Bool
    @Published private(set) var inputMonitoringGranted: Bool

    /// Emits whenever either grant flips. Late subscribers receive a `Void` on
    /// the next flip; the current state is always readable via the published
    /// properties.
    let changes: AsyncStream<Void>
    private let changesContinuation: AsyncStream<Void>.Continuation

    private var pollTimer: Timer?
    private let pollInterval: TimeInterval = 2.0

    init() {
        let ax = AXIsProcessTrusted()
        let input = CGPreflightListenEventAccess()
        self.accessibilityGranted = ax
        self.inputMonitoringGranted = input

        var continuation: AsyncStream<Void>.Continuation!
        self.changes = AsyncStream<Void> { continuation = $0 }
        self.changesContinuation = continuation
    }

    deinit {
        pollTimer?.invalidate()
        changesContinuation.finish()
    }

    /// Begins the ~2 s preflight poll. Idempotent: a second call restarts the
    /// timer rather than stacking two.
    func start() {
        pollTimer?.invalidate()
        // Pick up any change that happened between init and start immediately.
        poll()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            // Timer fires on the main run loop; hop to the main actor for state.
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Stops polling. Published state retains its last values.
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Requesting permissions (explicit user action only, doc 02)

    /// Triggers the Accessibility system prompt and deep-links to its pane. The
    /// poll confirms the grant; the caller must not assume instant effect.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            openSettingsPane("com.apple.preference.security?Privacy_Accessibility")
        }
        poll()
    }

    /// Triggers the Input Monitoring system prompt. The poll confirms the grant.
    func requestInputMonitoring() {
        let granted = CGRequestListenEventAccess()
        if !granted {
            openSettingsPane("com.apple.preference.security?Privacy_ListenEvent")
        }
        poll()
    }

    // MARK: - Polling

    private func poll() {
        let ax = AXIsProcessTrusted()
        let input = CGPreflightListenEventAccess()
        var flipped = false

        if ax != accessibilityGranted {
            accessibilityGranted = ax
            flipped = true
        }
        if input != inputMonitoringGranted {
            inputMonitoringGranted = input
            flipped = true
        }
        if flipped {
            changesContinuation.yield(())
        }
    }

    private func openSettingsPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}
