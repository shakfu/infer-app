import Foundation

/// What a named configuration driving a runner for a particular purpose
/// looks like. See `docs/dev/agents.md` for the design doc.
///
/// The protocol is deliberately narrow: a small set of hooks over a shared
/// loop, rather than a god-type. Conformances override only what they
/// need; the `run` default throws `AgentError.loopNotAvailable` until
/// PR 2's `AgentSession` provides a real loop implementation.
public protocol Agent: Sendable {
    var id: AgentID { get }
    var metadata: AgentMetadata { get }
    var requirements: AgentRequirements { get }

    /// Decoding parameters applied when this agent is active. Overrides
    /// `InferSettings` for the duration of the turn.
    func decodingParams(for context: AgentContext) -> DecodingParams

    /// Build the system prompt for a turn. Default: rely on a stored
    /// prompt. Dynamic agents can inspect `context` (time of day, recent
    /// transcript, tool availability) and recompute per turn.
    func systemPrompt(for context: AgentContext) async throws -> String

    /// Choose which tools are exposed to the model this turn, from the
    /// full set the `ToolCatalog` offers. Default: intersect the catalog
    /// with `requirements.toolsAllow` / `toolsDeny`.
    func toolsAvailable(for context: AgentContext) async throws -> [ToolSpec]

    /// Optionally transform a tool result before it is injected back into
    /// the runner's transcript. Default: pass through. Useful for
    /// trimming, summarising, or redacting.
    func transformToolResult(
        _ result: ToolResult,
        call: ToolCall,
        context: AgentContext
    ) async throws -> ToolResult

    /// Decide whether to continue the loop after this step. Default:
    /// continue until one of the terminal `StepTrace.Step` cases fires.
    /// Override to add custom terminators (e.g. stop when the assistant
    /// has emitted a URL).
    func shouldContinue(
        after step: StepTrace.Step,
        context: AgentContext
    ) async -> LoopDecision

    /// Escape hatch: the agent runs its own loop. Default implementation
    /// throws `AgentError.loopNotAvailable` until PR 2 wires a real loop.
    /// Overriding is rare; provided for agents whose shape doesn't match
    /// the standard tool-call loop.
    func run(turn: AgentTurn, context: AgentContext) async throws -> StepTrace
}

public extension Agent {
    func toolsAvailable(for context: AgentContext) async throws -> [ToolSpec] {
        let allow = Set(requirements.toolsAllow)
        let deny = Set(requirements.toolsDeny)
        return context.tools.tools.filter { spec in
            guard !deny.contains(spec.name) else { return false }
            return allow.isEmpty || allow.contains(spec.name)
        }
    }

    func transformToolResult(
        _ result: ToolResult,
        call: ToolCall,
        context: AgentContext
    ) async throws -> ToolResult {
        result
    }

    func shouldContinue(
        after step: StepTrace.Step,
        context: AgentContext
    ) async -> LoopDecision {
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

    func run(turn: AgentTurn, context: AgentContext) async throws -> StepTrace {
        throw AgentError.loopNotAvailable
    }
}
