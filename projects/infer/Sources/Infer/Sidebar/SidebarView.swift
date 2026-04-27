import SwiftUI
import InferCore

enum SidebarTab: String, CaseIterable, Identifiable {
    case model, agents, tools, history, voice, appearance, console
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .model: return "cube.box"
        case .agents: return "person.crop.circle.badge.questionmark"
        case .tools: return "wrench.and.screwdriver"
        case .history: return "clock.arrow.circlepath"
        case .console: return "terminal"
        case .voice: return "waveform"
        case .appearance: return "paintbrush"
        }
    }
    var label: String {
        switch self {
        case .model: return "Model"
        case .agents: return "Agents"
        case .tools: return "Tools"
        case .history: return "History"
        case .console: return "Console"
        case .voice: return "Voice"
        case .appearance: return "Appearance"
        }
    }
}

struct SidebarView: View {
    @Bindable var vm: ChatViewModel
    @State var draft: InferSettings = .defaults
    @State var showSystemPrompt = false
    @State var didSeed = false
    @AppStorage(PersistKey.sidebarTab) var tabRaw: String = SidebarTab.model.rawValue

    var tab: Binding<SidebarTab> {
        Binding(
            get: { SidebarTab(rawValue: tabRaw) ?? .model },
            set: { tabRaw = $0.rawValue }
        )
    }
    @AppStorage(PersistKey.appearance) var appearanceRaw: String = AppearanceMode.light.rawValue

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab.wrappedValue {
                    case .model:
                        modelSection
                        parametersSection
                    case .agents:
                        agentsLibrarySection
                    case .tools:
                        toolsSection
                    case .history:
                        historySection
                    case .console:
                        consoleSection
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

    var tabBar: some View {
        Picker("", selection: tab) {
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

    var modelPickerTitle: String {
        if vm.modelLoaded, let cur = vm.currentModelId, !cur.isEmpty {
            switch vm.backend {
            case .llama: return (cur as NSString).lastPathComponent
            case .mlx: return cur
            }
        }
        if vm.availableModels.isEmpty { return "No downloaded models" }
        return "Choose a model…"
    }

    static func dropdownLabel(for entry: VaultModelEntry) -> String {
        let tag: String
        switch entry.backend {
        case Backend.llama.rawValue: tag = "GGUF"
        case Backend.mlx.rawValue: tag = "MLX"
        default: tag = entry.backend
        }
        let name: String
        if entry.backend == Backend.llama.rawValue {
            name = (entry.modelId as NSString).lastPathComponent
        } else {
            name = entry.modelId
        }
        return "[\(tag)] \(name)"
    }
}
