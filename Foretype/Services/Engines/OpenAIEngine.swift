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
            throw CompletionEngineError.generationFailed(reason: "Network error: \(urlError.localizedDescription)")
        } catch {
            throw CompletionEngineError.generationFailed(reason: "Request failed: \(error.localizedDescription)")
        }

        // If the request was cancelled while in flight, abandon it.
        try Task.checkCancellation()

        let latency = started.duration(to: clock.now)

        guard let http = response as? HTTPURLResponse else {
            throw CompletionEngineError.generationFailed(reason: "Non-HTTP response")
        }

        switch http.statusCode {
        case 200..<300:
            let text = try Self.parseContent(from: data)
            return CompletionResult(text: text, latency: latency)
        case 400..<500:
            // Configuration problem the user must fix (bad key, wrong path,
            // unknown model). Surfaced as `disabled` by the coordinator.
            throw CompletionEngineError.unavailable(
                reason: "Endpoint returned HTTP \(http.statusCode). Check the base URL, model, and API key."
            )
        default:
            // 5xx and anything else: transient.
            throw CompletionEngineError.generationFailed(reason: "Endpoint returned HTTP \(http.statusCode).")
        }
    }

    func reset() async {
        // HTTP is stateless per request; nothing to clear.
    }

    // MARK: Request construction

    private func makeURLRequest(for request: CompletionRequest) throws -> URLRequest {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop a trailing slash so we don't produce "//v1/...".
        let normalizedBase = trimmedBase.hasSuffix("/") ? String(trimmedBase.dropLast()) : trimmedBase

        guard !normalizedBase.isEmpty,
              let url = URL(string: normalizedBase + "/v1/chat/completions") else {
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
        ]
    }

    /// Pure helper: pull `choices[0].message.content` out of a chat-completions
    /// response. Throws `generationFailed` if the shape is missing/empty.
    static func parseContent(from data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CompletionEngineError.generationFailed(reason: "Malformed response JSON.")
        }
        guard
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw CompletionEngineError.generationFailed(reason: "Response missing choices[0].message.content.")
        }
        return content
    }
}
