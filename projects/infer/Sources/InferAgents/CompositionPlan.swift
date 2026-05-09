import Foundation

/// Dispatch shape for a single user turn, derived from the active
/// agent's composition fields.
///
/// `agent_composition.md` defines five primitives; M5a-runtime ships
/// `chain` and `fallback` (plus the implicit `single` for non-composition
/// agents). `branch`, `refine`, and `orchestrator` land in M5b/M5c.
///
/// The plan is data, not behaviour — `CompositionController` walks it
/// and produces an `AgentOutcome` for each segment. Keeping plan and
/// driver separated means the chat view-model can build a plan once
/// per user turn and the driver can be unit-tested with synthetic
/// `runOne` closures (no llama, no MLX).
public enum CompositionPlan: Equatable, Sendable {
    /// No composition — dispatch the single agent and return its
    /// outcome unchanged. The default for personas, plain agents, and
    /// any agent whose composition fields are empty.
    case single(AgentID)

    /// Sequential pipeline. Each agent in `members` runs in order;
    /// the previous agent's `.completed` text becomes the next agent's
    /// user turn. Mid-pipeline `.failed` terminates the chain.
    case chain([AgentID])

    /// Try `primary` first; if it returns `.failed`, walk
    /// `alternatives` in order. The first completion wins. All-failures
    /// returns the last `.failed` outcome.
    case fallback(primary: AgentID, alternatives: [AgentID])

    /// Conditional dispatch (M5b). Optional `probe` runs first to
    /// produce an outcome the predicate evaluates against; without a
    /// probe, the predicate evaluates against the user text wrapped in
    /// a synthetic `.completed` outcome. Predicate true → `then`,
    /// false → `else`.
    case branch(
        probe: AgentID?,
        predicate: Predicate,
        then: AgentID,
        elseAgent: AgentID
    )

    /// Producer-critic refinement loop (M5b). Producer drafts an
    /// answer; critic reviews. If `acceptWhen` matches the critic's
    /// outcome, the producer's last draft is the final answer. Else
    /// loop: critic's output feeds back to the producer for another
    /// round, up to `maxIterations`. Hitting the cap returns the
    /// producer's last draft anyway.
    case refine(
        producer: AgentID,
        critic: AgentID,
        maxIterations: Int,
        acceptWhen: Predicate
    )

    /// Router-driven dispatch (M5c). The router runs first against the
    /// user text with a synthetic `agents.invoke` tool exposed; its
    /// emitted tool call names a `candidates` member to dispatch to
    /// next. The chosen candidate's outcome is the composition's
    /// final result.
    case orchestrator(router: AgentID, candidates: [AgentID])

    /// Multi-hop delegation loop (`agent_delegate.md`). Like
    /// `.orchestrator` but the router runs in a loop: each candidate's
    /// output is fed back to the router as a synthetic tool result,
    /// and the router decides whether to invoke another candidate or
    /// terminate. The composition's final answer is the router's
    /// visible text on the iteration where it stops emitting
    /// `agents.invoke`, or the last candidate's text if `maxHops` is
    /// hit first. Loop detection (same `(target, input)` twice in a
    /// row) terminates the loop early. Pattern is ReAct-style
    /// (LLM emits "tool" calls, observes results, decides next step)
    /// applied to whole agents instead of fine-grained tools — see
    /// `ReActAgent` for the single-agent / many-tools variant.
    case delegate(router: AgentID, candidates: [AgentID], maxHops: Int)

    /// Build a plan for `agent`. Composition fields are checked in
    /// priority order: chain → fallback → branch → refine →
    /// orchestrator → delegate → single. Fields are mutually exclusive
    /// in practice; if more than one is set we surface the highest-
    /// priority one (the registry validation pass already warns when
    /// multiple are declared).
    public static func make(for agent: any Agent) -> CompositionPlan {
        guard let prompt = agent as? PromptAgent else {
            return .single(agent.id)
        }
        if let chain = prompt.chain, !chain.isEmpty {
            return .chain(chain)
        }
        if let fallback = prompt.fallback, !fallback.isEmpty {
            return .fallback(primary: prompt.id, alternatives: fallback)
        }
        if let branch = prompt.branch {
            return .branch(
                probe: branch.probe,
                predicate: branch.predicate,
                then: branch.then,
                elseAgent: branch.else
            )
        }
        if let refine = prompt.refine {
            return .refine(
                producer: refine.producer,
                critic: refine.critic,
                maxIterations: refine.maxIterations,
                acceptWhen: refine.acceptWhen
            )
        }
        if let orch = prompt.orchestrator {
            return .orchestrator(router: orch.router, candidates: orch.candidates)
        }
        if let delegate = prompt.delegate {
            return .delegate(
                router: delegate.router,
                candidates: delegate.candidates,
                maxHops: delegate.maxHops
            )
        }
        return .single(prompt.id)
    }

    /// Every agent id this plan touches, in dispatch order. Used by the
    /// driver for budget accounting and by transcript renderers that
    /// want to preview the chain before execution.
    public var members: [AgentID] {
        switch self {
        case .single(let id): return [id]
        case .chain(let members): return members
        case .fallback(let primary, let alternatives):
            return [primary] + alternatives
        case .branch(let probe, _, let then, let elseAgent):
            return [probe, then, elseAgent].compactMap { $0 }
        case .refine(let producer, let critic, _, _):
            return [producer, critic]
        case .orchestrator(let router, let candidates):
            return [router] + candidates
        case .delegate(let router, let candidates, _):
            return [router] + candidates
        }
    }
}
