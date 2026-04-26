import XCTest
@testable import InferAgents
@testable import InferCore

/// Tests that prove the shipping demo agents work end-to-end through
/// the substrate. Loads every JSON in `Sources/Infer/Resources/`,
/// asserts plan shapes per demo, runs registry validation across the
/// full set, and drives `CompositionController` against each demo's
/// actual loaded plan with a deterministic mock runner so we can
/// verify segment order and data flow on real demo data.
///
/// What this catches: typos, broken cross-references, schema-version
/// drift, missing fields, drivers misbehaving for these specific
/// agents' plans. What this can't catch (model-side): whether the
/// model emits the right tag sequence, whether the prose is good,
/// whether the critic actually approves. Those are model-evaluation
/// questions; this file is about wiring correctness.
final class BundledAgentDemoTests: XCTestCase {

    // MARK: - Resource path resolution

    /// Resolve the path to a bundled agent / persona JSON. Tests live
    /// at `Tests/InferAgentsTests/...`; agent JSONs at
    /// `Sources/Infer/Resources/{agents,personas}/`. Both rooted at
    /// the package directory, so we walk up from `#filePath` to find
    /// the package root and descend into Resources.
    private func resourcesURL(_ subdir: String, _ file: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // .../Tests/InferAgentsTests
            .deletingLastPathComponent()  // .../Tests
            .deletingLastPathComponent()  // package root (projects/infer)
            .appendingPathComponent("Sources/Infer/Resources")
            .appendingPathComponent(subdir)
            .appendingPathComponent("\(file).json")
    }

    private func loadAgent(_ subdir: String, _ file: String) throws -> PromptAgent {
        try AgentRegistry.decodePersona(at: resourcesURL(subdir, file))
    }

    /// Every demo / persona file shipped under Resources/. Drives the
    /// validation test plus the smoke "every file parses" loop. Update
    /// in lock-step when files are added or removed.
    private static let bundledAgents: [(subdir: String, file: String)] = [
        ("agents", "clock-assistant"),
        ("agents", "draft-then-edit"),
        ("agents", "branch-by-topic"),
        ("agents", "refine-prose"),
        ("agents", "code-or-prose"),
        ("personas", "brainstorm-partner"),
        ("personas", "code-reviewer"),
        ("personas", "explainer"),
        ("personas", "writing-editor"),
        ("personas", "prose-critic"),
    ]

    // MARK: - Smoke: every file parses

    func testEveryBundledFileParses() throws {
        for entry in Self.bundledAgents {
            XCTAssertNoThrow(
                try loadAgent(entry.subdir, entry.file),
                "failed to parse \(entry.subdir)/\(entry.file).json"
            )
        }
    }

    // MARK: - Per-demo plan shape

    func testClockAssistantIsAgentSinglePlanWithTools() throws {
        let agent = try loadAgent("agents", "clock-assistant")
        XCTAssertEqual(agent.kind, .agent)
        XCTAssertTrue(agent.requirements.toolsAllow.contains("builtin.clock.now"))
        XCTAssertTrue(agent.requirements.toolsAllow.contains("builtin.text.wordcount"))
        XCTAssertEqual(CompositionPlan.make(for: agent), .single(agent.id))
    }

    func testDraftThenEditIsChainAcrossTwoPersonas() throws {
        let agent = try loadAgent("agents", "draft-then-edit")
        XCTAssertEqual(agent.kind, .agent)
        guard case .chain(let members) = CompositionPlan.make(for: agent) else {
            return XCTFail("expected .chain plan")
        }
        XCTAssertEqual(members, ["infer.brainstorm", "infer.writing-editor"])
    }

