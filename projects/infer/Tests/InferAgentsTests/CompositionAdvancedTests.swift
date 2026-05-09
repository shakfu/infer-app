import XCTest
@testable import InferAgents
@testable import InferCore

/// M5b + M5c: branch / refine / orchestrator drivers in
/// `CompositionController`. Driver is runner-agnostic — these tests
/// exercise it with synthetic `runOne` closures so no llama / MLX
/// dependency is needed.
final class CompositionAdvancedTests: XCTestCase {

    // MARK: - Plan builder for new cases

    func testPlanForBranchAgent() {
        let a = PromptAgent(
            id: "router",
            kind: .agent,
            metadata: AgentMetadata(name: "Router"),
            requirements: AgentRequirements(),
            systemPrompt: "x",
            branch: PromptAgent.BranchSpec(
                probe: "probe",
                predicate: .regex(pattern: "yes"),
                then: "y",
                else: "n"
            )
        )
        XCTAssertEqual(
            CompositionPlan.make(for: a),
            .branch(probe: "probe", predicate: .regex(pattern: "yes"), then: "y", elseAgent: "n")
        )
    }

    func testPlanForRefineAgent() {
        let a = PromptAgent(
            id: "loop",
            kind: .agent,
            metadata: AgentMetadata(name: "Loop"),
            requirements: AgentRequirements(),
            systemPrompt: "x",
            refine: PromptAgent.RefineSpec(
                producer: "p",
                critic: "c",
                maxIterations: 3,
                acceptWhen: .regex(pattern: "approved")
            )
        )
        XCTAssertEqual(
            CompositionPlan.make(for: a),
            .refine(producer: "p", critic: "c", maxIterations: 3, acceptWhen: .regex(pattern: "approved"))
        )
    }

    func testPlanForOrchestratorAgent() {
        let a = PromptAgent(
            id: "router",
            kind: .agent,
            metadata: AgentMetadata(name: "Router"),
            requirements: AgentRequirements(),
            systemPrompt: "x",
            orchestrator: PromptAgent.OrchestratorSpec(
                router: "router",
                candidates: ["a", "b"]
            )
        )
        XCTAssertEqual(
            CompositionPlan.make(for: a),
            .orchestrator(router: "router", candidates: ["a", "b"])
        )
    }

    // MARK: - Branch driver

