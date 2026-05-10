import Foundation
import AppKit
import UniformTypeIdentifiers
import InferAppCore
import InferCore

extension ChatViewModel {
    /// UTTypes accepted by the transcript save/load panels. `.md` may not
    /// resolve on older macOS versions — fall back to plain text alone.
    static var markdownContentTypes: [UTType] {
        if let md = UTType(filenameExtension: "md") {
            return [md, .plainText]
        }
        return [.plainText]
    }

    /// Canonical markdown representation of the transcript. Used by Copy,
    /// Save, and Load (which round-trips this exact format).
    var transcriptMarkdown: String {
        TranscriptMarkdown.render(
            messages.map { TranscriptMarkdown.Turn(role: $0.role.rawValue, text: $0.text) }
        )
    }

    func copyTranscriptAsMarkdown() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(transcriptMarkdown, forType: .string)
    }

    func printTranscript() {
        PrintRenderer.printTranscript(messages)
    }

    func exportTranscriptHTML() {
        guard let url = FileDialogs.saveFile(
            message: "Export transcript as HTML",
            defaultName: "transcript.html",
            contentTypes: [.html]
        ) else { return }
        do {
            try PrintRenderer.exportHTML(messages, to: url)
        } catch {
            errorMessage = "Failed to export HTML: \(error.localizedDescription)"
        }
    }

    func exportTranscriptPDF() {
        guard let url = FileDialogs.saveFile(
            message: "Export transcript as PDF",
            defaultName: "transcript.pdf",
            contentTypes: [.pdf]
        ) else { return }
        PrintRenderer.exportPDF(messages, to: url) { [weak self] result in
            if case .failure(let err) = result {
                self?.errorMessage = "Failed to export PDF: \(err.localizedDescription)"
            }
        }
    }

    func saveTranscript() {
        guard let url = FileDialogs.saveFile(
            message: "Save transcript as Markdown",
            defaultName: "transcript.md",
            contentTypes: Self.markdownContentTypes
        ) else { return }
        do {
            try transcriptMarkdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Failed to save transcript: \(error.localizedDescription)"
        }
    }

    func loadTranscript() {
        guard let url = FileDialogs.openFile(
            message: "Load transcript from Markdown",
            contentTypes: Self.markdownContentTypes
        ) else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let loaded = Self.parseTranscript(text)
            guard !loaded.isEmpty else {
                errorMessage = "Transcript file contains no recognizable messages."
                return
            }
            stop()
            messages = loaded
            syncTranscriptMirror()
            // Imported `.md` is file-only: not linked to any vault row.
            // Next send() will start a fresh vault conversation.
            currentConversationId = nil
            restoreBackendHistory(loaded)
        } catch {
            errorMessage = "Failed to load transcript: \(error.localizedDescription)"
        }
    }

    /// Replay the current `messages[]` (which holds the *visible*,
    /// `<think>…</think>`-stripped text) into the active backend's
    /// KV cache. Called automatically at end-of-turn for assistant
    /// messages that captured reasoning content, so the cache stays
    /// in sync with what the user sees.
    ///
    /// Uses the same `setHistory` plumbing that transcript-load and
    /// regenerate use — the runner clears its cache, re-renders the
    /// chat template from the supplied (stripped) history, tokenizes,
    /// and decodes one prefill batch. Cost: ~few hundred ms for a
    /// typical conversation length, paid once per reasoning turn.
    /// Token usage is refreshed afterwards so the header percentage
    /// reflects the post-compaction state.
    ///
    /// On failure: logs at `warning` level and falls through. The
    /// runner is left in its prior state (cache still has the raw
    /// sequence); the user's next turn still works, just at the old
    /// cost.
    func compactKVForVisibleHistory() {
        let snapshot = self.messages
        let runner = self.activeChatRunner
        Task { [weak self] in
            guard let self else { return }
            let started = Date()
            let history = Self.chatTurns(from: snapshot)
            do {
                try await runner.setHistory(history)
                let elapsed = Date().timeIntervalSince(started)
                self.logs.logFromBackground(
                    .debug,
                    source: "runner",
                    message: "compacted KV cache (stripped think blocks) in \(String(format: "%.0f", elapsed * 1000))ms"
                )
                await MainActor.run { self.refreshTokenUsage() }
            } catch {
                self.logs.logFromBackground(
                    .warning,
                    source: "runner",
                    message: "KV cache compaction failed; cache still holds raw decoded sequence",
                    payload: String(describing: error)
                )
            }
        }
    }

    /// Push `restored` into the active backend's KV cache so continued turns
    /// have context. System turns are filtered out — the current
    /// `settings.systemPrompt` is what each runner prepends automatically.
    /// Llama's pre-fill can throw (tokenize/decode); on failure we silently
    /// fall back to a reset so the transcript is still readable.
    func restoreBackendHistory(_ restored: [ChatMessage]) {
        let history = Self.chatTurns(from: restored)
        let runner = self.activeChatRunner
        Task {
            do {
                try await runner.setHistory(history)
            } catch {
                // Only Llama can throw (tokenize/decode); fall back to a
                // reset so the transcript is still readable. Harmless
                // for MLX/Cloud — their adapters never throw.
                await runner.resetConversation()
            }
            await MainActor.run { self.refreshTokenUsage() }
        }
    }

    /// Build the `ChatRunner.setHistory` snapshot from a `[ChatMessage]`
    /// slice. System turns are filtered out — the chat-VM tracks the
    /// current `settings.systemPrompt` separately and applies it via
    /// each runner's load / configure path; including a system turn
    /// here would either double-apply (Llama: overwrite the loaded
    /// prompt) or fight the runner's stored value (MLX/Cloud).
    /// Image attachments are preserved per turn so MLX VLM-capable
    /// models keep their multimodal context after a regenerate /
    /// load-transcript / KV-compaction cycle.
    static func chatTurns(from messages: [ChatMessage]) -> [ChatTurn] {
        messages.compactMap { msg in
            guard msg.role != .system else { return nil }
            if case .agentDivider = msg.kind { return nil }
            let role: ChatTurn.Role
            switch msg.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .system: return nil // unreachable (filtered above) but exhaustive
            }
            return ChatTurn(
                role: role,
                content: msg.text,
                imageURLs: msg.imageURL.map { [$0] } ?? []
            )
        }
    }

    /// Parse the canonical Save format back into messages. Strict enough to
    /// round-trip `transcriptMarkdown`; lenient about extra whitespace and
    /// unknown roles (skipped).
    static func parseTranscript(_ markdown: String) -> [ChatMessage] {
        TranscriptMarkdown.parse(markdown).compactMap { turn in
            guard let role = ChatMessage.Role(rawValue: turn.role) else { return nil }
            return ChatMessage(role: role, text: turn.text)
        }
    }

    /// Map a UI-side `ChatMessage` to the value-typed `TranscriptEntry`
    /// that the `transcriptStore` mirror holds. Lossy on purpose —
    /// agent attribution, step traces, retrieved-chunk provenance, and
    /// `<think>`-block disclosure state all live on the UI type and
    /// don't belong in the runner-history snapshot. `agentDivider`
    /// rows are filtered upstream (they have no role in prompts) and
    /// don't reach this helper.
    static func makeTranscriptEntry(_ msg: ChatMessage) -> TranscriptEntry {
        let role: ChatTurn.Role
        switch msg.role {
        case .user: role = .user
        case .assistant: role = .assistant
        case .system: role = .system
        }
        return TranscriptEntry(
            id: msg.id,
            role: role,
            text: msg.text,
            imageURL: msg.imageURL
        )
    }

    /// Rebuild `transcriptStore` from the current `messages` array.
    /// Called at well-defined sync points (`reset`, `loadTranscript`,
    /// post-`send`, post-`unspoolLastTurn`) so the mirror reflects the
    /// committed transcript state. Streaming-time chunk writes inside
    /// `Generation.swift` are intentionally NOT mirrored per-chunk —
    /// the mirror is end-of-turn-accurate, not per-token-accurate. A
    /// follow-up can either fold the streaming writes into a
    /// store-first model or accept the mirror as the source of truth
    /// for runner history (today the chat-VM builds those snapshots
    /// inline from `messages` in `restoreBackendHistory` and
    /// `compactKVForVisibleHistory`).
    func syncTranscriptMirror() {
        let entries = messages
            .filter { if case .agentDivider = $0.kind { return false } else { return true } }
            .map(Self.makeTranscriptEntry)
        transcriptStore = TranscriptStore(entries: entries)
    }
}
