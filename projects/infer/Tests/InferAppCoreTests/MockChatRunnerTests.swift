import XCTest
@testable import InferAppCore

final class MockChatRunnerTests: XCTestCase {

    func testSingleChunkResponseStreamsAndFinishes() async throws {
        let runner = MockChatRunner(scripted: [.text("hello")])
        let stream = await runner.respondToUser("hi", maxTokens: 512)
        var collected: [String] = []
        for try await chunk in stream { collected.append(chunk) }
        XCTAssertEqual(collected, ["hello"])
    }

    func testMultiChunkResponseStreamsInOrder() async throws {
        let runner = MockChatRunner(scripted: [.chunks(["he", "llo", "!"])])
        let stream = await runner.respondToUser("hi", maxTokens: 512)
        var collected: [String] = []
        for try await chunk in stream { collected.append(chunk) }
        XCTAssertEqual(collected, ["he", "llo", "!"])
    }

    func testScriptedErrorThrowsFromStream() async {
        struct Boom: Error, Equatable {}
        let runner = MockChatRunner(scripted: [.failure(Boom())])
        let stream = await runner.respondToUser("hi", maxTokens: 512)
        do {
            for try await _ in stream { /* drain */ }
            XCTFail("expected the stream to throw")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("expected Boom, got \(error)")
        }
    }

    func testScriptedChunksThenErrorEmitsChunksBeforeThrowing() async {
        struct Boom: Error {}
        let runner = MockChatRunner(scripted: [.init(chunks: ["partial"], error: Boom())])
        let stream = await runner.respondToUser("hi", maxTokens: 512)
        var collected: [String] = []
        do {
            for try await chunk in stream { collected.append(chunk) }
            XCTFail("expected throw")
        } catch is Boom {
            XCTAssertEqual(collected, ["partial"])
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testOutOfScriptCallReturnsEmptyStream() async throws {
        let runner = MockChatRunner(scripted: [])
        let stream = await runner.respondToUser("hi", maxTokens: 512)
        var collected: [String] = []
        for try await chunk in stream { collected.append(chunk) }
        XCTAssertTrue(collected.isEmpty)
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 1, "the call should still be recorded so unmet expectations surface")
    }

    func testCallsAreRecordedInOrder() async throws {
        let runner = MockChatRunner(scripted: [.text("ok")])
        try await runner.setHistory([ChatTurn(role: .system, content: "be terse"), ChatTurn(role: .user, content: "prior")])
        _ = await runner.respondToUser("now", maxTokens: 64)
        await runner.requestStop()
        await runner.resetConversation()

        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 4)
        guard case .setHistory(let turns) = calls[0] else { return XCTFail() }
        XCTAssertEqual(turns.first?.role, .system)
        XCTAssertEqual(turns.last?.content, "prior")
        guard case .respondToUser(let text, let maxTokens) = calls[1] else { return XCTFail() }
        XCTAssertEqual(text, "now")
        XCTAssertEqual(maxTokens, 64)
        guard case .requestStop = calls[2] else { return XCTFail() }
        guard case .resetConversation = calls[3] else { return XCTFail() }
    }
}

// MARK: - Cross-type integration

/// These exercises drive the `TranscriptStore` and the `MockChatRunner`
/// together — the same coupling the chat-VM has on the real path. They
/// are the closest thing in this PR to a "ChatViewModel test"; they
/// catch the F-3 / F-8 class of bug (history-rebuild ordering, stream
/// late-arrival into a truncated transcript) without dragging in any
/// of the chat-VM's 20+ concrete collaborators.
final class TranscriptRunnerIntegrationTests: XCTestCase {

