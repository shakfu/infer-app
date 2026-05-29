import XCTest
import InferAppCore
@testable import InferSession

final class ChatEngineTests: XCTestCase {
    private struct Boom: Error {}

    // MARK: - Incremental send

    /// A plain `send` streams chunks, returns the assembled reply, and records
    /// the user + assistant turns in the transcript. Crucially it does NOT
    /// call `setHistory` (incremental mode preserves runner state).
    func testSendIsIncrementalAndRecordsTranscript() async throws {
        let runner = MockChatRunner(scripted: [.chunks(["Hel", "lo"])])
        let engine = ChatEngine(runner: runner)

        let reply = try await engine.send("hi", maxTokens: 128)

        XCTAssertEqual(reply, "Hello")
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls, [.respondToUser(text: "hi", maxTokens: 128)])

        let entries = await engine.transcript.entries
        XCTAssertEqual(entries.map(\.role), [.user, .assistant])
        XCTAssertEqual(entries.map(\.text), ["hi", "Hello"])
    }

    /// Multiple sends accumulate turns without ever rebuilding history.
    func testMultiTurnStaysIncremental() async throws {
        let runner = MockChatRunner(scripted: [.text("a1"), .text("a2")])
        let engine = ChatEngine(runner: runner)

        _ = try await engine.send("u1")
        _ = try await engine.send("u2")

        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls, [
            .respondToUser(text: "u1", maxTokens: 512),
            .respondToUser(text: "u2", maxTokens: 512),
        ])
        let entries = await engine.transcript.entries
        XCTAssertEqual(entries.map(\.text), ["u1", "a1", "u2", "a2"])
    }

    /// A thrown error leaves the partial reply in the transcript and rethrows.
    func testSendPropagatesErrorKeepingPartial() async throws {
        let runner = MockChatRunner(scripted: [.init(chunks: ["partial"], error: Boom())])
        let engine = ChatEngine(runner: runner)

        do {
            _ = try await engine.send("hi")
            XCTFail("expected throw")
        } catch is Boom {
            // expected
        }
        let entries = await engine.transcript.entries
        XCTAssertEqual(entries.last?.text, "partial")
    }

    /// The engine strips `<think>` blocks from the reply via the shared
    /// `StreamTurnConsumer` kernel, so neither the returned reply nor the
    /// transcript contains reasoning text.
    func testSendStripsThinkBlocks() async throws {
        let runner = MockChatRunner(scripted: [.text("a<think>secret</think>b")])
        let engine = ChatEngine(runner: runner)

        let reply = try await engine.send("hi")

        XCTAssertEqual(reply, "ab")
        let entries = await engine.transcript.entries
        XCTAssertEqual(entries.last?.text, "ab")
    }

    // MARK: - Rebuild paths

    /// `regenerate` drops the trailing assistant turn, pushes the prior
    /// history via `setHistory` (which excludes the user turn being resent),
    /// then re-runs the user turn.
    func testRegenerateRebuildsHistoryBeforeRespond() async throws {
        let runner = MockChatRunner(scripted: [.text("first"), .text("second")])
        let engine = ChatEngine(runner: runner)
        _ = try await engine.send("question")

        let reply = try await engine.regenerate(maxTokens: 64)
        XCTAssertEqual(reply, "second")

        let calls = await runner.recordedCalls()
        // send → respond; regenerate → setHistory(prior, no trailing user) then respond.
        XCTAssertEqual(calls, [
            .respondToUser(text: "question", maxTokens: 512),
            .setHistory([]),
            .respondToUser(text: "question", maxTokens: 64),
        ])
        let entries = await engine.transcript.entries
        XCTAssertEqual(entries.map(\.text), ["question", "second"])
    }

    /// `regenerate` is a no-op (nil, no runner call) when there is no trailing
    /// assistant turn to drop.
    func testRegenerateNoOpOnEmptyTranscript() async throws {
        let runner = MockChatRunner()
        let engine = ChatEngine(runner: runner)
        let reply = try await engine.regenerate()
        XCTAssertNil(reply)
        let calls = await runner.recordedCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    /// `editAndResend` truncates after the edited user turn, rebuilds history
    /// from the turns before it, resends the new text, and returns the dropped
    /// entries.
    func testEditAndResendRebuildsFromPriorTurns() async throws {
        let runner = MockChatRunner(scripted: [.text("a1"), .text("a2"), .text("edited-reply")])
        let engine = ChatEngine(runner: runner)
        _ = try await engine.send("u1")
        _ = try await engine.send("u2")

        // Edit the first user turn.
        let firstUserId = await engine.transcript.entries.first { $0.role == .user }!.id
        let dropped = try await engine.editAndResend(messageId: firstUserId, newText: "u1-edited")

        // Dropped everything after u1: a1, u2, a2.
        XCTAssertEqual(dropped?.map(\.text), ["a1", "u2", "a2"])

        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls, [
            .respondToUser(text: "u1", maxTokens: 512),
            .respondToUser(text: "u2", maxTokens: 512),
            // editAndResend: prior history empty (u1-edited is the only turn left,
            // and is the one being resent), then respond with the edited text.
            .setHistory([]),
            .respondToUser(text: "u1-edited", maxTokens: 512),
        ])
        let entries = await engine.transcript.entries
        XCTAssertEqual(entries.map(\.text), ["u1-edited", "edited-reply"])
    }

    // MARK: - Reset

    func testResetClearsTranscriptAndRunner() async throws {
        let runner = MockChatRunner(scripted: [.text("a1")])
        let engine = ChatEngine(runner: runner)
        _ = try await engine.send("u1")

        await engine.reset()

        let entries = await engine.transcript.entries
        XCTAssertTrue(entries.isEmpty)
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.last, .resetConversation)
    }
}
