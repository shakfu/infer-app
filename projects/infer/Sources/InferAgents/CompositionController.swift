import Foundation

/// Driver that walks a `CompositionPlan` to completion, asking a
/// caller-supplied closure to execute each agent's turn.
///
/// `CompositionController` knows nothing about runners, vault, or UI —
/// the closure (`runOne`) handles all of that. This split is deliberate:
/// the driver is unit-tested with synthetic closures (`tests assert
/// chain forwarding, fallback, handoff, budget`), and the chat
/// view-model plugs in a real implementation that drives `LlamaRunner`
/// / `MLXRunner` and the existing tool loop. The same controller code
/// runs in both contexts.
///
/// Returns a `CompositionResult` with the final text the user sees and
/// the per-agent segments the transcript renderer attributes back to
/// each agent. The caller stitches segments into a `StepTrace` (via the
/// `SegmentSpan` shape M5a-foundation introduced).
public actor CompositionController {

    public typealias RunOne = @Sendable (
        _ agentId: AgentID,
        _ userText: String
    ) async -> AgentOutcome

    /// One agent's turn inside a composition.
    public struct Segment: Sendable, Equatable {
        public let agentId: AgentID
        public let outcome: AgentOutcome

        public init(agentId: AgentID, outcome: AgentOutcome) {
            self.agentId = agentId
            self.outcome = outcome
        }
    }

    /// Aggregate result of a composition dispatch.
    public struct CompositionResult: Sendable, Equatable {
        /// Final user-visible text. The last completed segment's text
        /// for chains; the alternative that succeeded for fallback;
        /// the original agent's output for `.single`. Empty when no
        /// segment completed (every fallback failed, budget exhausted
        /// before first run, etc.).
        public let finalText: String
        /// Final outcome — what the caller reports up the stack.
        /// `.completed` for a successful run; `.failed` if every path
        /// errored; `.abandoned` for a non-error early exit.
        public let outcome: AgentOutcome
        /// Per-agent segments in execution order. Includes the failed
        /// attempts in fallback so the user can see *what* was tried.
        public let segments: [Segment]

        public init(
            finalText: String,
            outcome: AgentOutcome,
            segments: [Segment]
        ) {
            self.finalText = finalText
            self.outcome = outcome
            self.segments = segments
        }
    }

    public init() {}

    /// Walk `plan` to completion. `budget` is the maximum number of
    /// agent turns this dispatch may consume; each segment costs 1.
    /// When the budget is exhausted before completion, the driver
    /// returns a `.budgetExceeded`-terminated outcome.
    ///
    /// Handoff envelopes (M5a-foundation `HandoffEnvelope`) are
    /// detected on every segment's completed text. When present, the
    /// stripped `visibleText` becomes the user-visible final and the
    /// payload is dispatched to the named target as a follow-on
    /// segment — counted against the same budget.
    public func dispatch(
        plan: CompositionPlan,
        userText: String,
        budget: Int,
        runOne: RunOne
    ) async -> CompositionResult {
        var remaining = budget
        var segments: [Segment] = []

        switch plan {
        case .single(let id):
            return await runSingle(
                id: id,
                userText: userText,
                budget: &remaining,
                segments: &segments,
                runOne: runOne
            )

        case .chain(let members):
            return await runChain(
                members: members,
                userText: userText,
                budget: &remaining,
                segments: &segments,
                runOne: runOne
            )

        case .fallback(let primary, let alternatives):
            return await runFallback(
                primary: primary,
                alternatives: alternatives,
                userText: userText,
                budget: &remaining,
                segments: &segments,
                runOne: runOne
            )

        case .branch(let probe, let predicate, let then, let elseAgent):
            return await runBranch(
                probe: probe,
                predicate: predicate,
                thenAgent: then,
                elseAgent: elseAgent,
                userText: userText,
                budget: &remaining,
                segments: &segments,
                runOne: runOne
            )

        case .refine(let producer, let critic, let maxIterations, let acceptWhen):
            return await runRefine(
                producer: producer,
                critic: critic,
                maxIterations: maxIterations,
                acceptWhen: acceptWhen,
                userText: userText,
                budget: &remaining,
                segments: &segments,
                runOne: runOne
            )

        case .orchestrator(let router, let candidates):
            return await runOrchestrator(
                router: router,
                candidates: candidates,
                userText: userText,
                budget: &remaining,
                segments: &segments,
                runOne: runOne
            )
        }
    }

    // MARK: - Drivers

    /// Single-agent dispatch with handoff handling. Acts as the
    /// elementary unit the chain and fallback drivers compose over.
    private func runSingle(
        id: AgentID,
        userText: String,
        budget: inout Int,
        segments: inout [Segment],
        runOne: RunOne
    ) async -> CompositionResult {
        guard budget > 0 else {
            return budgetExceededResult(segments: segments)
        }
        budget -= 1
        let outcome = await runOne(id, userText)
        segments.append(Segment(agentId: id, outcome: outcome))

        // Handoff resolution: the agent emitted a `<<HANDOFF>>` envelope.
        // The visible text becomes the user-facing final; the payload
        // is dispatched to the target as a follow-on segment counted
        // against the same budget. If the target itself emits another
        // handoff, the recursion handles it the same way.
        if case .handoff(let target, let payload, _) = outcome {
            return await runSingle(
                id: target,
                userText: payload,
                budget: &budget,
                segments: &segments,
                runOne: runOne
            )
        }

        return CompositionResult(
            finalText: finalText(of: outcome),
            outcome: outcome,
            segments: segments
        )
    }

    /// Sequential pipeline. Each agent's `.completed` text becomes the
    /// next agent's user turn. Mid-chain `.failed` terminates with
    /// that failure; `.abandoned` likewise short-circuits. Empty
    /// `members` returns a `.failed` result — caller bug, not a
    /// silent no-op.
    private func runChain(
        members: [AgentID],
        userText: String,
        budget: inout Int,
        segments: inout [Segment],
        runOne: RunOne
    ) async -> CompositionResult {
        guard !members.isEmpty else {
            let outcome = AgentOutcome.failed(
                message: "chain has no members",
                trace: StepTrace.finalAnswer("")
            )
            return CompositionResult(finalText: "", outcome: outcome, segments: segments)
        }

        var carriedText = userText
        var lastOutcome: AgentOutcome = .failed(
            message: "chain did not run",
            trace: StepTrace.finalAnswer("")
        )

        for id in members {
            guard budget > 0 else {
                return budgetExceededResult(segments: segments)
            }
            // Each chain segment is its own runSingle so handoffs
            // inside a member resolve before chain-forwarding starts.
            let inner = await runSingle(
                id: id,
                userText: carriedText,
                budget: &budget,
                segments: &segments,
                runOne: runOne
            )
            lastOutcome = inner.outcome
            switch inner.outcome {
            case .completed:
                carriedText = inner.finalText
                continue
            case .failed, .abandoned:
                // Short-circuit. Caller-level fallback (if any) handles
                // recovery; from inside the chain, the chain is over.
                return CompositionResult(
                    finalText: inner.finalText,
                    outcome: inner.outcome,
                    segments: segments
                )
            case .handoff:
                // runSingle already followed the handoff and updated
                // segments; carry its visible text forward as the next
                // chain step's input.
                carriedText = inner.finalText
                continue
            }
        }

        return CompositionResult(
            finalText: carriedText,
            outcome: lastOutcome,
            segments: segments
        )
    }

    /// Try `primary`. On `.failed`, walk `alternatives` in order; the
    /// first `.completed` (or `.handoff`-resolved completion) wins.
    /// All-failures returns the *last* failure so the user sees the
    /// rightmost reason. `.abandoned` short-circuits without trying
    /// alternatives — abandonment is intentional, not an error.
    private func runFallback(
        primary: AgentID,
        alternatives: [AgentID],
        userText: String,
        budget: inout Int,
        segments: inout [Segment],
        runOne: RunOne
    ) async -> CompositionResult {
        var lastFailure: CompositionResult? = nil
        let attempts = [primary] + alternatives

        for id in attempts {
            guard budget > 0 else {
                return budgetExceededResult(segments: segments)
            }
            let inner = await runSingle(
                id: id,
                userText: userText,
                budget: &budget,
                segments: &segments,
                runOne: runOne
            )
            switch inner.outcome {
            case .completed, .handoff:
                return inner
            case .abandoned:
                return inner
            case .failed:
                lastFailure = inner
                continue
            }
        }

        return lastFailure ?? CompositionResult(
            finalText: "",
            outcome: .failed(
                message: "fallback exhausted",
                trace: StepTrace.finalAnswer("")
            ),
            segments: segments
        )
    }

    /// Branch driver. With `probe`, runs probe → evaluates predicate
    /// against probe's outcome → dispatches `thenAgent` or `elseAgent`.
    /// Without probe, evaluates predicate against a synthetic
    /// `.completed(userText)` outcome — useful for cheap regex-based
    /// routing on the user input alone.
    private func runBranch(
        probe: AgentID?,
        predicate: Predicate,
        thenAgent: AgentID,
        elseAgent: AgentID,
        userText: String,
        budget: inout Int,
        segments: inout [Segment],
        runOne: RunOne
    ) async -> CompositionResult {
        let probeOutcome: AgentOutcome
        let inputForBranch: String
        if let probe {
            guard budget > 0 else {
                return budgetExceededResult(segments: segments)
            }
            let probeResult = await runSingle(
                id: probe,
                userText: userText,
                budget: &budget,
                segments: &segments,
                runOne: runOne
            )
            probeOutcome = probeResult.outcome
            inputForBranch = userText  // probe doesn't transform input
        } else {
            probeOutcome = .completed(
                text: userText,
                trace: StepTrace.finalAnswer(userText)
            )
            inputForBranch = userText
        }
        let branchTo = predicate.evaluate(outcome: probeOutcome, remainingBudget: budget)
            ? thenAgent
            : elseAgent
        return await runSingle(
            id: branchTo,
            userText: inputForBranch,
            budget: &budget,
            segments: &segments,
            runOne: runOne
        )
    }

    /// Refine driver: producer-critic loop. Producer drafts; critic
    /// reviews; if `acceptWhen(critic.outcome)` true → producer's last
    /// draft wins. Else feed critic's output back to producer for
    /// another round, up to `maxIterations`. Hitting the cap returns
    /// producer's last draft regardless. Each iteration costs 2
    /// segments (producer + critic) — budget can clip the loop.
    private func runRefine(
        producer: AgentID,
        critic: AgentID,
        maxIterations: Int,
        acceptWhen: Predicate,
        userText: String,
        budget: inout Int,
        segments: inout [Segment],
        runOne: RunOne
    ) async -> CompositionResult {
        var producerInput = userText
        var lastProducerOutcome: AgentOutcome = .failed(
            message: "refine did not run",
            trace: StepTrace.finalAnswer("")
        )

        for _ in 0..<maxIterations {
            // Producer draft.
            guard budget > 0 else {
                return budgetExceededResult(segments: segments)
            }
            let producerResult = await runSingle(
                id: producer,
                userText: producerInput,
                budget: &budget,
                segments: &segments,
                runOne: runOne
            )
            lastProducerOutcome = producerResult.outcome
            switch producerResult.outcome {
            case .failed, .abandoned:
                return producerResult  // bail; nothing to refine
            case .completed, .handoff:
                break
            }

            // Critic review against producer's draft.
            guard budget > 0 else {
                return CompositionResult(
                    finalText: producerResult.finalText,
                    outcome: lastProducerOutcome,
                    segments: segments
                )
            }
            let criticResult = await runSingle(
                id: critic,
                userText: producerResult.finalText,
                budget: &budget,
                segments: &segments,
                runOne: runOne
            )

            if acceptWhen.evaluate(outcome: criticResult.outcome, remainingBudget: budget) {
                // Critic accepted — return the producer's draft, not
                // the critic's text (the critic produces a critique,
                // not the user-facing answer).
                return CompositionResult(
                    finalText: producerResult.finalText,
                    outcome: lastProducerOutcome,
                    segments: segments
                )
            }

            // Loop: critic's text becomes producer's next input.
            producerInput = criticResult.finalText
        }

        // Iteration cap hit. Return producer's last draft anyway —
        // "good enough" beats "no answer" per `agent_composition.md`.
        let lastDraftText: String
        switch lastProducerOutcome {
        case .completed(let text, _): lastDraftText = text
        case .handoff(_, _, _), .abandoned, .failed: lastDraftText = ""
        }
        return CompositionResult(
            finalText: lastDraftText,
            outcome: lastProducerOutcome,
            segments: segments
        )
    }

    /// Orchestrator driver (M5c). The router runs first; its emitted
    /// text is parsed for an `agents.invoke` tool call that names the
    /// candidate to dispatch to. The chosen candidate's outcome is the
    /// composition's final answer. If the router doesn't emit a valid
    /// dispatch — picks no candidate, picks a non-candidate, or
    /// dispatch parsing fails — we return the router's outcome
    /// directly (graceful degradation: the user at least sees the
    /// router's commentary instead of a silent failure).
    private func runOrchestrator(
        router: AgentID,
        candidates: [AgentID],
        userText: String,
        budget: inout Int,
        segments: inout [Segment],
        runOne: RunOne
    ) async -> CompositionResult {
        guard budget > 0 else {
            return budgetExceededResult(segments: segments)
        }
        let routerResult = await runSingle(
            id: router,
            userText: userText,
            budget: &budget,
            segments: &segments,
            runOne: runOne
        )
        // Look for an invoke tool call in the router's trace; failing
        // that, scan its visible text for an inline invoke pattern.
        let dispatch = OrchestratorDispatch.parse(
            routerOutcome: routerResult.outcome,
            candidates: candidates
        )
        guard let dispatch else {
            // Router didn't pick a candidate — surface its output
            // directly so the user sees something rather than nothing.
            return routerResult
        }
        guard budget > 0 else {
            return budgetExceededResult(segments: segments)
        }
        return await runSingle(
            id: dispatch.target,
            userText: dispatch.input,
            budget: &budget,
            segments: &segments,
            runOne: runOne
        )
    }

    // MARK: - Helpers

    private func budgetExceededResult(segments: [Segment]) -> CompositionResult {
        var trace = StepTrace()
        trace.steps.append(.budgetExceeded)
        return CompositionResult(
            finalText: "",
            outcome: .failed(
                message: "step budget exhausted",
                trace: trace
            ),
            segments: segments
        )
    }

    private func finalText(of outcome: AgentOutcome) -> String {
        switch outcome {
        case .completed(let text, _): return text
        case .handoff(_, _, _): return ""  // handoff has no user-visible final by itself
        case .abandoned, .failed: return ""
        }
    }
}
