import Testing
@testable import Foretype

/// The chat-completions URL resolver must tolerate the base-URL variations users
/// actually type — especially an included `/v1`, which previously produced a
/// doubled `/v1/v1/chat/completions` and a 404.
struct OpenAIEngineURLTests {
    private let endpoint = "/v1/chat/completions"

    @Test func bareHostGetsV1ChatCompletions() {
        #expect(OpenAIEngine.chatCompletionsURLString(base: "http://127.0.0.1:8000")
                == "http://127.0.0.1:8000\(endpoint)")
    }

    @Test func trailingSlashIsHandled() {
        #expect(OpenAIEngine.chatCompletionsURLString(base: "http://127.0.0.1:8000/")
                == "http://127.0.0.1:8000\(endpoint)")
    }

    @Test func includedV1IsNotDoubled() {
        // The reported bug: base already ends in /v1.
        #expect(OpenAIEngine.chatCompletionsURLString(base: "http://127.0.0.1:8000/v1")
                == "http://127.0.0.1:8000\(endpoint)")
    }

    @Test func includedV1WithTrailingSlash() {
        #expect(OpenAIEngine.chatCompletionsURLString(base: "http://127.0.0.1:8000/v1/")
                == "http://127.0.0.1:8000\(endpoint)")
    }

    @Test func fullPathIsLeftUnchanged() {
        let full = "http://127.0.0.1:8000/v1/chat/completions"
        #expect(OpenAIEngine.chatCompletionsURLString(base: full) == full)
    }

    @Test func remoteHostWithV1() {
        #expect(OpenAIEngine.chatCompletionsURLString(base: "https://api.openai.com/v1")
                == "https://api.openai.com\(endpoint)")
    }

    @Test func whitespaceTrimmed() {
        #expect(OpenAIEngine.chatCompletionsURLString(base: "  http://localhost:11434  ")
                == "http://localhost:11434\(endpoint)")
    }

    @Test func emptyReturnsNil() {
        #expect(OpenAIEngine.chatCompletionsURLString(base: "   ") == nil)
        #expect(OpenAIEngine.chatCompletionsURLString(base: "") == nil)
    }
}
