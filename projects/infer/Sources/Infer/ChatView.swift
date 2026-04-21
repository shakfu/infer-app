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
    var recentLlamaPaths: [String] = UserDefaults.standard.stringArray(forKey: PersistKey.recentLlamaPaths) ?? []
    var recentMLXIds: [String] = UserDefaults.standard.stringArray(forKey: PersistKey.recentMLXIds) ?? []

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
                    self.rememberRecent(mlxId: hfId)
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
    @AppStorage(PersistKey.sidebarOpen) private var sidebarOpen: Bool = true

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
