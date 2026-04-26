import XCTest
@testable import InferAgents

final class TurnTelemetryTests: XCTestCase {

    func testRefreshCountsCountsCallsAndFailures() {
        var t = StepTrace.TurnTelemetry()
        t.refreshCounts(from: [
            .toolCall(ToolCall(name: "a", arguments: "{}")),
            .toolResult(ToolResult(output: "ok")),
            .toolCall(ToolCall(name: "b", arguments: "{}")),
            .toolResult(ToolResult(output: "", error: "boom")),
            .toolCall(ToolCall(name: "c", arguments: "{}")),
            .toolResult(ToolResult(output: "", error: "fail")),
            .finalAnswer("done"),
        ])
        XCTAssertEqual(t.toolCallCount, 3)
        XCTAssertEqual(t.toolFailureCount, 2)
    }

    func testRecordToolLatencyAccumulatesPerName() {
        var t = StepTrace.TurnTelemetry()
        t.recordToolLatency("clock.now", millis: 5)
        t.recordToolLatency("clock.now", millis: 7)
        t.recordToolLatency("vault.search", millis: 120)
        XCTAssertEqual(t.toolLatencyMillisByName["clock.now"], 12)
        XCTAssertEqual(t.toolLatencyMillisByName["vault.search"], 120)
    }

    func testTelemetryRoundTripsThroughJSON() throws {
        var t = StepTrace.TurnTelemetry(
            tokens: 42,
            durationMillis: 1234,
            toolCallCount: 1,
            toolFailureCount: 0
        )
        t.recordToolLatency("clock.now", millis: 6)
        let trace = StepTrace(
            steps: [
                .toolCall(ToolCall(name: "clock.now", arguments: "{}")),
                .toolResult(ToolResult(output: "now")),
                .finalAnswer("ok"),
            ],
            telemetry: t
        )

        let data = try JSONEncoder().encode(trace)
        let decoded = try JSONDecoder().decode(StepTrace.self, from: data)
        XCTAssertEqual(decoded.telemetry, t)
        XCTAssertEqual(decoded.steps.count, 3)
    }

    func testTelemetryOmittedWhenNilForBackwardCompat() throws {
        // Pre-telemetry traces must round-trip with no `telemetry` key
        // in the encoded form so on-disk vault rows don't grow.
        let trace = StepTrace.finalAnswer("hi")
        let data = try JSONEncoder().encode(trace)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("telemetry"), "telemetry key should be omitted when nil; got: \(json)")
    }

    func testLegacyTraceWithoutTelemetryFieldDecodes() throws {
        // Hand-crafted legacy JSON: no telemetry, no segments. Must
        // decode to a trace with `telemetry == nil`.
        let json = #"{"steps":[{"finalAnswer":{"_0":"hi"}}]}"#
        let decoded = try JSONDecoder().decode(
            StepTrace.self,
            from: Data(json.utf8)
        )
        XCTAssertNil(decoded.telemetry)
        XCTAssertEqual(decoded.steps.count, 1)
    }
}
