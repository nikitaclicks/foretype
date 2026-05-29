import Foundation

/// Routes `generate`/`reset` to the concrete engine selected in settings
/// (doc 07). Itself a `CompletionEngine`, so the coordinator never branches on
/// backend type — all backend selection lives here.
///
/// An `actor` because it holds the currently-selected backend and the latest
/// OpenAI configuration, mutated whenever settings change.
actor EngineRouter: CompletionEngine {

    private let openAI: OpenAIEngine
    private let appleIntelligence: AppleIntelligenceEngine

    private var backend: Backend = .appleIntelligence
    /// Whether an OpenAI endpoint is configured well enough to be a fallback.
    private var openAIConfigured: Bool = false

    init(openAI: OpenAIEngine, appleIntelligence: AppleIntelligenceEngine) {
        self.openAI = openAI
        self.appleIntelligence = appleIntelligence
    }

    /// Apply the latest settings: select the backend and reconfigure the OpenAI
    /// engine in place (no rebuild). The API key is passed separately since it
    /// is never stored in `Settings`.
    func updateSettings(_ settings: Settings, apiKey: String?) async {
        backend = settings.backend

        let baseURL = settings.openAI.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.openAI.model.trimmingCharacters(in: .whitespacesAndNewlines)
        openAIConfigured = !baseURL.isEmpty && !model.isEmpty

        await openAI.configure(baseURL: settings.openAI.baseURL, model: settings.openAI.model, apiKey: apiKey)
    }

    // MARK: CompletionEngine

    func generate(_ request: CompletionRequest) async throws -> CompletionResult {
        switch backend {
        case .openAICompatible:
            return try await openAI.generate(request)

        case .appleIntelligence:
            do {
                return try await appleIntelligence.generate(request)
            } catch let error as CompletionEngineError {
                // Optional fallback: Apple Intelligence reported `unavailable`
                // (e.g. unsupported language) and an OpenAI endpoint is
                // configured → fall back to it. Otherwise propagate so the
                // coordinator shows a clear `disabled` reason.
                if case .unavailable = error, openAIConfigured {
                    return try await openAI.generate(request)
                }
                throw error
            }
        }
    }

    func reset() async {
        // Reset both so a backend switch never leaves stale state behind.
        await openAI.reset()
        await appleIntelligence.reset()
    }
}
