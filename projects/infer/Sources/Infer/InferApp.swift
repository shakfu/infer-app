import SwiftUI
import AppKit
import llama
import InferCore
import InferRAG

@main
struct InferApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var chatVM = ChatViewModel()
    @AppStorage("infer.appearance") private var appearanceRaw: String = AppearanceMode.light.rawValue
    @AppStorage(PersistKey.sidebarOpen) private var sidebarOpen: Bool = true
    @AppStorage(PersistKey.sidebarTab) private var sidebarTabRaw: String = SidebarTab.model.rawValue

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
                Divider()
                Button("Export as HTML…") { chatVM.exportTranscriptHTML() }
                    .disabled(chatVM.messages.isEmpty)
                Button("Export as PDF…") { chatVM.exportTranscriptPDF() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
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
            CommandMenu("Agent") {
                Button("Focus Agent Picker") {
                    sidebarTabRaw = SidebarTab.agents.rawValue
                    sidebarOpen = true
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help("Open the Agents tab in the sidebar to switch or inspect the active agent.")

                Button("Inspect Active Agent") {
                    // Direct presentation — the sheet lives on `ChatView`,
                    // which is always in the view hierarchy, so this works
                    // regardless of which sidebar tab is active.
                    chatVM.inspectorListing = chatVM.activeAgentListing
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .help("Open a read-only view of the active agent's configuration.")
            }
            CommandMenu("Speech") {
                Button("Stop Speaking") { chatVM.speechSynthesizer.stop() }
                    // Parallels ⌘. (Stop generation); ⌘⇧. targets speech.
                    // Works whenever TTS is speaking, regardless of whether
                    // barge-in or continuous-voice mode is on.
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    .disabled(!chatVM.speechSynthesizer.isSpeaking)
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
        // Register sqlite-vec with SQLiteVec's bundled SQLite as early
        // as possible. Every Database opened after this point gets
        // the vec0 virtual table machinery. Idempotent — safe to call
        // before the first VectorStore access.
        do {
            try RAG.initialize()
        } catch {
            // Non-fatal: RAG will fail cleanly on first ingest. Log
            // so the cause shows up in the Console tab.
            FileHandle.standardError.write(
                Data("RAG.initialize() failed: \(error)\n".utf8)
            )
        }
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
            await vm.embedder.shutdown()
            await vm.reranker.shutdown()
            await vm.vectorStore.shutdown()
            await MainActor.run { vm.audioRecorder.cancel() }
            await WhisperRunner.shared.shutdown()
            await VaultStore.shared.shutdown()
            llama_backend_free()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2.0)
    }
}
