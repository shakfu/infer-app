import XCTest
@testable import InferAgents
@testable import InferCore

/// Sendable mutable flag for asserting "this closure didn't run."
/// `@Sendable` runOne closures can't capture mutable `var`s under
/// strict concurrency; a class with `nonisolated(unsafe)` storage is
/// the smallest workaround for test scaffolding.
private final class CallFlag: @unchecked Sendable {
    nonisolated(unsafe) var fired: Bool = false
}

/// M5a-runtime (`docs/dev/agent_implementation_plan.md`):
/// `CompositionController` driving `chain` / `fallback` / handoff /
/// budget exhaustion. The driver is runner-agnostic — these tests
/// exercise it with synthetic `runOne` closures so no llama / MLX
/// dependency is needed.
final class CompositionControllerTests: XCTestCase {

    // MARK: - CompositionPlan builder

    func testPlanForPersonaIsSingle() {
        let p = PromptAgent(
            id: "p",
            kind: .persona,
            metadata: AgentMetadata(name: "P"),
            systemPrompt: "x"
        )
        XCTAssertEqual(CompositionPlan.make(for: p), .single("p"))
    }

    func testPlanForChainAgentIsChain() {
        let a = PromptAgent(
            id: "head",
            kind: .agent,
            metadata: AgentMetadata(name: "Head"),
            requirements: AgentRequirements(),
            systemPrompt: "x",
            chain: ["b", "c"]
        )
        XCTAssertEqual(CompositionPlan.make(for: a), .chain(["b", "c"]))
    }

    func testPlanForFallbackOnlyAgentIsFallback() {
        let a = PromptAgent(
            id: "primary",
            kind: .agent,
            metadata: AgentMetadata(name: "P"),
            requirements: AgentRequirements(toolsAllow: ["t"]),
            systemPrompt: "x",
            fallback: ["alt1", "alt2"]
        )
        XCTAssertEqual(
            CompositionPlan.make(for: a),
            .fallback(primary: "primary", alternatives: ["alt1", "alt2"])
        )
    }

    func testPlanChainWinsOverFallback() {
        // When both are present, chain wins (M5a-runtime scope; M5b/M5c
        // adds per-segment fallback inside chains).
        let a = PromptAgent(
            id: "head",
            kind: .agent,
            metadata: AgentMetadata(name: "Head"),
            requirements: AgentRequirements(),
            systemPrompt: "x",
            chain: ["b"],
            fallback: ["c"]
        )
        XCTAssertEqual(CompositionPlan.make(for: a), .chain(["b"]))
    }

    func testPlanMembersInDispatchOrder() {
        XCTAssertEqual(CompositionPlan.single("a").members, ["a"])
        XCTAssertEqual(CompositionPlan.chain(["a", "b", "c"]).members, ["a", "b", "c"])
        XCTAssertEqual(
            CompositionPlan.fallback(primary: "a", alternatives: ["b", "c"]).members,
            ["a", "b", "c"]
        )
    }

    // MARK: - dispatch: single

