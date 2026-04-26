import XCTest
@testable import InferAgents
@testable import InferCore

/// End-to-end integration test demonstrating the user's target
/// scenario: a chain of three agents with mixed shapes, dispatched
/// through the existing `CompositionController`.
///
///   Agent A (deterministic) ── calls an external API via `fetch`
///        │ output: raw API payload
///        ▼
///   Agent B (deterministic) ── transforms / extracts a field
///        │ output: cleaned payload
///        ▼
///   Agent C (LLM-backed)    ── consumes the cleaned payload as its
///                              user turn and writes the final answer
///                              via the standard tool-call loop
///                              (no tool call needed, single decode)
///
/// This proves three things at once:
///
/// 1. Deterministic agents can run with NO LLM at all
///    (`Agent.customLoop` returns a `StepTrace` directly).
/// 2. Mixed pipelines compose: the same `CompositionController.chain`
///    handles deterministic + LLM agents transparently — each
///    segment's `.completed` text becomes the next segment's input.
/// 3. The same host-supplied `ToolInvoker` works for both
///    deterministic (direct invocation in `customLoop`) and
///    LLM-backed agents (in-stream tool-call parse, then invoke).
final class MixedAgentChainIntegrationTests: XCTestCase {

    // MARK: - Synthetic in-process tools (no network, no disk)

    /// A pretend external API: returns a JSON-shaped fixed payload
    /// keyed by the input "topic". Stands in for `http.fetch`.
    private struct ExternalAPITool: BuiltinTool {
        let name: ToolName = "ext.api"
        var spec: ToolSpec { ToolSpec(name: name, description: "demo external API") }
        struct Args: Decodable { let topic: String }
        func invoke(arguments: String) async throws -> ToolResult {
            guard let data = arguments.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(Args.self, from: data)
            else { return ToolResult(output: "", error: "bad args") }
            // Pretend payload — real one would come over HTTPS.
            let payload = "{\"topic\":\"\(parsed.topic)\",\"facts\":[\"alpha\",\"beta\"]}"
            return ToolResult(output: payload)
        }
    }

