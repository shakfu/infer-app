import XCTest
@testable import InferCore

final class StreamTurnConsumerTests: XCTestCase {
    private struct Boom: Error {}

    /// Collects callback output. A reference type so the non-escaping async
    /// callbacks can accumulate into it; the kernel runs everything on one
    /// task (no real concurrency in these tests).
    private final class Sink {
        var display: [String] = []
        var raw: [String] = []
        var thinkingSnapshots: [(String, Bool)] = []
        var netTokens = 0
        var totalTokens = 0
        var stopCount = 0
    }

    private func makeStream(_ pieces: [String], error: Error? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for p in pieces { continuation.yield(p) }
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
    }

    private func run(
        _ pieces: [String],
        netCap: Int = .max,
        error: Error? = nil,
        into sink: Sink
    ) async throws -> (display: String, thinking: String) {
        try await StreamTurnConsumer.consume(
            makeStream(pieces, error: error),
            netCap: netCap,
            onDisplayDelta: { sink.display.append($0) },
            onThinking: { sink.thinkingSnapshots.append(($0, $1)) },
            onRawPiece: { sink.raw.append($0) },
            onToken: { net in
                sink.totalTokens += 1
                if net { sink.netTokens += 1 }
            },
            netCountSoFar: { sink.netTokens },
            requestStop: { sink.stopCount += 1 }
        )
    }

    /// Plain text with no reasoning blocks streams through verbatim; raw and
    /// display match, every piece is a net token, and the runner is not stopped.
    func testPlainTextPassesThrough() async throws {
        let sink = Sink()
        let result = try await run(["Hel", "lo"], into: sink)
        XCTAssertEqual(result.display, "Hello")
        XCTAssertEqual(result.thinking, "")
        XCTAssertEqual(sink.display.joined(), "Hello")
        XCTAssertEqual(sink.raw, ["Hel", "lo"])
        XCTAssertEqual(sink.netTokens, 2)
        XCTAssertEqual(sink.totalTokens, 2)
        XCTAssertEqual(sink.stopCount, 0)
    }

    /// A `<think>` block split across pieces is stripped from the visible
    /// display and captured as thinking text; raw retains everything.
    func testThinkBlockSplitAcrossPieces() async throws {
        let sink = Sink()
        let result = try await run(["a", "<think>", "x", "</think>", "b"], into: sink)
        XCTAssertEqual(result.display, "ab")
        XCTAssertEqual(result.thinking, "x")
        XCTAssertEqual(sink.raw, ["a", "<think>", "x", "</think>", "b"])
    }

    /// The net-token cap stops the runner and breaks the loop once the
    /// *visible* count reaches the cap — pieces after that are never consumed.
    func testNetCapStopsAndBreaks() async throws {
        let sink = Sink()
        let result = try await run(["w1", "w2", "w3"], netCap: 2, into: sink)
        XCTAssertEqual(result.display, "w1w2")
        XCTAssertEqual(sink.stopCount, 1)
        XCTAssertEqual(sink.raw, ["w1", "w2"], "w3 must not be consumed after the cap fires")
        XCTAssertEqual(sink.netTokens, 2)
    }

    /// While inside a `<think>` block the cap is suppressed (the `!inThink`
    /// half of the condition), so it only fires after the block closes and a
    /// net-visible token is produced.
    func testCapSuppressedWhileThinking() async throws {
        let sink = Sink()
        let result = try await run(["<think>", "a</think>", "b", "c"], netCap: 1, into: sink)
        XCTAssertEqual(result.display, "b")
        XCTAssertEqual(result.thinking, "a")
        XCTAssertEqual(sink.stopCount, 1)
        XCTAssertFalse(sink.raw.contains("c"), "c must not be consumed after the cap fires")
    }

    /// Errors thrown by the stream propagate, with the display collected so
    /// far preserved by the caller (the kernel rethrows after partial output).
    func testErrorPropagatesAfterPartial() async throws {
        let sink = Sink()
        do {
            _ = try await run(["partial"], error: Boom(), into: sink)
            XCTFail("expected throw")
        } catch is Boom {
            // expected
        }
        XCTAssertEqual(sink.display.joined(), "partial")
    }
}
