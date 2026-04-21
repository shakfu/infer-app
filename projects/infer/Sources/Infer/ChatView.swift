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
    var recentLlamaPaths: [String] = UserDefaults.standard.stringArray(forKey: PersistKey.recentLlamaPaths) ?? []
    var recentMLXIds: [String] = UserDefaults.standard.stringArray(forKey: PersistKey.recentMLXIds) ?? []

    let llama = LlamaRunner()
    let mlx = MLXRunner()
    let speechRecognizer = SpeechRecognizer()
    let speechSynthesizer = SpeechSynthesizer()

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

        let backend = self.backend
        let maxTokens = self.settings.maxTokens

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
                await MainActor.run { self.messages.removeAll() }
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
        let b = self.backend
        Task {
            switch b {
            case .llama: await self.llama.resetConversation()
            case .mlx: await self.mlx.resetConversation()
            }
            await MainActor.run { self.refreshTokenUsage() }
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

private struct SidebarView: View {
    @Bindable var vm: ChatViewModel
    @State private var draft: InferSettings = .defaults
    @State private var showSystemPrompt = false
    @State private var didSeed = false
    @AppStorage(PersistKey.appearance) private var appearanceRaw: String = AppearanceMode.light.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                parametersSection
                modelSection
                speechSection
                appearanceSection
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if !didSeed { draft = vm.settings; didSeed = true }
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
            SectionHeader(icon: "waveform", title: "Speech")

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
        }
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
            SectionHeader(icon: "paintbrush", title: "Appearance")
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
