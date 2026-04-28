import SwiftUI
import InferCore

// Tools, Voice, Appearance, and the Model-parameters card all
// migrated to the Settings window (Cmd-,) across P2 and P3 of the
// Settings migration. The sidebar now holds only navigation/selection
// surfaces; configuration lives in Settings. Stale raw values
// (`tools`, `voice`, `appearance`) read from UserDefaults fall
// through `SidebarTab(rawValue:) ?? .model` and land on the Model
// tab — no migration needed.
enum SidebarTab: String, CaseIterable, Identifiable {
    case model, agents, history, console
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .model: return "cube.box"
        case .agents: return "person.crop.circle.badge.questionmark"
        case .history: return "clock.arrow.circlepath"
        case .console: return "terminal"
        }
    }
    var label: String {
        switch self {
        case .model: return "Model"
        case .agents: return "Agents"
        case .history: return "History"
        case .console: return "Console"
        }
    }
}

struct SidebarView: View {
    @Bindable var vm: ChatViewModel
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
                    case .agents:
                        agentsLibrarySection
                    case .history:
                        historySection
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
