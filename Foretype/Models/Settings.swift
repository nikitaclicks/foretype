import Foundation

/// Which generation backend is selected.
enum Backend: String, Codable, Sendable, CaseIterable {
    case appleIntelligence
    case openAICompatible
}

/// OpenAI-compatible endpoint configuration. The API key is **never** stored
/// here — it lives only in the Keychain (doc 10).
struct OpenAISettings: Equatable, Codable, Sendable {
    var baseURL: String   // e.g. "http://localhost:11434" or a remote host
    var model: String     // e.g. "qwen2.5-coder", "gpt-4o-mini"

    static let `default` = OpenAISettings(baseURL: "http://localhost:11434", model: "qwen2.5-coder")
}

/// Per-app rule mode. The global policy is a blocklist: allow everywhere except
/// apps explicitly blocked (doc 10).
enum AppRuleMode: String, Codable, Sendable {
    case block   // disable Foretype in this app
    case allow   // explicitly allow (meaningful only under an allowlist policy)
}

/// A per-app enable/disable rule, matched by bundle id (doc 10).
struct AppRule: Equatable, Codable, Sendable {
    let bundleID: String
    let mode: AppRuleMode
}

/// User-facing output length preset. Maps to a `LengthHint` and a `maxTokens`
/// ceiling (doc 06/10). Three presets is enough; labels stay human.
enum LengthPreset: String, Codable, Sendable, CaseIterable {
    case short   // 3–7 words
    case medium  // 7–12 words
    case long    // 12–20 words

    var hint: LengthHint {
        switch self {
        case .short: return .short
        case .medium: return .medium
        case .long: return .long
        }
    }

    /// Human label with word range, for the settings UI.
    var displayName: String {
        switch self {
        case .short: return "Short (3–7 words)"
        case .medium: return "Medium (7–12 words)"
        case .long: return "Long (12–20 words)"
        }
    }
}

/// The complete, persisted settings model (minus the API key). `SettingsStore`
/// is the single reader/writer (doc 10).
struct Settings: Equatable, Codable, Sendable {
    // Master controls
    var isEnabled: Bool
    var appRules: [AppRule]

    // Backend
    var backend: Backend
    var openAI: OpenAISettings

    // Output shape
    var lengthPreset: LengthPreset

    // Timing (clamped, e.g. 10…500)
    var debounceMilliseconds: Int
    var focusPollMilliseconds: Int

    // Appearance
    var ghostTextColorHex: String?   // nil → default secondary label color
    var showActivationIndicator: Bool

    static let `default` = Settings(
        isEnabled: true,
        appRules: [],
        backend: .appleIntelligence,
        openAI: .default,
        lengthPreset: .medium,
        debounceMilliseconds: 50,
        focusPollMilliseconds: 50,
        ghostTextColorHex: nil,
        showActivationIndicator: false
    )

    /// Clamp timing fields into their sane ranges (doc 10).
    func clamped() -> Settings {
        var copy = self
        copy.debounceMilliseconds = min(500, max(10, debounceMilliseconds))
        copy.focusPollMilliseconds = min(500, max(10, focusPollMilliseconds))
        return copy
    }
}
