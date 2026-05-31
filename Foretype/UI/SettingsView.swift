import AppKit
import SwiftUI

/// The compact settings window (doc 10). Five sections: General (with an
/// Advanced timing disclosure), Backend (Apple-Intelligence availability +
/// OpenAI base URL / model / key + a Test round-trip hook), Completions (length
/// preset), Apps (per-app block rules with an add-frontmost quick action), and
/// Appearance (ghost-text color + activation indicator).
///
/// The view only OBSERVES the injected `SettingsStore` / `PermissionMonitor`;
/// it never constructs services. All writes go through the store's typed
/// mutators so they persist and emit.
struct SettingsView: View {
    @ObservedObject var permissions: PermissionMonitor
    @ObservedObject var settings: SettingsStore
    let windowManager: WindowManager

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings, windowManager: windowManager)
                .tabItem { Label("General", systemImage: "gearshape") }

            BackendSettingsTab(settings: settings)
                .tabItem { Label("Backend", systemImage: "cpu") }

            CompletionsSettingsTab(settings: settings)
                .tabItem { Label("Completions", systemImage: "text.append") }

            AppsSettingsTab(settings: settings)
                .tabItem { Label("Apps", systemImage: "app.badge") }

            AppearanceSettingsTab(settings: settings)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
        .padding(16)
        .frame(width: 460, height: 560)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var settings: SettingsStore
    let windowManager: WindowManager
    @State private var showAdvanced = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable Foretype", isOn: Binding(
                    get: { settings.current.isEnabled },
                    set: { settings.setEnabled($0) }
                ))
                Button("Open Onboarding…") {
                    windowManager.showOnboarding()
                }
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    timingField(
                        label: "Debounce",
                        value: settings.current.debounceMilliseconds,
                        set: { settings.setDebounceMilliseconds($0) }
                    )
                    timingField(
                        label: "Focus poll interval",
                        value: settings.current.focusPollMilliseconds,
                        set: { settings.setFocusPollMilliseconds($0) }
                    )
                    Text("Values are clamped to 10–500 ms. Defaults are sensible; change only if needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func timingField(label: String,
                             value: Int,
                             set: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(label)
            Spacer()
            Stepper(
                value: Binding(get: { value }, set: { set($0) }),
                in: 10...500,
                step: 10
            ) {
                Text("\(value) ms")
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
            }
        }
    }
}

// MARK: - Backend

private struct BackendSettingsTab: View {
    @ObservedObject var settings: SettingsStore

    @State private var baseURL: String = ""
    @State private var model: String = ""
    @State private var apiKey: String = ""
    @State private var testResult: TestResult = .none

    private let appleAvailable = AppleIntelligenceEngine.isAvailable()

    enum TestResult: Equatable {
        case none, testing, success(String), failure(String)
    }

