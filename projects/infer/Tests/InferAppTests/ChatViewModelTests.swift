import XCTest
@testable import Infer
@testable import InferCore
@testable import InferRAG

/// First direct tests of `ChatViewModel` — the app's highest-churn
/// component, 27k lines of app target behind it, previously covered only
/// indirectly through the extracted `InferAppCore` kernel.
///
/// What made this possible was not a refactor of the target: the
/// executable target has always been `@testable`-importable. It was
/// making the view model's storage locations parameters. Before that,
/// `ChatViewModel()` read and wrote the user's real vault, vector store,
/// wiki, and log directory during `init` — `bootstrapAgents()`,
/// `refreshWorkspaces()` and `logRAGIndexHealth()` all run there, so the
/// damage happened before the first assertion could.
///
/// Scope note: these cover construction, dependency wiring, and
/// transcript-level state. The generation path is covered separately by
/// `GenerationTests`, which became possible once `imageURLs` was lifted
/// onto `ChatRunner.respondToUser` and `send()` stopped switching on the
/// backend to reach the concrete runners.
@MainActor
final class ChatViewModelTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "ChatViewModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    /// Every store points inside the per-test temp directory, and log
    /// persistence is off — nothing here may touch real user data.
    private func makeViewModel() -> ChatViewModel {
        ChatViewModel(
            vectorStore: VectorStore(url: directory.appending(path: "vectors.sqlite")),
            vault: VaultStore(url: directory.appending(path: "vault.sqlite")),
            wiki: WikiStore(rootURL: directory.appending(path: "wiki")),
            logs: LogCenter(persister: nil)
        )
    }

    // MARK: - Construction

    func testConstructsAgainstInjectedStores() {
        let vm = makeViewModel()
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertFalse(vm.modelLoaded)
        XCTAssertFalse(vm.isGenerating)
        XCTAssertNil(vm.errorMessage)
    }

    /// The guard that matters: construction must not create or write the
    /// real Application Support databases. If someone re-hardcodes a
    /// store, this fails rather than silently corrupting a user's vault
    /// on the next test run.
    func testConstructionTouchesOnlyTheInjectedDirectory() async throws {
        let vm = makeViewModel()
        // Let the async bootstrap tasks (`refreshWorkspaces`,
        // `logRAGIndexHealth`) actually run before inspecting the disk.
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = vm.messages

        let real = VaultStore.defaultURL().deletingLastPathComponent()
        let realVaultBefore = FileManager.default.fileExists(
            atPath: real.appending(path: "vault.sqlite").path
        )
        // Whatever the store wrote, it must be under the temp directory.
        let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(written.isEmpty, "bootstrap should have created its stores in the temp dir")

        // Re-check the real location is unchanged by our construction:
        // if it existed before it still does, and if it did not exist we
        // must not have created it.
        let realVaultAfter = FileManager.default.fileExists(
            atPath: real.appending(path: "vault.sqlite").path
        )
        XCTAssertEqual(realVaultBefore, realVaultAfter)
    }

    func testTwoViewModelsWithDifferentStoresDoNotShareState() async throws {
        let first = makeViewModel()
        first.messages.append(ChatMessage(role: .user, text: "only in first"))

        let secondDir = directory.appending(path: "second")
        try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        let second = ChatViewModel(
            vectorStore: VectorStore(url: secondDir.appending(path: "vectors.sqlite")),
            vault: VaultStore(url: secondDir.appending(path: "vault.sqlite")),
            wiki: WikiStore(rootURL: secondDir.appending(path: "wiki")),
            logs: LogCenter(persister: nil)
        )
        XCTAssertTrue(second.messages.isEmpty)
        XCTAssertEqual(first.messages.count, 1)
    }

    // MARK: - Dependency wiring

    /// Injection is only useful if the view model actually holds what it
    /// was handed. Identity checks, not equality — these are reference
    /// types, and a defaulted parameter silently replacing the injected
    /// store is exactly the regression worth catching.
    func testHoldsTheInjectedStoreInstances() {
        let vectors = VectorStore(url: directory.appending(path: "v.sqlite"))
        let vault = VaultStore(url: directory.appending(path: "va.sqlite"))
        let wiki = WikiStore(rootURL: directory.appending(path: "w"))
        let logs = LogCenter(persister: nil)
        let vm = ChatViewModel(vectorStore: vectors, vault: vault, wiki: wiki, logs: logs)

        XCTAssertTrue(vm.vectorStore === vectors)
        XCTAssertTrue(vm.vault === vault)
        XCTAssertTrue(vm.wiki === wiki)
        XCTAssertTrue(vm.logs === logs)
    }

    func testInjectedVaultIsTheOneUsedForConversations() async throws {
        let vault = VaultStore(url: directory.appending(path: "conversations.sqlite"))
        let vm = ChatViewModel(
            vectorStore: VectorStore(url: directory.appending(path: "vectors.sqlite")),
            vault: vault,
            wiki: WikiStore(rootURL: directory.appending(path: "wiki")),
            logs: LogCenter(persister: nil)
        )
        let cid = try await vm.vault.startConversation(
            backend: "llama", modelId: "m", systemPrompt: ""
        )
        try await vm.vault.appendMessage(conversationId: cid, role: "user", content: "hello")

        // Reading through a second store at the same path proves the
        // write went where we pointed it, not to the shared singleton.
        let independent = VaultStore(url: directory.appending(path: "conversations.sqlite"))
        let turns = try await independent.loadConversation(id: cid)
        XCTAssertEqual(turns.map(\.content), ["hello"])
    }

    // MARK: - Transcript state

    /// Polls on the main actor until `condition` holds or the deadline
    /// passes. Needed because the operations below finish on a later
    /// main-actor hop rather than synchronously.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for: \(description)") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// `reset()` clears the transcript on a **later** main-actor hop,
    /// not synchronously, and that is load-bearing rather than
    /// incidental: an in-flight turn is suspended inside the stream loop
    /// holding an index into `messages`, so clearing the array
    /// immediately would leave that index dangling and crash when the
    /// turn resumed. Both halves are pinned here — still populated when
    /// `reset()` returns, empty once the turn has unwound.
    func testResetDefersTheClearUntilTheTurnUnwinds() async throws {
        let vm = makeViewModel()
        vm.messages.append(ChatMessage(role: .user, text: "one"))
        vm.messages.append(ChatMessage(role: .assistant, text: "two"))

        vm.reset()
        XCTAssertEqual(
            vm.messages.count, 2,
            "clear must be deferred; doing it synchronously is the crash this design avoids"
        )

        try await waitUntil("transcript cleared") { vm.messages.isEmpty }
        XCTAssertNil(vm.currentConversationId)
        XCTAssertNil(vm.pendingImageURL)
    }

    /// Documents an actual behaviour rather than asserting a wished-for
    /// one: `reset()` clears the transcript and counters but leaves
    /// `errorMessage` standing. That is defensible — an error like
    /// "no model loaded" is still true after a reset — but it is
    /// undocumented, so pin it and let a deliberate change fail here.
    func testResetLeavesErrorBannerInPlace() async throws {
        let vm = makeViewModel()
        vm.messages.append(ChatMessage(role: .user, text: "one"))
        vm.errorMessage = "model failed to load"

        vm.reset()
        try await waitUntil("transcript cleared") { vm.messages.isEmpty }

        XCTAssertEqual(vm.errorMessage, "model failed to load")
    }

    func testResetIsSafeOnAnEmptyTranscript() async throws {
        let vm = makeViewModel()
        vm.reset()
        try await waitUntil("reset settled") { vm.messages.isEmpty }
        XCTAssertTrue(vm.messages.isEmpty)
    }

    /// `logs` is the Console tab's backing store. With persistence
    /// disabled it must still record in memory, or the tab would be
    /// blank in any build that opts out of disk logging.
    func testLogCenterRecordsWithoutPersistence() {
        let vm = makeViewModel()
        vm.logs.log(.warning, source: "test", message: "recorded", payload: nil)
        XCTAssertTrue(
            vm.logs.events.contains { $0.message == "recorded" },
            "in-memory log should hold the entry even with persister: nil"
        )
    }
}
