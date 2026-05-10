import XCTest
@testable import InferAppCore

final class ChatTurnDriverTests: XCTestCase {

    func testHappyPathSetsHistoryThenSendsAndAssemblesChunks() async throws {
        let runner = MockChatRunner(scripted: [.chunks(["hel", "lo"])])
        let history: [ChatTurn] = [
            ChatTurn(role: .user, content: "first"),
            ChatTurn(role: .assistant, content: "first reply"),
        ]

        let reply = try await ChatTurnDriver.runOneTurn(
            runner: runner,
            priorHistory: history,
            userText: "second",
            maxTokens: 256
        )

        XCTAssertEqual(reply, "hello")

        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        guard case .setHistory(let turns) = calls[0] else { return XCTFail("first call must be setHistory") }
        XCTAssertEqual(turns.map(\.content), ["first", "first reply"])
        guard case .respondToUser(let text, let maxTokens) = calls[1] else { return XCTFail("second call must be respondToUser") }
        XCTAssertEqual(text, "second")
        XCTAssertEqual(maxTokens, 256)
    }

    func testEmptyHistoryStillSendsTheMessage() async throws {
        let runner = MockChatRunner(scripted: [.text("hi back")])
        let reply = try await ChatTurnDriver.runOneTurn(
            runner: runner,
            priorHistory: [],
            userText: "hi",
            maxTokens: 64
        )
        XCTAssertEqual(reply, "hi back")
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        guard case .setHistory(let turns) = calls[0] else { return XCTFail() }
        XCTAssertTrue(turns.isEmpty)
    }

    func testOnChunkSeesEachChunkInOrder() async throws {
        let runner = MockChatRunner(scripted: [.chunks(["a", "b", "c", "d"])])
        var observed: [String] = []
        _ = try await ChatTurnDriver.runOneTurn(
            runner: runner,
            priorHistory: [],
            userText: "stream please",
            maxTokens: 64,
            onChunk: { observed.append($0) }
        )
        XCTAssertEqual(observed, ["a", "b", "c", "d"])
    }

    func testRunnerStreamErrorPropagates() async {
        struct Boom: Error {}
        let runner = MockChatRunner(scripted: [.failure(Boom())])
        do {
            _ = try await ChatTurnDriver.runOneTurn(
                runner: runner,
                priorHistory: [],
                userText: "x",
                maxTokens: 64
            )
            XCTFail("expected throw")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testPartialChunksThenErrorYieldsThemBeforeThrowing() async {
        struct Boom: Error {}
        let runner = MockChatRunner(scripted: [.init(chunks: ["partial-1 ", "partial-2"], error: Boom())])
        var observed: [String] = []
        do {
            _ = try await ChatTurnDriver.runOneTurn(
                runner: runner,
                priorHistory: [],
                userText: "x",
                maxTokens: 64,
                onChunk: { observed.append($0) }
            )
            XCTFail("expected throw")
        } catch is Boom {
            XCTAssertEqual(observed, ["partial-1 ", "partial-2"])
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testHistoryIncludesSystemTurnsAsSuppliedByCaller() async throws {
        // The driver does not filter; the chat-VM's `chatTurns(from:)`
        // helper is what drops system turns before the call. That
        // separation is intentional — tests + alternative callers can
        // pass system turns in if they want them honoured by the
        // adapter (e.g. `LlamaRunner` routes leading system turns to
        // its `setSystemPrompt` setter).
        let runner = MockChatRunner(scripted: [.text("ok")])
        _ = try await ChatTurnDriver.runOneTurn(
            runner: runner,
            priorHistory: [
                ChatTurn(role: .system, content: "be terse"),
                ChatTurn(role: .user, content: "prior"),
            ],
            userText: "next",
            maxTokens: 64
        )
        let calls = await runner.recordedCalls()
        guard case .setHistory(let turns) = calls[0] else { return XCTFail() }
        XCTAssertEqual(turns.map(\.role), [.system, .user])
    }

    /// The driver's contract is "setHistory before respondToUser, no
    /// matter what." Even an empty user text still triggers a
    /// respondToUser call (the runner decides whether to no-op or
    /// emit an empty stream). Catches a class of bug where a caller
    /// guards on `userText.isEmpty` and ends up with a setHistory
    /// that mutates runner state without a corresponding generation.
    func testEmptyUserTextStillCallsRespondToUser() async throws {
        let runner = MockChatRunner(scripted: [.text("")])
        _ = try await ChatTurnDriver.runOneTurn(
            runner: runner,
            priorHistory: [ChatTurn(role: .user, content: "prior")],
            userText: "",
            maxTokens: 64
        )
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 2)
        guard case .respondToUser(let text, _) = calls[1] else { return XCTFail() }
        XCTAssertEqual(text, "")
    }

    /// End-to-end with `TranscriptStore`: the chat-VM's send flow
    /// reduced to its kernel. Append a user turn, snapshot history
    /// excluding it, drive the runner, append the reply. This is the
    /// closest test in the suite to a `ChatViewModel.send()` test.
    func testTranscriptStoreSendCycleEndToEnd() async throws {
        var store = TranscriptStore()
        _ = store.appendUser("first")
        let a1 = store.beginAssistant()
        store.appendChunk("first reply", to: a1)

        let runner = MockChatRunner(scripted: [.chunks(["se", "cond reply"])])
        _ = store.appendUser("second")
        let history = Array(store.turnsForHistory().dropLast()) // exclude trailing user
        let aid = store.beginAssistant()

        let reply = try await ChatTurnDriver.runOneTurn(
            runner: runner,
            priorHistory: history,
            userText: "second",
            maxTokens: 256,
            onChunk: { store.appendChunk($0, to: aid) }
        )

        XCTAssertEqual(reply, "second reply")
        XCTAssertEqual(store.entries.count, 4)
        XCTAssertEqual(store.entries.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(store.entries.map(\.text), ["first", "first reply", "second", "second reply"])
    }
}
