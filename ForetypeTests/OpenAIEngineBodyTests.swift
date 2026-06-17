import Testing
import Foundation
@testable import Foretype

/// Tests for `OpenAIEngine.makeBody` (request shape) and `parseContent` (response
/// handling), focused on the reasoning-model fix: the request must disable model
/// "thinking", and a valid-but-content-less response must degrade to "" (no
/// suggestion) rather than a hard failure.
struct OpenAIEngineBodyTests {

    private func request(prompt: String = "Continue this:", maxTokens: Int = 48) -> CompletionRequest {
        CompletionRequest(
            generation: 1,
            precedingText: "",
            trailingText: "",
            appName: "TestApp",
            fieldRole: "AXTextField",
            surroundingContext: "",
            lengthHint: .medium,
            sampling: SamplingParameters(temperature: 0.2, maxTokens: maxTokens, topP: 0.95),
            prompt: prompt
        )
    }

    // MARK: - makeBody

    @Test func bodyDisablesThinking() {
        let body = OpenAIEngine.makeBody(model: "some-model", request: request())
        let kwargs = body["chat_template_kwargs"] as? [String: Any]
        #expect(kwargs?["enable_thinking"] as? Bool == false)
    }

    @Test func bodyCarriesModelAndSampling() {
        let body = OpenAIEngine.makeBody(model: "gemma-test", request: request(maxTokens: 24))
        #expect(body["model"] as? String == "gemma-test")
        #expect(body["max_tokens"] as? Int == 24)
        #expect(body["stream"] as? Bool == false)
    }

    @Test func bodyEncodesToJSON() throws {
        // The added field must not break JSON serialization.
        let body = OpenAIEngine.makeBody(model: "m", request: request())
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        #expect(!data.isEmpty)
    }

    // MARK: - parseContent

    @Test func parsesNormalContent() throws {
        let json = #"{"choices":[{"message":{"role":"assistant","content":"hello there"}}]}"#
        let out = try OpenAIEngine.parseContent(from: Data(json.utf8))
        #expect(out == "hello there")
    }

    @Test func reasoningOnlyResponseYieldsEmptyNotError() throws {
        // The bug: a reasoning model returned only `reasoning_content`, no `content`,
        // truncated at the token cap. This must NOT throw — it degrades to "".
        let json = #"""
        {"choices":[{"index":0,"message":{"role":"assistant","reasoning_content":"Thinking Process: 1. Analyze..."},"finish_reason":"length"}]}
        """#
        let out = try OpenAIEngine.parseContent(from: Data(json.utf8))
        #expect(out == "")
    }

    @Test func emptyContentYieldsEmptyNotError() throws {
        let json = #"{"choices":[{"message":{"role":"assistant","content":""}}]}"#
        let out = try OpenAIEngine.parseContent(from: Data(json.utf8))
        #expect(out == "")
    }

    @Test func malformedJSONThrows() {
        let data = Data("not json".utf8)
        #expect(throws: CompletionEngineError.self) {
            _ = try OpenAIEngine.parseContent(from: data)
        }
    }

    @Test func missingMessageThrows() {
        // A genuinely broken shape (no message) is still a real error.
        let json = #"{"choices":[{"index":0,"finish_reason":"stop"}]}"#
        #expect(throws: CompletionEngineError.self) {
            _ = try OpenAIEngine.parseContent(from: Data(json.utf8))
        }
    }
}
