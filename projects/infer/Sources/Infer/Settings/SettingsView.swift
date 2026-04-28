import SwiftUI

/// Root of the macOS Settings window. Wired from the App scene via
/// SwiftUI's `Settings { }` builder, which auto-binds Cmd-, and adds
/// the "Settings…" item to the App menu. The cog icon in
/// `ChatHeader` invokes `NSApplication.showSettingsWindow(_:)` to
/// surface the same window from the chat panel.
///
/// What lives here: configuration that is set-once-and-forget
/// (Tools, Plugins, Appearance). What does *not* live here: anything
/// the user touches mid-session — Model parameters and Voice are in
/// the sidebar (Model tab and Voice tab respectively). They were
/// migrated here in P3 of the original Settings work and reverted
/// after early use showed the extra Cmd-, hop wasn't worth it.
struct SettingsView: View {
    var vm: ChatViewModel

    var body: some View {
        TabView {
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
        .frame(minWidth: 520, minHeight: 360)
        .padding(.bottom, 8)
    }
}

enum SettingsTab: Hashable {
    case tools
    case plugins
    case appearance
}
