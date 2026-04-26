import XCTest
@testable import InferAgents
@testable import InferCore

/// M5a-foundation (`docs/dev/agent_implementation_plan.md`): schema v3
/// fields, handoff envelope parser, per-segment trace attribution, and
/// registry-time composition-reference validation. Runtime semantics
/// (`CompositionController`) land in the follow-up milestone.
final class CompositionFoundationTests: XCTestCase {

    // MARK: - Schema v3 round-trip

    func testSchemaV3ChainAndFallbackRoundTrip() throws {
        let agent = PromptAgent(
            id: "rt",
            kind: .agent,
            metadata: AgentMetadata(name: "RT"),
            requirements: AgentRequirements(),
            systemPrompt: "p",
            chain: ["a", "b"],
            fallback: ["c"],
            budget: PromptAgent.BudgetSpec(maxSteps: 4, onBudgetLow: nil)
        )
        let data = try JSONEncoder().encode(agent)
        let decoded = try JSONDecoder().decode(PromptAgent.self, from: data)
        XCTAssertEqual(decoded.chain, ["a", "b"])
        XCTAssertEqual(decoded.fallback, ["c"])
        XCTAssertEqual(decoded.budget?.maxSteps, 4)
        XCTAssertEqual(decoded.schemaVersion, 3)
    }

    func testSchemaV3PersonaWithFallbackRejected() {
        let data = """
        {
          "schemaVersion": 3,
          "kind": "persona",
          "id": "p",
          "metadata": {"name": "P"},
          "systemPrompt": "p",
          "fallback": ["other"]
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(PromptAgent.self, from: data)) { error in
            guard case AgentError.invalidPersona = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testSchemaV3PersonaWithBudgetRejected() {
        let data = """
        {
          "schemaVersion": 3,
          "kind": "persona",
          "id": "p",
          "metadata": {"name": "P"},
          "systemPrompt": "p",
          "budget": {"maxSteps": 2}
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(PromptAgent.self, from: data))
    }

