import AppKit

/// Owns the process-lifetime dependency graph. The composition root
/// (`AppEnvironment`) is built once here and retained for the process lifetime.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment()

    func applicationDidFinishLaunching(_ notification: Notification) {
        environment.start()
    }
}
