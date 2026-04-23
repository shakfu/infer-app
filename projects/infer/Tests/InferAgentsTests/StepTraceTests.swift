import XCTest
@testable import InferAgents

final class StepTraceTests: XCTestCase {
    func testFinalAnswerConvenience() {
        let trace = StepTrace.finalAnswer("hello")
        XCTAssertEqual(trace.steps.count, 1)
        guard case .finalAnswer(let text) = trace.steps.first else {
            return XCTFail("expected .finalAnswer")
        }
        XCTAssertEqual(text, "hello")
    }

    func testTerminatorIdentifiesTerminalStep() {
        let inProgress = StepTrace(steps: [.assistantText("mid")])
        XCTAssertNil(inProgress.terminator)

        let done = StepTrace(steps: [.assistantText("mid"), .finalAnswer("end")])
        guard case .finalAnswer = done.terminator else {
            return XCTFail("expected finalAnswer terminator")
        }

        let cancelled = StepTrace(steps: [.cancelled])
        XCTAssertEqual(cancelled.terminator, .cancelled)

        let budget = StepTrace(steps: [.budgetExceeded])
        XCTAssertEqual(budget.terminator, .budgetExceeded)

        let err = StepTrace(steps: [.error("boom")])
        guard case .error(let msg) = err.terminator else {
            return XCTFail("expected error terminator")
        }
        XCTAssertEqual(msg, "boom")
    }

    func testRoundTripAcrossAllStepVariants() throws {
        let original = StepTrace(steps: [
            .assistantText("thinking"),
            .toolCall(ToolCall(name: "read_file", arguments: "{\"path\":\"/tmp/x\"}")),
            .toolResult(ToolResult(output: "contents")),
            .toolResult(ToolResult(output: "", error: "boom")),
            .assistantText("got it"),
            .finalAnswer("done"),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StepTrace.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// Persistence contract: assistant messages produced before agents
    /// existed have no trace. Slice B will add `steps: StepTrace?` to the
    /// app's `ChatMessage`; this test pins down that a trace with zero
    /// user-visible steps still round-trips (sentinel for "no agent ran").
    func testEmptyTraceRoundTrips() throws {
        let empty = StepTrace()
        let data = try JSONEncoder().encode(empty)
        let decoded = try JSONDecoder().decode(StepTrace.self, from: data)
        XCTAssertEqual(decoded.steps, [])
        XCTAssertNil(decoded.terminator)
    }
}
