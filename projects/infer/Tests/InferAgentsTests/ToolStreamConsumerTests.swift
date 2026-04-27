import XCTest
@testable import InferAgents

/// Integration test for the streaming-tool consumer used by both the
/// chat view-model's tool loop and any future host driver.
///
/// Validates the parts of the chat-VM glue that don't depend on
/// `LlamaRunner` / `MLXRunner` / SwiftUI: the consumer correctly drains
/// `ToolEvent.log` events into `onProgress`, mirrors them as
/// `AgentEvent.toolProgress` into `onEvent`, returns the terminal
/// `ToolResult`, and guarantees ordering — every `onProgress` call
/// happens-before the consumer's `await` returns, so a caller that
/// clears its transient progress state immediately after `consume(…)`
/// won't be overwritten by a late callback.
final class ToolStreamConsumerTests: XCTestCase {

    /// Tool that emits `lines.count` `.log` events then a final
    /// `.result`. Sleep between yields is intentional — exposes any
    /// reordering bug that would land in production with a real
    /// (slow) Quarto render.
    private struct ScriptedStreamingTool: StreamingBuiltinTool {
        let name: ToolName = "test.scripted"
        var spec: ToolSpec { ToolSpec(name: name, description: "test") }

        let lines: [String]
        let finalOutput: String
        let perLineDelayNanos: UInt64

        func invokeStreaming(arguments: String) -> AsyncThrowingStream<ToolEvent, Error> {
            let lines = self.lines
            let finalOutput = self.finalOutput
            let delay = self.perLineDelayNanos
            return AsyncThrowingStream { continuation in
                let task = Task {
                    for line in lines {
                        if delay > 0 {
                            try? await Task.sleep(nanoseconds: delay)
                        }
                        continuation.yield(.log(line))
                    }
                    continuation.yield(.result(ToolResult(output: finalOutput)))
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    /// Tool whose stream finishes without ever yielding `.result`.
    private struct NoResultStreamingTool: StreamingBuiltinTool {
        let name: ToolName = "test.noresult"
        var spec: ToolSpec { ToolSpec(name: name, description: "test") }
        func invokeStreaming(arguments: String) -> AsyncThrowingStream<ToolEvent, Error> {
            AsyncThrowingStream { c in
                c.yield(.log("only a log"))
                c.finish()
            }
        }
    }

    /// Tool that throws mid-stream.
    private struct FailingStreamingTool: StreamingBuiltinTool {
        let name: ToolName = "test.fail"
        var spec: ToolSpec { ToolSpec(name: name, description: "test") }
        struct Boom: Error {}
        func invokeStreaming(arguments: String) -> AsyncThrowingStream<ToolEvent, Error> {
            AsyncThrowingStream { c in
                c.yield(.log("about to fail"))
                c.finish(throwing: Boom())
            }
        }
    }

    /// Thread-safe sink for the test's progress / event observers.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _progress: [String] = []
        private var _events: [AgentEvent] = []
        var progress: [String] {
            lock.lock(); defer { lock.unlock() }; return _progress
        }
        var events: [AgentEvent] {
            lock.lock(); defer { lock.unlock() }; return _events
        }
        func appendProgress(_ s: String) {
            lock.lock(); _progress.append(s); lock.unlock()
        }
        func appendEvent(_ e: AgentEvent) {
            lock.lock(); _events.append(e); lock.unlock()
        }
    }

    // MARK: - Happy path

    func testConsumeStreamsProgressInOrderAndReturnsResult() async throws {
        let registry = ToolRegistry()
        await registry.register(ScriptedStreamingTool(
            lines: ["step 1", "step 2", "step 3"],
            finalOutput: "final.path",
            perLineDelayNanos: 5_000_000   // 5ms between events
        ))
        let sink = Sink()

        let result = await ToolStreamConsumer.consume(
            registry: registry,
            name: "test.scripted",
            arguments: "{}",
            onProgress: { line in sink.appendProgress(line) },
            onEvent: { event in sink.appendEvent(event) }
        )

        XCTAssertEqual(result.output, "final.path")
        XCTAssertNil(result.error)
        // Order preservation: progress arrives in script order.
        XCTAssertEqual(sink.progress, ["step 1", "step 2", "step 3"])
        // Mirror through onEvent: every `.log` becomes a `.toolProgress`.
        let progressEvents = sink.events.compactMap { event -> String? in
            if case .toolProgress(let n, let m) = event {
                XCTAssertEqual(n, "test.scripted")
                return m
            }
            return nil
        }
        XCTAssertEqual(progressEvents, ["step 1", "step 2", "step 3"])
    }

    // MARK: - Ordering / "no late callback" guarantee

    /// Reproduces the production bug that would occur if the chat VM's
    /// post-`consume` `latestToolProgress = nil` could race a late
    /// progress callback. We record the progress sequence, then —
    /// immediately after `consume` returns — append a sentinel "CLEAR"
    /// to the same sink. If any callback runs after the await returns,
    /// "CLEAR" won't be the last entry.
    func testNoCallbackArrivesAfterConsumeReturns() async throws {
        let registry = ToolRegistry()
        await registry.register(ScriptedStreamingTool(
            lines: (1...10).map { "line \($0)" },
            finalOutput: "done",
            perLineDelayNanos: 1_000_000
        ))
        let sink = Sink()

        _ = await ToolStreamConsumer.consume(
            registry: registry,
            name: "test.scripted",
            arguments: "{}",
            onProgress: { line in sink.appendProgress(line) },
            onEvent: { _ in }
        )
        sink.appendProgress("CLEAR")

        XCTAssertEqual(sink.progress.last, "CLEAR")
        XCTAssertEqual(sink.progress.count, 11)
    }

    // MARK: - Error / degenerate paths

    func testStreamThatEndsWithoutResultProducesError() async throws {
        let registry = ToolRegistry()
        await registry.register(NoResultStreamingTool())
        let sink = Sink()
        let result = await ToolStreamConsumer.consume(
            registry: registry,
            name: "test.noresult",
            arguments: "{}",
            onProgress: { line in sink.appendProgress(line) }
        )
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("ended without a result"))
        XCTAssertEqual(sink.progress, ["only a log"])
    }

    func testStreamThrowsConvertsToToolResultError() async throws {
        let registry = ToolRegistry()
        await registry.register(FailingStreamingTool())
        let result = await ToolStreamConsumer.consume(
            registry: registry,
            name: "test.fail",
            arguments: "{}"
        )
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("tool invocation failed"))
    }

    func testUnknownToolSurfacesAsError() async throws {
        let registry = ToolRegistry()
        let result = await ToolStreamConsumer.consume(
            registry: registry,
            name: "test.does-not-exist",
            arguments: "{}"
        )
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
    }

    // MARK: - Plain (non-streaming) tool path

    func testPlainBuiltinToolFlowsThroughAsSingleResult() async throws {
        let registry = ToolRegistry()
        await registry.register(WordCountTool())
        let sink = Sink()
        let result = await ToolStreamConsumer.consume(
            registry: registry,
            name: "builtin.text.wordcount",
            arguments: #"{"text": "alpha beta gamma"}"#,
            onProgress: { line in sink.appendProgress(line) },
            onEvent: { event in sink.appendEvent(event) }
        )
        XCTAssertEqual(result.output, "3")
        XCTAssertNil(result.error)
        // Plain tools yield no `.log` events, so onProgress / onEvent
        // are never called — the chat-VM's `latestToolProgress` stays
        // nil, and the disclosure shows the existing "running…" row.
        XCTAssertTrue(sink.progress.isEmpty)
        XCTAssertTrue(sink.events.isEmpty)
    }
}
