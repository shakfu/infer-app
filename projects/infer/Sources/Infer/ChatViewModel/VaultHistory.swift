import Foundation

extension ChatViewModel {
    func refreshVaultRecents() {
        let tagFilter = Array(vaultTagFilter)
        Task { [weak self] in
            guard let self else { return }
            do {
                async let recents = self.vault.recentConversations(tags: tagFilter)
                async let tags = self.vault.allTags()
                let (r, t) = try await (recents, tags)
                await MainActor.run {
                    self.vaultRecents = r
                    self.allVaultTags = t
                    // Clear any tag filter entries that no longer exist
                    // (last conversation carrying them was deleted).
                    let valid = Set(t.map { VaultStore.normalizeTag($0) })
                    self.vaultTagFilter = self.vaultTagFilter.filter {
                        valid.contains(VaultStore.normalizeTag($0))
                    }
                }
            } catch {
                self.logs.logFromBackground(
                    .error,
                    source: "vault",
                    message: "read failed (recent conversations)",
                    payload: String(describing: error)
                )
            }
        }
    }

    /// Toggle a tag's presence in the History filter. AND-match, so
    /// adding narrows the list. Refreshes recents on change.
    func toggleTagFilter(_ tag: String) {
        let n = VaultStore.normalizeTag(tag)
        guard !n.isEmpty else { return }
        if vaultTagFilter.contains(n) {
            vaultTagFilter.remove(n)
        } else {
            vaultTagFilter.insert(n)
        }
        refreshVaultRecents()
    }

    func clearTagFilter() {
        guard !vaultTagFilter.isEmpty else { return }
        vaultTagFilter.removeAll()
        refreshVaultRecents()
    }

    /// Attach a tag to a vault conversation. Refreshes recents on
    /// completion so the chip appears without manual reload.
    func addTag(_ tag: String, to conversationId: Int64) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.vault.addTag(tag, to: conversationId)
                await MainActor.run { self.refreshVaultRecents() }
            } catch {
                self.logs.logFromBackground(
                    .error,
                    source: "vault",
                    message: "addTag failed",
                    payload: String(describing: error)
                )
            }
        }
    }

    /// Detach a tag from a vault conversation.
    func removeTag(_ tag: String, from conversationId: Int64) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.vault.removeTag(tag, from: conversationId)
                await MainActor.run { self.refreshVaultRecents() }
            } catch {
                self.logs.logFromBackground(
                    .error,
                    source: "vault",
                    message: "removeTag failed",
                    payload: String(describing: error)
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
                self.logs.logFromBackground(
                    .error,
                    source: "vault",
                    message: "search failed",
                    payload: String(describing: error)
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
                    self.restoreBackendHistory(msgs)
                }
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
