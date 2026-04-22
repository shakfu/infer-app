import Foundation
import InferCore

extension ChatViewModel {
    /// Persist settings and apply them to whichever backend is currently loaded.
    /// Sampling params apply without a re-load; changing the system prompt
    /// resets the conversation (history is lost).
    func applySettings(_ new: InferSettings) {
        let prevSystemPrompt = settings.systemPrompt
        settings = new
        new.save()

        let temp = Float(new.temperature)
        let top = Float(new.topP)
        let sp = new.systemPrompt

        Task {
            await self.llama.updateSampling(temperature: temp, topP: top, topK: 40)
            await self.mlx.updateSettings(
                systemPrompt: sp,
                temperature: temp,
                topP: top
            )
            if prevSystemPrompt != sp {
                await self.llama.setSystemPrompt(sp.isEmpty ? nil : sp)
                await MainActor.run {
                    self.messages.removeAll()
                    // New system prompt => new vault conversation on next send.
                    self.currentConversationId = nil
                }
            }
        }
    }

    /// Recompute context-window usage for the active backend. llama reports
    /// real token counts; MLX has no cheap way to query, so approximate from
    /// transcript character count (~4 chars/token for English).
    func refreshTokenUsage() {
        let b = self.backend
        let msgs = self.messages
        let systemChars = self.settings.systemPrompt.count
        Task {
            let usage: TokenUsage?
            switch b {
            case .llama:
                usage = await self.llama.tokenUsage()
            case .mlx:
                let chars = msgs.reduce(0) { $0 + $1.text.count } + systemChars
                usage = chars == 0 ? nil : TokenUsage(used: chars / 4, total: nil)
            }
            await MainActor.run { self.tokenUsage = usage }
        }
    }
}
