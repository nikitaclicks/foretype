import AppKit
import SwiftUI

/// Owns the two on-demand windows Foretype can show — Settings and Onboarding —
/// for a menu-bar-only (`LSUIElement`) app that has no automatic window scene
/// (doc 02/10). Self-contained: it lazily builds one `NSWindow` per surface,
/// reuses it across opens, and hosts the SwiftUI views via `NSHostingController`.
///
/// The manager never constructs services; it is handed the already-built
/// services by the composition root and forwards them into the hosted views.
@MainActor
final class WindowManager: ObservableObject {
    private let permissions: PermissionMonitor
    private let settings: SettingsStore

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    init(permissions: PermissionMonitor,
         settings: SettingsStore,
         coordinator: CompletionCoordinator) {
        // `coordinator` is accepted for parity with the composition root and
        // potential future use; the windows themselves observe permissions and
        // settings only.
        self.permissions = permissions
        self.settings = settings
    }

    /// Open (or bring forward) the Settings window.
    func showSettings() {
        if let window = settingsWindow {
            present(window)
            return
        }
        let view = SettingsView(
            permissions: permissions,
            settings: settings,
            windowManager: self
        )
        let window = makeWindow(
            title: "Foretype Settings",
            size: NSSize(width: 460, height: 560),
            content: view
        )
        settingsWindow = window
        present(window)
    }

    /// Open (or bring forward) the Onboarding window. Used on first run and when
    /// re-opened from Settings (doc 02).
    func showOnboarding() {
        if let window = onboardingWindow {
            present(window)
            return
        }
        let view = OnboardingView(
            permissions: permissions,
            settings: settings,
            windowManager: self
        )
        let window = makeWindow(
            title: "Welcome to Foretype",
            size: NSSize(width: 460, height: 520),
            content: view
        )
        onboardingWindow = window
        present(window)
    }

    /// Close the onboarding window (the "Finish" action calls this).
    func closeOnboarding() {
        onboardingWindow?.close()
    }

    // MARK: - Private

    private func makeWindow<Content: View>(title: String,
                                           size: NSSize,
                                           content: Content) -> NSWindow {
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        // A menu-bar accessory app is normally not active; activate so the
        // window can take key focus and the user can type into fields.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
