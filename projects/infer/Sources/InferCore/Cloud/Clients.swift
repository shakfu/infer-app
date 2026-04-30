import Foundation

/// Common message type for cloud providers. Roles match the wire format for
/// both OpenAI (chat.completions) and Anthropic (messages) — anthropic drops
/// `system` from the list and moves it to a top-level field at send time.
public struct CloudChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user, assistant }
    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public enum CloudError: Error, LocalizedError, Equatable {
    case notConfigured
    case missingKey
    case invalidEndpoint
    case invalidResponse
    case http(status: Int, body: String)
    case decodingFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Cloud backend not configured"
        case .missingKey: return "No API key set for this provider"
        case .invalidEndpoint:
            return "Endpoint URL must use https:// (or http://localhost for local runtimes)"
        case .invalidResponse: return "Unexpected response from cloud provider"
        case .http(let s, let b):
            // Body may contain structured error JSON; truncate so a giant
            // payload doesn't overflow the UI. Body has already been
            // scrubbed of any leading-bytes match against the API key
            // (see `CloudClients.checkHTTP`).
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
public protocol CloudClient: Sendable {
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
///
/// Also serves the `.openaiCompatible` provider — same wire format, just a
/// different `baseURL`. That's why `baseURL` is a public init parameter
/// rather than locked down: it's load-bearing for compat support, not
/// just a test seam. For canonical OpenAI the runner passes the default.
public struct OpenAIClient: CloudClient {
    public let apiKey: String
    public let baseURL: URL
    public let session: URLSession

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.openai.com")!,
        session: URLSession = CloudClients.sharedSession
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    public func streamChat(
        messages: [CloudChatMessage],
        model: String,
        temperature: Double,
        topP: Double,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        let apiKey = self.apiKey
        let baseURL = self.baseURL
        let session = self.session
        return AsyncThrowingStream { continuation in
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
                        // o-series and GPT-5 reject `max_tokens` outright;
                        // `max_completion_tokens` is accepted by all current
                        // chat-completions models, so use it unconditionally.
                        "max_completion_tokens": maxTokens,
                        "messages": messages.map {
                            ["role": $0.role.rawValue, "content": $0.content]
                        },
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: req)
                    try Task.checkCancellation()
                    try await CloudClients.checkHTTP(
                        response: response,
                        bytes: bytes,
                        apiKey: apiKey
                    )

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
/// `role: system`) and emits typed SSE events. We only need
/// `content_block_delta` with `delta.type == "text_delta"`.
///
/// `baseURL` is exposed for tests; **do not** route user input here for
/// canonical Anthropic. Bedrock / Vertex use entirely different auth
/// (AWS SigV4, GCP service accounts) and need separate adapter types,
/// not a base-URL swap.
public struct AnthropicClient: CloudClient {
    public let apiKey: String
    public let baseURL: URL
    public let session: URLSession
    public let version: String

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        session: URLSession = CloudClients.sharedSession,
        version: String = "2023-06-01"
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.version = version
    }

    public func streamChat(
        messages: [CloudChatMessage],
        model: String,
        temperature: Double,
        topP: Double,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        let apiKey = self.apiKey
        let baseURL = self.baseURL
        let session = self.session
        let version = self.version
        return AsyncThrowingStream { continuation in
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

                    // Anthropic rejects sending both `temperature` and
                    // `top_p` for Claude 4.x models. We send `temperature`
                    // only; `topP` is intentionally ignored here until the
                    // UI grows a segmented "which sampler" control.
                    _ = topP
                    var body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "temperature": temperature,
                        "max_tokens": maxTokens,
                        "messages": convo,
                    ]
                    if let s = systemText, !s.isEmpty {
                        body["system"] = s
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: req)
                    try Task.checkCancellation()
                    try await CloudClients.checkHTTP(
                        response: response,
                        bytes: bytes,
                        apiKey: apiKey
                    )

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

public enum CloudClients {
    /// Shared URLSession tuned for streaming SSE: no response caching, and a
    /// generous per-resource timeout since long completions naturally exceed
    /// the default 60s when many tokens are requested.
    public static let sharedSession: URLSession = {
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
    ///
    /// Belt-and-suspenders against an upstream that mirrors request data
    /// in errors: the body is scrubbed of any literal `apiKey` substring
    /// before being included in the thrown error. OpenAI and Anthropic
    /// don't echo auth headers today, but the cost of scrubbing is
    /// negligible and removes the dependency on provider goodwill.
    public static func checkHTTP(
        response: URLResponse,
        bytes: URLSession.AsyncBytes,
        apiKey: String
    ) async throws {
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
        throw CloudError.http(status: http.statusCode, body: scrubKey(from: body, apiKey: apiKey))
    }

    /// Replace any occurrence of `apiKey` (or its first 8 chars, to catch
    /// providers that echo a truncated form) with `***`. Runs only on the
    /// error path, so the cost is in the noise. Key is required to be ≥ 12
    /// chars before partial scrubbing kicks in — short test keys would
    /// otherwise collide with arbitrary 4-char substrings.
    static func scrubKey(from body: String, apiKey: String) -> String {
        guard !apiKey.isEmpty else { return body }
        var out = body.replacingOccurrences(of: apiKey, with: "***")
        if apiKey.count >= 12 {
            let prefix = String(apiKey.prefix(8))
            out = out.replacingOccurrences(of: prefix, with: "***")
        }
        return out
    }
}
