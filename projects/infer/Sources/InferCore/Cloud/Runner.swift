import Foundation

/// Runner for cloud chat providers (OpenAI, Anthropic, OpenAI-compatible).
/// Mirrors the surface of `LlamaRunner` / `MLXRunner` so `ChatViewModel` can
/// swap on the active backend without abstracting behind a protocol — the
/// runners still diverge in load semantics (local path vs HF repo vs
/// provider+model+key) enough that a protocol would leak.
///
/// One actor handles all three providers because the differences (system
/// prompt placement, SSE event shape, base URL) are isolated inside the
/// `CloudClient` implementation. The actor body — transcript management,
/// cancellation, rollback, settings — is provider-agnostic.
///
/// Unlike llama/MLX there is no model to load, so `configure` just records
/// what to send. History is kept here because cloud chat endpoints are
/// stateless — every turn sends the full transcript.
public actor CloudRunner {
    private var provider: CloudProvider?
    private var model: String?
    private var client: CloudClient?

    private var systemPrompt: String?
    private var temperature: Double = 0.8
    private var topP: Double = 0.95

    /// Full transcript we resend each turn. System prompt, if any, sits at
    /// index 0; both providers accept it there (Anthropic relocates it to a
    /// top-level field in its client; OpenAI takes it inline).
    private var messages: [CloudChatMessage] = []
    private var isGenerating = false
    private var activeTask: Task<Void, Never>?

    /// Factory for the underlying HTTP client. Default routes by provider;
    /// tests inject a stub to avoid touching the network. Stored as a
    /// `@Sendable` closure so the runner stays usable from any actor.
    private let clientFactory: @Sendable (CloudProvider, String) -> CloudClient

    public init(
        clientFactory: @escaping @Sendable (CloudProvider, String) -> CloudClient = CloudRunner.defaultClientFactory
    ) {
        self.clientFactory = clientFactory
    }

    public static let defaultClientFactory: @Sendable (CloudProvider, String) -> CloudClient = { provider, apiKey in
        switch provider {
        case .openai:
            return OpenAIClient(apiKey: apiKey)
        case .anthropic:
            return AnthropicClient(apiKey: apiKey)
        case .openaiCompatible(_, let baseURL):
            return OpenAIClient(apiKey: apiKey, baseURL: baseURL)
        }
    }

    public var loadedModelId: String? { model }
    public var activeProvider: CloudProvider? { provider }

    /// Set or replace the current provider/model/credentials. Resets history.
    /// Throws `CloudError.missingKey` if no key is available — the view model
    /// checks `APIKeyStore` first and shows a friendlier message, but the
    /// defensive throw here prevents a silent misconfiguration. Throws
    /// `CloudError.invalidEndpoint` if a compat provider's URL fails the
    /// scheme/host check (`CloudEndpointPolicy`).
    public func configure(
        provider: CloudProvider,
        model: String,
        apiKey: String,
        systemPrompt: String?,
        temperature: Double,
        topP: Double
    ) throws {
        guard !apiKey.isEmpty else { throw CloudError.missingKey }
        if case .openaiCompatible(_, let url) = provider,
           !CloudEndpointPolicy.isAcceptable(url) {
            throw CloudError.invalidEndpoint
        }
        self.provider = provider
        self.model = model
        self.systemPrompt = (systemPrompt?.isEmpty ?? true) ? nil : systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.client = clientFactory(provider, apiKey)
        rebuildInitialMessages()
    }

    private func rebuildInitialMessages() {
        messages.removeAll()
        if let sp = systemPrompt {
            messages.append(CloudChatMessage(role: .system, content: sp))
        }
    }

    /// Apply new sampling / system-prompt settings. Rebuilds the seed history
    /// if the system prompt changed (conversation history lost — symmetric
    /// with MLXRunner's behavior).
    public func updateSettings(systemPrompt: String?, temperature: Double, topP: Double) {
        let normalized: String? = (systemPrompt?.isEmpty ?? true) ? nil : systemPrompt
        let promptChanged = normalized != self.systemPrompt
        self.systemPrompt = normalized
        self.temperature = temperature
        self.topP = topP
        if promptChanged {
            rebuildInitialMessages()
        }
    }

    public func resetConversation() {
        rebuildInitialMessages()
    }

    /// Replace the conversation transcript wholesale. The system prompt
    /// (if configured) is preserved at index 0; the supplied turns
    /// (already filtered to user/assistant by the caller) follow. Used
    /// by the vault's restore path and by KV-compaction (which strips
    /// `<think>…</think>` blocks before feeding history back). Unrecognised
    /// roles are dropped silently — the cloud wire format only knows
    /// `user`/`assistant`.
    public func setHistory(_ turns: [(role: String, content: String)]) {
        rebuildInitialMessages()
        for turn in turns {
            switch turn.role {
            case "user":
                messages.append(CloudChatMessage(role: .user, content: turn.content))
            case "assistant":
                messages.append(CloudChatMessage(role: .assistant, content: turn.content))
            default:
                continue
            }
        }
    }

    /// Pop the most recent assistant + user pair from the transcript. Used
    /// by the chat VM's regenerate-last and edit-and-resend paths so the
    /// next `sendUserMessage` runs against the same context the prior one
    /// did. No-op when the trailing pair isn't `[…, .user, .assistant]`.
    /// Cloud is wire-stateless, so this is purely local bookkeeping.
    public func rewindLastTurn() {
        guard messages.count >= 2 else { return }
        let last = messages.count - 1
        if messages[last].role == .assistant, messages[last - 1].role == .user {
            messages.removeSubrange((last - 1)...last)
        }
    }

    /// Read-only snapshot of the current transcript. Used by tests; the UI
    /// keeps its own `[ChatMessage]` so doesn't need this.
    public func transcriptSnapshot() -> [CloudChatMessage] {
        messages
    }

    public func sendUserMessage(
        _ text: String,
        maxTokens: Int = 512
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard !isGenerating else {
                continuation.finish(throwing: CloudError.notConfigured)
                return
            }
            guard let client, let model else {
                continuation.finish(throwing: CloudError.notConfigured)
                return
            }

            messages.append(CloudChatMessage(role: .user, content: text))
            let outbound = messages
            let temperature = self.temperature
            let topP = self.topP

            isGenerating = true
            let task = Task {
                // Task inherits actor isolation, so the runner's private
                // helpers below are direct sync calls — no await hop needed.
                defer { self.finishGeneration() }

                var assistant = ""
                do {
                    let stream = client.streamChat(
                        messages: outbound,
                        model: model,
                        temperature: temperature,
                        topP: topP,
                        maxTokens: maxTokens
                    )
                    for try await piece in stream {
                        if Task.isCancelled {
                            self.commitPartialAssistantAndFinish(text: assistant)
                            continuation.finish(throwing: CloudError.cancelled)
                            return
                        }
                        assistant += piece
                        continuation.yield(piece)
                    }
                    self.commitAssistant(text: assistant)
                    continuation.finish()
                } catch is CancellationError {
                    self.commitPartialAssistantAndFinish(text: assistant)
                    continuation.finish(throwing: CloudError.cancelled)
                } catch {
                    // On error, discard the trailing user turn so the next
                    // attempt isn't double-counted. Matches LlamaRunner's
                    // rollback behavior.
                    self.rollbackLastUser()
                    continuation.finish(throwing: error)
                }
            }
            activeTask = task
        }
    }

    private func commitAssistant(text: String) {
        guard !text.isEmpty else { return }
        messages.append(CloudChatMessage(role: .assistant, content: text))
    }

    private func commitPartialAssistantAndFinish(text: String) {
        if !text.isEmpty {
            messages.append(CloudChatMessage(role: .assistant, content: text))
        }
    }

    private func rollbackLastUser() {
        if let last = messages.last, last.role == .user {
            messages.removeLast()
        }
    }

    private func finishGeneration() {
        isGenerating = false
        activeTask = nil
    }

    public func requestStop() {
        activeTask?.cancel()
    }

    public func shutdown() {
        activeTask?.cancel()
        activeTask = nil
        client = nil
        provider = nil
        model = nil
        messages.removeAll()
        isGenerating = false
    }
}