    func testBranchByTopicIsProbelessRegexBranch() throws {
        let agent = try loadAgent("agents", "branch-by-topic")
        XCTAssertEqual(agent.kind, .agent)
        guard case .branch(let probe, let predicate, let then, let elseAgent) = CompositionPlan.make(for: agent) else {
            return XCTFail("expected .branch plan")
        }
        XCTAssertNil(probe, "demo should be probe-less for cheap pure-data routing")
        if case .regex(let pattern) = predicate {
            // Sanity-check the regex pattern lights up on code-shaped words.
            XCTAssertTrue(NSRegularExpression.matches(pattern: pattern, against: "review this swift function"))
            XCTAssertFalse(NSRegularExpression.matches(pattern: pattern, against: "polish this paragraph"))
        } else {
            XCTFail("expected regex predicate")
        }
        XCTAssertEqual(then, "infer.code-reviewer")
        XCTAssertEqual(elseAgent, "infer.writing-editor")
    }

    func testRefineProseIsRefineLoop() throws {
        let agent = try loadAgent("agents", "refine-prose")
        XCTAssertEqual(agent.kind, .agent)
        guard case .refine(let producer, let critic, let maxIter, let acceptWhen) = CompositionPlan.make(for: agent) else {
            return XCTFail("expected .refine plan")
        }
        XCTAssertEqual(producer, "infer.writing-editor")
        XCTAssertEqual(critic, "infer.prose-critic")
        XCTAssertGreaterThan(maxIter, 0)
        if case .regex(let pattern) = acceptWhen {
            XCTAssertTrue(NSRegularExpression.matches(pattern: pattern, against: "approve"))
            XCTAssertFalse(NSRegularExpression.matches(pattern: pattern, against: "revise: needs work"))
        } else {
            XCTFail("expected regex acceptWhen predicate")
        }
    }

    func testCodeOrProseRouterIsOrchestrator() throws {
        let agent = try loadAgent("agents", "code-or-prose")
        XCTAssertEqual(agent.kind, .agent)
        XCTAssertTrue(agent.requirements.toolsAllow.contains("agents.invoke"))
        guard case .orchestrator(let router, let candidates) = CompositionPlan.make(for: agent) else {
            return XCTFail("expected .orchestrator plan")
        }
        XCTAssertEqual(router, agent.id)
        XCTAssertEqual(candidates, ["infer.code-reviewer", "infer.writing-editor"])
    }

    // MARK: - Personas are personas

    func testEveryShippingPersonaParsesAsKindPersona() throws {
        let personaFiles = Self.bundledAgents.filter { $0.subdir == "personas" }
        for entry in personaFiles {
            let agent = try loadAgent(entry.subdir, entry.file)
            XCTAssertEqual(
                agent.kind, .persona,
                "persona file \(entry.file).json must declare kind: persona"
            )
            XCTAssertTrue(
                agent.requirements.toolsAllow.isEmpty,
                "persona \(entry.file) must not declare tools"
            )
            XCTAssertEqual(CompositionPlan.make(for: agent), .single(agent.id))
        }
    }

    func testProseCriticEmitsTerseVerdictsByPromptDesign() throws {
        // The refine demo's regex acceptWhen depends on the critic
        // emitting either `approve` or `revise: ...`. The critic's
        // system prompt is what makes that contract real. This test
        // pins the prompt's terse-output contract so a future
        // simplification doesn't silently break the refine loop.
        let critic = try loadAgent("personas", "prose-critic")
        XCTAssertTrue(critic.promptText.contains("approve"))
        XCTAssertTrue(critic.promptText.contains("revise"))
    }

    // MARK: - Cross-reference resolution across the full bundled set

    @MainActor
    func testAllDemoCrossReferencesResolveAndNoCycles() async throws {
        let registry = AgentRegistry()
        for entry in Self.bundledAgents {
            let agent = try loadAgent(entry.subdir, entry.file)
            await registry.register(agent, source: .firstParty)
        }
        let errors = await registry.validateCompositionReferences()
        XCTAssertTrue(
            errors.isEmpty,
            "registry validation surfaced unexpected errors:\n" +
            errors.map { "  - \($0.severity): \($0.message)" }.joined(separator: "\n")
        )
    }

    // MARK: - End-to-end dispatch with deterministic mock runner

