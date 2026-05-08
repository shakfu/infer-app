import SwiftUI
import AppKit
import UniformTypeIdentifiers
import InferCore

struct ChatView: View {
    @Bindable var vm: ChatViewModel
    @AppStorage(PersistKey.sidebarOpen) var sidebarOpen: Bool = true
    /// Independent visibility flag for the left wiki sidebar so users
    /// can collapse it without affecting the right (Model / Agents /
    /// etc.) sidebar.
    @AppStorage(PersistKey.wikiSidebarOpen) var wikiSidebarOpen: Bool = true
    @State var composerExpanded: Bool = false
    @FocusState var composerFocused: Bool
    @State var pinnedToBottom: Bool = true
    /// SwiftUI's macOS-14+ Settings opener. The `Settings { }` scene
    /// in `InferApp` registers as the target; calling this from the
    /// cog icon in the header surfaces the same window Cmd-, opens.
    @Environment(\.openSettings) var openSettings

    var body: some View {
        HStack(spacing: 0) {
            if wikiSidebarOpen {
                WikiSidebar(vm: vm)
                    .frame(width: 240)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }

            VStack(spacing: 0) {
                MainContentTabBar(vm: vm)
                Divider()
                Group {
                    switch vm.activeTab {
                    case .chat:
                        chatTabContent
                    case .page(let id):
                        WikiPageView(vm: vm, pageId: id)
                            .id(id)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 520)

            if sidebarOpen {
                Divider()
                SidebarView(vm: vm)
                    .frame(width: 280)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(
            minWidth: (sidebarOpen ? 800 : 520) + (wikiSidebarOpen ? 240 : 0),
            minHeight: 500
        )
        .animation(.easeInOut(duration: 0.18), value: sidebarOpen)
        .animation(.easeInOut(duration: 0.18), value: wikiSidebarOpen)
        .background(tabKeyboardShortcuts)
        .overlay(alignment: .bottom) {
            ToastOverlay(center: vm.toasts)
                .animation(.easeInOut(duration: 0.2), value: vm.toasts.current)
                .allowsHitTesting(vm.toasts.current != nil)
        }
        .sheet(item: $vm.inspectorListing) { listing in
            AgentInspectorView(vm: vm, listing: listing) {
                vm.inspectorListing = nil
            }
        }
        // Workspace creation still uses the modal sheet — single
        // decision point that benefits from focus. Editing existing
        // workspaces happens inline in the WikiSidebar
        // (`WorkspaceSettingsInline`); the `workspaceInSheet` field on
        // the VM is no longer presented modally.
        .sheet(isPresented: Binding(
            get: { vm.creatingWorkspace },
            set: { open in
                if !open {
                    vm.workspaceInSheet = nil
                    vm.creatingWorkspace = false
                }
            }
        )) {
            WorkspaceSheet(vm: vm) {
                vm.workspaceInSheet = nil
                vm.creatingWorkspace = false
            }
        }
        .sheet(isPresented: $vm.showQuickSwitcher) {
            WikiQuickSwitcher(vm: vm)
        }
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

    /// Hidden zero-size buttons that register Cmd+W (close active
    /// tab) and Cmd+1..9 (switch to tab N) keyboard shortcuts.
    /// Cmd+W is only registered when the active tab is a page so the
    /// system Close-Window shortcut still works when the user is on
    /// the (uncloseable) Chat tab.
    @ViewBuilder
    private var tabKeyboardShortcuts: some View {
        Group {
            if vm.activeTab != .chat {
                Button("") { vm.closeTab(vm.activeTab) }
                    .keyboardShortcut("w", modifiers: .command)
            }
            // Cmd+1..9 — index into vm.openTabs (1-indexed for the
            // user, 0-indexed in the array). Out-of-range indices
            // are no-ops.
            ForEach(1...9, id: \.self) { n in
                Button("") {
                    let idx = n - 1
                    guard vm.openTabs.indices.contains(idx) else { return }
                    vm.switchTab(vm.openTabs[idx])
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(String(n))),
                    modifiers: .command
                )
            }
            // Cmd+O — fuzzy quick-switcher. Mirrors Obsidian's
            // shortcut for the same affordance. Only fires when a
            // workspace is active (no point opening the picker with
            // an empty page list).
            Button("") {
                if vm.activeWorkspaceId != nil {
                    vm.showQuickSwitcher = true
                }
            }
            .keyboardShortcut("o", modifiers: .command)
            // Cmd+F — open the in-transcript find bar. Only fires
            // on the chat tab; on a wiki page tab the system-level
            // Find bar of `usesFindBar=true` NSTextView handles
            // intra-document search instead.
            if vm.activeTab == .chat {
                Button("") { vm.transcriptFindOpen() }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// What the main content area renders when the active tab is
    /// `.chat`. Same elements as before the Phase 4a tab restructure
    /// (header + transcript + transcription banner + composer); the
    /// outer tab bar replaces the previous responsibility for telling
    /// the user "you're in chat mode."
    @ViewBuilder
    var chatTabContent: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            transcriptionBanner
            Divider()
            composer
        }
    }

    func handleAudioDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { vm.attachURL(url) }
                }
                return true
            }
        }
        return false
    }
}
