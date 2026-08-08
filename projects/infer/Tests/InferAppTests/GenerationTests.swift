import XCTest
@testable import Infer
@testable import InferAppCore
@testable import InferCore
@testable import InferRAG

/// Coverage for the generation path — `send()`'s guards, the decode
/// loop, stop, and vault persistence.
///
/// This suite was impossible until `imageURLs` was lifted onto
/// `ChatRunner.respondToUser`. Before that, `send()` switched on
/// `backend` and called the concrete runners' `sendUserMessage`
/// directly, so no injected runner could reach the decode loop and any
/// test that looked like it covered streaming was in fact driving the
/// real `LlamaRunner` with no model loaded.
///
/// Assertions favour the observable contract — what lands in the
/// transcript, and what the view model asked the runner to do — over
/// internal sequencing, so the suite survives the `Generation.swift`
/// split that F-4 proposes.
@MainActor
final class GenerationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "GenerationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func makeViewModel(runner: MockChatRunner) -> ChatViewModel {
        let vm = ChatViewModel(
            vectorStore: VectorStore(url: directory.appending(path: "vectors.sqlite")),
            vault: VaultStore(url: directory.appending(path: "vault.sqlite")),
            wiki: WikiStore(rootURL: directory.appending(path: "wiki")),
            logs: LogCenter(persister: nil),
            runner: runner
        )
        vm.modelLoaded = true
        vm.currentModelId = "test-model"
        return vm
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 10,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for: \(description)") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func settle(_ vm: ChatViewModel) async throws {
        try await waitUntil("generation finished") { !vm.isGenerating }
    }

    // MARK: - The decode loop

    func testStreamedChunksAreConcatenatedIntoTheAssistantMessage() async throws {
        let runner = MockChatRunner(scripted: [.chunks(["Hel", "lo ", "world"])])
        let vm = makeViewModel(runner: runner)
        vm.input = "hi"

        vm.send()
        try await settle(vm)

        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages.first?.role, .user)
        XCTAssertEqual(vm.messages.first?.text, "hi")
        XCTAssertEqual(vm.messages.last?.role, .assistant)
        XCTAssertEqual(vm.messages.last?.text, "Hello world")
    }

    func testUserTextReachesTheRunnerTrimmed() async throws {
        let runner = MockChatRunner(scripted: [.text("reply")])
        let vm = makeViewModel(runner: runner)
        vm.input = "  what is an actor?  "

        vm.send()
        try await settle(vm)

        let calls = await runner.calls
        let asked = calls.compactMap { call -> String? in
            if case .respondToUser(let text, _) = call { return text }
            return nil
        }
        XCTAssertEqual(asked, ["what is an actor?"])
    }

    /// `maxTokens` handed to the runner is the user's cap plus the
    /// thinking budget, because reasoning models spend tokens on
    /// `<think>` blocks that never reach the transcript. Passing the
    /// bare user cap would truncate visible output on those models.
    func testRunnerReceivesMaxTokensPlusThinkingBudget() async throws {
        let runner = MockChatRunner(scripted: [.text("ok")])
        let vm = makeViewModel(runner: runner)
        vm.input = "question"

        let expected = vm.activeDecodingParams.maxTokens + vm.settings.thinkingBudget
        vm.send()
        try await settle(vm)

        let calls = await runner.calls
        let caps = calls.compactMap { call -> Int? in
            if case .respondToUser(_, let maxTokens) = call { return maxTokens }
            return nil
        }
        XCTAssertEqual(caps, [expected])
    }

    func testInputIsClearedSynchronouslyAndGeneratingFlagCycles() async throws {
        let runner = MockChatRunner(scripted: [.text("ok")])
        let vm = makeViewModel(runner: runner)
        vm.input = "a question"

        vm.send()
        XCTAssertEqual(vm.input, "", "input must clear before the first await, or a fast typist resubmits")
        XCTAssertTrue(vm.isGenerating)

        try await settle(vm)
        XCTAssertFalse(vm.isGenerating)
    }

    func testThinkBlocksAreStrippedFromTheVisibleReply() async throws {
        let runner = MockChatRunner(scripted: [.text("a<think>hidden reasoning</think>b")])
        let vm = makeViewModel(runner: runner)
        vm.input = "reason about this"

        vm.send()
        try await settle(vm)

        let reply = try XCTUnwrap(vm.messages.last?.text)
        XCTAssertFalse(reply.contains("hidden reasoning"), "reasoning must not leak into the reply: \(reply)")
        XCTAssertFalse(reply.contains("<think>"))
        XCTAssertTrue(reply.contains("a") && reply.contains("b"))
    }

    // MARK: - Guards

    func testSendIgnoresEmptyInput() async throws {
        let runner = MockChatRunner(scripted: [.text("must not be reached")])
        let vm = makeViewModel(runner: runner)

        vm.input = ""
        vm.send()

        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertFalse(vm.isGenerating)
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testSendIgnoresWhitespaceOnlyInput() async throws {
        let runner = MockChatRunner(scripted: [.text("must not be reached")])
        let vm = makeViewModel(runner: runner)

        vm.input = "   \n\t  "
        vm.send()

        XCTAssertTrue(vm.messages.isEmpty)
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testSendIsIgnoredWhenNoModelIsLoaded() async throws {
        let runner = MockChatRunner(scripted: [.text("must not be reached")])
        let vm = makeViewModel(runner: runner)
        vm.modelLoaded = false

        vm.input = "a real prompt"
        vm.send()

        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertEqual(vm.input, "a real prompt", "a rejected send must not consume the input")
        let calls = await runner.calls
        XCTAssertTrue(calls.isEmpty)
    }

    /// A second `send()` mid-turn must be dropped, or two turns
    /// interleave into the same transcript indices.
    func testSecondSendWhileGeneratingIsDropped() async throws {
        let runner = MockChatRunner(scripted: [.chunks(["one"]), .chunks(["two"])])
        let vm = makeViewModel(runner: runner)

        vm.input = "first"
        vm.send()
        XCTAssertTrue(vm.isGenerating)

        vm.input = "second"
        vm.send()
        XCTAssertEqual(vm.input, "second", "the dropped send must not consume the input")

        try await settle(vm)
        XCTAssertEqual(vm.messages.count, 2, "only the first turn produced messages")

        let calls = await runner.calls
        let responds = calls.filter { if case .respondToUser = $0 { return true } else { return false } }
        XCTAssertEqual(responds.count, 1)
    }

    // MARK: - Failure

    private struct Boom: Error, CustomStringConvertible {
        var description: String { "stream exploded" }
    }

    /// A mid-stream throw must still unwind `isGenerating`. A stuck flag
    /// leaves the UI permanently unable to send — worse for the user
    /// than the error itself.
    func testStreamFailureEndsGeneration() async throws {
        let runner = MockChatRunner(scripted: [.init(chunks: ["partial"], error: Boom())])
        let vm = makeViewModel(runner: runner)
        vm.input = "trigger a failure"

        vm.send()
        try await settle(vm)

        XCTAssertFalse(vm.isGenerating)
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages.last?.role, .assistant)
    }

    func testPartialOutputSurvivesAFailedStream() async throws {
        let runner = MockChatRunner(scripted: [.init(chunks: ["kept so far"], error: Boom())])
        let vm = makeViewModel(runner: runner)
        vm.input = "fail midway"

        vm.send()
        try await settle(vm)

        let reply = try XCTUnwrap(vm.messages.last?.text)
        XCTAssertTrue(
            reply.contains("kept so far"),
            "tokens already streamed should not be discarded on failure, got: \(reply)"
        )
    }

    func testViewModelRecoversAfterAFailedTurn() async throws {
        let runner = MockChatRunner(scripted: [
            .init(chunks: [], error: Boom()),
            .chunks(["recovered"]),
        ])
        let vm = makeViewModel(runner: runner)

        vm.input = "first"
        vm.send()
        try await settle(vm)

        vm.input = "second"
        vm.send()
        try await settle(vm)

        XCTAssertEqual(vm.messages.last?.text, "recovered", "a failed turn must not wedge the VM")
    }

    // MARK: - Stop

    func testStopReachesTheRunner() async throws {
        let runner = MockChatRunner(scripted: [.chunks(["streaming"])])
        let vm = makeViewModel(runner: runner)
        vm.input = "long answer please"

        vm.send()
        vm.stop()
        try await settle(vm)

        let calls = await runner.calls
        XCTAssertTrue(
            calls.contains(.requestStop),
            "stop() must reach the runner, not just flip a local flag"
        )
        XCTAssertFalse(vm.isGenerating)
    }

    // MARK: - Persistence

    /// End-to-end proof that generation and persistence are wired to the
    /// same store the test controls, rather than the shared singleton.
    func testCompletedTurnIsPersistedToTheInjectedVault() async throws {
        let vaultURL = directory.appending(path: "vault.sqlite")
        let runner = MockChatRunner(scripted: [.text("persisted reply")])
        let vm = makeViewModel(runner: runner)
        vm.input = "persist me"

        vm.send()
        try await settle(vm)
        try await waitUntil("conversation id assigned") { vm.currentConversationId != nil }
        let cid = try XCTUnwrap(vm.currentConversationId)

        let independent = VaultStore(url: vaultURL)
        let turns = try await independent.loadConversation(id: cid)
        XCTAssertTrue(
            turns.contains { $0.role == "user" && $0.content == "persist me" },
            "user turn missing from the vault: \(turns)"
        )
    }
}