    func testBranchTakesThenWhenPredicateTrue() async {
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: .branch(
                probe: nil,
                predicate: .regex(pattern: "(?i)code"),
                then: "code-path",
                elseAgent: "prose-path"
            ),
            userText: "review this code",
            budget: 5,
            runOne: { id, _ in
                .completed(text: "from-\(id)", trace: StepTrace.finalAnswer("from-\(id)"))
            }
        )
        XCTAssertEqual(result.finalText, "from-code-path")
        XCTAssertEqual(result.segments.map(\.agentId), ["code-path"])
    }

    func testBranchTakesElseWhenPredicateFalse() async {
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: .branch(
                probe: nil,
                predicate: .regex(pattern: "(?i)code"),
                then: "code-path",
                elseAgent: "prose-path"
            ),
            userText: "polish this paragraph",
            budget: 5,
            runOne: { id, _ in
                .completed(text: "from-\(id)", trace: StepTrace.finalAnswer("from-\(id)"))
            }
        )
        XCTAssertEqual(result.finalText, "from-prose-path")
    }

    func testBranchWithProbeRunsProbeFirst() async {
        let driver = CompositionController()
        let order = CallLog()
        let result = await driver.dispatch(
            plan: .branch(
                probe: "probe",
                predicate: .regex(pattern: "yes"),
                then: "y-path",
                elseAgent: "n-path"
            ),
            userText: "anything",
            budget: 5,
            runOne: { id, _ in
                order.append(id)
                if id == "probe" {
                    return .completed(text: "yes", trace: StepTrace.finalAnswer("yes"))
                }
                return .completed(text: "from-\(id)", trace: StepTrace.finalAnswer("from-\(id)"))
            }
        )
        XCTAssertEqual(order.entries, ["probe", "y-path"])
        XCTAssertEqual(result.finalText, "from-y-path")
    }

    // MARK: - Refine driver

    func testRefineAcceptsOnFirstRound() async {
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: .refine(
                producer: "p",
                critic: "c",
                maxIterations: 3,
                acceptWhen: .regex(pattern: "(?i)approve")
            ),
            userText: "draft this",
            budget: 10,
            runOne: { id, text in
                if id == "p" {
                    return .completed(text: "draft-\(text)", trace: StepTrace.finalAnswer("draft-\(text)"))
                }
                XCTAssertEqual(id, "c")
                return .completed(text: "approve", trace: StepTrace.finalAnswer("approve"))
            }
        )
        XCTAssertEqual(result.finalText, "draft-draft this")
        XCTAssertEqual(result.segments.map(\.agentId), ["p", "c"])
    }

    func testRefineLoopsAndReturnsLastDraftOnIterationCap() async {
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: .refine(
                producer: "p",
                critic: "c",
                maxIterations: 2,
                acceptWhen: .regex(pattern: "approve")
            ),
            userText: "go",
            budget: 10,
            runOne: { id, text in
                if id == "p" {
                    return .completed(text: "draft(\(text))", trace: StepTrace.finalAnswer("draft(\(text))"))
                }
                // Critic never approves — force loop to hit cap.
                return .completed(text: "needs work", trace: StepTrace.finalAnswer("needs work"))
            }
        )
        // Two iterations: producer ran twice, critic ran twice. Last
        // producer input was the critic's "needs work" feedback.
        XCTAssertEqual(result.segments.map(\.agentId), ["p", "c", "p", "c"])
        XCTAssertEqual(result.finalText, "draft(needs work)")
    }

    func testRefineProducerFailureBailsImmediately() async {
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: .refine(
                producer: "p",
                critic: "c",
                maxIterations: 5,
                acceptWhen: .noToolCalls
            ),
            userText: "x",
            budget: 10,
            runOne: { id, _ in
                if id == "p" {
                    return .failed(message: "broke", trace: StepTrace.finalAnswer(""))
                }
                XCTFail("critic should not run if producer failed")
                return .completed(text: "", trace: StepTrace.finalAnswer(""))
            }
        )
        if case .failed = result.outcome {} else {
            XCTFail("expected .failed when producer fails")
        }
        XCTAssertEqual(result.segments.map(\.agentId), ["p"])
    }

    // MARK: - Orchestrator driver

    func testOrchestratorRouterDispatchesToCandidate() async {
        let driver = CompositionController()
        // Router emits a tool call to agents.invoke targeting "code-helper".
        let routerTrace = StepTrace(steps: [
            .toolCall(ToolCall(
                name: OrchestratorDispatch.invokeToolName,
                arguments: #"{"agentID":"code-helper","input":"review the diff"}"#
            )),
            .finalAnswer("dispatching to code-helper"),
        ])
        let result = await driver.dispatch(
            plan: .orchestrator(router: "router", candidates: ["code-helper", "prose-helper"]),
            userText: "look at this diff",
            budget: 5,
            runOne: { id, text in
                if id == "router" {
                    return .completed(text: "dispatching to code-helper", trace: routerTrace)
                }
                XCTAssertEqual(id, "code-helper")
                XCTAssertEqual(text, "review the diff")
                return .completed(text: "code review!", trace: StepTrace.finalAnswer("code review!"))
            }
        )
        XCTAssertEqual(result.finalText, "code review!")
        XCTAssertEqual(result.segments.map(\.agentId), ["router", "code-helper"])
    }

    func testOrchestratorReturnsRouterOutputWhenNoDispatch() async {
        let driver = CompositionController()
        // Router emits no tool call — orchestrator surfaces router output.
        let result = await driver.dispatch(
            plan: .orchestrator(router: "router", candidates: ["a", "b"]),
            userText: "x",
            budget: 5,
            runOne: { id, _ in
                XCTAssertEqual(id, "router")
                return .completed(text: "I'm not sure who to dispatch to", trace: StepTrace.finalAnswer(""))
            }
        )
        XCTAssertEqual(result.finalText, "I'm not sure who to dispatch to")
        XCTAssertEqual(result.segments.map(\.agentId), ["router"])
    }

    func testOrchestratorRejectsNonCandidate() async {
        let driver = CompositionController()
        let routerTrace = StepTrace(steps: [
            .toolCall(ToolCall(
                name: OrchestratorDispatch.invokeToolName,
                arguments: #"{"agentID":"unknown-agent","input":"x"}"#
            )),
        ])
        let result = await driver.dispatch(
            plan: .orchestrator(router: "router", candidates: ["a", "b"]),
            userText: "x",
            budget: 5,
            runOne: { id, _ in
                XCTAssertEqual(id, "router")
                return .completed(text: "trying unknown", trace: routerTrace)
            }
        )
        // Router output surfaced; non-candidate ignored.
        XCTAssertEqual(result.segments.map(\.agentId), ["router"])
    }

    func testOrchestratorParsesInlineQwenSyntax() async {
        let driver = CompositionController()
        // Runtime tool loop didn't intercept — invoke survives in the
        // visible body. Parser falls through to text scan.
        let visible = #"<tool_call>{"name":"agents.invoke","arguments":{"agentID":"a","input":"hi"}}</tool_call>"#
        let result = await driver.dispatch(
            plan: .orchestrator(router: "router", candidates: ["a"]),
            userText: "x",
            budget: 5,
            runOne: { id, text in
                if id == "router" {
                    return .completed(text: visible, trace: StepTrace.finalAnswer(visible))
                }
                XCTAssertEqual(id, "a")
                XCTAssertEqual(text, "hi")
                return .completed(text: "handled", trace: StepTrace.finalAnswer("handled"))
            }
        )
        XCTAssertEqual(result.finalText, "handled")
    }

    // MARK: - Delegate (multi-hop) driver

    func testPlanForDelegateAgent() {
        let a = PromptAgent(
            id: "delegate-router",
            kind: .agent,
            metadata: AgentMetadata(name: "Delegate"),
            requirements: AgentRequirements(),
            systemPrompt: "x",
            delegate: PromptAgent.DelegateSpec(
                router: "delegate-router",
                candidates: ["a", "b"],
                maxHops: 4
            )
        )
        XCTAssertEqual(
            CompositionPlan.make(for: a),
            .delegate(router: "delegate-router", candidates: ["a", "b"], maxHops: 4)
        )
    }

    /// Two real hops then the router stops emitting `agents.invoke`.
    /// The router's third turn (the one with no dispatch) supplies the
    /// final answer; both candidates appear as segments in order.
    func testDelegateRouterMultiHopThenStops() async {
        let driver = CompositionController()
        let log = CallLog()
        let invokeA = makeInvokeTrace(target: "a", input: "do A")
        let invokeB = makeInvokeTrace(target: "b", input: "do B")
        let result = await driver.dispatch(
            plan: .delegate(router: "router", candidates: ["a", "b"], maxHops: 5),
            userText: "kick off",
            budget: 10,
            runOne: { id, _ in
                log.append(id)
                switch id.rawValue {
                case "router":
                    let calls = log.entries.filter { $0 == "router" }.count
                    if calls == 1 {
                        return .completed(text: "calling a", trace: invokeA)
                    } else if calls == 2 {
                        return .completed(text: "calling b", trace: invokeB)
                    } else {
                        return .completed(
                            text: "all done",
                            trace: StepTrace.finalAnswer("all done")
                        )
                    }
                case "a":
                    return .completed(text: "A-result", trace: StepTrace.finalAnswer("A-result"))
                case "b":
                    return .completed(text: "B-result", trace: StepTrace.finalAnswer("B-result"))
                default:
                    XCTFail("unexpected agent: \(id)")
                    return .completed(text: "", trace: StepTrace.finalAnswer(""))
                }
            }
        )
        XCTAssertEqual(result.finalText, "all done")
        XCTAssertEqual(
            result.segments.map(\.agentId),
            ["router", "a", "router", "b", "router"]
        )
    }

    /// Router dispatches with a *different* input each iteration
    /// (so loop detection doesn't fire); `maxHops` clips the loop and
    /// the last candidate's text is surfaced as the final answer.
    func testDelegateMaxHopsCap() async {
        let driver = CompositionController()
        let log = CallLog()
        let result = await driver.dispatch(
            plan: .delegate(router: "router", candidates: ["a"], maxHops: 2),
            userText: "x",
            budget: 20,
            runOne: { id, _ in
                log.append(id)
                if id == "router" {
                    let calls = log.entries.filter { $0 == "router" }.count
                    let trace = StepTrace(steps: [
                        .toolCall(ToolCall(
                            name: OrchestratorDispatch.invokeToolName,
                            arguments: #"{"agentID":"a","input":"call-\#(calls)"}"#
                        )),
                        .finalAnswer(""),
                    ])
                    return .completed(text: "still going", trace: trace)
                }
                let suffix = log.entries.filter { $0 == "a" }.count
                return .completed(
                    text: "A-\(suffix)",
                    trace: StepTrace.finalAnswer("A-\(suffix)")
                )
            }
        )
        // Two router dispatches, two candidate runs, then cap hits.
        XCTAssertEqual(
            result.segments.map(\.agentId),
            ["router", "a", "router", "a"]
        )
        XCTAssertEqual(result.finalText, "A-2")
    }

    /// Router emits the same `(target, input)` twice in a row. Second
    /// occurrence triggers loop detection: we surface the prior
    /// candidate's text rather than burn budget redoing the same call.
    func testDelegateLoopDetection() async {
        let driver = CompositionController()
        let log = CallLog()
        let invokeA = makeInvokeTrace(target: "a", input: "same")
        let result = await driver.dispatch(
            plan: .delegate(router: "router", candidates: ["a"], maxHops: 5),
            userText: "x",
            budget: 20,
            runOne: { id, _ in
                log.append(id)
                if id == "router" {
                    return .completed(text: "calling a", trace: invokeA)
                }
                return .completed(text: "A-result", trace: StepTrace.finalAnswer("A-result"))
            }
        )
        // First router → first 'a' → second router (loops) → break.
        XCTAssertEqual(
            result.segments.map(\.agentId),
            ["router", "a", "router"]
        )
        XCTAssertEqual(result.finalText, "A-result")
    }

    /// Router never dispatches — first hop returns its visible text.
    /// Matches one-shot orchestrator semantics for the no-dispatch
    /// path so authoring an empty delegate agent doesn't surprise.
    func testDelegateNoDispatchOnFirstHop() async {
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: .delegate(router: "router", candidates: ["a"], maxHops: 3),
            userText: "x",
            budget: 5,
            runOne: { id, _ in
                XCTAssertEqual(id, "router")
                return .completed(
                    text: "I have nothing to dispatch",
                    trace: StepTrace.finalAnswer("nothing")
                )
            }
        )
        XCTAssertEqual(result.finalText, "I have nothing to dispatch")
        XCTAssertEqual(result.segments.map(\.agentId), ["router"])
    }

    /// Subsequent router iterations see the prior candidate's output
    /// in their input scratchpad. We assert this by capturing the
    /// `userText` the router receives on its second call.
    func testDelegateScratchpadContainsPriorCandidateOutput() async {
        let driver = CompositionController()
        let log = CallLog()
        let invokeA = makeInvokeTrace(target: "a", input: "first input")
        let secondRouterInput = ScratchpadSink()
        let result = await driver.dispatch(
            plan: .delegate(router: "router", candidates: ["a"], maxHops: 3),
            userText: "original user text",
            budget: 10,
            runOne: { id, text in
                log.append(id)
                if id == "router" {
                    let calls = log.entries.filter { $0 == "router" }.count
                    if calls == 1 {
                        return .completed(text: "calling a", trace: invokeA)
                    }
                    secondRouterInput.value = text
                    return .completed(
                        text: "done",
                        trace: StepTrace.finalAnswer("done")
                    )
                }
                return .completed(
                    text: "A-output-content",
                    trace: StepTrace.finalAnswer("A-output-content")
                )
            }
        )
        XCTAssertEqual(result.finalText, "done")
        let captured = secondRouterInput.value
        XCTAssertTrue(captured.contains("original user text"), "scratchpad missing user text: \(captured)")
        XCTAssertTrue(captured.contains("Prior dispatches"), "scratchpad missing header: \(captured)")
        XCTAssertTrue(captured.contains("A-output-content"), "scratchpad missing candidate output: \(captured)")
        XCTAssertTrue(captured.contains("Invoked agent: a"), "scratchpad missing target: \(captured)")
    }

    /// Schema-level rejection: maxHops must be positive.
    func testDelegateRejectsNonPositiveMaxHops() {
        let json = #"""
        {
          "schemaVersion": 3,
          "id": "bad",
          "kind": "agent",
          "metadata": {"name": "Bad"},
          "systemPrompt": "x",
          "delegate": {"router": "r", "candidates": ["a"], "maxHops": 0}
        }
        """#
        XCTAssertThrowsError(
            try JSONDecoder().decode(PromptAgent.self, from: Data(json.utf8))
        )
    }

    /// Schema-level rejection: router must not also be a candidate.
    func testDelegateRejectsRouterAsCandidate() {
        let json = #"""
        {
          "schemaVersion": 3,
          "id": "bad",
          "kind": "agent",
          "metadata": {"name": "Bad"},
          "systemPrompt": "x",
          "delegate": {"router": "r", "candidates": ["r", "a"], "maxHops": 3}
        }
        """#
        XCTAssertThrowsError(
            try JSONDecoder().decode(PromptAgent.self, from: Data(json.utf8))
        )
    }

    // MARK: - Delegate test helpers

    /// Build a router trace whose only step is an `agents.invoke`
    /// tool call with the given target + input. Used by delegate
    /// tests to drive deterministic dispatches.
    private func makeInvokeTrace(target: String, input: String) -> StepTrace {
        let args = #"{"agentID":"\#(target)","input":"\#(input)"}"#
        return StepTrace(steps: [
            .toolCall(ToolCall(
                name: OrchestratorDispatch.invokeToolName,
                arguments: args
            )),
            .finalAnswer(""),
        ])
    }
}

/// Sendable scratchpad sink for capturing strings out of an `@Sendable`
/// closure. `nonisolated(unsafe)` for the same reason `CallLog` uses it
/// — these tests are single-threaded.
private final class ScratchpadSink: @unchecked Sendable {
    nonisolated(unsafe) var value: String = ""
}

/// Sendable accumulator used by tests that need to assert call order
/// across an `@Sendable` runOne closure.
private final class CallLog: @unchecked Sendable {
    nonisolated(unsafe) var entries: [String] = []
    func append(_ id: AgentID) { entries.append(id.rawValue) }
    func append(_ s: String) { entries.append(s) }
}