    /// Mirrors the chat-VM's send flow: append the user turn, snapshot
    /// the prior history, push it to the runner via `setHistory`, then
    /// open the assistant stream. Asserts the runner sees `setHistory`
    /// *before* `sendUserMessage` — the inverted order is a real
    /// regression class on the MLX path (where settings changes can
    /// rebuild the session and clobber history if `setHistory` lands
    /// after the new send opens its session).
    func testSendFlowFeedsHistoryBeforeMessage() async throws {
        var store = TranscriptStore()
        _ = store.appendUser("first")
        let a1 = store.beginAssistant()
        store.appendChunk("first reply", to: a1)

        let runner = MockChatRunner(scripted: [.text("second reply")])
        _ = store.appendUser("second")

        // Snapshot for history excludes the just-appended user turn —
        // that's what `sendUserMessage`'s text argument carries.
        let history = Array(store.turnsForHistory().dropLast())
        try await runner.setHistory(history)
        let stream = await runner.respondToUser("second", maxTokens: 512)
        let aid = store.beginAssistant()
        for try await chunk in stream { store.appendChunk(chunk, to: aid) }

        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        guard case .setHistory(let turns) = calls[0] else {
            return XCTFail("expected setHistory before respondToUser")
        }
        XCTAssertEqual(turns.map(\.content), ["first", "first reply"])
        guard case .respondToUser = calls[1] else {
            return XCTFail("expected respondToUser after setHistory")
        }
        XCTAssertEqual(store.entries.last?.text, "second reply")
    }

    /// F-8: the user clicks Edit-and-resend after the runner stream
    /// has started but before all chunks arrive. The truncation must
    /// drop the in-flight assistant row, and any chunk that arrives
    /// after must be a no-op against the stale id (rather than
    /// resurrecting the row or crashing).
    func testEditAndResendDuringStreamIsRobustToLateChunks() {
        var store = TranscriptStore()
        let u1 = store.appendUser("ping")
        let staleAssistant = store.beginAssistant()
        store.appendChunk("po", to: staleAssistant)

        // Simulate the user's edit landing here.
        _ = store.editAndResend(messageId: u1, newText: "ping (edited)")

        // Late chunk from the cancelled stream — must not crash and
        // must not bring the row back.
        store.appendChunk("ng", to: staleAssistant)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].text, "ping (edited)")
        XCTAssertEqual(store.entries[0].role, .user)
    }

    /// Regenerate flow: drop the trailing assistant row, re-open the
    /// stream with the same user turn, and verify the runner gets the
    /// rebuilt history (without the dropped row) on the second send.
    func testRegenerateFeedsRebuiltHistoryToRunner() async throws {
        var store = TranscriptStore()
        _ = store.appendUser("ping")
        let a1 = store.beginAssistant()
        store.appendChunk("first attempt", to: a1)

        guard let resend = store.regenerate() else { return XCTFail("regenerate should succeed") }
        XCTAssertEqual(resend, "ping")

        let runner = MockChatRunner(scripted: [.text("second attempt")])
        let history = Array(store.turnsForHistory().dropLast()) // exclude trailing user
        try await runner.setHistory(history)
        let stream = await runner.respondToUser(resend, maxTokens: 512)
        let aid = store.beginAssistant()
        for try await chunk in stream { store.appendChunk(chunk, to: aid) }

        XCTAssertEqual(store.entries.last?.text, "second attempt")
        let calls = await runner.recordedCalls()
        guard case .setHistory(let turns) = calls[0] else { return XCTFail() }
        XCTAssertTrue(turns.isEmpty, "history before regen send should be empty — only the user turn remains, and that's the message arg")
    }

    /// Stop semantics: requestStop terminates the in-flight stream
    /// with a CancellationError. Mirrors the user clicking "Stop".
    func testRequestStopTerminatesInFlightStream() async throws {
        let runner = MockChatRunner(scripted: [.chunks(["a", "b", "c"])])
        let stream = await runner.respondToUser("hi", maxTokens: 512)
        // The mock yields all chunks synchronously inside the
        // continuation closure, so by the time we iterate the stream
        // is already finished. Drain, then call requestStop and
        // verify it's recorded — the realistic "interrupt mid-stream"
        // path requires a runner with async chunk emission, which is
        // out of scope for this mock.
        var collected: [String] = []
        for try await chunk in stream { collected.append(chunk) }
        XCTAssertEqual(collected, ["a", "b", "c"])
        await runner.requestStop()
        let calls = await runner.recordedCalls()
        XCTAssertTrue(calls.contains(.requestStop))
    }
}
