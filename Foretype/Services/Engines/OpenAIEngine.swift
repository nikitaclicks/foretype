import Foundation

/// OpenAI-compatible HTTP completion engine (doc 07). Talks to any endpoint
/// implementing `POST {baseURL}/v1/chat/completions` — local servers (Ollama,
/// MLX) or remote providers. Non-streaming, stateless per request.
///
/// An `actor` because it holds mutable configuration (base URL / model / key)
/// that the router updates as settings change, and because engines run off the
/// main actor.
actor OpenAIEngine: CompletionEngine {

    // MARK: Configuration

    private var baseURL: String = ""
    private var model: String = ""
    private var apiKey: String?

    /// Dedicated session with a bounded request timeout so a hung endpoint
    /// cannot wedge the pipeline.
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// Reconfigure the endpoint. Called by the router when settings change.
    func configure(baseURL: String, model: String, apiKey: String?) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    // MARK: CompletionEngine

    func generate(_ request: CompletionRequest) async throws -> CompletionResult {
        try Task.checkCancellation()

        let urlRequest = try makeURLRequest(for: request)
        let host = urlRequest.url?.host ?? "?"

        let clock = ContinuousClock()
        let started = clock.now

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw CompletionEngineError.cancelled
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CompletionEngineError.cancelled
        } catch let urlError as URLError {
            // Transport errors and timeouts are transient.
            Self.genDiag("evt=net host=\(host) code=\(urlError.code.rawValue) desc=\"\(urlError.localizedDescription)\"")
            throw CompletionEngineError.generationFailed(reason: "Network error: \(urlError.localizedDescription)")
        } catch {
            Self.genDiag("evt=net host=\(host) code=? desc=\"\(error.localizedDescription)\"")
            throw CompletionEngineError.generationFailed(reason: "Request failed: \(error.localizedDescription)")
        }

        // If the request was cancelled while in flight, abandon it.
        try Task.checkCancellation()

        let latency = started.duration(to: clock.now)

        guard let http = response as? HTTPURLResponse else {
            Self.genDiag("evt=non-http host=\(host) body=\"\(Self.bodySnippet(data))\"")
            throw CompletionEngineError.generationFailed(reason: "Non-HTTP response")
        }

        switch http.statusCode {
        case 200..<300:
            let text = try Self.parseContent(from: data)
            return CompletionResult(text: text, latency: latency)
        case 400..<500:
            // Configuration problem the user must fix (bad key, wrong path,
            // unknown model). Surfaced as `disabled` by the coordinator.
            Self.genDiag("evt=http host=\(host) status=\(http.statusCode) body=\"\(Self.bodySnippet(data))\"")
            throw CompletionEngineError.unavailable(
                reason: "Endpoint returned HTTP \(http.statusCode). Check the base URL, model, and API key."
            )
        default:
            // 5xx and anything else: transient.
            Self.genDiag("evt=http host=\(host) status=\(http.statusCode) body=\"\(Self.bodySnippet(data))\"")
            throw CompletionEngineError.generationFailed(reason: "Endpoint returned HTTP \(http.statusCode).")
        }
    }

    func reset() async {
        // HTTP is stateless per request; nothing to clear.
    }

    // MARK: Request construction

    private func makeURLRequest(for request: CompletionRequest) throws -> URLRequest {
        guard let urlString = Self.chatCompletionsURLString(base: baseURL),
              let url = URL(string: urlString) else {
            throw CompletionEngineError.unavailable(reason: "Invalid base URL.")
        }

        let body = Self.makeBody(model: model, request: request)
        let encoded: Data
        do {
            encoded = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw CompletionEngineError.generationFailed(reason: "Failed to encode request.")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = encoded

        if let key = apiKey, !key.trimmingCharacters(in: .whitespaces).isEmpty {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        return urlRequest
    }

    /// Pure helper: resolve the chat-completions endpoint from a user-supplied
    /// base URL, tolerating the common variations people actually enter:
    ///   "http://host:8000"               → http://host:8000/v1/chat/completions
    ///   "http://host:8000/"              → http://host:8000/v1/chat/completions
    ///   "http://host:8000/v1"            → http://host:8000/v1/chat/completions
    ///   "http://host:8000/v1/"           → http://host:8000/v1/chat/completions
    ///   "http://host:8000/v1/chat/completions" → unchanged
    /// Avoids the doubled "/v1/v1/..." that yields a 404. Returns nil if empty.
    static func chatCompletionsURLString(base: String) -> String? {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return nil }

        if s.hasSuffix("/chat/completions") { return s }
        if s.hasSuffix("/v1") { return s + "/chat/completions" }
        return s + "/v1/chat/completions"
    }

    /// Pure helper: build the chat-completions JSON body. Factored out so the
    /// encoding is easy to reason about / test independently of the network.
    static func makeBody(model: String, request: CompletionRequest) -> [String: Any] {
        let systemMessage =
            "You are an inline autocomplete engine. Continue the user's text naturally. " +
            "Return ONLY the continuation text — no quotes, labels, or commentary."

        return [
            "model": model,
            "messages": [
                ["role": "system", "content": systemMessage],
                ["role": "user", "content": request.prompt],
            ],
            "temperature": request.sampling.temperature,
            "max_tokens": request.sampling.maxTokens,
            "top_p": request.sampling.topP,
            "stream": false,
            // Disable model "thinking"/reasoning. Reasoning models (Qwen3, and the
            // reasoning-parser servers wrapping Gemma etc.) otherwise emit a
            // chain-of-thought into `reasoning_content` and, on the small token
            // budget an autocomplete uses, get truncated (`finish_reason: length`)
            // before producing any `content` — yielding empty completions. This is
            // the chat-template flag honored by vLLM / SGLang / MLX servers; other
            // OpenAI-compatible servers ignore the unknown field harmlessly. The
            // defensive parse in `parseContent` covers servers that don't honor it.
            "chat_template_kwargs": ["enable_thinking": false],
        ]
    }

    /// Pure helper: pull `choices[0].message.content` out of a chat-completions
    /// response. Throws `generationFailed` only when the response shape is genuinely
    /// malformed (not valid JSON, or no `choices[0].message`).
    ///
    /// A *valid* response whose `content` is missing or empty is NOT an error: it
    /// happens when a reasoning model spends its whole token budget on
    /// `reasoning_content` (`finish_reason: length`) and never emits content. We
    /// return "" so the coordinator treats it as "no suggestion" (silent) rather
    /// than surfacing a red failure. `chat_template_kwargs.enable_thinking=false`
    /// in `makeBody` prevents this on servers that honor it; this is the safety net
    /// for those that don't.
    static func parseContent(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            genDiag("evt=parse detail=malformed-json body=\"\(bodySnippet(data))\"")
            throw CompletionEngineError.generationFailed(reason: "Malformed response JSON.")
        }
        guard
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else {
            genDiag("evt=parse detail=malformed-shape body=\"\(bodySnippet(data))\"")
            throw CompletionEngineError.generationFailed(reason: "Response missing choices[0].message.")
        }
        guard let content = message["content"] as? String, !content.isEmpty else {
            // Valid response, but no usable content (reasoning-only / truncated).
            genDiag("evt=parse detail=empty-content body=\"\(bodySnippet(data))\"")
            return ""
        }
        return content
    }

    // MARK: - Diagnostics (temporary; gated on the `genDiag` UserDefaults flag)

    /// Append a line to `/tmp/foretype-gendiag.log`, gated on the `genDiag`
    /// UserDefaults flag (mirrors `CompletionCoordinator.ctxDiag`). Captures the
    /// raw OpenAI failure detail — HTTP status + response body, network error code,
    /// or parse failure — that the thrown `CompletionEngineError` discards. Logs
    /// only the response body and request host: never the API key or request body.
    /// Remove once the failure path is understood.
    static func genDiag(_ message: String) {
        guard UserDefaults.standard.bool(forKey: "genDiag") else { return }
        let timestamp = diagDateFormatter.string(from: Date())
        guard let data = ("[engine] \(timestamp) \(message)\n").data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/foretype-gendiag.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private static let diagDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// A short, single-line snippet of a response body for diagnostics: decoded as
    /// UTF-8, newlines collapsed, capped to `limit` characters.
    static func bodySnippet(_ data: Data, limit: Int = 400) -> String {
        guard var s = String(data: data, encoding: .utf8) else { return "<non-utf8 \(data.count)B>" }
        s = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        if s.count > limit { s = String(s.prefix(limit)) + "…" }
        return s
    }
}
