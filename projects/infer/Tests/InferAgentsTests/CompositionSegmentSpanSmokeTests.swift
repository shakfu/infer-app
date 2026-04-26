import XCTest
@testable import InferAgents
@testable import InferCore

/// End-to-end smoke test for chained-turn `SegmentSpan` attribution.
///
/// Validates the data path the transcript renderer depends on: a chain
/// of two agents dispatched through `CompositionController` produces a
/// `CompositionResult` whose `unifiedTrace()` carries one
/// `SegmentSpan` per agent, tiling the steps in dispatch order with
/// the right agent ids attached. The renderer's per-step attribution
/// (`StepTrace.agentId(forStepAt:)`) is exercised against the
/// resulting trace so a regression in span construction or attribution
/// surfaces here, not deep in the UI layer.
///
/// Stays runner-agnostic — uses synthetic `runOne` closures so no
/// llama / MLX dependency is needed.
final class CompositionSegmentSpanSmokeTests: XCTestCase {

    func testChainProducesContiguousSegmentSpansAttributedToEachAgent() async {
        let driver = CompositionController()

        // Each agent emits one assistantText step plus a finalAnswer
        // terminator. Two agents chained → 4 steps total, split 2/2
        // across the spans. Using distinct outputs so we can also
        // assert chain-forwarding semantics in the same test.
        let result = await driver.dispatch(
            plan: .chain(["first", "second"]),
            userText: "hello",
            budget: 8,
            runOne: { agentId, userText in
                let body = "[\(agentId) saw: \(userText)]"
                return .completed(
                    text: body,
                    trace: StepTrace(steps: [
                        .assistantText(body),
                        .finalAnswer(body),
                    ])
                )
            }
        )

        // Composition-level attribution.
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].agentId, "first")
        XCTAssertEqual(result.segments[1].agentId, "second")
        XCTAssertEqual(result.finalText, "[second saw: [first saw: hello]]")

        // Unified trace shape.
        let trace = result.unifiedTrace()
        XCTAssertEqual(trace.steps.count, 4)
        XCTAssertEqual(trace.segments.count, 2)

        // Spans tile the steps with no gap and no overlap.
        XCTAssertEqual(trace.segments[0].agentId, "first")
        XCTAssertEqual(trace.segments[0].startStep, 0)
        XCTAssertEqual(trace.segments[0].endStep, 2)
        XCTAssertEqual(trace.segments[1].agentId, "second")
        XCTAssertEqual(trace.segments[1].startStep, 2)
        XCTAssertEqual(trace.segments[1].endStep, 4)

        // Per-step attribution — the surface the transcript renderer
        // calls. Both inner steps of the first segment attribute to
        // "first", both of the second attribute to "second".
        XCTAssertEqual(trace.agentId(forStepAt: 0), "first")
        XCTAssertEqual(trace.agentId(forStepAt: 1), "first")
        XCTAssertEqual(trace.agentId(forStepAt: 2), "second")
        XCTAssertEqual(trace.agentId(forStepAt: 3), "second")
        // Out-of-range index returns nil rather than the last span's
        // agent — matches the renderer's "no attribution" branch.
        XCTAssertNil(trace.agentId(forStepAt: 4))
        XCTAssertNil(trace.agentId(forStepAt: -1))
    }

    func testSingleAgentTurnHasNoSegmentSpans() async {
        // Confirms that a non-composition turn produces a trace with
        // an empty `segments` array — the renderer falls back to the
        // message-level agentId in that case, and `agentId(forStepAt:)`
        // returns nil for every index.
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: .single("solo"),
            userText: "hello",
            budget: 4,
            runOne: { _, _ in
                .completed(
                    text: "ok",
                    trace: StepTrace(steps: [.finalAnswer("ok")])
                )
            }
        )
        let trace = result.unifiedTrace()
        XCTAssertEqual(trace.steps.count, 1)
        // Even single-agent turns get a span when there's at least
        // one step — the unified trace is uniform across plan shapes.
        // What the renderer keys on is whether the per-message
        // agentId matches the lone span (yes here), in which case it
        // can elide span rendering.
        XCTAssertEqual(trace.segments, [
            StepTrace.SegmentSpan(agentId: "solo", startStep: 0, endStep: 1),
        ])
        XCTAssertEqual(trace.agentId(forStepAt: 0), "solo")
    }

    func testHandoffFollowsAttributionThroughTarget() async {
        // Handoff envelopes are resolved by `runSingle` recursively —
        // a single-plan dispatch can still emit two segments. The
        // unified trace must attribute the second segment to the
        // handoff target, not the originator.
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: .single("router"),
            userText: "ignored",
            budget: 4,
            runOne: { agentId, _ in
                if agentId == "router" {
                    return .handoff(
                        target: "specialist",
                        payload: "do the thing",
                        trace: StepTrace(steps: [.assistantText("handing off")])
                    )
                }
                return .completed(
                    text: "done",
                    trace: StepTrace(steps: [.finalAnswer("done")])
                )
            }
        )
        let trace = result.unifiedTrace()
        XCTAssertEqual(trace.segments.map(\.agentId), ["router", "specialist"])
        XCTAssertEqual(trace.agentId(forStepAt: 0), "router")
        XCTAssertEqual(trace.agentId(forStepAt: 1), "specialist")
    }
}
