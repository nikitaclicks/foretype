import SwiftUI

/// `@main` entry point. Foretype is a menu-bar-only agent app (`LSUIElement`),
/// so it has no main window scene — only a `MenuBarExtra`. The long-lived
/// dependency graph is owned by `AppDelegate` via `AppEnvironment`.
@main
struct ForetypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Foretype", systemImage: "text.cursor") {
            MenuBarView(
                permissions: appDelegate.environment.permissions,
                settings: appDelegate.environment.settings,
                coordinator: appDelegate.environment.coordinator,
                windowManager: appDelegate.environment.windowManager
            )
            .environmentObject(appDelegate.environment)
        }
        .menuBarExtraStyle(.window)
    }
}
