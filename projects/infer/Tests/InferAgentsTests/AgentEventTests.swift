import XCTest
@testable import InferAgents

/// M2 (`docs/dev/agent_implementation_plan.md`): `AgentEvent` async
/// stream replaces direct `messages[i].steps` mutation in the tool
/// loop. These tests pin two contracts:
///
/// 1. `AgentEvent.applyToTrace` produces the exact `StepTrace.steps`
///    shape that the pre-event-stream implementation emitted inline —
///    bytewise. If a future refactor reorders or adds a step, this
///    test fails first.
/// 2. The controller's broadcast stream surfaces the events in the
///    order they were emitted, so M3 subscribers (streaming disclosure,
///    transcript exporter) see a deterministic sequence.
final class AgentEventTests: XCTestCase {

    // MARK: - applyToTrace bytewise compatibility

    /// The "tool success" path the live loop emits. Final trace must
    /// match what the pre-event stamping in `maybeRunToolLoop` produced:
    /// `[assistantText(prefix), toolCall, toolResult, finalAnswer]`.
    func testApplyToTraceBytewiseToolSuccess() {
        var trace = StepTrace()
        let call = ToolCall(name: "builtin.clock.now", arguments: "{}")
        let result = ToolResult(output: "12:00")

        let events: [AgentEvent] = [
            .toolRequested(prefix: "Let me check.", call: call),
            .toolRunning(name: call.name),
            .finalChunk("It's noon."),
            .toolResulted(result),
            .terminated(.finalAnswer("It's noon.")),
        ]
        for event in events { event.applyToTrace(&trace) }

        XCTAssertEqual(trace.steps, [
            .assistantText("Let me check."),
            .toolCall(call),
            .toolResult(result),
            .finalAnswer("It's noon."),
        ])
    }

    /// Empty prefix: no `.assistantText` step prepended. The model
    /// emitted the tool call without preamble.
    func testApplyToTraceOmitsAssistantTextOnEmptyPrefix() {
        var trace = StepTrace()
        let call = ToolCall(name: "builtin.text.wordcount", arguments: "{\"s\":\"hi\"}")
        let result = ToolResult(output: "1")

        for event in [
            AgentEvent.toolRequested(prefix: "", call: call),
            .toolResulted(result),
            .terminated(.finalAnswer("One word.")),
        ] {
            event.applyToTrace(&trace)
        }

        XCTAssertEqual(trace.steps, [
            .toolCall(call),
            .toolResult(result),
            .finalAnswer("One word."),
        ])
    }

    /// Tool error path: registry / invocation failures surface as a
    /// `ToolResult` with `error` set. The trace shape is unchanged from
    /// success — the runner gets the error as ipython feedback and
    /// produces a final answer the same way.
    func testApplyToTraceToolError() {
        var trace = StepTrace()
        let call = ToolCall(name: "builtin.clock.now", arguments: "{}")
        let failed = ToolResult(output: "", error: "tool invocation failed: …")

        for event in [
            AgentEvent.toolRequested(prefix: "", call: call),
            .toolResulted(failed),
            .terminated(.finalAnswer("Sorry, I couldn't reach the clock.")),
        ] {
            event.applyToTrace(&trace)
        }

        XCTAssertEqual(trace.steps, [
            .toolCall(call),
            .toolResult(failed),
            .finalAnswer("Sorry, I couldn't reach the clock."),
        ])
    }

    /// Cancellation between request and result: the trace ends at
    /// `.cancelled` with no `toolResult` or `finalAnswer`. Matches the
    /// `finalizeIncompleteTrace(.cancelled)` path that fires from
    /// `send`'s catch blocks.
    func testApplyToTraceMidToolCancel() {
        var trace = StepTrace()
        let call = ToolCall(name: "builtin.clock.now", arguments: "{}")

        for event in [
            AgentEvent.toolRequested(prefix: "", call: call),
            .toolRunning(name: call.name),
            .terminated(.cancelled),
        ] {
            event.applyToTrace(&trace)
        }

        XCTAssertEqual(trace.steps, [
            .toolCall(call),
            .cancelled,
        ])
    }

    /// `.assistantChunk`, `.toolRunning`, `.finalChunk` are UI-only —
    /// no `StepTrace` effect. Adding any of them to the trace would
    /// break export determinism.
    func testUIOnlyEventsHaveNoTraceEffect() {
        var trace = StepTrace()
        let events: [AgentEvent] = [
            .assistantChunk("a"),
            .assistantChunk("b"),
            .toolRunning(name: "x"),
            .finalChunk("c"),
            .finalChunk("d"),
        ]
        for event in events { event.applyToTrace(&trace) }
        XCTAssertTrue(trace.steps.isEmpty)
    }

    // MARK: - terminator coverage

    func testTerminatedBudgetExceeded() {
        var trace = StepTrace()
        AgentEvent.terminated(.budgetExceeded).applyToTrace(&trace)
        XCTAssertEqual(trace.steps, [.budgetExceeded])
    }

    func testTerminatedError() {
        var trace = StepTrace()
        AgentEvent.terminated(.error("boom")).applyToTrace(&trace)
        XCTAssertEqual(trace.steps, [.error("boom")])
    }

    // MARK: - controller broadcast stream

    /// Events emitted by the controller surface on `events` in order.
    /// Stream is single-consumer (`AsyncStream`) — the test consumes
    /// from one task while the producer emits from another.
    @MainActor
    func testControllerEventsStreamPreservesOrder() async {
        let controller = AgentController(registry: AgentRegistry())
        let call = ToolCall(name: "builtin.clock.now", arguments: "{}")
        let result = ToolResult(output: "noon")

        let emitted: [AgentEvent] = [
            .toolRequested(prefix: "", call: call),
            .toolRunning(name: call.name),
            .toolResulted(result),
            .terminated(.finalAnswer("noon")),
        ]

        // Subscribe before emitting so the unbounded buffer captures
        // every event. The controller's `events` is process-lifetime;
        // we read the first `emitted.count` items and stop.
        let collector = Task { () -> [AgentEvent] in
            var seen: [AgentEvent] = []
            for await event in controller.events {
                seen.append(event)
                if seen.count == emitted.count { break }
            }
            return seen
        }

        for event in emitted { controller.emit(event) }
        let observed = await collector.value

        XCTAssertEqual(observed, emitted)
    }
}
