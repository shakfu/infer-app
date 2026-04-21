import SwiftUI
import AppKit
import llama

@main
struct InferApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var chatVM = ChatViewModel()
    @AppStorage("infer.appearance") private var appearanceRaw: String = AppearanceMode.light.rawValue

    var body: some Scene {
        WindowGroup("Infer") {
            ChatView(vm: chatVM)
                .preferredColorScheme((AppearanceMode(rawValue: appearanceRaw) ?? .light).colorScheme)
                .onAppear {
                    appDelegate.chatVM = chatVM
                    chatVM.autoLoadLastModel()
                }
        }
        .defaultSize(width: 780, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Transcript…") { chatVM.loadTranscript() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Save Transcript…") { chatVM.saveTranscript() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(chatVM.messages.isEmpty)
            }
            CommandGroup(replacing: .printItem) {
                Button("Print Transcript…") { chatVM.printTranscript() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(chatVM.messages.isEmpty)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Copy Transcript as Markdown") { chatVM.copyTranscriptAsMarkdown() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(chatVM.messages.isEmpty)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Populated by InferApp.onAppear so terminate can reach the runner.
    var chatVM: ChatViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Block the main thread briefly so the llama context is freed and any
        // in-flight decode is cancelled before the process exits.
        guard let vm = chatVM else { return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await vm.llama.requestStop()
            await vm.llama.shutdown()
            await vm.mlx.requestStop()
            await vm.mlx.shutdown()
            llama_backend_free()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2.0)
    }
}
