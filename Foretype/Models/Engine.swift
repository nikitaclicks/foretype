import Foundation

/// Why an engine could not produce a completion. The distinction drives
/// coordinator state: `unavailable` → `disabled` (user must fix configuration);
/// `generationFailed` → `failed` (transient, retry on next keystroke). See doc 07.
enum CompletionEngineError: Error, Equatable {
    case unavailable(reason: String)
    case generationFailed(reason: String)
    case cancelled
}

/// Turns a `CompletionRequest` into completion text. Two concrete engines exist
/// (Apple Intelligence, OpenAI-compatible HTTP) plus a router; the coordinator
/// only ever knows this protocol (doc 07).
protocol CompletionEngine: Sendable {
    /// Generate a continuation. Must support cooperative cancellation because
    /// the coordinator cancels superseded work.
    func generate(_ request: CompletionRequest) async throws -> CompletionResult

    /// Clear any per-context backend state. No-op for stateless engines.
    func reset() async
}
