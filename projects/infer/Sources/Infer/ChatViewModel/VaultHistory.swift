import Foundation

extension ChatViewModel {
    func refreshVaultRecents() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let recents = try await self.vault.recentConversations()
                await MainActor.run { self.vaultRecents = recents }
            } catch {
                FileHandle.standardError.write(
                    Data("vault read failed: \(error)\n".utf8)
                )
            }
        }
    }

    /// Debounced search against the vault. Empty query shows recents in the
    /// sidebar; non-empty triggers FTS search 250 ms after the last keystroke.
    func scheduleVaultSearch() {
        vaultSearchTask?.cancel()
        let q = vaultQuery
        vaultSearchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            guard let self else { return }
            if q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await MainActor.run { self.vaultResults = [] }
                return
            }
            do {
                let hits = try await self.vault.search(query: q)
                await MainActor.run {
                    // Only apply if the query is still current.
                    if self.vaultQuery == q { self.vaultResults = hits }
                }
            } catch {
                FileHandle.standardError.write(
                    Data("vault search failed: \(error)\n".utf8)
                )
            }
        }
    }

    /// Load a conversation from the vault into the UI. Backend memory is
    /// wiped (same caveat as `loadTranscript`). Further turns append to the
    /// same vault row — a continuation of the saved thread.
    func loadVaultConversation(id: Int64) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let rows = try await self.vault.loadConversation(id: id)
                let msgs: [ChatMessage] = rows.compactMap { row in
                    guard let role = ChatMessage.Role(rawValue: row.role) else { return nil }
                    return ChatMessage(role: role, text: row.content)
                }
                guard !msgs.isEmpty else { return }
                await MainActor.run {
                    self.stop()
                    self.messages = msgs
                    self.currentConversationId = id
                }
                switch self.backend {
                case .llama: await self.llama.resetConversation()
                case .mlx: await self.mlx.resetConversation()
                }
                await MainActor.run { self.refreshTokenUsage() }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to load conversation: \(error.localizedDescription)"
                }
            }
        }
    }

    func deleteVaultConversation(id: Int64) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.vault.deleteConversation(id: id)
                if self.currentConversationId == id {
                    await MainActor.run { self.currentConversationId = nil }
                }
                await MainActor.run { self.refreshVaultRecents() }
                self.scheduleVaultSearch()
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to delete conversation: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Drop every conversation and message. Confirmed via `NSAlert` at the
    /// call site; this method assumes the user has already agreed.
    func clearVault() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.vault.clearAll()
                await MainActor.run {
                    self.currentConversationId = nil
                    self.vaultResults = []
                    self.vaultRecents = []
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to clear vault: \(error.localizedDescription)"
                }
            }
        }
    }
}
