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

    let llama = LlamaRunner()
    let mlx = MLXRunner()
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
        downloadProgress = 0
        let id = hfId.isEmpty ? nil : hfId
        modelStatus = "Downloading \(id ?? "default")…"
        errorMessage = nil
        let runner = self.mlx
        let s = self.settings
        loadTask = Task { [weak self] in
            let progressHandler: @Sendable (Progress) -> Void = { progress in
                let frac = progress.totalUnitCount > 0
                    ? Double(progress.completedUnitCount) / Double(progress.totalUnitCount)
                    : nil
                Task { @MainActor in
                    self?.downloadProgress = frac
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

    // MARK: - Copy / Print

    func copyTranscriptAsMarkdown() {
        let text = messages
            .map { "## \($0.role.rawValue)\n\n\($0.text)" }
            .joined(separator: "\n\n---\n\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func printTranscript() {
        PrintRenderer.printTranscript(messages)
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
        }
    }
}

struct ChatView: View {
    @Bindable var vm: ChatViewModel
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .frame(minWidth: 600, minHeight: 500)
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
            Picker("", selection: $vm.backend) {
                ForEach(Backend.allCases) { b in
                    Text(b.label).tag(b)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .disabled(vm.isLoadingModel || vm.isGenerating)

            if vm.backend == .mlx {
                TextField("HF repo id (empty = default)", text: $vm.mlxModelId)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .disabled(vm.isLoadingModel || vm.isGenerating)
            }

            if vm.isLoadingModel {
                Button(action: { vm.cancelLoad() }) {
                    Label("Cancel", systemImage: "xmark.circle")
                }
            } else {
                Button(action: { vm.loadCurrentBackend() }) {
                    Label(vm.backend == .llama ? "Load Model…" : "Load",
                          systemImage: "tray.and.arrow.down")
                }
                .disabled(vm.isGenerating)
            }

            statusView

            Spacer()

            Button(action: { showingSettings.toggle() }) {
                Image(systemName: "gearshape")
            }
            .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                SettingsView(initial: vm.settings) { applied in
                    vm.applySettings(applied)
                    showingSettings = false
                }
            }

            Button("Reset") { vm.reset() }
                .disabled(vm.messages.isEmpty && !vm.isGenerating)
        }
        .padding(10)
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
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.textBackgroundColor))
            .onChange(of: vm.messages.last?.text) { _, _ in
                if let last = vm.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $vm.input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .font(.body)
                .onSubmit { vm.send() }

            if vm.isGenerating {
                Button("Stop") { vm.stop() }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button("Send") { vm.send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!vm.modelLoaded || vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
    }
}

private struct SettingsView: View {
    @State private var draft: InferSettings
    let onApply: (InferSettings) -> Void

    init(initial: InferSettings, onApply: @escaping (InferSettings) -> Void) {
        _draft = State(initialValue: initial)
        self.onApply = onApply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("System prompt").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.systemPrompt)
                    .font(.body)
                    .frame(minHeight: 80, maxHeight: 140)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                Text("Changes reset the conversation.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            HStack {
                Text("Temperature").frame(width: 90, alignment: .leading)
                Slider(value: $draft.temperature, in: 0...2, step: 0.05)
                Text(String(format: "%.2f", draft.temperature))
                    .font(.caption.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }

            HStack {
                Text("top_p").frame(width: 90, alignment: .leading)
                Slider(value: $draft.topP, in: 0...1, step: 0.01)
                Text(String(format: "%.2f", draft.topP))
                    .font(.caption.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }

            HStack {
                Text("Max tokens").frame(width: 90, alignment: .leading)
                Stepper(value: $draft.maxTokens, in: 64...8192, step: 64) {
                    Text("\(draft.maxTokens)")
                        .font(.body.monospacedDigit())
                }
            }

            HStack {
                Button("Reset to defaults") { draft = .defaults }
                Spacer()
                Button("Apply") { onApply(draft) }
                    .keyboardShortcut(.return, modifiers: [])
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}

private struct MessageRow: View {
    let message: ChatMessage

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
