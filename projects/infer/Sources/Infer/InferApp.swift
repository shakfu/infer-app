import SwiftUI
import AppKit
import LlamaCpp
import InferAgents
import InferCore
import InferRAG

@main
struct InferApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var chatVM = ChatViewModel()
    @AppStorage("infer.appearance") private var appearanceRaw: String = AppearanceMode.light.rawValue
    @AppStorage(PersistKey.sidebarOpen) private var sidebarOpen: Bool = true
    @AppStorage(PersistKey.sidebarTab) private var sidebarTabRaw: String = SidebarTab.model.rawValue

    /// Compatible agents in picker order (Personas before Agents,
    /// alphabetised within each kind), with the synthetic Default first.
    /// Mirrors the dropdown sectioning in `AgentPickerMenu` so the
    /// `⌘⌥N` shortcut maps to the Nth row a user actually sees.
    private func quickActivateTargets() -> [AgentListing] {
        let listings = chatVM.availableAgents.filter { chatVM.isVisibleAgent($0) }
        let personas = listings.filter { $0.kind == .persona }
        let agents = listings.filter { $0.kind == .agent }
        return personas + agents
    }

    /// `⌘⌥1` … `⌘⌥9`. `KeyEquivalent` constructs from a `Character`,
    /// so we map index → digit char.
    private func quickActivateKey(for index: Int) -> KeyEquivalent {
        let digit = Character(String(index + 1))
        return KeyEquivalent(digit)
    }

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

                Divider()

                // ⌘⌥1..9 quick-activate the first nine compatible agents
                // in the order the picker shows them. The shortcuts live
                // in the menu so they're discoverable (macOS Help search
                // surfaces menu items) and so the buttons disable cleanly
                // when there are fewer than N compatible agents. Index
                // matches the row position the user sees in the header
                // dropdown — Personas first, then Agents.
                ForEach(Array(quickActivateTargets().prefix(9).enumerated()), id: \.element.id) { idx, listing in
                    Button("Activate \(listing.name)") {
                        chatVM.switchAgent(to: listing)
                    }
                    .keyboardShortcut(quickActivateKey(for: idx), modifiers: [.command, .option])
                    .disabled(listing.id == chatVM.activeAgentId)
                }
            }
            CommandMenu("Speech") {
                Button("Stop Speaking") { chatVM.speechSynthesizer.stop() }
                    // Parallels ⌘. (Stop generation); ⌘⇧. targets speech.
                    // Works whenever TTS is speaking, regardless of whether
                    // barge-in or continuous-voice mode is on.
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    .disabled(!chatVM.speechSynthesizer.isSpeaking)
            }
            CommandGroup(after: .windowList) {
                GalleryMenuItem()
            }
        }
        Window("Gallery", id: galleryWindowID) {
            GalleryView(vm: chatVM)
                .preferredColorScheme((AppearanceMode(rawValue: appearanceRaw) ?? .light).colorScheme)
        }
        .defaultSize(width: 880, height: 640)
        // Settings window — Cmd-, opens it from anywhere in the app,
        // and the cog icon in `ChatHeader` invokes the same scene via
        // `NSApplication.showSettingsWindow(_:)`. P1 (this PR) ships
        // one tab (Plugins); P2/P3 add Tools / Voice / Appearance /
        // Model as the corresponding sidebar tabs migrate over.
        Settings {
            SettingsView(vm: chatVM)
                .preferredColorScheme((AppearanceMode(rawValue: appearanceRaw) ?? .light).colorScheme)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Populated by InferApp.onAppear so terminate can reach the runner.
    var chatVM: ChatViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Register defaults for keys whose intended fallback is `true`.
        // `UserDefaults.bool(forKey:)` returns false for unset keys, so
        // any `@AppStorage(...) ... = true` declaration silently reads
        // false on first launch unless we register the default here.
        UserDefaults.standard.register(defaults: [
            PersistKey.autoExpandAgentTraces: true,
        ])
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
        //
        // **Per-step timeout, not blanket.** The prior implementation
        // wrapped every shutdown in a single 2-second `DispatchSemaphore`
        // wait. If any one step stalled (an MCP subprocess wedged on
        // stdio, an HF download cancel, a SQLite WAL checkpoint), the
        // whole chain stalled and the app force-exited with later steps
        // — including `llama_backend_free` — un-run. That left a stale
        // llama backend across relaunch and either crashed `EXC_BAD_ACCESS`
        // on `llama_backend_init` or leaked the prior model context.
        //
        // The replacement runs each step on a detached task with its
        // own per-step timeout. Timeouts and slow completions are
        // logged to stderr so the next user can identify the culprit.
        // Stuck step A no longer starves step B; `llama_backend_free`
        // always runs at the end. Worst-case wall time is bounded by
        // `steps.count * perStepTimeout` (~5s with the values below);
        // the realistic median is <100ms because every step typically
        // completes in tens of ms.
        guard let vm = chatVM else { return }
        let perStepTimeout: TimeInterval = 0.3
        let slowStepLogThreshold: TimeInterval = 0.1
        let overallStarted = Date()

        // Each entry: (label, work). Order matters — `requestStop`
        // before `shutdown` per runner; `vault.shutdown` last so
        // anything that wrote to the vault during the prior steps has
        // its WAL checkpointed.
        let steps: [(String, @Sendable () async -> Void)] = [
            ("llama.requestStop",      { await vm.llama.requestStop() }),
            ("llama.shutdown",         { await vm.llama.shutdown() }),
            ("mlx.requestStop",        { await vm.mlx.requestStop() }),
            ("mlx.shutdown",           { await vm.mlx.shutdown() }),
            ("cloud.requestStop",      { await vm.cloud.requestStop() }),
            ("cloud.shutdown",         { await vm.cloud.shutdown() }),
            ("sd.requestStop",         { await vm.sd.requestStop() }),
            ("sd.shutdown",            { await vm.sd.shutdown() }),
            ("cloudImage.requestStop", { await vm.cloudImage.requestStop() }),
            ("cloudImage.shutdown",    { await vm.cloudImage.shutdown() }),
            ("embedder.shutdown",      { await vm.embedder.shutdown() }),
            ("reranker.shutdown",      { await vm.reranker.shutdown() }),
            ("vectorStore.shutdown",   { await vm.vectorStore.shutdown() }),
            // Tear down MCP server subprocesses before the process
            // exits — otherwise the children outlive us and either
            // get reaped by launchd or hold onto file handles we
            // can't release.
            ("mcpHost.shutdown",       { await vm.mcpHost.shutdown() }),
            ("audioRecorder.cancel",   { await MainActor.run { vm.audioRecorder.cancel() } }),
            ("whisper.shutdown",       { await WhisperRunner.shared.shutdown() }),
            ("vault.shutdown",         { await VaultStore.shared.shutdown() }),
            // Flush the persistent log file last so any messages
            // from the prior shutdown steps land on disk.
            ("logs.shutdown",          { await MainActor.run { vm.logs.shutdown() } }),
        ]

        for (label, work) in steps {
            let stepStarted = Date()
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                await work()
                sem.signal()
            }
            let result = sem.wait(timeout: .now() + perStepTimeout)
            let elapsed = Date().timeIntervalSince(stepStarted)
            if result == .timedOut {
                FileHandle.standardError.write(Data(
                    "[shutdown] '\(label)' timed out after \(Self.formatMs(elapsed)) — proceeding (resource may leak)\n".utf8
                ))
            } else if elapsed >= slowStepLogThreshold {
                FileHandle.standardError.write(Data(
                    "[shutdown] '\(label)' took \(Self.formatMs(elapsed))\n".utf8
                ))
            }
        }

        // Always free the llama backend last, regardless of whether
        // earlier llama steps timed out — the C call is independent
        // of the actor and skipping it across relaunch is the exact
        // crash class this rewrite targets.
        llama_backend_free()

        let totalElapsed = Date().timeIntervalSince(overallStarted)
        if totalElapsed >= slowStepLogThreshold {
            FileHandle.standardError.write(Data(
                "[shutdown] complete in \(Self.formatMs(totalElapsed))\n".utf8
            ))
        }
    }

    private static func formatMs(_ seconds: TimeInterval) -> String {
        "\(Int((seconds * 1000).rounded()))ms"
    }
}
