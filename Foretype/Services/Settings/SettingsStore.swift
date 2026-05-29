import Foundation
import Combine

/// The single source of truth for persisted settings (doc 10). Settings are
/// stored as JSON in `UserDefaults` under one key; the OpenAI API key lives only
/// in the Keychain via `KeychainStore`. Every mutator clamps, persists, and emits
/// the full `Settings` through `changes` so the coordinator can react (doc 05).
@MainActor
final class SettingsStore: ObservableObject, SettingsProviding {
    /// The current settings value. Satisfies `SettingsProviding.current`.
    @Published private(set) var current: Settings

    /// Emits the full `Settings` value on every change.
    var changes: AsyncStream<Settings> { stream }

    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private static let storageKey = "com.foretype.settings"

    private let stream: AsyncStream<Settings>
    private let continuation: AsyncStream<Settings>.Continuation

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain

        var cont: AsyncStream<Settings>.Continuation!
        self.stream = AsyncStream { cont = $0 }
        self.continuation = cont

        // Load persisted JSON, falling back to defaults; clamp on the way in.
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(Settings.self, from: data) {
            self.current = decoded.clamped()
        } else {
            self.current = .default
        }
    }

    // MARK: - Typed mutators

    func setEnabled(_ value: Bool) {
        mutate { $0.isEnabled = value }
    }

    func setBackend(_ value: Backend) {
        mutate { $0.backend = value }
    }

    func setOpenAI(_ value: OpenAISettings) {
        mutate { $0.openAI = value }
    }

    func setLengthPreset(_ value: LengthPreset) {
        mutate { $0.lengthPreset = value }
    }

    func setDebounceMilliseconds(_ value: Int) {
        mutate { $0.debounceMilliseconds = value }
    }

    func setFocusPollMilliseconds(_ value: Int) {
        mutate { $0.focusPollMilliseconds = value }
    }

    func setGhostTextColorHex(_ value: String?) {
        mutate { $0.ghostTextColorHex = value }
    }

    func setShowActivationIndicator(_ value: Bool) {
        mutate { $0.showActivationIndicator = value }
    }

    func addAppRule(_ rule: AppRule) {
        mutate { settings in
            var rules = settings.appRules.filter { $0.bundleID != rule.bundleID }
            rules.append(rule)
            settings.appRules = rules
        }
    }

    func removeAppRule(bundleID: String) {
        mutate { settings in
            settings.appRules = settings.appRules.filter { $0.bundleID != bundleID }
        }
    }

    // MARK: - API key (Keychain only)

    func apiKey() -> String? {
        keychain.read()
    }

    func setAPIKey(_ key: String?) {
        keychain.set(key)
    }

    // MARK: - Private

    /// Apply a mutation, clamp, persist to `UserDefaults`, and emit.
    private func mutate(_ body: (inout Settings) -> Void) {
        var next = current
        body(&next)
        let clamped = next.clamped()
        guard clamped != current else {
            // Still persist (e.g. first write) but skip an emit when unchanged.
            persist(clamped)
            return
        }
        current = clamped
        persist(clamped)
        continuation.yield(clamped)
    }

    private func persist(_ settings: Settings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
