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
    private var session: ChatSession?
    private var modelId: String?
    private var isGenerating = false

    private var systemPrompt: String?
    private var genParams = GenerateParameters()

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
        session = nil
        container = nil
        modelId = nil

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
        self.session = buildSession(container: loaded)
        self.modelId = configuration.name
    }

    private func buildSession(container: ModelContainer) -> ChatSession {
        ChatSession(
            container,
            instructions: systemPrompt,
            generateParameters: genParams
        )
    }

    /// Replace the current sampling / system-prompt settings. Forces a session
    /// rebuild (conversation history is lost).
    func updateSettings(systemPrompt: String?, temperature: Float, topP: Float) {
        self.systemPrompt = systemPrompt?.isEmpty == true ? nil : systemPrompt
        self.genParams = GenerateParameters(temperature: temperature, topP: topP)
        if let container {
            self.session = buildSession(container: container)
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
            guard let session else {
                continuation.finish(throwing: MLXRunnerError.notLoaded)
                return
            }

            // ChatSession's generation params are captured at init. Rebuild
            // with the current maxTokens so per-send limits apply.
            if let container {
                let params = GenerateParameters(
                    maxTokens: maxTokens,
                    temperature: genParams.temperature,
                    topP: genParams.topP
                )
                self.genParams = params
                self.session = ChatSession(
                    container,
                    instructions: systemPrompt,
                    generateParameters: params
                )
            }
            let activeSession = self.session ?? session
            let images: [UserInput.Image] = imageURLs.map { .url($0) }

            isGenerating = true
            let task = Task {
                defer { Task { self.finishGeneration() } }
                do {
                    let stream = activeSession.streamResponse(
                        to: text,
                        images: images,
                        videos: []
                    )
                    for try await piece in stream {
                        if Task.isCancelled {
                            continuation.finish(throwing: MLXRunnerError.cancelled)
                            return
                        }
                        continuation.yield(piece)
                    }
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

    private func finishGeneration() {
        isGenerating = false
        activeTask = nil
    }

    func requestStop() {
        activeTask?.cancel()
    }

    func resetConversation() async {
        if let container {
            session = buildSession(container: container)
        }
    }

    func shutdown() {
        activeTask?.cancel()
        activeTask = nil
        session = nil
        container = nil
        modelId = nil
        isGenerating = false
    }
}