    /// A deterministic transform: extracts the `facts` array and
    /// returns it as a comma-joined string. Stands in for any local
    /// JSON / regex / structured processing step.
    private struct ExtractFactsTool: BuiltinTool {
        let name: ToolName = "ext.extractFacts"
        var spec: ToolSpec { ToolSpec(name: name, description: "extract facts array") }
        struct Args: Decodable { let payload: String }
        func invoke(arguments: String) async throws -> ToolResult {
            guard let data = arguments.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(Args.self, from: data),
                  let inner = parsed.payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: inner) as? [String: Any],
                  let facts = obj["facts"] as? [String]
            else { return ToolResult(output: "", error: "bad payload") }
            return ToolResult(output: facts.joined(separator: ", "))
        }
    }

    // MARK: - Test

    func testThreeAgentChainExternalAPIThenTransformThenLLM() async throws {
        // Wire a tool registry with the two synthetic tools.
        let registry = ToolRegistry()
        await registry.register([ExternalAPITool(), ExtractFactsTool()])

        // Tool invoker the loop and deterministic agents share.
        let invoker: ToolInvoker = { name, args in
            try await registry.invoke(name: name, arguments: args)
        }

        // Agent A: fetch from the external API. No LLM.
        let fetcher = DeterministicPipelineAgent(
            id: "demo.fetch",
            metadata: AgentMetadata(name: "Fetch"),
            toolsAllow: ["ext.api"],
            steps: [
                .init(
                    name: "ext.api",
                    arguments: { user, _ in "{\"topic\":\"\(user)\"}" },
                    bind: "payload"
                ),
            ],
            output: { _, bag in bag["payload"] ?? "" }
        )

        // Agent B: extract facts from the payload. No LLM.
        let processor = DeterministicPipelineAgent(
            id: "demo.process",
            metadata: AgentMetadata(name: "Process"),
            toolsAllow: ["ext.extractFacts"],
            steps: [
                .init(
                    name: "ext.extractFacts",
                    // Payload arrives as the chain's input text.
                    arguments: { user, _ in
                        let escaped = user.replacingOccurrences(of: "\"", with: "\\\"")
                        return "{\"payload\":\"\(escaped)\"}"
                    },
                    bind: "facts"
                ),
            ],
            output: { _, bag in bag["facts"] ?? "" }
        )

        // Agent C: LLM-backed reply. The mock runner produces a single
        // assistant turn that quotes the cleaned payload — simulating
        // a real model that would render the facts into prose.
        struct ReplierAgent: Agent {
            let id: AgentID = "demo.reply"
            let metadata = AgentMetadata(name: "Reply")
            let requirements = AgentRequirements(toolsAllow: [])
            func decodingParams(for context: AgentContext) -> DecodingParams {
                DecodingParams(temperature: 0, topP: 1, maxTokens: 64)
            }
            func systemPrompt(for context: AgentContext) async throws -> String {
                "Answer the user using the structured facts in their message."
            }
        }
        // The mock's response interpolates whatever user-turn text it
        // sees into a templated reply; that lets us assert the chain
        // forwarded the processor's output as Agent C's input.
        let llmRunner = MockAgentRunner(["Here are the facts: alpha, beta."])

        // Compose chain via the existing controller. The runOne
        // closure dispatches each agent against the appropriate
        // mechanism — customLoop short-circuit for deterministic
        // agents, BasicLoop for LLM-backed agents.
        let driver = CompositionController()
        let agentsById: [AgentID: any Agent] = [
            fetcher.id: fetcher,
            processor.id: processor,
            ReplierAgent().id: ReplierAgent(),
        ]
        let llmRunnerRef = llmRunner
        let invokerRef = invoker
        let result = await driver.dispatch(
            plan: .chain([fetcher.id, processor.id, ReplierAgent().id]),
            userText: "weather",
            budget: 8,
            runOne: { @Sendable agentId, userText in
                guard let agent = agentsById[agentId] else {
                    return .failed(message: "unknown agent: \(agentId)", trace: StepTrace())
                }
                let ctx = AgentContext(
                    runner: RunnerHandle(
                        backend: .llama,
                        templateFamily: .llama3,
                        maxContext: 4096,
                        currentTokenCount: 0
                    ),
                    tools: ToolCatalog.empty,
                    transcript: [],
                    stepCount: 0,
                    invokeTool: invokerRef
                )
                return await BasicLoop.runOutcome(
                    agent: agent,
                    turn: AgentTurn(userText: userText),
                    context: ctx,
                    runner: llmRunnerRef
                )
            }
        )

        // Final user-visible text comes from Agent C's mock response.
        XCTAssertEqual(result.finalText, "Here are the facts: alpha, beta.")

        // Three segments, one per agent, in chain order. Each is
        // attributed correctly via SegmentSpan when flattened.
        XCTAssertEqual(result.segments.count, 3)
        XCTAssertEqual(result.segments.map(\.agentId), [
            "demo.fetch",
            "demo.process",
            "demo.reply",
        ])

        // Spans tile the unified trace and attribute steps correctly.
        let trace = result.unifiedTrace()
        XCTAssertEqual(trace.segments.count, 3)
        XCTAssertEqual(trace.segments[0].agentId, "demo.fetch")
        XCTAssertEqual(trace.segments[1].agentId, "demo.process")
        XCTAssertEqual(trace.segments[2].agentId, "demo.reply")
        // Last step belongs to the LLM agent, not the processor.
        XCTAssertEqual(trace.agentId(forStepAt: trace.steps.count - 1), "demo.reply")

        // Verify the chain forwarded the processor's output AS the
        // LLM agent's user-turn text — that's the integration we
        // care about, where data flows agent-to-agent without going
        // back to the human.
        XCTAssertEqual(llmRunner.calls.count, 1)
        let llmTranscript = llmRunner.calls[0]
        XCTAssertEqual(llmTranscript.last?.role, .user)
        XCTAssertEqual(llmTranscript.last?.content, "alpha, beta")
    }
}
