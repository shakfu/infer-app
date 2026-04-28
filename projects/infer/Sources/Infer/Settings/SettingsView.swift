import SwiftUI

/// Root of the macOS Settings window. Wired from the App scene via
/// SwiftUI's `Settings { }` builder, which auto-binds Cmd-, and adds
/// the "Settings…" item to the App menu. The cog icon in
/// `ChatHeader` invokes `NSApplication.showSettingsWindow(_:)` to
/// surface the same window from the chat panel.
///
/// Phasing — see `docs/dev/plugins.md` and the Settings discussion in
/// the project README:
///   P1 (this PR): Plugins tab only. Sidebar Tools/Voice/Appearance
///                 unchanged.
///   P2: Tools moves here; sidebar Tools tab removed.
///   P3: Voice + Appearance + Model parameters move here.
struct SettingsView: View {
    var vm: ChatViewModel

    var body: some View {
        TabView {
            ModelParametersSettingsView(vm: vm)
                .tabItem { Label("Model", systemImage: "slider.horizontal.3") }
                .tag(SettingsTab.modelParameters)

            VoiceSettingsView(vm: vm)
                .tabItem { Label("Voice", systemImage: "waveform") }
                .tag(SettingsTab.voice)

            ToolsSettingsView(vm: vm)
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.tools)

            PluginsSettingsView(entries: vm.pluginStatus)
                .tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }
                .tag(SettingsTab.plugins)

            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(SettingsTab.appearance)
        }
        .frame(minWidth: 560, minHeight: 420)
        .padding(.bottom, 8)
    }
}

enum SettingsTab: Hashable {
    case modelParameters
    case voice
    case tools
    case plugins
    case appearance
}
