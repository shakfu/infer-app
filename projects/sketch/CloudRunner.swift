import Foundation

/// Runner for cloud chat providers (OpenAI, Anthropic). Mirrors the surface of
/// `LlamaRunner` / `MLXRunner` so `ChatViewModel` can swap on the active
/// backend without abstracting behind a protocol — the three runners still
/// diverge in load semantics (local path vs HF repo vs provider+model+key).
///
/// Unlike llama/MLX there is no model to load, so `configure` just records
/// what to send. History is kept here because cloud chat endpoints are
/// stateless — every turn sends the full transcript.
actor CloudRunner {
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

    init() {}

    var loadedModelId: String? { model }
    var activeProvider: CloudProvider? { provider }

    /// Set or replace the current provider/model/credentials. Resets history.
    /// Throws `CloudError.missingKey` if no key is available — the view model
    /// checks `APIKeyStore` first and shows a friendlier message, but the
    /// defensive throw here prevents a silent misconfiguration.
    func configure(
        provider: CloudProvider,
        model: String,
        apiKey: String,
        systemPrompt: String?,
        temperature: Double,
        topP: Double
    ) throws {
        guard !apiKey.isEmpty else { throw CloudError.missingKey }
        self.provider = provider
        self.model = model
        self.systemPrompt = (systemPrompt?.isEmpty ?? true) ? nil : systemPrompt
        self.temperature = temperature
        self.topP = topP
        self.client = Self.makeClient(provider: provider, apiKey: apiKey)
        rebuildInitialMessages()
    }

    private static func makeClient(provider: CloudProvider, apiKey: String) -> CloudClient {
        switch provider {
        case .openai: return OpenAIClient(apiKey: apiKey)
        case .anthropic: return AnthropicClient(apiKey: apiKey)
        }
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
    func updateSettings(systemPrompt: String?, temperature: Double, topP: Double) {
        let normalized: String? = (systemPrompt?.isEmpty ?? true) ? nil : systemPrompt
        let promptChanged = normalized != self.systemPrompt
        self.systemPrompt = normalized
        self.temperature = temperature
        self.topP = topP
        if promptChanged {
            rebuildInitialMessages()
        }
    }

    func resetConversation() {
        rebuildInitialMessages()
    }

    func sendUserMessage(
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
                defer { Task { await self.finishGeneration() } }

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
                            await self.commitPartialAssistantAndFinish(text: assistant)
                            continuation.finish(throwing: CloudError.cancelled)
                            return
                        }
                        assistant += piece
                        continuation.yield(piece)
                    }
                    await self.commitAssistant(text: assistant)
                    continuation.finish()
                } catch is CancellationError {
                    await self.commitPartialAssistantAndFinish(text: assistant)
                    continuation.finish(throwing: CloudError.cancelled)
                } catch {
                    // On error, discard the trailing user turn so the next
                    // attempt isn't double-counted. Matches LlamaRunner's
                    // rollback behavior.
                    await self.rollbackLastUser()
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

    func requestStop() {
        activeTask?.cancel()
    }

    func shutdown() {
        activeTask?.cancel()
        activeTask = nil
        client = nil
        provider = nil
        model = nil
        messages.removeAll()
        isGenerating = false
    }
}