    func testSchemaV3NonPositiveBudgetRejected() {
        let data = """
        {
          "schemaVersion": 3,
          "kind": "agent",
          "id": "a",
          "metadata": {"name": "A"},
          "systemPrompt": "p",
          "requirements": {"toolsAllow": ["x"]},
          "budget": {"maxSteps": 0}
        }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(PromptAgent.self, from: data))
    }

    func testV2FilesStillLoadable() throws {
        // Schema v2 file with no v3 fields should still parse cleanly.
        let data = """
        {
          "schemaVersion": 2,
          "kind": "agent",
          "id": "x",
          "metadata": {"name": "X"},
          "systemPrompt": "p",
          "requirements": {"toolsAllow": ["t"]}
        }
        """.data(using: .utf8)!
        let agent = try JSONDecoder().decode(PromptAgent.self, from: data)
        XCTAssertEqual(agent.schemaVersion, 2)
        XCTAssertNil(agent.fallback)
        XCTAssertNil(agent.budget)
    }

    // MARK: - HandoffEnvelope parser

    func testHandoffNoEnvelopePassthrough() {
        let parsed = HandoffEnvelope.parse("Just a normal reply.")
        XCTAssertEqual(parsed.visibleText, "Just a normal reply.")
        XCTAssertNil(parsed.handoff)
    }

    func testHandoffBasicEnvelopeStripped() {
        let text = """
        Here's what I found.
        <<HANDOFF target="critic">>Please review this draft.<<END_HANDOFF>>
        Done.
        """
        let parsed = HandoffEnvelope.parse(text)
        XCTAssertEqual(parsed.handoff?.target, "critic")
        XCTAssertEqual(parsed.handoff?.payload, "Please review this draft.")
        // Visible text is the prefix + suffix joined and trimmed.
        XCTAssertTrue(parsed.visibleText.contains("Here's what I found."))
        XCTAssertTrue(parsed.visibleText.contains("Done."))
        XCTAssertFalse(parsed.visibleText.contains("HANDOFF"))
        XCTAssertFalse(parsed.visibleText.contains("Please review"))
    }

    func testHandoffSingleQuotesAccepted() {
        let parsed = HandoffEnvelope.parse(
            "<<HANDOFF target='critic'>>x<<END_HANDOFF>>"
        )
        XCTAssertEqual(parsed.handoff?.target, "critic")
    }

    func testHandoffMissingTargetReturnsNil() {
        let parsed = HandoffEnvelope.parse(
            "<<HANDOFF>>x<<END_HANDOFF>>"
        )
        XCTAssertNil(parsed.handoff)
        // Original text returned unchanged.
        XCTAssertEqual(parsed.visibleText, "<<HANDOFF>>x<<END_HANDOFF>>")
    }

    func testHandoffMissingCloseReturnsNil() {
        // Unterminated envelope — surface raw rather than swallow output.
        let text = "<<HANDOFF target=\"critic\">>still typing"
        let parsed = HandoffEnvelope.parse(text)
        XCTAssertNil(parsed.handoff)
        XCTAssertEqual(parsed.visibleText, text)
    }

    func testHandoffEmptyTargetReturnsNil() {
        let parsed = HandoffEnvelope.parse(
            "<<HANDOFF target=\"\">>x<<END_HANDOFF>>"
        )
        XCTAssertNil(parsed.handoff)
    }

    func testHandoffEnvelopeOnlyEmptyVisibleText() {
        let parsed = HandoffEnvelope.parse(
            "<<HANDOFF target=\"x\">>just the envelope<<END_HANDOFF>>"
        )
        XCTAssertEqual(parsed.visibleText, "")
        XCTAssertEqual(parsed.handoff?.target, "x")
        XCTAssertEqual(parsed.handoff?.payload, "just the envelope")
    }

    // MARK: - StepTrace.SegmentSpan

    func testSegmentSpanRoundTrip() throws {
        let trace = StepTrace(
            steps: [.assistantText("hi"), .finalAnswer("done")],
            segments: [
                StepTrace.SegmentSpan(agentId: "first", startStep: 0, endStep: 1),
                StepTrace.SegmentSpan(agentId: "second", startStep: 1, endStep: 2),
            ]
        )
        let data = try JSONEncoder().encode(trace)
        let decoded = try JSONDecoder().decode(StepTrace.self, from: data)
        XCTAssertEqual(decoded.segments.count, 2)
        XCTAssertEqual(decoded.segments[0].agentId, "first")
        XCTAssertEqual(decoded.segments[1].endStep, 2)
    }

    func testSegmentSpanOmittedWhenEmpty() throws {
        // Single-agent traces stay byte-identical to the pre-M5 shape.
        let trace = StepTrace(steps: [.finalAnswer("x")])
        let data = try JSONEncoder().encode(trace)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("segments"), "got: \(json)")
    }

    func testSegmentSpanDecodesFromOldTraces() throws {
        // A trace written before SegmentSpan existed (no `segments` key).
        let json = """
        {"steps": [{"finalAnswer": {"_0": "x"}}]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(StepTrace.self, from: json)
        XCTAssertTrue(decoded.segments.isEmpty)
        XCTAssertEqual(decoded.steps.count, 1)
    }

    // MARK: - AgentRegistry composition validation

    func testRegistryDetectsMissingChainReference() async {
        let registry = AgentRegistry()
        let agent = PromptAgent(
            id: "a",
            kind: .agent,
            metadata: AgentMetadata(name: "A"),
            requirements: AgentRequirements(),
            systemPrompt: "p",
            chain: ["does-not-exist"]
        )
        await registry.register(agent, source: .user)
        let errors = await registry.validateCompositionReferences()
        XCTAssertTrue(errors.contains {
            $0.message.contains("unknown agent \"does-not-exist\"")
                && $0.severity == .warning
        })
    }

    func testRegistryDetectsMissingFallbackReference() async {
        let registry = AgentRegistry()
        let agent = PromptAgent(
            id: "a",
            kind: .agent,
            metadata: AgentMetadata(name: "A"),
            requirements: AgentRequirements(),
            systemPrompt: "p",
            fallback: ["missing"]
        )
        await registry.register(agent, source: .user)
        let errors = await registry.validateCompositionReferences()
        XCTAssertTrue(errors.contains {
            $0.message.contains("fallback")
                && $0.message.contains("missing")
        })
    }

    func testRegistryDetectsOrchestratorRouterAsCandidate() async {
        let registry = AgentRegistry()
        let router = PromptAgent(
            id: "router",
            kind: .agent,
            metadata: AgentMetadata(name: "Router"),
            requirements: AgentRequirements(),
            systemPrompt: "p",
            orchestrator: PromptAgent.OrchestratorSpec(
                router: "router",
                candidates: ["router", "other"]
            )
        )
        let other = PromptAgent(
            id: "other",
            kind: .agent,
            metadata: AgentMetadata(name: "Other"),
            requirements: AgentRequirements(toolsAllow: ["t"]),
            systemPrompt: "p"
        )
        await registry.register(router, source: .user)
        await registry.register(other, source: .user)
        let errors = await registry.validateCompositionReferences()
        XCTAssertTrue(errors.contains {
            $0.message.contains("router cannot also be a candidate")
        })
    }

    func testRegistryDetectsMutualChainCycle() async {
        let registry = AgentRegistry()
        let a = PromptAgent(
            id: "a",
            kind: .agent,
            metadata: AgentMetadata(name: "A"),
            requirements: AgentRequirements(),
            systemPrompt: "p",
            chain: ["b"]
        )
        let b = PromptAgent(
            id: "b",
            kind: .agent,
            metadata: AgentMetadata(name: "B"),
            requirements: AgentRequirements(),
            systemPrompt: "p",
            chain: ["a"]
        )
        await registry.register(a, source: .user)
        await registry.register(b, source: .user)
        let errors = await registry.validateCompositionReferences()
        XCTAssertTrue(errors.contains {
            $0.message.contains("composition cycle detected")
        })
    }

    func testRegistryNoErrorsForValidComposition() async {
        let registry = AgentRegistry()
        let producer = PromptAgent(
            id: "producer",
            kind: .agent,
            metadata: AgentMetadata(name: "Producer"),
            requirements: AgentRequirements(),
            systemPrompt: "p",
            chain: ["critic"]
        )
        let critic = PromptAgent(
            id: "critic",
            kind: .agent,
            metadata: AgentMetadata(name: "Critic"),
            requirements: AgentRequirements(toolsAllow: ["t"]),
            systemPrompt: "p"
        )
        await registry.register(producer, source: .user)
        await registry.register(critic, source: .user)
        let errors = await registry.validateCompositionReferences()
        XCTAssertTrue(errors.isEmpty, "got: \(errors)")
    }

    // MARK: - AgentOutcome cases compile and round-trip via Equatable

    func testAgentOutcomeEquality() {
        let trace = StepTrace.finalAnswer("hi")
        XCTAssertEqual(
            AgentOutcome.completed(text: "x", trace: trace),
            .completed(text: "x", trace: trace)
        )
        XCTAssertNotEqual(
            AgentOutcome.completed(text: "x", trace: trace),
            .failed(message: "x", trace: trace)
        )
    }
}