    /// Drive `CompositionController.dispatch` against the actual loaded
    /// plan for `clock-assistant`. Mock runOne returns a synthetic
    /// outcome containing a tool call to `builtin.clock.now`, simulating
    /// what the runtime tool loop would produce.
    @MainActor
    func testClockAssistantDispatchProducesToolCallAndAnswer() async throws {
        let agent = try loadAgent("agents", "clock-assistant")
        let plan = CompositionPlan.make(for: agent)

        let trace = StepTrace(steps: [
            .toolCall(ToolCall(name: "builtin.clock.now", arguments: "{}")),
            .toolResult(ToolResult(output: "2026-04-26T12:00:00Z")),
            .finalAnswer("It's noon."),
        ])
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: plan,
            userText: "what time is it?",
            budget: 5,
            runOne: { id, _ in
                XCTAssertEqual(id, "infer.clock-assistant")
                return .completed(text: "It's noon.", trace: trace)
            }
        )
        XCTAssertEqual(result.finalText, "It's noon.")
        XCTAssertEqual(result.segments.map(\.agentId), ["infer.clock-assistant"])
        // Trace contains the expected tool call — the substrate
        // surfaced what the runtime would have produced.
        XCTAssertTrue(
            Predicate.toolCalled(name: "builtin.clock.now")
                .evaluate(outcome: result.outcome, remainingBudget: 5)
        )
    }

    /// Draft-then-edit chain: brainstorm runs first, then writing
    /// editor sees brainstorm's output as its user turn. Mock runner
    /// echoes the agent id into the output so we can verify
    /// propagation across the chain.
    @MainActor
    func testDraftThenEditChainPropagatesText() async throws {
        let agent = try loadAgent("agents", "draft-then-edit")
        let plan = CompositionPlan.make(for: agent)
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: plan,
            userText: "brainstorm onboarding flows",
            budget: 10,
            runOne: { id, text in
                let answer = "[\(id) saw: \(text)]"
                return .completed(text: answer, trace: StepTrace.finalAnswer(answer))
            }
        )
        XCTAssertEqual(
            result.segments.map(\.agentId),
            ["infer.brainstorm", "infer.writing-editor"]
        )
        // Editor's input is brainstorm's output. Final text reflects
        // both agents in sequence.
        XCTAssertEqual(
            result.finalText,
            "[infer.writing-editor saw: [infer.brainstorm saw: brainstorm onboarding flows]]"
        )
    }

    /// Branch-by-topic with code-shaped input dispatches to Code
    /// reviewer and skips Writing editor. Pure-data routing — no
    /// model call for the predicate, no probe agent.
    @MainActor
    func testBranchByTopicCodeRoutesToCodeReviewer() async throws {
        let agent = try loadAgent("agents", "branch-by-topic")
        let plan = CompositionPlan.make(for: agent)
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: plan,
            userText: "review this swift function for bugs",
            budget: 5,
            runOne: { id, text in
                .completed(text: "from-\(id)", trace: StepTrace.finalAnswer("from-\(id)"))
            }
        )
        XCTAssertEqual(result.segments.map(\.agentId), ["infer.code-reviewer"])
        XCTAssertEqual(result.finalText, "from-infer.code-reviewer")
    }

    @MainActor
    func testBranchByTopicProseRoutesToWritingEditor() async throws {
        let agent = try loadAgent("agents", "branch-by-topic")
        let plan = CompositionPlan.make(for: agent)
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: plan,
            userText: "polish this paragraph for clarity",
            budget: 5,
            runOne: { id, _ in
                .completed(text: "from-\(id)", trace: StepTrace.finalAnswer("from-\(id)"))
            }
        )
        XCTAssertEqual(result.segments.map(\.agentId), ["infer.writing-editor"])
        XCTAssertEqual(result.finalText, "from-infer.writing-editor")
    }

    /// Refine-prose: producer drafts, critic approves on round 1,
    /// returning the producer's draft as the final answer.
    @MainActor
    func testRefineProseAcceptsOnFirstRound() async throws {
        let agent = try loadAgent("agents", "refine-prose")
        let plan = CompositionPlan.make(for: agent)
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: plan,
            userText: "polish: 'The thing was kinda done basically.'",
            budget: 10,
            runOne: { id, text in
                if id == "infer.writing-editor" {
                    return .completed(text: "polished draft", trace: StepTrace.finalAnswer("polished draft"))
                }
                XCTAssertEqual(id, "infer.prose-critic")
                return .completed(text: "approve", trace: StepTrace.finalAnswer("approve"))
            }
        )
        XCTAssertEqual(
            result.segments.map(\.agentId),
            ["infer.writing-editor", "infer.prose-critic"]
        )
        // Final text is the producer's draft, not the critic's verdict.
        XCTAssertEqual(result.finalText, "polished draft")
    }

    /// Refine-prose with an always-revising critic loops until the
    /// iteration cap and returns the producer's last draft.
    @MainActor
    func testRefineProseIterationCapReturnsLastDraft() async throws {
        let agent = try loadAgent("agents", "refine-prose")
        let plan = CompositionPlan.make(for: agent)
        guard case .refine(_, _, let cap, _) = plan else {
            return XCTFail("expected .refine plan")
        }
        let driver = CompositionController()
        let result = await driver.dispatch(
            plan: plan,
            userText: "input",
            budget: 100,
            runOne: { id, text in
                if id == "infer.writing-editor" {
                    return .completed(text: "draft(\(text))", trace: StepTrace.finalAnswer("draft(\(text))"))
                }
                return .completed(text: "revise: needs more work", trace: StepTrace.finalAnswer("revise: needs more work"))
            }
        )
        // Producer + critic per iteration → 2 * cap segments.
        XCTAssertEqual(result.segments.count, cap * 2)
        // Last producer input was the critic's most recent feedback.
        XCTAssertTrue(result.finalText.hasPrefix("draft("))
    }

    /// Code-or-prose orchestrator: router emits an `agents.invoke`
    /// tool call, driver extracts the dispatch and runs the chosen
    /// candidate.
    @MainActor
    func testCodeOrProseOrchestratorDispatchesToCodeReviewer() async throws {
        let agent = try loadAgent("agents", "code-or-prose")
        let plan = CompositionPlan.make(for: agent)
        let driver = CompositionController()

        let routerTrace = StepTrace(steps: [
            .toolCall(ToolCall(
                name: OrchestratorDispatch.invokeToolName,
                arguments: #"{"agentID":"infer.code-reviewer","input":"review the diff"}"#
            )),
            .finalAnswer("dispatching"),
        ])
        let result = await driver.dispatch(
            plan: plan,
            userText: "look at this diff",
            budget: 5,
            runOne: { id, text in
                if id == "infer.code-or-prose" {
                    return .completed(text: "dispatching", trace: routerTrace)
                }
                XCTAssertEqual(id, "infer.code-reviewer")
                XCTAssertEqual(text, "review the diff")
                return .completed(text: "code review here", trace: StepTrace.finalAnswer("code review here"))
            }
        )
        XCTAssertEqual(
            result.segments.map(\.agentId),
            ["infer.code-or-prose", "infer.code-reviewer"]
        )
        XCTAssertEqual(result.finalText, "code review here")
    }

    /// Code-or-prose orchestrator with a router that names a
    /// non-candidate: the dispatch is rejected and the orchestrator
    /// surfaces the router's output unchanged. Robust failure mode.
    @MainActor
    func testOrchestratorRejectsNonCandidate() async throws {
        let agent = try loadAgent("agents", "code-or-prose")
        let plan = CompositionPlan.make(for: agent)
        let driver = CompositionController()

        let badTrace = StepTrace(steps: [
            .toolCall(ToolCall(
                name: OrchestratorDispatch.invokeToolName,
                arguments: #"{"agentID":"infer.does-not-exist","input":"x"}"#
            )),
        ])
        let result = await driver.dispatch(
            plan: plan,
            userText: "x",
            budget: 5,
            runOne: { id, _ in
                XCTAssertEqual(id, "infer.code-or-prose")
                return .completed(text: "router output", trace: badTrace)
            }
        )
        XCTAssertEqual(result.segments.map(\.agentId), ["infer.code-or-prose"])
        XCTAssertEqual(result.finalText, "router output")
    }
}

// MARK: - Helpers

private extension NSRegularExpression {
    static func matches(pattern: String, against text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.firstMatch(in: text, range: range) != nil
    }
}
