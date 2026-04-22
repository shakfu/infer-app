import SwiftUI
import AppKit
import UniformTypeIdentifiers
import InferCore

struct ChatView: View {
    @Bindable var vm: ChatViewModel
    @AppStorage(PersistKey.sidebarOpen) var sidebarOpen: Bool = true
    @State var composerExpanded: Bool = false
    @FocusState var composerFocused: Bool
    @State var pinnedToBottom: Bool = true

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
