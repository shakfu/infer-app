import Foundation
import MLXLLM
import MLXVLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

enum MLXRunnerError: Error {
    case notLoaded
    case busy
    case cancelled
}

actor MLXRunner {
    private var container: ModelContainer?
    private var modelId: String?
    private var isGenerating = false

    private var systemPrompt: String?
    private var genParams = GenerateParameters()

    /// Completed conversation turns. Does NOT include the in-flight user turn
    /// being sent — that is added only after the assistant reply streams to
    /// completion, so a cancelled/failed send doesn't corrupt the record.
    private var history: [Chat.Message] = []

    private var activeTask: Task<Void, Never>?

    init() {}

    var loadedModelId: String? { modelId }

    /// Load a model from a Hugging Face repository id. Pass `nil` to use the
    /// registry default (gemma3_1B qat 4bit). The `progress` callback (if
    /// supplied) is invoked on an arbitrary queue; it receives the download's
    /// current `Progress` so the UI can show a determinate progress bar.
    func load(
        hfId: String? = nil,
        systemPrompt: String? = nil,
        temperature: Float = 0.6,
        topP: Float = 1.0,
        progress: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        container = nil
        modelId = nil
        history = []

        let configuration: ModelConfiguration
        if let hfId {
            configuration = ModelConfiguration(id: hfId)
        } else {
            configuration = LLMRegistry.gemma3_1B_qat_4bit
        }

        self.systemPrompt = systemPrompt?.isEmpty == true ? nil : systemPrompt
        self.genParams = GenerateParameters(temperature: temperature, topP: topP)

        let loaded: ModelContainer
        if let progress {
            loaded = try await #huggingFaceLoadModelContainer(
                configuration: configuration,
                progressHandler: progress
            )
        } else {
            loaded = try await #huggingFaceLoadModelContainer(configuration: configuration)
        }

        try Task.checkCancellation()

        self.container = loaded
        self.modelId = configuration.name
    }

    /// Build a session pre-filled with the current conversation history.
    /// ChatSession's KV cache is per-instance; rebuilds (for per-turn
    /// `maxTokens` overrides or settings changes) pass `history:` so prior
    /// context survives.
    private func buildSession(
        container: ModelContainer,
        maxTokens: Int? = nil
    ) -> ChatSession {
        let params: GenerateParameters
        if let maxTokens {
            params = GenerateParameters(
                maxTokens: maxTokens,
                temperature: genParams.temperature,
                topP: genParams.topP
            )
        } else {
            params = genParams
        }
        return ChatSession(
            container,
            instructions: systemPrompt,
            history: history,
            generateParameters: params
        )
    }

    /// Replace the current sampling / system-prompt settings. The next send
    /// rebuilds the session with these params; history is preserved.
    func updateSettings(systemPrompt: String?, temperature: Float, topP: Float) {
        self.systemPrompt = systemPrompt?.isEmpty == true ? nil : systemPrompt
        self.genParams = GenerateParameters(temperature: temperature, topP: topP)
    }

    /// Replace the runner's conversation history wholesale. Used by
    /// transcript-load and regenerate flows. Caller supplies the messages
    /// that should be in the KV cache as of the next send.
    func setHistory(_ messages: [Chat.Message]) {
        self.history = messages
    }

    func sendUserMessage(
        _ text: String,
        imageURLs: [URL] = [],
        maxTokens: Int = 512
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard !isGenerating else {
                continuation.finish(throwing: MLXRunnerError.busy)
                return
            }
            guard let container else {
                continuation.finish(throwing: MLXRunnerError.notLoaded)
                return
            }

            let images: [UserInput.Image] = imageURLs.map { .url($0) }
            // Rebuild per send so per-turn `maxTokens` applies; `history:`
            // keeps prior turns in the KV cache.
            let session = buildSession(container: container, maxTokens: maxTokens)

            isGenerating = true
            let task = Task {
                defer { Task { self.finishGeneration() } }
                var reply = ""
                do {
                    let stream = session.streamResponse(
                        to: text,
                        images: images,
                        videos: []
                    )
                    for try await piece in stream {
                        if Task.isCancelled {
                            continuation.finish(throwing: MLXRunnerError.cancelled)
                            return
                        }
                        reply += piece
                        continuation.yield(piece)
                    }
                    // Only record on clean completion; a cancelled/failed
                    // generation leaves history untouched so the next send
                    // isn't anchored to a partial reply.
                    self.appendCompletedTurn(
                        userText: text,
                        userImages: images,
                        assistant: reply
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: MLXRunnerError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            activeTask = task
        }
    }

    private func appendCompletedTurn(
        userText: String,
        userImages: [UserInput.Image],
        assistant: String
    ) {
        history.append(.user(userText, images: userImages))
        history.append(.assistant(assistant))
    }

    private func finishGeneration() {
        isGenerating = false
        activeTask = nil
    }

    func requestStop() {
        activeTask?.cancel()
    }

    func resetConversation() async {
        history = []
    }

    func shutdown() {
        activeTask?.cancel()
        activeTask = nil
        container = nil
        modelId = nil
        history = []
        isGenerating = false
    }
}
