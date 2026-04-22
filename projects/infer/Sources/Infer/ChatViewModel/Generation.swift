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
                    self.speakAssistantReply(finalText)
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

    /// Regenerate the most recent assistant response. Pops the last
    /// user+assistant pair from the transcript, rewinds the backend so its
    /// KV cache matches, then re-sends the original user turn (with any
    /// attached image) via `send()`.
    ///
    /// No-op when a generation is in flight, when the last two messages
    /// aren't a user→assistant pair, or when no model is loaded.
    func regenerateLast() {
        guard unspoolLastTurn() else { return }
        let b = self.backend
        Task {
            switch b {
            case .llama: await self.llama.rewindLastTurn()
            case .mlx: await self.mlx.rewindLastTurn()
            }
            await MainActor.run { self.send() }
        }
    }

    /// Pop the most recent user turn (and its assistant reply) back into the
    /// composer for editing. Next press of Send re-runs the turn. Same rewind
    /// mechanics as `regenerateLast` — the backend's pre-turn state is
    /// restored — but control returns to the user before sending.
    func editLastUserMessage() {
        guard unspoolLastTurn() else { return }
        let b = self.backend
        Task {
            switch b {
            case .llama: await self.llama.rewindLastTurn()
            case .mlx: await self.mlx.rewindLastTurn()
            }
        }
    }

    /// Shared precondition + transcript mutation for regenerate and
    /// edit-and-resend. Returns `true` when the last user+assistant pair was
    /// popped and the composer repopulated with the original user text +
    /// image; `false` means the caller should abort (no-op).
    private func unspoolLastTurn() -> Bool {
        guard modelLoaded, !isGenerating else { return false }
        guard messages.count >= 2 else { return false }
        let last = messages.count - 1
        guard messages[last].role == .assistant,
              messages[last - 1].role == .user
        else { return false }

        let userTurn = messages[last - 1]
        messages.removeSubrange((last - 1)...last)
        input = userTurn.text
        pendingImageURL = userTurn.imageURL
        return true
    }
}
