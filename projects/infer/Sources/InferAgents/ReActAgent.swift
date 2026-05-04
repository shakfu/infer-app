import Foundation
import InferCore

/// Optional ReAct-style agent: same `BasicLoop` mechanism as `DefaultAgent`,
/// layered with a Reason-Act-Observe prompt rubric. The agent does NOT
/// reinvent the tool-call wire format — it relies on the model's native
/// tool-call template (Llama 3.1 `<|python_tag|>`, Qwen / Hermes
/// `<tool_call>`) for the `Action`, and uses free-form `Thought:` and
/// `Final Answer:` sentinels around it. Tool results are wrapped as
/// `Observation:` blocks before re-injection.
///
/// Synthetic (like `DefaultAgent`) rather than a JSON persona so the
/// rubric stays in code where it can evolve with the loop. Activation is
/// keyed off `ReActAgent.id` in `AgentController.activate`, with a
/// matching synthetic listing surfaced in the picker.
public struct ReActAgent: Agent {
    public static let id: AgentID = "infer.react"

    public let settings: InferSettings

    public init(settings: InferSettings = .defaults) {
        self.settings = settings
    }

    public var id: AgentID { Self.id }

    public var metadata: AgentMetadata {
        AgentMetadata(
            name: "ReAct",
            description: "Reason-Act-Observe loop: the model emits a Thought before each tool call and a Final Answer when done.",
            author: "first-party"
        )
    }

    public var requirements: AgentRequirements {
        AgentRequirements(backend: .any)
    }

    public func decodingParams(for context: AgentContext) -> DecodingParams {
        DecodingParams(from: settings)
    }

    public func systemPrompt(for context: AgentContext) async throws -> String {
        let base = settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let rubric = Self.rubric
        if base.isEmpty { return rubric }
        return base + "\n\n" + rubric
    }

    /// Wrap tool output as an `Observation:` block before it re-enters
    /// the transcript. The next decode sees the rubric mirrored back to
    /// it, which keeps the model in-pattern without needing a custom
    /// loop driver. Errors are wrapped too so the model can recover
    /// rather than ignore a silent empty observation.
    public func transformToolResult(
        _ result: ToolResult,
        call: ToolCall,
        context: AgentContext
    ) async throws -> ToolResult {
        let body: String
        if let error = result.error, !error.isEmpty {
            body = "error: \(error)"
        } else {
            body = result.output
        }
        return ToolResult(
            output: "Observation: \(body)",
            error: result.error
        )
    }

    /// Stop early when the assistant emits `Final Answer:`, even if the
    /// loop hasn't classified the step as a terminator yet. Falls
    /// through to default behaviour for every other step kind.
    public func shouldContinue(
        after step: StepTrace.Step,
        context: AgentContext
    ) async -> LoopDecision {
        if case .assistantText(let text) = step,
           text.contains(Self.finalAnswerSentinel) {
            return .stop(reason: "finalAnswer")
        }
        switch step {
        case .finalAnswer:
            return .stop(reason: "finalAnswer")
        case .cancelled:
            return .stop(reason: "cancelled")
        case .budgetExceeded:
            return .stop(reason: "budgetExceeded")
        case .error(let message):
            return .stop(reason: "error: \(message)")
        case .assistantText, .toolCall, .toolResult:
            return .continue
        }
    }

    public static let finalAnswerSentinel = "Final Answer:"

    static let rubric = """
    Follow the ReAct protocol:

    - Before any tool call, emit a single line beginning with `Thought:` \
    explaining what you intend to do and why.
    - Issue the tool call using the model's native tool-call format. \
    Treat this as the `Action`.
    - The tool's response will be returned to you as an `Observation:` \
    block. Read it, then emit another `Thought:` reflecting on what you \
    learned and what to do next.
    - Repeat Thought / Action / Observation cycles as needed.
    - When you have enough information to answer the user, emit a line \
    beginning with `Final Answer:` followed by your response. Do not \
    emit `Final Answer:` until the user's question is fully addressed.
    """
}