    func testDispatchSingleReturnsAgentOutcome() async {
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: .single("a"),
            userText: "hello",
            budget: 5,
            runOne: { id, text in
                XCTAssertEqual(id, "a")
                XCTAssertEqual(text, "hello")
                return .completed(text: "answer", trace: StepTrace.finalAnswer("answer"))
            }
        )
        XCTAssertEqual(result.finalText, "answer")
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].agentId, "a")
    }

    // MARK: - dispatch: chain

    func testDispatchChainForwardsCompletedTextBetweenAgents() async {
        let driver = CompositionController()
        // Each agent writes its id into the carried text so we can
        // assert forwarding order in the final string.
        let result = await driver.dispatch(
            plan: .chain(["a", "b", "c"]),
            userText: "start",
            budget: 10,
            runOne: { id, text in
                let answer = text + "->\(id)"
                return .completed(text: answer, trace: StepTrace.finalAnswer(answer))
            }
        )
        XCTAssertEqual(result.finalText, "start->a->b->c")
        XCTAssertEqual(result.segments.map(\.agentId), ["a", "b", "c"])
    }

    func testDispatchChainShortCircuitsOnFailure() async {
        let driver = CompositionController()
        // `b` fails — `c` must not run.
        let result = await driver.dispatch(
            plan: .chain(["a", "b", "c"]),
            userText: "start",
            budget: 10,
            runOne: { id, _ in
                if id == "b" {
                    return .failed(message: "b broke", trace: StepTrace.finalAnswer(""))
                }
                return .completed(text: "ok-\(id)", trace: StepTrace.finalAnswer("ok-\(id)"))
            }
        )
        XCTAssertEqual(result.segments.map(\.agentId), ["a", "b"])
        if case .failed(let msg, _) = result.outcome {
            XCTAssertEqual(msg, "b broke")
        } else {
            XCTFail("expected .failed, got \(result.outcome)")
        }
    }

    func testDispatchChainEmptyMembersFails() async {
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: .chain([]),
            userText: "x",
            budget: 5,
            runOne: { _, _ in
                XCTFail("runOne must not be called for empty chain")
                return .failed(message: "", trace: StepTrace.finalAnswer(""))
            }
        )
        if case .failed(let msg, _) = result.outcome {
            XCTAssertTrue(msg.contains("no members"))
        } else {
            XCTFail("expected .failed")
        }
    }

    // MARK: - dispatch: fallback

    func testDispatchFallbackPrimarySucceedsAlternativesNotRun() async {
        let driver = CompositionController()
        let altRan = CallFlag()
        let result = await driver.dispatch(
            plan: .fallback(primary: "primary", alternatives: ["alt"]),
            userText: "x",
            budget: 5,
            runOne: { id, _ in
                if id == "alt" { altRan.fired = true }
                return .completed(text: "from-\(id)", trace: StepTrace.finalAnswer("from-\(id)"))
            }
        )
        XCTAssertEqual(result.finalText, "from-primary")
        XCTAssertEqual(result.segments.map(\.agentId), ["primary"])
        XCTAssertFalse(altRan.fired)
    }

    func testDispatchFallbackPrimaryFailsAlternativeWins() async {
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: .fallback(primary: "primary", alternatives: ["alt1", "alt2"]),
            userText: "x",
            budget: 10,
            runOne: { id, _ in
                if id == "primary" {
                    return .failed(message: "broke", trace: StepTrace.finalAnswer(""))
                }
                return .completed(text: "from-\(id)", trace: StepTrace.finalAnswer("from-\(id)"))
            }
        )
        XCTAssertEqual(result.finalText, "from-alt1")
        XCTAssertEqual(result.segments.map(\.agentId), ["primary", "alt1"])
    }

    func testDispatchFallbackAllFailReturnsLastFailure() async {
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: .fallback(primary: "p", alternatives: ["a", "b"]),
            userText: "x",
            budget: 10,
            runOne: { id, _ in
                .failed(message: "fail-\(id)", trace: StepTrace.finalAnswer(""))
            }
        )
        XCTAssertEqual(result.segments.map(\.agentId), ["p", "a", "b"])
        if case .failed(let msg, _) = result.outcome {
            XCTAssertEqual(msg, "fail-b")
        } else {
            XCTFail("expected .failed")
        }
    }

    func testDispatchFallbackAbandonedShortCircuits() async {
        // .abandoned is intentional — alternatives shouldn't be tried.
        let driver = CompositionController()
        let altRan = CallFlag()
        let result = await driver.dispatch(
            plan: .fallback(primary: "p", alternatives: ["a"]),
            userText: "x",
            budget: 5,
            runOne: { id, _ in
                if id == "a" { altRan.fired = true }
                return .abandoned(reason: "user said no", trace: StepTrace.finalAnswer(""))
            }
        )
        XCTAssertFalse(altRan.fired)
        if case .abandoned = result.outcome {} else {
            XCTFail("expected .abandoned")
        }
    }

    // MARK: - handoff

    func testDispatchSingleHandoffDispatchesToTarget() async {
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: .single("a"),
            userText: "original",
            budget: 5,
            runOne: { id, text in
                if id == "a" {
                    return .handoff(
                        target: "b",
                        payload: "delegated",
                        trace: StepTrace.finalAnswer("")
                    )
                }
                XCTAssertEqual(id, "b")
                XCTAssertEqual(text, "delegated")
                return .completed(text: "b answers", trace: StepTrace.finalAnswer("b answers"))
            }
        )
        XCTAssertEqual(result.segments.map(\.agentId), ["a", "b"])
        XCTAssertEqual(result.finalText, "b answers")
    }

    func testHandoffChainsMultipleHops() async {
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: .single("a"),
            userText: "x",
            budget: 5,
            runOne: { id, _ in
                switch id {
                case "a":
                    return .handoff(target: "b", payload: "to-b", trace: StepTrace.finalAnswer(""))
                case "b":
                    return .handoff(target: "c", payload: "to-c", trace: StepTrace.finalAnswer(""))
                case "c":
                    return .completed(text: "final", trace: StepTrace.finalAnswer("final"))
                default:
                    XCTFail("unexpected id: \(id)")
                    return .failed(message: "", trace: StepTrace.finalAnswer(""))
                }
            }
        )
        XCTAssertEqual(result.segments.map(\.agentId), ["a", "b", "c"])
        XCTAssertEqual(result.finalText, "final")
    }

    // MARK: - budget exhaustion

    func testBudgetExhaustionTerminatesChain() async {
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: .chain(["a", "b", "c"]),
            userText: "start",
            budget: 2,  // a + b run; c blocked.
            runOne: { id, _ in
                .completed(text: id.rawValue, trace: StepTrace.finalAnswer(id.rawValue))
            }
        )
        XCTAssertEqual(result.segments.map { $0.agentId.rawValue }, ["a", "b"])
        if case .failed(let msg, _) = result.outcome {
            XCTAssertTrue(msg.contains("budget"))
        } else {
            XCTFail("expected .failed budget message, got \(result.outcome)")
        }
    }

    func testBudgetZeroPreventsAnyDispatch() async {
        let driver = CompositionController()
        let ran = CallFlag()
        let result = await driver.dispatch(
            plan: .single("a"),
            userText: "x",
            budget: 0,
            runOne: { _, _ in
                ran.fired = true
                return .completed(text: "", trace: StepTrace.finalAnswer(""))
            }
        )
        XCTAssertFalse(ran.fired)
        XCTAssertTrue(result.segments.isEmpty)
        if case .failed = result.outcome {} else {
            XCTFail("expected .failed for zero budget")
        }
    }
}
