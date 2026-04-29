import SwiftUI
import InferCore

// Tools, Appearance migrated to the Settings window (Cmd-,) in P2/P3
// of the Settings migration. Voice and Model-parameters were
// migrated, then reverted back to the sidebar — they're accessed
// often enough during normal use that the extra Cmd-, hop wasn't
// worth it (Settings is for set-once-and-forget configuration).
// Stale `tools` / `appearance` raw values read from UserDefaults
// fall through `SidebarTab(rawValue:) ?? .model` and land on the
// Model tab.
enum SidebarTab: String, CaseIterable, Identifiable {
    case model, agents, image, history, voice, console
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .model: return "cube.box"
        case .agents: return "person.crop.circle.badge.questionmark"
        case .image: return "photo.on.rectangle"
        case .history: return "clock.arrow.circlepath"
        case .voice: return "waveform"
        case .console: return "terminal"
        }
    }
    var label: String {
        switch self {
        case .model: return "Model"
        case .agents: return "Agents"
        case .image: return "Image"
        case .history: return "History"
        case .voice: return "Voice"
        case .console: return "Console"
        }
    }
}

struct SidebarView: View {
    @Bindable var vm: ChatViewModel
    /// Local draft of `vm.settings` for the parameters card's
    /// Apply/Reset pattern — sliders mutate this in-place and
    /// `vm.applySettings(draft)` writes it back to the runner. Keeps
    /// each slider tick from re-initialising the model.
    @State var draft: InferSettings = .defaults
    @State var showSystemPrompt = false
    @State var didSeed = false
    /// Controls the "Set API Key…" sheet for the cloud backend. Owned
    /// here (not the VM) because it's transient UI state with no
    /// persistence requirement.
    @State var showingCloudKeySheet = false
    @AppStorage(PersistKey.sidebarTab) var tabRaw: String = SidebarTab.model.rawValue

    var tab: Binding<SidebarTab> {
        Binding(
            get: { SidebarTab(rawValue: tabRaw) ?? .model },
            set: { tabRaw = $0.rawValue }
        )
    }

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
                    case .image:
                        imageSection
                    case .history:
                        historySection
                    case .voice:
                        speechSection
                    case .console:
                        consoleSection
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
            case .cloud: return cur
            }
        }
        if vm.backend == .cloud {
            // Cloud doesn't list "downloaded" models — the user picks
            // provider + model id directly via the cloud config row, so
            // a "Choose a model" hint here would be misleading. Leave
            // the field empty until configured.
            return vm.cloudActiveModel.isEmpty ? "Configure cloud below" : vm.cloudActiveModel
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
