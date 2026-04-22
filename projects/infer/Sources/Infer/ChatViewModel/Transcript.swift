import Foundation
import AppKit
import UniformTypeIdentifiers

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
        messages
            .map { "## \($0.role.rawValue)\n\n\($0.text)" }
            .joined(separator: "\n\n---\n\n")
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
            // Imported `.md` is file-only: not linked to any vault row.
            // Next send() will start a fresh vault conversation.
            currentConversationId = nil
            restoreBackendHistory(loaded)
        } catch {
            errorMessage = "Failed to load transcript: \(error.localizedDescription)"
        }
    }

    /// Push `restored` into the active backend's KV cache so continued turns
    /// have context. System turns are filtered out — the current
    /// `settings.systemPrompt` is what each runner prepends automatically.
    /// Llama's pre-fill can throw (tokenize/decode); on failure we silently
    /// fall back to a reset so the transcript is still readable.
    func restoreBackendHistory(_ restored: [ChatMessage]) {
        let turns = restored.filter { $0.role != .system }
        let b = self.backend
        Task {
            switch b {
            case .llama:
                let history = turns.map { (role: $0.role.rawValue, content: $0.text) }
                do {
                    try await self.llama.setHistory(history)
                } catch {
                    await self.llama.resetConversation()
                }
            case .mlx:
                let history = turns.map { msg in
                    (role: msg.role.rawValue,
                     content: msg.text,
                     imageURLs: msg.imageURL.map { [$0] } ?? [])
                }
                await self.mlx.setHistory(history)
            }
            await MainActor.run { self.refreshTokenUsage() }
        }
    }

    /// Parse the canonical Save format back into messages. Strict enough to
    /// round-trip `transcriptMarkdown`; lenient about extra whitespace and
    /// unknown roles (skipped).
    static func parseTranscript(_ markdown: String) -> [ChatMessage] {
        var result: [ChatMessage] = []
        let chunks = markdown.components(separatedBy: "\n\n---\n\n")
        for raw in chunks {
            let chunk = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard chunk.hasPrefix("## ") else { continue }
            guard let bodyBreak = chunk.range(of: "\n\n") else { continue }
            let headerStart = chunk.index(chunk.startIndex, offsetBy: 3)
            let header = chunk[headerStart..<bodyBreak.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let body = String(chunk[bodyBreak.upperBound...])
            let role: ChatMessage.Role
            switch header {
            case "user": role = .user
            case "assistant": role = .assistant
            case "system": role = .system
            default: continue
            }
            result.append(ChatMessage(role: role, text: body))
        }
        return result
    }
}
