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

/// Carrier for everything `streamChat` needs beyond messages + model. Lets
/// the protocol grow new sampling / generation knobs without breaking every
/// adapter signature. Each provider client picks the subset that applies and
/// silently ignores the rest (e.g. Anthropic ignores `seed`,
/// `reasoningEffort`; OpenAI ignores `thinkingBudgetTokens`).
///
/// Field semantics that are *non-obvious* are commented inline. Per-provider
/// guards (model-id whitelisting for `reasoningEffort` / `verbosity`,
/// `temperature` clamp when `thinkingBudgetTokens` is set) live in the
/// concrete client `streamChat` implementations — the runner just forwards
/// the user's preferences and doesn't try to second-guess.
public struct CloudGenerationParams: Sendable, Equatable {
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int

    // Tier 1
    /// OpenAI only. Anthropic has no equivalent and ignores the value.
    public var seed: UInt64?
    /// Maps to `stop` (OpenAI) / `stop_sequences` (Anthropic). Empty array
    /// = omit the field.
    public var stopSequences: [String]
    /// Anthropic-only "extended thinking" budget. `nil` = omit. When set,
    /// the Anthropic client forces `temperature = 1.0` (the API rejects
    /// non-default temperature combined with thinking).
    public var thinkingBudgetTokens: Int?

    // Tier 2
    /// OpenAI o-series + gpt-5 only. The OpenAI client checks the model id
    /// before attaching — passing this with a non-reasoning model is a
    /// no-op, not an error.
    public var reasoningEffort: ReasoningEffort?
    /// OpenAI: forwarded as `prompt_cache_key`. Anthropic uses a different
    /// `cache_control` mechanism, gated by `anthropicPromptCaching` below.
    public var promptCacheKey: String?
    /// Anthropic-only flag. When true, the Anthropic client tags the
    /// system prompt with `cache_control: { type: "ephemeral" }` so the
    /// re-sent system prefix is billed at the cached rate.
    public var anthropicPromptCaching: Bool

    // Tier 3
    /// OpenAI gpt-5 only. Controls response length.
    public var verbosity: Verbosity?
    /// OpenAI only. `nil` = omit.
    public var frequencyPenalty: Double?
    /// OpenAI only. `nil` = omit.
    public var presencePenalty: Double?
    /// Provider-specific values — OpenAI accepts `auto|default|flex|scale|priority`,
    /// Anthropic accepts `auto|standard_only`. Stored as a String because
    /// the two enums don't unify; each client forwards as-is and the
    /// provider rejects anything it doesn't recognise.
    public var serviceTier: String?

    public enum ReasoningEffort: String, Sendable, Equatable, CaseIterable {
        case none, minimal, low, medium, high, xhigh
    }

    public enum Verbosity: String, Sendable, Equatable, CaseIterable {
        case low, medium, high
    }

    public init(
        temperature: Double = 0.8,
        topP: Double = 0.95,
        maxTokens: Int = 512,
        seed: UInt64? = nil,
        stopSequences: [String] = [],
        thinkingBudgetTokens: Int? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        promptCacheKey: String? = nil,
        anthropicPromptCaching: Bool = false,
        verbosity: Verbosity? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        serviceTier: String? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.seed = seed
        self.stopSequences = stopSequences
        self.thinkingBudgetTokens = thinkingBudgetTokens
        self.reasoningEffort = reasoningEffort
        self.promptCacheKey = promptCacheKey
        self.anthropicPromptCaching = anthropicPromptCaching
        self.verbosity = verbosity
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.serviceTier = serviceTier
    }
}

