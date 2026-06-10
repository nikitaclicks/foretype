import Foundation

/// Turns a focus snapshot + settings into a fully-assembled `CompletionRequest`
/// (doc 06). PURE: identical inputs yield an identical prompt string — no
/// `UserDefaults`, no clock, no I/O. The "should we even ask?" gate lives in
/// `AvailabilityEvaluator`, not here; the builder assumes generation is warranted
/// and focuses solely on assembling a good request.
enum PromptBuilder {
    /// Build a `CompletionRequest` for the given snapshot/settings/generation.
    ///
    /// - Windows `precedingText` to its tail and `trailingText` to a short head
    ///   via `ContextWindowing`.
    /// - Windows `surroundingContext` to its budget via
    ///   `SurroundingContextWindowing`. This string is *gathered* by the
    ///   coordinator (an AX side effect); the builder only receives and windows
    ///   it so it stays pure (doc 06).
    /// - Maps `settings.lengthPreset.hint` to a natural-language length
    ///   instruction and `SamplingParameters` (temperature 0.2, topP 0.95,
    ///   maxTokens: short 24 / medium 48 / long 80).
    /// - Frames the task as inline continuation, instructing the model to return
    ///   ONLY the continuation.
    static func build(
        snapshot: FocusSnapshot,
        settings: Settings,
        generation: UInt64,
        surroundingContext: String = ""
    ) -> CompletionRequest {
        let precedingText = ContextWindowing.windowedPreceding(snapshot.precedingText)
        let trailingText = ContextWindowing.windowedTrailing(snapshot.trailingText)
        let surrounding = SurroundingContextWindowing.windowed(surroundingContext)

        let hint = settings.lengthPreset.hint
        let sampling = SamplingParameters(
            temperature: 0.2,
            maxTokens: maxTokens(for: hint),
            topP: 0.95
        )

        let appName = snapshot.appName
        let fieldRole = fieldRole(for: snapshot)

        let prompt = assemblePrompt(
            precedingText: precedingText,
            trailingText: trailingText,
            surroundingContext: surrounding,
            appName: appName,
            lengthInstruction: lengthInstruction(for: hint)
        )

        return CompletionRequest(
            generation: generation,
            precedingText: precedingText,
            trailingText: trailingText,
            appName: appName,
            fieldRole: fieldRole,
            surroundingContext: surrounding,
            lengthHint: hint,
            sampling: sampling,
            prompt: prompt
        )
    }

    // MARK: - Length mapping

    /// `maxTokens` ceiling derived from the length hint (doc 06).
    private static func maxTokens(for hint: LengthHint) -> Int {
        switch hint {
        case .short: return 24
        case .medium: return 48
        case .long: return 80
        }
    }

    /// Natural-language length instruction for the prompt (doc 06).
    private static func lengthInstruction(for hint: LengthHint) -> String {
        switch hint {
        case .short: return "about 3-7 words"
        case .medium: return "about 7-12 words"
        case .long: return "about 12-20 words"
        }
    }

    // MARK: - Field role hint

    /// A coarse AX role/subrole hint (e.g. text area vs. one-line field).
    private static func fieldRole(for snapshot: FocusSnapshot) -> String {
        if let subrole = snapshot.subrole, !subrole.isEmpty {
            return "\(snapshot.role)/\(subrole)"
        }
        return snapshot.role
    }

    // MARK: - Prompt assembly

    /// Single canonical prompt string framing inline continuation, not chat.
    /// The optional surrounding-context section is emitted ONLY when non-empty,
    /// so native / no-context cases produce a byte-identical prompt to before.
    /// It is placed before the caret context so the live text the model must
    /// continue stays physically last (the continuation target).
    private static func assemblePrompt(
        precedingText: String,
        trailingText: String,
        surroundingContext: String,
        appName: String,
        lengthInstruction: String
    ) -> String {
        var lines: [String] = []
        lines.append("You are an inline autocomplete engine. Continue the user's text naturally from the caret.")
        lines.append("SPACING: If the caret sits in the middle of a word, reproduce that whole in-progress word and continue it with NO leading space. If you are starting a NEW word, BEGIN your output with exactly one leading space.")
        lines.append("Examples (before caret -> your output):")
        lines.append("  \"I am tes\" -> \"testing autocomplete\"   (continues the in-progress word \"tes\"; no leading space)")
        lines.append("  \"I am testing\" -> \" autocomplete now\"    (new word; one leading space)")
        lines.append("  \"I am testing \" -> \"autocomplete now\"    (caret already after a space; no extra leading space)")
        lines.append("Return ONLY the continuation text — no quotes, no labels, no commentary, no code fences.")
        lines.append("Target length: \(lengthInstruction). Stop at a natural boundary.")
        lines.append("Application: \(appName).")
        lines.append("")
        if !surroundingContext.isEmpty {
            lines.append("Background context (read-only). The following is other content visible around the")
            lines.append("field the user is typing in — for example earlier messages in the conversation, a")
            lines.append("document, or a task's title and description. Use it only to understand the topic")
            lines.append("and intent. Do NOT continue it, quote it, summarize it, or repeat any of it.")
            lines.append("Continue ONLY the user's text at the caret below.")
            lines.append("")
            lines.append("Surrounding content:")
            lines.append(surroundingContext)
            lines.append("")
        }
        lines.append("Text before caret:")
        lines.append(precedingText)
        lines.append("")
        lines.append("Text after caret:")
        lines.append(trailingText)
        lines.append("")
        lines.append("Continuation:")
        return lines.joined(separator: "\n")
    }
}
