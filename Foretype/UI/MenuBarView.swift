import AppKit
import SwiftUI

/// Menu bar content (doc 11 / 02). Surfaces, in order of urgency:
///  - a "Permissions needed" section with one Enable… action per missing grant,
///  - the global enable toggle,
///  - a "Disable for current app" quick action (frontmost app, doc 10),
///  - a one-line state readout of the completion pipeline,
///  - entries to open Settings and Onboarding, and Quit.
///
/// The view only OBSERVES injected services; it never constructs them.
struct MenuBarView: View {
    @ObservedObject var permissions: PermissionMonitor
    @ObservedObject var settings: SettingsStore
    @ObservedObject var coordinator: CompletionCoordinator
    let windowManager: WindowManager

    /// The frontmost app at render time, used for the per-app quick toggle.
    @State private var frontmost: FrontmostApp?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !bothPermissionsGranted {
                Divider()
                permissionsSection
            }

            Divider()
            controlsSection

            Divider()
            stateReadout

            Divider()
            actionsSection
        }
        .padding(12)
        .frame(width: 280)
        .onAppear(perform: refreshFrontmost)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Foretype")
                .font(.headline)
            Text("Inline autocomplete, everywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Permissions needed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if !permissions.accessibilityGranted {
                permissionRow(
                    label: "Accessibility",
                    action: { permissions.requestAccessibility() }
                )
            }
            if !permissions.inputMonitoringGranted {
                permissionRow(
                    label: "Input Monitoring",
                    action: { permissions.requestInputMonitoring() }
                )
            }
        }
    }

    private func permissionRow(label: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(label)
            Spacer()
            Button("Enable…", action: action)
                .buttonStyle(.borderless)
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enable Foretype", isOn: Binding(
                get: { settings.current.isEnabled },
                set: { settings.setEnabled($0) }
            ))
            .toggleStyle(.switch)

            currentAppToggle
        }
    }

    @ViewBuilder
    private var currentAppToggle: some View {
        if let app = frontmost {
            let blocked = isAppBlocked(app.bundleID)
            Button {
                toggleCurrentApp(app)
            } label: {
                HStack {
                    Image(systemName: blocked ? "play.circle" : "nosign")
                    Text(blocked
                         ? "Enable for \(app.name)"
                         : "Disable for \(app.name)")
                    Spacer()
                }
            }
            .buttonStyle(.borderless)
        } else {
            Text("No frontmost app")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var stateReadout: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            Text(stateDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Settings…") {
                windowManager.showSettings()
            }
            .buttonStyle(.borderless)

            Button("Onboarding…") {
                windowManager.showOnboarding()
            }
            .buttonStyle(.borderless)

            Button("Quit Foretype") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Derived

    private var bothPermissionsGranted: Bool {
        permissions.accessibilityGranted && permissions.inputMonitoringGranted
    }

    private var stateColor: Color {
        switch coordinator.state {
        case .idle, .debouncing, .generating, .previewing:
            return .green
        case .disabled:
            return .orange
        case .failed:
            return .red
        }
    }

    private var stateDescription: String {
        switch coordinator.state {
        case .idle:
            return "Ready"
        case .debouncing:
            return "Waiting for typing to settle…"
        case .generating:
            return "Generating…"
        case .previewing:
            return "Suggestion shown — press Tab to accept"
        case .failed(let reason):
            return "Last attempt failed: \(reason)"
        case .disabled(let reason):
            return "Disabled — \(Self.describe(reason))"
        }
    }

    static func describe(_ reason: DisabledReason) -> String {
        switch reason {
        case .permissionMissing: return "permissions needed"
        case .fieldUnsupported: return "this field isn't supported"
        case .fieldSecure: return "secure field"
        case .appDisabledByRule: return "turned off for this app"
        case .globallyOff: return "globally off"
        case .backendUnavailable: return "backend unavailable"
        }
    }

    // MARK: - Frontmost app / rules

    private func refreshFrontmost() {
        if let app = NSWorkspace.shared.frontmostApplication,
           let bundleID = app.bundleIdentifier {
            frontmost = FrontmostApp(
                bundleID: bundleID,
                name: app.localizedName ?? bundleID
            )
        } else {
            frontmost = nil
        }
    }

    private func isAppBlocked(_ bundleID: String) -> Bool {
        settings.current.appRules.contains {
            $0.bundleID == bundleID && $0.mode == .block
        }
    }

    private func toggleCurrentApp(_ app: FrontmostApp) {
        if isAppBlocked(app.bundleID) {
            settings.removeAppRule(bundleID: app.bundleID)
        } else {
            settings.addAppRule(AppRule(bundleID: app.bundleID, mode: .block))
        }
    }
}

/// Lightweight value describing the current frontmost app for the per-app rule
/// quick action.
struct FrontmostApp: Equatable {
    let bundleID: String
    let name: String
}