/// Minimal interface both providers implement. Concrete types differ in how
/// they format the request body and parse the SSE stream; the runner only
/// cares about the streaming text deltas.
public protocol CloudClient: Sendable {
    func streamChat(
        messages: [CloudChatMessage],
        model: String,
        params: CloudGenerationParams
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

    /// Reasoning-effort capable: o-series and gpt-5.x.
    private static func supportsReasoningEffort(_ modelId: String) -> Bool {
        let lc = modelId.lowercased()
        return lc.hasPrefix("o1") || lc.hasPrefix("o3") || lc.hasPrefix("o4")
            || lc.hasPrefix("gpt-5")
    }

    /// Verbosity is documented for the gpt-5 family only. Older models
    /// reject the parameter; reasoning-only o-series doesn't accept it
    /// either.
    private static func supportsVerbosity(_ modelId: String) -> Bool {
        modelId.lowercased().hasPrefix("gpt-5")
    }

    public func streamChat(
        messages: [CloudChatMessage],
        model: String,
        params: CloudGenerationParams
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

                    var body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "temperature": params.temperature,
                        "top_p": params.topP,
                        // o-series and GPT-5 reject `max_tokens` outright;
                        // `max_completion_tokens` is accepted by all current
                        // chat-completions models, so use it unconditionally.
                        "max_completion_tokens": params.maxTokens,
                        "messages": messages.map {
                            ["role": $0.role.rawValue, "content": $0.content]
                        },
                    ]
                    if let seed = params.seed {
                        // OpenAI's `seed` is documented as int64; cast through
                        // a clamp so a UInt64 above Int64.max doesn't overflow
                        // the JSONSerialization path silently.
                        body["seed"] = Int(min(seed, UInt64(Int64.max)))
                    }
                    if !params.stopSequences.isEmpty {
                        // OpenAI accepts up to 4 stop sequences. Trim the
                        // tail so we don't 400 on an over-eager UI.
                        body["stop"] = Array(params.stopSequences.prefix(4))
                    }
                    if let effort = params.reasoningEffort,
                       Self.supportsReasoningEffort(model) {
                        body["reasoning_effort"] = effort.rawValue
                    }
                    if let verbosity = params.verbosity,
                       Self.supportsVerbosity(model) {
                        body["verbosity"] = verbosity.rawValue
                    }
                    if let fp = params.frequencyPenalty {
                        body["frequency_penalty"] = fp
                    }
                    if let pp = params.presencePenalty {
                        body["presence_penalty"] = pp
                    }
                    if let tier = params.serviceTier, !tier.isEmpty {
                        body["service_tier"] = tier
                    }
                    if let cacheKey = params.promptCacheKey, !cacheKey.isEmpty {
                        body["prompt_cache_key"] = cacheKey
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
        params: CloudGenerationParams
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
                    let convo: [[String: Any]] = messages
                        .filter { $0.role != .system }
                        .map { ["role": $0.role.rawValue, "content": $0.content] }

                    // Anthropic rejects sending both `temperature` and
                    // `top_p` for Claude 4.x models — `top_p` from params
                    // is intentionally ignored here.
                    //
                    // `thinking` is mutually exclusive with non-default
                    // `temperature`: when extended thinking is enabled the
                    // API requires `temperature = 1.0`, so clamp.
                    let thinkingEnabled = (params.thinkingBudgetTokens ?? 0) > 0
                    let effectiveTemperature: Double = thinkingEnabled ? 1.0 : params.temperature

                    var body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "temperature": effectiveTemperature,
                        "max_tokens": params.maxTokens,
                        "messages": convo,
                    ]
                    if let s = systemText, !s.isEmpty {
                        if params.anthropicPromptCaching {
                            // Tag the system prompt as cacheable. Anthropic
                            // requires the structured-content form (array of
                            // text blocks with cache_control) — a bare
                            // string can't carry the marker.
                            body["system"] = [
                                [
                                    "type": "text",
                                    "text": s,
                                    "cache_control": ["type": "ephemeral"],
                                ]
                            ]
                        } else {
                            body["system"] = s
                        }
                    }
                    if thinkingEnabled, let budget = params.thinkingBudgetTokens {
                        body["thinking"] = [
                            "type": "enabled",
                            "budget_tokens": budget,
                        ]
                    }
                    if !params.stopSequences.isEmpty {
                        body["stop_sequences"] = params.stopSequences
                    }
                    if let tier = params.serviceTier, !tier.isEmpty {
                        body["service_tier"] = tier
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
