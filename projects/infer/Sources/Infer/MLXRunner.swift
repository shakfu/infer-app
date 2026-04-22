import Foundation
import MLX
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
    /// Optional fixed seed. Applied via `MLXRandom.seed` immediately before
    /// each generation. nil = non-deterministic (MLX's default RNG state).
    private var seed: UInt64?

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
        seed: UInt64? = nil,
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
        self.seed = seed

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
    func updateSettings(
        systemPrompt: String?,
        temperature: Float,
        topP: Float,
        seed: UInt64? = nil
    ) {
        self.systemPrompt = systemPrompt?.isEmpty == true ? nil : systemPrompt
        self.genParams = GenerateParameters(temperature: temperature, topP: topP)
        self.seed = seed
    }

    /// Replace the runner's conversation history wholesale. Used by
    /// transcript-load and regenerate flows. Caller supplies the messages
    /// that should be in the KV cache as of the next send; the next send
    /// triggers pre-fill via `ChatSession(history:)`. Role strings follow
    /// our app convention: "user", "assistant", "system" (other values are
    /// skipped).
    func setHistory(_ messages: [(role: String, content: String, imageURLs: [URL])]) {
        self.history = messages.compactMap { m in
            let images: [UserInput.Image] = m.imageURLs.map { .url($0) }
            switch m.role {
            case "user": return .user(m.content, images: images)
            case "assistant": return .assistant(m.content, images: images)
            case "system": return .system(m.content, images: images)
            default: return nil
            }
        }
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

            // Apply a fixed seed before each generation so runs with the same
            // seed + prompt + params are reproducible. MLX.seed sets a global
            // RNG; fine here because we serialize generations via the
            // `isGenerating` guard.
            if let seed {
                MLX.seed(seed)
            }

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

    /// Drop the most recent user+assistant pair from history. The next send
    /// rebuilds the session with the truncated history. No-op if the tail
    /// isn't a user→assistant pair.
    func rewindLastTurn() {
        guard history.count >= 2,
              history[history.count - 1].role == .assistant,
              history[history.count - 2].role == .user
        else { return }
        history.removeLast(2)
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
