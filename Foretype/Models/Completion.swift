import Foundation

/// Desired output length. Maps to a natural-language instruction and a
/// `maxTokens` ceiling (doc 06).
enum LengthHint: Equatable, Sendable {
    case short   // ~3–7 words
    case medium  // ~7–12 words
    case long    // ~12–20 words
}

/// Generation knobs. Defaults favor determinism — inline autocomplete should be
/// steady, not creative. These are constants in code, not user-facing (doc 06).
struct SamplingParameters: Equatable, Sendable {
    let temperature: Double
    let maxTokens: Int
    let topP: Double
}

/// Everything an engine needs to produce a continuation. Assembled by the pure
/// `PromptBuilder` (doc 06). Carries both component fields and a fully-assembled
/// `prompt` so engines are not forced to parse the string.
struct CompletionRequest: Equatable, Sendable {
    /// Freshness token (doc 05). Bound to focus identity + content at request time.
    let generation: UInt64

    // Context
    let precedingText: String
    let trailingText: String
    let appName: String
    let fieldRole: String
    /// Bounded, read-only background content read from the accessibility tree
    /// *around* the focused field (e.g. a ClickUp task title, description, or
    /// earlier comments). Empty when none is available or the field is not a
    /// multi-line composer. Never the continuation target (doc 06).
    let surroundingContext: String

    // Shape of the desired output
    let lengthHint: LengthHint
    let sampling: SamplingParameters

    // The fully assembled prompt engines may use as-is.
    let prompt: String
}

/// Raw engine output plus measured latency. Normalization happens later, in the
/// coordinator-side `CompletionTextNormalizer` (doc 07).
struct CompletionResult: Equatable, Sendable {
    let text: String        // raw model output, pre-normalization
    let latency: Duration   // measured round-trip, for diagnostics
}

/// A single completion being consumed incrementally. The user advances it word
/// by word (`Tab`) or by typing matching characters (doc 05).
struct ActiveSession: Equatable, Sendable {
    let fullText: String        // normalized completion as generated
    var consumedCount: Int      // characters already inserted / typed-through

    init(fullText: String, consumedCount: Int = 0) {
        self.fullText = fullText
        self.consumedCount = consumedCount
    }

    /// The not-yet-accepted tail; this is what ghost text displays.
    var remainder: String {
        let chars = Array(fullText)
        guard consumedCount >= 0, consumedCount < chars.count else { return "" }
        return String(chars[consumedCount...])
    }

    /// Whether the session has any non-whitespace text left to show.
    var isExhausted: Bool {
        remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Why completions are currently off. Surfaced in the menu bar (doc 05).
enum DisabledReason: Equatable, Sendable {
    case permissionMissing
    case fieldUnsupported
    case fieldSecure
    case appDisabledByRule
    case globallyOff
    case backendUnavailable
}

/// The single observable state of the completion pipeline. The coordinator is
/// the only writer; UI observes (doc 05).
enum CompletionState: Equatable, Sendable {
    case idle                          // focused & ready, nothing pending
    case disabled(reason: DisabledReason)
    case debouncing                    // waiting for typing to settle
    case generating                    // engine call in flight
    case previewing(ActiveSession)     // ghost text shown, session active
    case failed(reason: String)        // last generation errored
}
