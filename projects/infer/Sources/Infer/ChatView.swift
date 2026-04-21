import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MarkdownUI
import Splash

struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant, system }
    let id = UUID()
    let role: Role
    var text: String
}

enum Backend: String, CaseIterable, Identifiable {
    case llama
    case mlx
    var id: String { rawValue }
    var label: String {
        switch self {
        case .llama: return "llama.cpp"
        case .mlx: return "MLX"
        }
    }
}

private enum PersistKey {
    static let backend = "infer.lastBackend"
    static let llamaPath = "infer.lastLlamaPath"
    static let mlxId = "infer.lastMLXId"
    static let systemPrompt = "infer.systemPrompt"
    static let temperature = "infer.temperature"
    static let topP = "infer.topP"
    static let maxTokens = "infer.maxTokens"
    static let recentLlamaPaths = "infer.recentLlamaPaths"
    static let recentMLXIds = "infer.recentMLXIds"
    static let sidebarOpen = "infer.sidebarOpen"
    static let appearance = "infer.appearance"
    static let ttsEnabled = "infer.ttsEnabled"
    static let ttsVoiceId = "infer.ttsVoiceId"
    static let voiceSendPhrase = "infer.voiceSendPhrase"
}

private let recentsLimit = 8

enum AppearanceMode: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var label: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

struct InferSettings {
    var systemPrompt: String
    var temperature: Double
    var topP: Double
    var maxTokens: Int

    static let defaults = InferSettings(
        systemPrompt: "",
        temperature: 0.8,
        topP: 0.95,
        maxTokens: 512
    )

    static func load() -> InferSettings {
        let d = UserDefaults.standard
        return InferSettings(
            systemPrompt: d.string(forKey: PersistKey.systemPrompt) ?? "",
            temperature: d.object(forKey: PersistKey.temperature) as? Double ?? 0.8,
            topP: d.object(forKey: PersistKey.topP) as? Double ?? 0.95,
            maxTokens: d.object(forKey: PersistKey.maxTokens) as? Int ?? 512
        )
    }

