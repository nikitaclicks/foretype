import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence completion engine (doc 07). Uses the on-device Foundation
/// Models system language model — private, offline, no network. Available only
/// on supported hardware/OS (macOS 26+); the engine reports its own
/// availability so the router and settings UI can reflect it.
///
/// A `final class` (not an actor): each request builds a fresh, short-lived
/// session, so there is no shared mutable state to protect. It is `Sendable`
/// because it carries no stored mutable state.
final class AppleIntelligenceEngine: CompletionEngine {

    init() {}

    /// Whether the on-device system model is usable right now. Checked at
    /// startup and when settings open; the router/UI use it to gate selecting
    /// this backend.
    static func isAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return true
            default:
                return false
            }
        } else {
            return false
        }
        #else
        return false
        #endif
    }

    // MARK: CompletionEngine

    func generate(_ request: CompletionRequest) async throws -> CompletionResult {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try await generateWithFoundationModels(request)
        } else {
            throw CompletionEngineError.unavailable(reason: "Apple Intelligence not available")
        }
        #else
        throw CompletionEngineError.unavailable(reason: "Apple Intelligence not available")
        #endif
    }

    func reset() async {
        // Each request already uses a fresh session; nothing to clear.
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func generateWithFoundationModels(_ request: CompletionRequest) async throws -> CompletionResult {
        // Availability gate: an unavailable model is a configuration/capability
        // problem the user must resolve (unsupported device, disabled, region).
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw CompletionEngineError.unavailable(reason: "Apple Intelligence unavailable: \(String(describing: reason))")
        @unknown default:
            throw CompletionEngineError.unavailable(reason: "Apple Intelligence not available")
        }

        try Task.checkCancellation()

        // Fresh, stateless session per request — no context bleeds across fields.
        // The instructions channel frames inline continuation; the prefix is the
        // prompt. (We send the assembled prompt, which already carries the
        // before/after-caret context and length instruction.)
        let instructions = Instructions(
            "You are an inline autocomplete engine. Continue the user's text naturally from where it stops. " +
            "Return ONLY the continuation text — no quotes, labels, restatement, or commentary. " +
            "Respect the requested length and stop at a natural boundary."
        )
        let session = LanguageModelSession(instructions: instructions)

        let options = GenerationOptions(
            temperature: request.sampling.temperature,
            maximumResponseTokens: request.sampling.maxTokens
        )

        let clock = ContinuousClock()
        let started = clock.now

        do {
            let response = try await session.respond(to: request.prompt, options: options)
            try Task.checkCancellation()
            let latency = started.duration(to: clock.now)
            return CompletionResult(text: response.content, latency: latency)
        } catch is CancellationError {
            throw CompletionEngineError.cancelled
        } catch let error as LanguageModelSession.GenerationError {
            // Unsupported-language / locale style problems are configuration
            // issues recoverable by another backend → unavailable. Everything
            // else is treated as a transient generation hiccup.
            switch error {
            case .unsupportedLanguageOrLocale:
                throw CompletionEngineError.unavailable(reason: "Unsupported language or locale for Apple Intelligence.")
            default:
                throw CompletionEngineError.generationFailed(reason: "Apple Intelligence generation failed: \(error.localizedDescription)")
            }
        } catch {
            throw CompletionEngineError.generationFailed(reason: "Apple Intelligence generation failed: \(error.localizedDescription)")
        }
    }
    #endif
}
