import Foundation

extension ChatViewModel {
    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, modelLoaded, !isGenerating else { return }

        let attachedImage = self.pendingImageURL
        messages.append(ChatMessage(role: .user, text: text, imageURL: attachedImage))
        messages.append(ChatMessage(role: .assistant, text: ""))
        let assistantIndex = messages.count - 1
        input = ""
        pendingImageURL = nil
        isGenerating = true
        generationTokenCount = 0
        generationStart = Date()
        generationEnd = nil

        let backend = self.backend
        let maxTokens = self.settings.maxTokens

        // Record the turn in the vault (best-effort; never blocks generation).
        let systemPrompt = self.settings.systemPrompt
        let modelIdForVault = self.vaultModelId()
        let backendName = backend.rawValue
        Task { [weak self] in
            guard let self else { return }
            do {
                let cid: Int64
                if let existing = self.currentConversationId {
                    cid = existing
                } else {
                    cid = try await self.vault.startConversation(
                        backend: backendName,
                        modelId: modelIdForVault,
                        systemPrompt: systemPrompt
                    )
                    await MainActor.run { self.currentConversationId = cid }
                }
                try await self.vault.appendMessage(
                    conversationId: cid, role: "user", content: text
                )
                await MainActor.run { self.refreshVaultRecents() }
            } catch {
                // Vault errors are non-fatal. Surface once per session by
                // printing to stderr; do not disturb the chat UI.
                FileHandle.standardError.write(
                    Data("vault write failed: \(error)\n".utf8)
                )
            }
        }

        generationTask = Task {
            do {
                let stream: AsyncThrowingStream<String, Error>
                switch backend {
                case .llama:
                    // llama backend has no multimodal path here; the send
                    // button is disabled when an image is attached, so this
                    // branch will not carry one in practice.
                    stream = await self.llama.sendUserMessage(text, maxTokens: maxTokens)
                case .mlx:
                    let imgs: [URL] = attachedImage.map { [$0] } ?? []
                    stream = await self.mlx.sendUserMessage(
                        text, imageURLs: imgs, maxTokens: maxTokens
                    )
                }
                for try await piece in stream {
                    if assistantIndex < self.messages.count {
                        self.messages[assistantIndex].text += piece
                    }
                    self.generationTokenCount += 1
                }
                self.generationEnd = Date()
                // Persist the assistant reply to the vault. Only on success —
                // cancellations and errors are caught below and skip this.
                if assistantIndex < self.messages.count,
                   let cid = self.currentConversationId {
                    let finalText = self.messages[assistantIndex].text
                    let stats = self.generationStats
                    Task { [vault = self.vault] in
                        do {
                            try await vault.appendMessage(
                                conversationId: cid,
                                role: "assistant",
                                content: finalText,
                                tokens: stats?.tokens,
                                tokPerSec: stats?.tps
                            )
                        } catch {
                            FileHandle.standardError.write(
                                Data("vault write failed: \(error)\n".utf8)
                            )
                        }
                    }
                }
                if self.ttsEnabled, assistantIndex < self.messages.count {
                    let finalText = self.messages[assistantIndex].text
                    self.speechSynthesizer.speak(
                        finalText,
                        voiceIdentifier: self.ttsVoiceId.isEmpty ? nil : self.ttsVoiceId
                    )
                }
                self.refreshTokenUsage()
            } catch is CancellationError {
                // user-initiated stop
            } catch LlamaError.cancelled {
                // user-initiated stop
            } catch MLXRunnerError.cancelled {
                // user-initiated stop
            } catch {
                self.errorMessage = "Generation error: \(error)"
            }
            if self.generationEnd == nil { self.generationEnd = Date() }
            self.isGenerating = false
        }
    }

    func stop() {
        let b = self.backend
        Task {
            switch b {
            case .llama: await self.llama.requestStop()
            case .mlx: await self.mlx.requestStop()
            }
        }
        generationTask?.cancel()
        generationTask = nil
        speechSynthesizer.stop()
    }
}
