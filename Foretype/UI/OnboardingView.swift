import AppKit
import SwiftUI

/// First-run onboarding (doc 02). The one window Foretype shows automatically.
/// It: explains itself in one sentence; walks Accessibility then Input
/// Monitoring with Enable… buttons and live "Granted" indicators; lets the user
/// pick a backend (Apple Intelligence if available, else OpenAI-compatible with
/// fields); and finishes into the menu-bar-only running state.
///
/// The view only OBSERVES the injected services; it never constructs them. It
/// degrades gracefully if closed early — the app simply stays disabled and keeps
/// prompting from the menu bar.
struct OnboardingView: View {
    @ObservedObject var permissions: PermissionMonitor
    @ObservedObject var settings: SettingsStore
    let windowManager: WindowManager

    @State private var baseURL: String = ""
    @State private var model: String = ""
    @State private var apiKey: String = ""

    private let appleAvailable = AppleIntelligenceEngine.isAvailable()

    private var bothGranted: Bool {
        permissions.accessibilityGranted && permissions.inputMonitoringGranted
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                intro
                Divider()
                permissionsStep
                Divider()
                backendStep
                Divider()
                finishStep
            }
            .padding(20)
        }
        .frame(width: 460, height: 520)
        .onAppear(perform: load)
    }

    // MARK: - Steps

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to Foretype")
                .font(.title2.weight(.semibold))
            Text("Foretype suggests inline text completions in any app and accepts them with Tab.")
                .foregroundStyle(.secondary)
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. Grant permissions")
                .font(.headline)

            permissionRow(
                title: "Accessibility",
                detail: "Reads the focused field's text and caret position.",
                granted: permissions.accessibilityGranted,
                enable: { permissions.requestAccessibility() }
            )
            permissionRow(
                title: "Input Monitoring",
                detail: "Observes typing and the Tab accept gesture.",
                granted: permissions.inputMonitoringGranted,
                enable: { permissions.requestInputMonitoring() }
            )
        }
    }

    private func permissionRow(title: String,
                               detail: String,
                               granted: Bool,
                               enable: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Granted").font(.caption).foregroundStyle(.green)
            } else {
                Button("Enable…", action: enable)
            }
        }
    }

    private var backendStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2. Choose a backend")
                .font(.headline)

            Picker("Engine", selection: Binding(
                get: { settings.current.backend },
                set: { settings.setBackend($0) }
            )) {
                Text("Apple Intelligence").tag(Backend.appleIntelligence)
                Text("OpenAI-compatible").tag(Backend.openAICompatible)
            }
            .pickerStyle(.radioGroup)

            if settings.current.backend == .appleIntelligence {
                HStack(spacing: 6) {
                    Image(systemName: appleAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(appleAvailable ? .green : .orange)
                    Text(appleAvailable
                         ? "Available on this Mac — no setup needed."
                         : "Not available on this Mac. Pick OpenAI-compatible below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Base URL", text: $baseURL, prompt: Text("http://localhost:11434"))
                        .textFieldStyle(.roundedBorder)
                    TextField("Model", text: $model, prompt: Text("qwen2.5-coder"))
                        .textFieldStyle(.roundedBorder)
                    SecureField("API key (optional)", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }
                .onChange(of: baseURL) { _, _ in commitOpenAI() }
                .onChange(of: model) { _, _ in commitOpenAI() }
            }
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("3. Finish")
                .font(.headline)
            Text(bothGranted
                 ? "You're all set. Foretype runs from the menu bar."
                 : "You can finish now and grant the remaining permissions later from the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Finish") {
                    commitOpenAI()
                    commitKey()
                    windowManager.closeOnboarding()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Persistence

    private func load() {
        baseURL = settings.current.openAI.baseURL
        model = settings.current.openAI.model
        apiKey = settings.apiKey() ?? ""
    }

    private func commitOpenAI() {
        let next = OpenAISettings(
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if next != settings.current.openAI {
            settings.setOpenAI(next)
        }
    }

    private func commitKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.setAPIKey(trimmed.isEmpty ? nil : trimmed)
    }
}