    func save() {
        let d = UserDefaults.standard
        d.set(systemPrompt, forKey: PersistKey.systemPrompt)
        d.set(temperature, forKey: PersistKey.temperature)
        d.set(topP, forKey: PersistKey.topP)
        d.set(maxTokens, forKey: PersistKey.maxTokens)
    }
}

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var input: String = ""
    var backend: Backend = .llama
    var modelLoaded: Bool = false
    var modelStatus: String = "No model loaded"
    var isLoadingModel = false
    var isGenerating = false
    var errorMessage: String? = nil
    /// User-entered HF repo id for MLX; empty => registry default.
    var mlxModelId: String = ""
    var settings: InferSettings = InferSettings.load()
    var downloadProgress: Double? = nil
    var tokenUsage: TokenUsage? = nil
    /// Number of stream pieces received for the current or most-recent
    /// generation. For both backends, stream pieces correspond 1:1 with
    /// sampled tokens in the common case (they may merge for multi-byte UTF-8
    /// fragments — close enough for a user-facing tok/s readout).
    var generationTokenCount: Int = 0
    private var generationStart: Date? = nil
    private var generationEnd: Date? = nil

    /// Tokens + tok/s for the current (if generating) or most-recent
    /// generation. Nil when no generation has happened in this session.
    var generationStats: (tokens: Int, tps: Double)? {
        guard let start = generationStart, generationTokenCount > 0 else { return nil }
        let end = generationEnd ?? Date()
        let elapsed = end.timeIntervalSince(start)
        guard elapsed > 0 else { return nil }
        return (generationTokenCount, Double(generationTokenCount) / elapsed)
    }
    var recentLlamaPaths: [String] = UserDefaults.standard.stringArray(forKey: PersistKey.recentLlamaPaths) ?? []
    var recentMLXIds: [String] = UserDefaults.standard.stringArray(forKey: PersistKey.recentMLXIds) ?? []

    let llama = LlamaRunner()
    let mlx = MLXRunner()
    let speechRecognizer = SpeechRecognizer()
    let speechSynthesizer = SpeechSynthesizer()
    let whisperModels = WhisperModelManager()
    let audioRecorder = AudioFileRecorder()

    /// True while a dropped audio file is being transcribed. Mutually
    /// exclusive for simplicity — the second drop is ignored with a banner.
    var isTranscribingFile: Bool = false
    var transcriptionStatus: String? = nil

    private let vault = VaultStore.shared

    /// Row id of the in-progress vault conversation, or nil if no turns have
    /// been recorded yet (next `send()` will create a new row).
    private var currentConversationId: Int64? = nil

    // Vault search UI state.
    var vaultQuery: String = ""
    var vaultResults: [VaultSearchHit] = []
    var vaultRecents: [VaultConversationSummary] = []
    private var vaultSearchTask: Task<Void, Never>? = nil

    var ttsEnabled: Bool = UserDefaults.standard.bool(forKey: PersistKey.ttsEnabled) {
        didSet { UserDefaults.standard.set(ttsEnabled, forKey: PersistKey.ttsEnabled) }
    }
    var ttsVoiceId: String = UserDefaults.standard.string(forKey: PersistKey.ttsVoiceId) ?? "" {
        didSet { UserDefaults.standard.set(ttsVoiceId, forKey: PersistKey.ttsVoiceId) }
    }
    /// Trailing phrase that, when detected at the end of dictated text,
    /// strips itself and submits the message. Empty disables voice send.
    var voiceSendPhrase: String = UserDefaults.standard.string(forKey: PersistKey.voiceSendPhrase) ?? "send it" {
        didSet { UserDefaults.standard.set(voiceSendPhrase, forKey: PersistKey.voiceSendPhrase) }
    }

    private var generationTask: Task<Void, Never>? = nil
    private var loadTask: Task<Void, Never>? = nil

    // MARK: - Loading

    func autoLoadLastModel() {
        guard !modelLoaded, !isLoadingModel else { return }
        let d = UserDefaults.standard
        guard let raw = d.string(forKey: PersistKey.backend),
              let last = Backend(rawValue: raw) else { return }
        switch last {
        case .llama:
            guard let path = d.string(forKey: PersistKey.llamaPath),
                  FileManager.default.fileExists(atPath: path) else { return }
            backend = .llama
            loadLlama(at: path)
        case .mlx:
            let id = d.string(forKey: PersistKey.mlxId) ?? ""
            backend = .mlx
            mlxModelId = id
            loadMLX(hfId: id)
        }
    }

    func loadCurrentBackend() {
        switch backend {
        case .llama: pickLlamaModel()
        case .mlx: loadMLX(hfId: mlxModelId.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Load a previously-used llama .gguf path from recents.
    func loadLlamaPath(_ path: String) { loadLlama(at: path) }

    /// Load a previously-used MLX HF id from recents.
    func loadMLXId(_ id: String) {
        mlxModelId = id
        loadMLX(hfId: id)
    }

    func browseForLlamaModel() { pickLlamaModel() }

    private func rememberRecent(llamaPath path: String) {
        var list = recentLlamaPaths.filter { $0 != path && FileManager.default.fileExists(atPath: $0) }
        list.insert(path, at: 0)
        if list.count > recentsLimit { list = Array(list.prefix(recentsLimit)) }
        recentLlamaPaths = list
        UserDefaults.standard.set(list, forKey: PersistKey.recentLlamaPaths)
    }

    private func rememberRecent(mlxId id: String) {
        guard !id.isEmpty else { return }
        var list = recentMLXIds.filter { $0 != id }
        list.insert(id, at: 0)
        if list.count > recentsLimit { list = Array(list.prefix(recentsLimit)) }
        recentMLXIds = list
        UserDefaults.standard.set(list, forKey: PersistKey.recentMLXIds)
    }

    private func pickLlamaModel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let gguf = UTType(filenameExtension: "gguf") {
            panel.allowedContentTypes = [gguf]
        }
        panel.message = "Select a .gguf model file"
        if panel.runModal() == .OK, let url = panel.url {
            loadLlama(at: url.path)
        }
    }

    private func loadLlama(at path: String) {
        guard !isLoadingModel else { return }
        isLoadingModel = true
        modelLoaded = false
        downloadProgress = nil
        modelStatus = "Loading \((path as NSString).lastPathComponent)…"
        errorMessage = nil
        let runner = self.llama
        let s = self.settings
        loadTask = Task {
            do {
                try Task.checkCancellation()
                try await runner.load(
                    path: path,
                    systemPrompt: s.systemPrompt,
                    temperature: Float(s.temperature),
                    topP: Float(s.topP),
                    topK: 40
                )
                try Task.checkCancellation()
                await MainActor.run {
                    self.modelLoaded = true
                    self.modelStatus = "llama: \((path as NSString).lastPathComponent)"
                    self.isLoadingModel = false
                    self.loadTask = nil
                    let d = UserDefaults.standard
                    d.set(Backend.llama.rawValue, forKey: PersistKey.backend)
                    d.set(path, forKey: PersistKey.llamaPath)
                    self.rememberRecent(llamaPath: path)
                    self.refreshTokenUsage()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.modelStatus = "Load cancelled"
                    self.isLoadingModel = false
                    self.loadTask = nil
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to load model: \(error)"
                    self.modelStatus = "No model loaded"
                    self.isLoadingModel = false
                    self.loadTask = nil
                }
            }
        }
    }

    private func loadMLX(hfId: String) {
        guard !isLoadingModel else { return }
        isLoadingModel = true
        modelLoaded = false
        // Start as nil so statusView shows an indeterminate spinner during
        // the HF metadata/resolution phase (before any byte-level progress
        // callback fires). A stale 0% is misleading when the repo name is
        // wrong and the resolver is retrying.
        downloadProgress = nil
        let id = hfId.isEmpty ? nil : hfId
        modelStatus = "Resolving \(id ?? "default")…"
        errorMessage = nil
        let runner = self.mlx
        let s = self.settings
        loadTask = Task { [weak self] in
            let progressHandler: @Sendable (Progress) -> Void = { progress in
                let frac = progress.totalUnitCount > 0
                    ? Double(progress.completedUnitCount) / Double(progress.totalUnitCount)
                    : nil
                Task { @MainActor in
                    guard let self else { return }
                    self.downloadProgress = frac
                    if frac != nil, self.modelStatus.hasPrefix("Resolving ") {
                        self.modelStatus = "Downloading \(id ?? "default")…"
                    }
                }
            }
            do {
                try Task.checkCancellation()
                try await runner.load(
                    hfId: id,
                    systemPrompt: s.systemPrompt,
                    temperature: Float(s.temperature),
                    topP: Float(s.topP),
                    progress: progressHandler
                )
                try Task.checkCancellation()
                let shown = await runner.loadedModelId ?? "mlx"
                await MainActor.run {
                    guard let self else { return }
                    self.modelLoaded = true
                    self.modelStatus = "MLX: \(shown)"
                    self.isLoadingModel = false
                    self.downloadProgress = nil
                    self.loadTask = nil
                    let d = UserDefaults.standard
                    d.set(Backend.mlx.rawValue, forKey: PersistKey.backend)
                    d.set(hfId, forKey: PersistKey.mlxId)
                    self.rememberRecent(mlxId: hfId)
                    self.refreshTokenUsage()
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self else { return }
                    self.modelStatus = "Load cancelled"
                    self.isLoadingModel = false
                    self.downloadProgress = nil
                    self.loadTask = nil
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.errorMessage = "Failed to load MLX model: \(error)"
                    self.modelStatus = "No model loaded"
                    self.isLoadingModel = false
                    self.downloadProgress = nil
                    self.loadTask = nil
                }
            }
        }
    }

    func cancelLoad() {
        loadTask?.cancel()
    }

    // MARK: - Generate

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, modelLoaded, !isGenerating else { return }

        messages.append(ChatMessage(role: .user, text: text))
        messages.append(ChatMessage(role: .assistant, text: ""))
        let assistantIndex = messages.count - 1
        input = ""
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
                    stream = await self.llama.sendUserMessage(text, maxTokens: maxTokens)
                case .mlx:
                    stream = await self.mlx.sendUserMessage(text, maxTokens: maxTokens)
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

    // MARK: - Settings

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

    // MARK: - Token usage

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

    // MARK: - Voice-send trigger

    /// If `text` ends with the configured trigger phrase (case-insensitive,
    /// ignoring trailing punctuation/whitespace), return the text with the
    /// phrase removed. Returns nil otherwise. Returns nil if `phrase` is empty.
    static func stripTrailingTrigger(_ text: String, phrase: String) -> String? {
        let trigger = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trigger.isEmpty else { return nil }

        let trailingPunct = CharacterSet(charactersIn: " .,!?;:\n\t")
        // Peel trailing whitespace/punctuation off the text for comparison.
        var lowered = text.lowercased()
        while let last = lowered.unicodeScalars.last, trailingPunct.contains(last) {
            lowered.unicodeScalars.removeLast()
        }
        guard lowered.hasSuffix(trigger) else { return nil }

        // Require a word boundary before the trigger so "resend it"
        // doesn't match "send it". Boundary = start-of-string or whitespace.
        let triggerStartLowered = lowered.index(lowered.endIndex, offsetBy: -trigger.count)
        if triggerStartLowered > lowered.startIndex {
            let prev = lowered[lowered.index(before: triggerStartLowered)]
            if !prev.isWhitespace { return nil }
        }

        // Map the lowercased boundary back to the original string by length
        // (lowercasing doesn't change UTF-16 length for ASCII triggers; for
        // non-ASCII we conservatively measure from the end of the stripped
        // lowered string in the original).
        let strippedLoweredCount = lowered.count
        // Find corresponding index in `text` by walking from the end past
        // the same number of trailing punct/whitespace scalars we peeled.
        var peelOffset = 0
        var scratch = text
        while let last = scratch.unicodeScalars.last, trailingPunct.contains(last) {
            scratch.unicodeScalars.removeLast()
            peelOffset += 1
        }
        let originalCore = text.prefix(text.count - peelOffset)
        guard originalCore.count >= trigger.count else { return nil }
        let triggerStart = originalCore.index(originalCore.endIndex, offsetBy: -trigger.count)
        var result = String(originalCore[..<triggerStart])
        _ = strippedLoweredCount
        // Trim the now-trailing comma/space/period left behind.
        let tailTrim = CharacterSet(charactersIn: " ,.;:\n\t")
        while let last = result.unicodeScalars.last, tailTrim.contains(last) {
            result.unicodeScalars.removeLast()
        }
        return result
    }

    // MARK: - Copy / Print / Save / Load

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
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "transcript.html"
        panel.message = "Export transcript as HTML"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PrintRenderer.exportHTML(messages, to: url)
        } catch {
            errorMessage = "Failed to export HTML: \(error.localizedDescription)"
        }
    }

    func exportTranscriptPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "transcript.pdf"
        panel.message = "Export transcript as PDF"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        PrintRenderer.exportPDF(messages, to: url) { [weak self] result in
            if case .failure(let err) = result {
                self?.errorMessage = "Failed to export PDF: \(err.localizedDescription)"
            }
        }
    }

    func saveTranscript() {
        let panel = NSSavePanel()
        if let md = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [md, .plainText]
        } else {
            panel.allowedContentTypes = [.plainText]
        }
        panel.nameFieldStringValue = "transcript.md"
        panel.message = "Save transcript as Markdown"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try transcriptMarkdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Failed to save transcript: \(error.localizedDescription)"
        }
    }

    func loadTranscript() {
        let panel = NSOpenPanel()
        if let md = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [md, .plainText]
        } else {
            panel.allowedContentTypes = [.plainText]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Load transcript from Markdown"
        guard panel.runModal() == .OK, let url = panel.url else { return }
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
            // Reset backend conversation state. MLX's `ChatSession` has no
            // public API to inject a prior transcript, so for consistency we
            // wipe both backends — the loaded transcript is for review; a
            // follow-up message starts a fresh backend conversation.
            let b = self.backend
            Task {
                switch b {
                case .llama: await self.llama.resetConversation()
                case .mlx: await self.mlx.resetConversation()
                }
                await MainActor.run { self.refreshTokenUsage() }
            }
        } catch {
            errorMessage = "Failed to load transcript: \(error.localizedDescription)"
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

    func reset() {
        stop()
        messages.removeAll()
        generationTokenCount = 0
        generationStart = nil
        generationEnd = nil
        currentConversationId = nil
        let b = self.backend
        Task {
            switch b {
            case .llama: await self.llama.resetConversation()
            case .mlx: await self.mlx.resetConversation()
            }
            await MainActor.run { self.refreshTokenUsage() }
        }
    }

    // MARK: - Vault

    /// Stable identifier string used as the vault's `model_id` column.
    private func vaultModelId() -> String {
        switch backend {
        case .llama:
            return UserDefaults.standard.string(forKey: PersistKey.llamaPath) ?? ""
        case .mlx:
            return mlxModelId.isEmpty ? "default" : mlxModelId
        }
    }

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

    // MARK: - Whisper file transcription

    /// Transcribe a dropped audio file with whisper.cpp. Output is prefixed
    /// with the source filename so the LLM gets context about what it's
    /// reading.
    func transcribeDroppedFile(url: URL) {
        transcribeURL(url, prefix: "[Transcript of \(url.lastPathComponent)]\n\n",
                      statusLabel: url.lastPathComponent)
    }

    /// Transcribe an in-app recording. Output is inserted as bare text —
    /// the user originates the recording, so they already know what it is.
    func transcribeRecording(url: URL) {
        transcribeURL(url, prefix: nil, statusLabel: "recording")
    }

    private func transcribeURL(_ url: URL, prefix: String?, statusLabel: String) {
        guard !isTranscribingFile else {
            errorMessage = "Already transcribing an audio file. Please wait."
            return
        }
        isTranscribingFile = true
        transcriptionStatus = "Preparing \(statusLabel)…"

        Task { [weak self] in
            guard let self else { return }
            do {
                let modelURL = try await self.whisperModels.ensureDownloaded()
                try await WhisperRunner.shared.load(modelPath: modelURL.path)

                await MainActor.run {
                    self.transcriptionStatus = "Transcribing \(statusLabel)…"
                }
                let translate = self.whisperModels.translate
                let text = try await WhisperRunner.shared.transcribeFile(
                    url: url, translate: translate
                )

                await MainActor.run {
                    self.transcriptionStatus = nil
                    self.isTranscribingFile = false
                    if text.isEmpty {
                        self.errorMessage = "Transcription of \(statusLabel) produced no text."
                        return
                    }
                    let toInsert = (prefix ?? "") + text
                    if self.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.input = toInsert
                    } else {
                        let sep = self.input.hasSuffix("\n") ? "\n" : "\n\n"
                        self.input += sep + toInsert
                    }
                }
            } catch {
                await MainActor.run {
                    self.transcriptionStatus = nil
                    self.isTranscribingFile = false
                    self.errorMessage = "Transcription failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Toggle the mic recorder. On stop, kicks off transcription of the
    /// recorded .wav. Runs concurrently with normal dictation (they use
    /// separate AVAudioEngine instances) but is disabled in the UI when
    /// dictation is active to avoid audio routing surprises.
    func toggleAudioRecording() {
        if audioRecorder.isRecording {
            if let url = audioRecorder.stop() {
                transcribeRecording(url: url)
            }
        } else {
            do {
                try audioRecorder.start()
            } catch {
                errorMessage = "Could not start recording: \(error.localizedDescription)"
            }
        }
    }

    func cancelAudioRecording() {
        audioRecorder.cancel()
    }

    /// Open the recordings directory in Finder. Creates it on demand so the
    /// user doesn't hit a "nothing selected" window on first use.
    func revealRecordingsInFinder() {
        do {
            let dir = try AudioFileRecorder.recordingsDirectory()
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        } catch {
            errorMessage = "Could not open recordings folder: \(error.localizedDescription)"
        }
    }

    /// Delete every `.wav` under the recordings directory. Caller is
    /// expected to have confirmed via NSAlert.
    func clearRecordings() {
        do {
            let dir = try AudioFileRecorder.recordingsDirectory()
            let fm = FileManager.default
            let urls = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for url in urls where url.pathExtension.lowercased() == "wav" {
                try? fm.removeItem(at: url)
            }
        } catch {
            errorMessage = "Could not clear recordings: \(error.localizedDescription)"
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

struct ChatView: View {
    @Bindable var vm: ChatViewModel
    @AppStorage(PersistKey.sidebarOpen) private var sidebarOpen: Bool = true
    @State private var composerExpanded: Bool = false
    @FocusState private var composerFocused: Bool
    @State private var pinnedToBottom: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()
                transcript
                transcriptionBanner
                Divider()
                composer
            }
            .frame(minWidth: 520)

            if sidebarOpen {
                Divider()
                SidebarView(vm: vm)
                    .frame(width: 280)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(minWidth: sidebarOpen ? 800 : 520, minHeight: 500)
        .animation(.easeInOut(duration: 0.18), value: sidebarOpen)
        .onDrop(of: [.audiovisualContent, .audio, .fileURL], isTargeted: nil) { providers in
            handleAudioDrop(providers: providers)
        }
        .alert("Error",
               isPresented: Binding(
                get: { vm.errorMessage != nil },
                set: { if !$0 { vm.errorMessage = nil } }
               ),
               actions: { Button("OK") { vm.errorMessage = nil } },
               message: { Text(vm.errorMessage ?? "") })
    }

    private var header: some View {
        HStack(spacing: 12) {
            statusView
            tokenIndicator
            generationRateView

            Spacer()

            Button("Reset") { vm.reset() }
                .disabled(vm.messages.isEmpty && !vm.isGenerating)

            Button {
                sidebarOpen.toggle()
            } label: {
                Image(systemName: sidebarOpen ? "sidebar.right" : "sidebar.squares.right")
            }
            .help(sidebarOpen ? "Hide sidebar" : "Show sidebar")
        }
        .padding(10)
    }

    @ViewBuilder
    private var generationRateView: some View {
        if let stats = vm.generationStats {
            Text("\(stats.tokens) tok · \(String(format: "%.1f", stats.tps)) tok/s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(vm.isGenerating ? SwiftUI.Color.accentColor : SwiftUI.Color.secondary)
                .help(vm.isGenerating ? "Generation in progress" : "Last generation stats")
        }
    }

    @ViewBuilder
    private var tokenIndicator: some View {
        if let usage = vm.tokenUsage {
            if let total = usage.total, total > 0 {
                let ratio = min(1.0, Double(usage.used) / Double(total))
                let tint: SwiftUI.Color = ratio > 0.95 ? .red : (ratio > 0.80 ? .orange : .accentColor)
                HStack(spacing: 6) {
                    ProgressView(value: ratio)
                        .progressViewStyle(.linear)
                        .tint(tint)
                        .frame(width: 80)
                    Text("\(usage.used) / \(total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .help("Context window: \(usage.used) of \(total) tokens used")
            } else {
                Text("~\(usage.used) tok")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Approximate token count (backend does not expose context size)")
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if vm.isLoadingModel {
            HStack(spacing: 6) {
                if let p = vm.downloadProgress {
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                    Text("\(Int(p * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(vm.modelStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            Text(vm.modelStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.messages) { msg in
                        MessageRow(message: msg).id(msg.id)
                    }
                    // Bottom sentinel: when the LazyVStack has it in its
                    // render range (user is near the bottom), we're pinned
                    // and streaming auto-scrolls. Scrolling up unloads it
                    // and unpins.
                    Color.clear
                        .frame(height: 1)
                        .onAppear { pinnedToBottom = true }
                        .onDisappear { pinnedToBottom = false }
                        .id("_bottom_sentinel")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.textBackgroundColor))
            .onChange(of: vm.messages.last?.text) { _, _ in
                if pinnedToBottom, let last = vm.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: vm.messages.count) { _, _ in
                // A new turn was appended — treat as a user intention to
                // follow the conversation again.
                pinnedToBottom = true
                if let last = vm.messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if !pinnedToBottom, !vm.messages.isEmpty {
                    Button {
                        pinnedToBottom = true
                        if let last = vm.messages.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color.secondary.opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: pinnedToBottom)
        }
    }

    @ViewBuilder
    private var transcriptionBanner: some View {
        if let status = vm.transcriptionStatus {
            HStack(spacing: 8) {
                if let p = vm.whisperModels.downloadProgress {
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                    Text("\(Int(p * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial)
            .overlay(Divider(), alignment: .top)
        }
    }

    private func handleAudioDrop(providers: [NSItemProvider]) -> Bool {
        guard !vm.isTranscribingFile else { return false }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    let ext = url.pathExtension.lowercased()
                    // Conservative whitelist; AVAudioFile can actually open a
                    // broader set, but anything outside these is rarely audio.
                    let allowed: Set<String> = [
                        "wav", "mp3", "m4a", "aac", "aiff", "aif", "caf",
                        "flac", "mp4", "mov", "mpeg", "mpg", "ogg", "opus"
                    ]
                    guard allowed.contains(ext) else { return }
                    DispatchQueue.main.async { vm.transcribeDroppedFile(url: url) }
                }
                return true
            }
        }
        return false
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                composerExpanded.toggle()
                DispatchQueue.main.async { composerFocused = true }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(composerExpanded ? 90 : 0))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(composerExpanded ? "Collapse editor" : "Expand editor")
            .padding(.bottom, 4)

            micButton
                .padding(.bottom, 4)

            Group {
                if composerExpanded {
                    expandedEditor
                } else {
                    collapsedField
                }
            }

            if vm.isGenerating {
                Button("Stop") { vm.stop() }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button("Send") {
                    vm.send()
                    if composerExpanded { composerExpanded = false }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!vm.modelLoaded || vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .animation(.easeInOut(duration: 0.15), value: composerExpanded)
    }

    private var micButton: some View {
        let recording = vm.speechRecognizer.isRecording
        let starting = vm.speechRecognizer.isStarting
        let active = recording || starting
        return Button {
            vm.speechRecognizer.toggle(baseline: vm.input) { text in
                if let stripped = ChatViewModel.stripTrailingTrigger(text, phrase: vm.voiceSendPhrase) {
                    vm.input = stripped
                    vm.speechRecognizer.cancel()
                    if vm.modelLoaded, !stripped.isEmpty { vm.send() }
                } else {
                    vm.input = text
                }
            }
        } label: {
            Image(systemName: active ? "mic.fill" : "mic")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? .red : .secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(starting && !recording)
        .help(recording ? "Stop dictation" : "Dictate (on-device)")
    }

    private var collapsedField: some View {
        TextField("Message", text: $vm.input, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...6)
            .font(.body)
            .focused($composerFocused)
            .onKeyPress(keys: [.return], phases: .down) { keyPress in
                if keyPress.modifiers.contains(.shift) {
                    // NSTextField can't insert newlines, so auto-expand
                    // into the TextEditor and carry the newline forward.
                    vm.input += "\n"
                    composerExpanded = true
                    DispatchQueue.main.async { composerFocused = true }
                    return .handled
                }
                vm.send()
                return .handled
            }
    }

    private var expandedEditor: some View {
        TextEditor(text: $vm.input)
            .font(.body)
            .focused($composerFocused)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: 120, maxHeight: 260)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.35))
            )
            .overlay(alignment: .bottomTrailing) {
                Text("Cmd+Return to send")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(6)
            }
    }
}

private enum SidebarTab: String, CaseIterable, Identifiable {
    case model, history, voice, appearance
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .model: return "cube.box"
        case .history: return "clock.arrow.circlepath"
        case .voice: return "waveform"
        case .appearance: return "paintbrush"
        }
    }
    var label: String {
        switch self {
        case .model: return "Model"
        case .history: return "History"
        case .voice: return "Voice"
        case .appearance: return "Appearance"
        }
    }
}

private struct SidebarView: View {
    @Bindable var vm: ChatViewModel
    @State private var draft: InferSettings = .defaults
    @State private var showSystemPrompt = false
    @State private var didSeed = false
    @State private var tab: SidebarTab = .model
    @AppStorage(PersistKey.appearance) private var appearanceRaw: String = AppearanceMode.light.rawValue

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .model:
                        modelSection
                        parametersSection
                    case .history:
                        historySection
                    case .voice:
                        speechSection
                    case .appearance:
                        appearanceSection
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if !didSeed { draft = vm.settings; didSeed = true }
            vm.refreshVaultRecents()
        }
    }

    private var tabBar: some View {
        Picker("", selection: $tab) {
            ForEach(SidebarTab.allCases) { t in
                Image(systemName: t.icon)
                    .help(t.label)
                    .tag(t)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search conversations", text: Binding(
                get: { vm.vaultQuery },
                set: { vm.vaultQuery = $0; vm.scheduleVaultSearch() }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)

            let isSearching = !vm.vaultQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            if isSearching {
                if vm.vaultResults.isEmpty {
                    Text("No matches").font(.caption2).foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(vm.vaultResults) { hit in
                            VaultHitRow(hit: hit) { vm.loadVaultConversation(id: hit.conversationId) }
                        }
                    }
                }
            } else {
                if vm.vaultRecents.isEmpty {
                    Text("No saved conversations yet.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(vm.vaultRecents) { conv in
                            VaultConversationRow(
                                conv: conv,
                                onOpen: { vm.loadVaultConversation(id: conv.id) },
                                onDelete: { vm.deleteVaultConversation(id: conv.id) }
                            )
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Clear vault…") {
                    let alert = NSAlert()
                    alert.messageText = "Clear all saved conversations?"
                    alert.informativeText = "This removes every conversation in the vault and cannot be undone."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Clear")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        vm.clearVault()
                    }
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: Parameters

    private var parametersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(icon: "slider.horizontal.3", title: "Parameters")

            ParamRow(label: "Temperature",
                     value: String(format: "%.2f", draft.temperature)) {
                Slider(value: $draft.temperature, in: 0...2, step: 0.05)
            }

            ParamRow(label: "Top P",
                     value: String(format: "%.2f", draft.topP)) {
                Slider(value: $draft.topP, in: 0...1, step: 0.01)
            }

            ParamRow(label: "Max tokens",
                     value: "\(draft.maxTokens)") {
                Slider(
                    value: Binding(
                        get: { Double(draft.maxTokens) },
                        set: { draft.maxTokens = Int($0) }
                    ),
                    in: 64...8192,
                    step: 64
                )
            }

            DisclosureGroup(isExpanded: $showSystemPrompt) {
                TextEditor(text: $draft.systemPrompt)
                    .font(.body)
                    .frame(minHeight: 70, maxHeight: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                Text("Applying a change resets the conversation.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } label: {
                Text("System prompt").font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Reset") { draft = .defaults }
                    .controlSize(.small)
                Spacer()
                Button("Apply") { vm.applySettings(draft) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(draftMatchesCurrent)
            }
            .padding(.top, 4)
        }
    }

    private var draftMatchesCurrent: Bool {
        let s = vm.settings
        return s.systemPrompt == draft.systemPrompt
            && s.temperature == draft.temperature
            && s.topP == draft.topP
            && s.maxTokens == draft.maxTokens
    }

    // MARK: Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(icon: "cube.box", title: "Model")

            Picker("Backend", selection: $vm.backend) {
                ForEach(Backend.allCases) { b in
                    Text(b.label).tag(b)
                }
            }
            .pickerStyle(.segmented)
            .disabled(vm.isLoadingModel || vm.isGenerating)

            modelPicker

            if vm.backend == .mlx {
                TextField("HF repo id (empty = default)", text: $vm.mlxModelId)
                    .textFieldStyle(.roundedBorder)
                    .disabled(vm.isLoadingModel || vm.isGenerating)
            }

            HStack {
                if vm.isLoadingModel {
                    Button(role: .cancel) { vm.cancelLoad() } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    Button {
                        vm.loadCurrentBackend()
                    } label: {
                        Label(vm.backend == .llama ? "Browse…" : "Load",
                              systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(vm.isGenerating)
                }
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        let title = modelPickerTitle
        Menu {
            switch vm.backend {
            case .llama:
                if vm.recentLlamaPaths.isEmpty {
                    Text("No recent models").foregroundStyle(.secondary)
                } else {
                    ForEach(vm.recentLlamaPaths, id: \.self) { path in
                        Button((path as NSString).lastPathComponent) {
                            vm.loadLlamaPath(path)
                        }
                    }
                }
                Divider()
                Button("Browse for .gguf…") { vm.browseForLlamaModel() }
            case .mlx:
                if vm.recentMLXIds.isEmpty {
                    Text("No recent models").foregroundStyle(.secondary)
                } else {
                    ForEach(vm.recentMLXIds, id: \.self) { id in
                        Button(id) { vm.loadMLXId(id) }
                    }
                }
            }
        } label: {
            HStack {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3))
        )
        .disabled(vm.isLoadingModel || vm.isGenerating)
    }

    // MARK: Speech

    private var speechSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Read responses aloud", isOn: Binding(
                get: { vm.ttsEnabled },
                set: { vm.ttsEnabled = $0; if !$0 { vm.speechSynthesizer.stop() } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack {
                Text("Voice").font(.caption)
                Spacer()
                voiceMenu
            }
            .disabled(!vm.ttsEnabled)

            HStack(spacing: 6) {
                Button {
                    let sample = "The quick brown fox jumps over the lazy dog."
                    vm.speechSynthesizer.speak(
                        sample,
                        voiceIdentifier: vm.ttsVoiceId.isEmpty ? nil : vm.ttsVoiceId
                    )
                } label: {
                    Label("Preview", systemImage: "play.circle")
                }
                .controlSize(.small)
                .disabled(!vm.ttsEnabled)

                Button {
                    vm.speechSynthesizer.stop()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .controlSize(.small)
                .disabled(!vm.speechSynthesizer.isSpeaking)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Voice-send phrase").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. send it", text: Binding(
                    get: { vm.voiceSendPhrase },
                    set: { vm.voiceSendPhrase = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                Text("Saying this at the end of a dictation submits the message. Leave empty to disable.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)

            if !vm.speechRecognizer.supportsOnDevice {
                Text("On-device dictation unavailable for this locale.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            switch vm.speechRecognizer.state {
            case .error(let msg):
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .unauthorized:
                Text("Microphone or speech-recognition permission denied. Enable in System Settings > Privacy & Security.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .unavailable(let msg):
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle, .recording:
                EmptyView()
            }

            Divider().padding(.vertical, 4)

            whisperSubsection
        }
    }

    private var whisperSubsection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File transcription (whisper.cpp)")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Text("Model").font(.caption)
                Spacer()
                whisperModelMenu
            }

            Toggle("Translate to English", isOn: Binding(
                get: { vm.whisperModels.translate },
                set: { vm.whisperModels.setTranslate($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack(spacing: 6) {
                Button {
                    vm.toggleAudioRecording()
                } label: {
                    Label(
                        vm.audioRecorder.isRecording ? "Stop & Transcribe" : "Record",
                        systemImage: vm.audioRecorder.isRecording ? "stop.circle.fill" : "record.circle"
                    )
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(vm.audioRecorder.isRecording ? SwiftUI.Color.red : SwiftUI.Color.primary)
                }
                .controlSize(.small)
                .disabled(vm.isTranscribingFile && !vm.audioRecorder.isRecording)

                if vm.audioRecorder.isRecording {
                    Text(Self.formatDuration(vm.audioRecorder.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.red)
                    Button {
                        vm.cancelAudioRecording()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Discard recording")
                }
                Spacer()
            }

            if case .error(let msg) = vm.audioRecorder.state {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Record from the mic or drop audio/video files onto the window. Transcripts are inserted into the composer.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Button {
                    vm.revealRecordingsInFinder()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .controlSize(.small)

                Button {
                    let alert = NSAlert()
                    alert.messageText = "Delete all recordings?"
                    alert.informativeText = "Every .wav file under ~/Library/Application Support/Infer/recordings/ will be removed. This cannot be undone."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Delete")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        vm.clearRecordings()
                    }
                } label: {
                    Label("Clear recordings…", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(vm.audioRecorder.isRecording)

                Spacer()
            }

            if let msg = vm.whisperModels.statusMessage {
                HStack(spacing: 6) {
                    if let p = vm.whisperModels.downloadProgress {
                        ProgressView(value: p)
                            .progressViewStyle(.linear)
                            .frame(width: 80)
                        Text("\(Int(p * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    static func formatDuration(_ t: TimeInterval) -> String {
        let total = Int(t)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private var whisperModelMenu: some View {
        let current = vm.whisperModels.selected
        let downloaded = current.isDownloaded()
        let title = "\(current.label) (\(downloaded ? "ready" : current.approxSize))"
        return Menu {
            ForEach(WhisperModelChoice.allCases) { m in
                Button(action: { vm.whisperModels.setSelected(m) }) {
                    HStack {
                        Text(m.label)
                        Spacer()
                        Text(m.isDownloaded() ? "ready" : m.approxSize)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title).font(.caption)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(vm.isTranscribingFile || vm.whisperModels.downloadProgress != nil)
    }

    private var voiceMenu: some View {
        let voices = SpeechSynthesizer.availableVoices()
        let current = voices.first { $0.identifier == vm.ttsVoiceId }
        let title = current.map { "\($0.name) (\($0.language))" } ?? "System default"
        return Menu {
            Button("System default") { vm.ttsVoiceId = "" }
            Divider()
            ForEach(voices, id: \.identifier) { v in
                Button("\(v.name) — \(v.language)") { vm.ttsVoiceId = v.identifier }
            }
        } label: {
            HStack {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(
                get: { AppearanceMode(rawValue: appearanceRaw) ?? .light },
                set: { appearanceRaw = $0.rawValue }
            )) {
                ForEach(AppearanceMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var modelPickerTitle: String {
        switch vm.backend {
        case .llama:
            if let path = UserDefaults.standard.string(forKey: PersistKey.llamaPath), vm.modelLoaded {
                return (path as NSString).lastPathComponent
            }
            return "No Selection"
        case .mlx:
            if vm.modelLoaded, !vm.mlxModelId.isEmpty { return vm.mlxModelId }
            if vm.modelLoaded { return "default" }
            return "No Selection"
        }
    }
}

private struct SectionHeader: View {
    let icon: String
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
        }
    }
}

private struct ParamRow<Control: View>: View {
    let label: String
    let value: String
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(value)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            control()
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    @State private var isHovered = false
    @State private var justCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(roleLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            content
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topTrailing) {
            if isHovered, !message.text.isEmpty {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(message.text, forType: .string)
                    justCopied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        await MainActor.run { justCopied = false }
                    }
                } label: {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(justCopied ? SwiftUI.Color.green : SwiftUI.Color.secondary)
                        .padding(4)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Copy message")
                .transition(.opacity)
            }
        }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: justCopied)
    }

    @ViewBuilder
    private var content: some View {
        if message.text.isEmpty {
            Text("…").foregroundStyle(.secondary)
        } else {
            switch message.role {
            case .assistant:
                Markdown(message.text)
                    .markdownTheme(.gitHub)
                    .markdownCodeSyntaxHighlighter(
                        .splash(theme: .sundellsColors(withFont: .init(size: 14)))
                    )
                    .environment(\.openURL, OpenURLAction { url in
                        NSWorkspace.shared.open(url)
                        return .handled
                    })
            case .user, .system:
                Text(message.text)
            }
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return "user"
        case .assistant: return "assistant"
        case .system: return "system"
        }
    }
}

// MARK: - Vault row views

private struct VaultConversationRow: View {
    let conv: VaultConversationSummary
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(conv.title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Text(conv.backend)
                        Text("·")
                        Text(Self.relativeDate(conv.updatedAt))
                        Text("·")
                        Text("\(conv.messageCount) msg")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open", action: onOpen)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private static let relFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func relativeDate(_ d: Date) -> String {
        relFormatter.localizedString(for: d, relativeTo: Date())
    }
}

private struct VaultHitRow: View {
    let hit: VaultSearchHit
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(hit.conversationTitle)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(hit.role)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(Self.attributed(from: hit.snippet))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    /// Parse FTS5 snippet output (`...<mark>term</mark>...`) into an
    /// AttributedString with highlighted runs. Unknown `<mark>` HTML is the
    /// only markup our snippet() call emits, so this parser is intentionally
    /// trivial rather than going through NSAttributedString's HTML import.
    static func attributed(from snippet: String) -> AttributedString {
        var out = AttributedString()
        var remaining = Substring(snippet)
        while let openRange = remaining.range(of: "<mark>") {
            let before = remaining[..<openRange.lowerBound]
            if !before.isEmpty {
                out.append(AttributedString(String(before)))
            }
            let afterOpen = remaining[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: "</mark>") else {
                out.append(AttributedString(String(afterOpen)))
                return out
            }
            let marked = afterOpen[..<closeRange.lowerBound]
            var run = AttributedString(String(marked))
            run.backgroundColor = .yellow.opacity(0.4)
            run.foregroundColor = .primary
            out.append(run)
            remaining = afterOpen[closeRange.upperBound...]
        }
        if !remaining.isEmpty {
            out.append(AttributedString(String(remaining)))
        }
        return out
    }
}
