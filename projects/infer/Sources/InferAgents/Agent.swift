import Foundation

/// What a named configuration driving a runner for a particular purpose
/// looks like. See `docs/dev/agents.md` for the design doc.
///
/// The protocol is deliberately narrow: a small set of hooks over a
/// shared loop, rather than a god-type. Conformances override only what
/// they need.
///
/// `Agent` is a *policy* type. The host owns *mechanism* — the loop
/// that decodes tokens, parses tool calls, mutates the transcript,
/// and emits events. Two host loops exist:
///
/// 1. `BasicLoop` (this module). Runner-agnostic; consumes any
///    `AgentRunner`. Use it from CLI / batch / headless contexts.
/// 2. `ChatViewModel.Generation` (host app). Specialised for the
///    SwiftUI VM — bundles vault writes, KV compaction, think-block
///    filtering, MainActor isolation, speech.
///
/// An agent that fits the standard tool-call cycle (decode → optional
/// tool call → re-decode → final answer) needs no custom loop hook;
/// the host's loop drives it via `systemPrompt`, `toolsAvailable`,
/// `transformToolResult`, `shouldContinue`. An agent that does NOT fit
/// (deterministic tool-only pipeline, agent driving an external
/// service, agent with a custom decoding protocol) overrides
/// `customLoop` to produce its `StepTrace` directly — the host then
/// uses that trace verbatim and never invokes an `AgentRunner` for
/// this turn.
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

    /// Custom turn driver. When this returns a non-nil `StepTrace`,
    /// the host uses it verbatim and does NOT invoke any `AgentRunner`
    /// for this agent's turn — the agent has supplied its own
    /// mechanism. Three concrete use cases:
    ///
    /// 1. *Deterministic / tool-only agents* — call one or more tools
    ///    and stitch the results into a `finalAnswer`, with no LLM
    ///    decode at all. See `DeterministicPipelineAgent`.
    /// 2. *External-service agents* — drive a remote API or local
    ///    process and adapt its output into a `StepTrace`.
    /// 3. *Custom decoding protocols* — agents whose shape doesn't
    ///    match `BasicLoop`'s standard tool-call cycle.
    ///
    /// `context.invokeTool` is the way to call tools without an LLM;
    /// `context.retrieve` is available for context enrichment. The
    /// agent's `metadata.id` becomes the `SegmentSpan.agentId` for
    /// the steps it produces, so composition attribution works the
    /// same as for LLM-backed agents.
    ///
    /// Default returns nil → the host falls through to its standard
    /// loop, which drives this agent through `systemPrompt`,
    /// `toolsAvailable`, etc. Most conformances should leave this
    /// default in place.
    func customLoop(
        turn: AgentTurn,
        context: AgentContext
    ) async throws -> StepTrace?
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

    func customLoop(
        turn: AgentTurn,
        context: AgentContext
    ) async throws -> StepTrace? {
        nil
    }
}