    var body: some View {
        Form {
            Section("Backend") {
                Picker("Engine", selection: Binding(
                    get: { settings.current.backend },
                    set: { settings.setBackend($0) }
                )) {
                    Text("Apple Intelligence").tag(Backend.appleIntelligence)
                    Text("OpenAI-compatible").tag(Backend.openAICompatible)
                }
                .pickerStyle(.radioGroup)

                if settings.current.backend == .appleIntelligence {
                    HStack {
                        Image(systemName: appleAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(appleAvailable ? .green : .orange)
                        Text(appleAvailable
                             ? "Apple Intelligence is available on this Mac."
                             : "Apple Intelligence is unavailable on this Mac (requires a supported device on macOS 26+). Choose OpenAI-compatible instead.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if settings.current.backend == .openAICompatible {
                Section("OpenAI-compatible endpoint") {
                    TextField("Base URL", text: $baseURL, prompt: Text("http://localhost:11434"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitOpenAI)
                    TextField("Model", text: $model, prompt: Text("qwen2.5-coder"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitOpenAI)
                    SecureField("API key (optional)", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("Save") { commitOpenAI(); commitKey() }
                        Button("Use localhost preset") {
                            baseURL = OpenAISettings.default.baseURL
                            model = OpenAISettings.default.model
                            commitOpenAI()
                        }
                        Spacer()
                        Button("Test") { runTest() }
                            .disabled(testResult == .testing)
                    }

                    testResultView
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var testResultView: some View {
        switch testResult {
        case .none:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").font(.caption).foregroundStyle(.secondary)
            }
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

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

    /// Test-button stub hook: persists the current fields then performs one
    /// best-effort round-trip against the configured endpoint. Integration may
    /// replace this with a call through the shared engine/router; kept simple
    /// and self-contained here.
    private func runTest() {
        commitOpenAI()
        commitKey()
        testResult = .testing

        let oai = settings.current.openAI
        let key = settings.apiKey()

        Task {
            let result = await Self.probe(baseURL: oai.baseURL, model: oai.model, apiKey: key)
            await MainActor.run { testResult = result }
        }
    }

    /// Minimal one-shot probe of the chat-completions endpoint. Returns a
    /// human-readable success/failure. Off the main actor.
    private static func probe(baseURL: String, model: String, apiKey: String?) async -> TestResult {
        // Resolve the endpoint the SAME way the engine does, so Test and live
        // completions agree (tolerates an included /v1, trailing slash, etc.).
        guard let urlString = OpenAIEngine.chatCompletionsURLString(base: baseURL),
              let url = URL(string: urlString) else {
            return .failure("Invalid base URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let payload: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "ping"]],
            "max_tokens": 1
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("No HTTP response")
            }
            if (200...299).contains(http.statusCode) {
                return .success("Connected (HTTP \(http.statusCode))")
            }
            return .failure("Endpoint returned HTTP \(http.statusCode)")
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

// MARK: - Completions

private struct CompletionsSettingsTab: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Suggestion length") {
                Picker("Length", selection: Binding(
                    get: { settings.current.lengthPreset },
                    set: { settings.setLengthPreset($0) }
                )) {
                    ForEach(LengthPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Apps

private struct AppsSettingsTab: View {
    @ObservedObject var settings: SettingsStore
    @State private var frontmost: FrontmostApp?

    private var blockedRules: [AppRule] {
        settings.current.appRules.filter { $0.mode == .block }
    }

    var body: some View {
        Form {
            Section("Disabled apps") {
                if blockedRules.isEmpty {
                    Text("Foretype is enabled everywhere. Add an app below to turn it off there.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(blockedRules, id: \.bundleID) { rule in
                        HStack {
                            Text(rule.bundleID)
                                .font(.callout)
                            Spacer()
                            Button(role: .destructive) {
                                settings.removeAppRule(bundleID: rule.bundleID)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section {
                if let app = frontmost {
                    let alreadyBlocked = blockedRules.contains { $0.bundleID == app.bundleID }
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Frontmost app")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(app.name)
                            Text(app.bundleID)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Disable here") {
                            settings.addAppRule(AppRule(bundleID: app.bundleID, mode: .block))
                        }
                        .disabled(alreadyBlocked)
                    }
                } else {
                    Text("No frontmost app detected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Refresh frontmost app", action: refreshFrontmost)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshFrontmost)
    }

    private func refreshFrontmost() {
        if let app = NSWorkspace.shared.frontmostApplication,
           let bundleID = app.bundleIdentifier,
           bundleID != Bundle.main.bundleIdentifier {
            frontmost = FrontmostApp(bundleID: bundleID, name: app.localizedName ?? bundleID)
        } else {
            frontmost = nil
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsTab: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Ghost text") {
                ColorPicker("Color", selection: Binding(
                    get: { Self.color(from: settings.current.ghostTextColorHex) },
                    set: { settings.setGhostTextColorHex(Self.hex(from: $0)) }
                ), supportsOpacity: false)

                Button("Reset to default color") {
                    settings.setGhostTextColorHex(nil)
                }
                .disabled(settings.current.ghostTextColorHex == nil)
            }

            Section("Activation indicator") {
                Toggle("Show the small caret marker", isOn: Binding(
                    get: { settings.current.showActivationIndicator },
                    set: { settings.setShowActivationIndicator($0) }
                ))
            }
        }
        .formStyle(.grouped)
    }

    /// Parse "#RRGGBB" / "RRGGBB" (also tolerates "#RRGGBBAA") into a SwiftUI
    /// Color, falling back to the default secondary-label color. Kept local to
    /// avoid colliding with the overlay's own hex parser.
    private static func color(from hex: String?) -> Color {
        guard let hex, let nsColor = parseHex(hex) else {
            return Color(nsColor: .secondaryLabelColor)
        }
        return Color(nsColor: nsColor)
    }

    /// Render the chosen color as "#RRGGBB" for persistence.
    private static func hex(from color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private static func parseHex(_ hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else {
            return nil
        }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
