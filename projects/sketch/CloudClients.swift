import Foundation

/// Common message type for cloud providers. Roles match the wire format for
/// both OpenAI (chat.completions) and Anthropic (messages) — anthropic drops
/// `system` from the list and moves it to a top-level field at send time.
struct CloudChatMessage: Sendable, Equatable {
    enum Role: String, Sendable { case system, user, assistant }
    let role: Role
    let content: String
}

enum CloudError: Error, LocalizedError {
    case notConfigured
    case missingKey
    case invalidResponse
    case http(status: Int, body: String)
    case decodingFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Cloud backend not configured"
        case .missingKey: return "No API key set for this provider"
        case .invalidResponse: return "Unexpected response from cloud provider"
        case .http(let s, let b):
            // Body may contain structured error JSON; truncate so a giant
            // payload doesn't overflow the UI. Never leaks the API key
            // because request headers are not echoed back.
            let trimmed = b.count > 400 ? String(b.prefix(400)) + "…" : b
            return "HTTP \(s): \(trimmed)"
        case .decodingFailed(let d): return "Decode error: \(d)"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Minimal interface both providers implement. Concrete types differ in how
/// they format the request body and parse the SSE stream; the runner only
/// cares about the streaming text deltas.
protocol CloudClient: Sendable {
    func streamChat(
        messages: [CloudChatMessage],
        model: String,
        temperature: Double,
        topP: Double,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error>
}

// MARK: - OpenAI

/// Streams `chat.completions` with `stream: true`. Parses SSE lines of the
/// form `data: {json}` and yields `choices[0].delta.content`.
struct OpenAIClient: CloudClient {
    let apiKey: String
    let baseURL: URL
    let session: URLSession

    init(apiKey: String,
         baseURL: URL = URL(string: "https://api.openai.com")!,
         session: URLSession = CloudClients.sharedSession) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    func streamChat(
        messages: [CloudChatMessage],
        model: String,
        temperature: Double,
        topP: Double,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = baseURL.appendingPathComponent("/v1/chat/completions")
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 60
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "temperature": temperature,
                        "top_p": topP,
                        // Both names accepted by recent OpenAI SKUs; max_tokens
                        // is the legacy one, max_completion_tokens is preferred
                        // for o-series models. Send the legacy one — chat
                        // completions still accepts it everywhere.
                        "max_tokens": maxTokens,
                        "messages": messages.map {
                            ["role": $0.role.rawValue, "content": $0.content]
                        },
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: req)
                    try Task.checkCancellation()
                    try await CloudClients.checkHTTP(response: response, bytes: bytes)

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = obj["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let text = delta["content"] as? String,
                              !text.isEmpty
                        else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CloudError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

// MARK: - Anthropic

/// Streams the `/v1/messages` endpoint. Unlike OpenAI, Anthropic takes the
/// system prompt as a top-level `system` field (not a message with
/// `role: system`) and emits typed SSE events. We only need `content_block_delta`
/// with `delta.type == "text_delta"`.
struct AnthropicClient: CloudClient {
    let apiKey: String
    let baseURL: URL
    let session: URLSession
    let version: String

    init(apiKey: String,
         baseURL: URL = URL(string: "https://api.anthropic.com")!,
         session: URLSession = CloudClients.sharedSession,
         version: String = "2023-06-01") {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.version = version
    }

    func streamChat(
        messages: [CloudChatMessage],
        model: String,
        temperature: Double,
        topP: Double,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = baseURL.appendingPathComponent("/v1/messages")
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 60
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    req.setValue(version, forHTTPHeaderField: "anthropic-version")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    // Split: system prompt goes to top-level; user/assistant
                    // become the messages array. Anthropic rejects a `system`
                    // role inside messages.
                    let systemText = messages.first(where: { $0.role == .system })?.content
                    let convo = messages.filter { $0.role != .system }.map {
                        ["role": $0.role.rawValue, "content": $0.content]
                    }

                    var body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "temperature": temperature,
                        "top_p": topP,
                        "max_tokens": maxTokens,
                        "messages": convo,
                    ]
                    if let s = systemText, !s.isEmpty {
                        body["system"] = s
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: req)
                    try Task.checkCancellation()
                    try await CloudClients.checkHTTP(response: response, bytes: bytes)

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        guard let data = payload.data(using: .utf8),
                              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = obj["type"] as? String
                        else { continue }
                        switch type {
                        case "content_block_delta":
                            if let delta = obj["delta"] as? [String: Any],
                               let dtype = delta["type"] as? String,
                               dtype == "text_delta",
                               let text = delta["text"] as? String,
                               !text.isEmpty {
                                continuation.yield(text)
                            }
                        case "message_stop":
                            break  // fall through; stream closes after this event
                        case "error":
                            let msg = (obj["error"] as? [String: Any])?["message"] as? String
                                ?? "Anthropic stream error"
                            throw CloudError.decodingFailed(msg)
                        default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CloudError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

// MARK: - Shared helpers

enum CloudClients {
    /// Shared URLSession tuned for streaming SSE: no response caching, and a
    /// generous per-resource timeout since long completions naturally exceed
    /// the default 60s when many tokens are requested.
    static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    /// Verify a 2xx response, otherwise drain the body (bounded) and surface
    /// as a `CloudError.http`. Runs before the SSE reader begins yielding —
    /// callers treat a throw here as a terminal stream error.
    static func checkHTTP(response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else {
            throw CloudError.invalidResponse
        }
        if (200..<300).contains(http.statusCode) { return }

        var data = Data()
        let cap = 4096
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= cap { break }
            }
        } catch {
            // If body read fails we still want the status code surfaced.
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        throw CloudError.http(status: http.statusCode, body: body)
    }
}
