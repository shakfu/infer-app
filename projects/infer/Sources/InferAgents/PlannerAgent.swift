import Foundation
import InferCore

/// LLM-driven planner agent.
///
/// `PlannerAgent` is the substrate's answer to "give the agent a goal
/// and let it figure out the steps" — the gap §5.2 / item 10 of the
/// agents review called out as the line between curated workflows and
/// a real agent runtime. Mechanism: own the loop via `customLoop`,
/// drive a multi-pass interaction against the host's LLM through the
/// new `AgentContext.decode` hook, and use the existing tool registry
/// for side effects.
///
/// Loop shape (one turn):
///
///   1. **Plan**. Decode against a planning prompt that asks for a
///      numbered list. Parse via `PlanParser.parseSteps` into a
///      `PlanLedger`. Empty / unparseable responses fall back to a
///      single-step plan so the turn always terminates with a real
///      attempt at the goal.
///   2. **Execute**. For each step, decode with the ledger rendered
///      into the prompt so the model sees prior step outputs. The
///      response is either a tool call (executed via
///      `AgentContext.invokeTool`, output captured into the ledger)
///      or plain text (taken verbatim as the step's output).
///   3. **Replan on failure**. When a step's tool call returns an
///      error and `replanCount < maxReplans`, decode a revision
///      prompt asking for fresh steps to replace the remaining work.
///      `PlanLedger.revise` overwrites everything from the cursor on.
///   4. **Synthesise**. Decode a final answer that summarises the
///      step outputs into the user-visible reply.
///
/// What's intentionally out of scope:
///
/// - **Sub-agent dispatch.** The composition primitives (`chain`,
///   `orchestrator`) already cover hand-offs between agents; the
///   planner stays a single-agent loop and routes side effects
///   through the tool catalog instead. Combining the two — a planner
///   that dispatches sub-agents — is a future composition primitive.
/// - **Branching plans.** Each `PlanStep` is linear. Conditional /
///   parallel work is the next planner generation.
/// - **JSON-backed planner schema.** This is a Swift conformance with
///   typed config so the policy stays readable. A `PromptAgent`
///   variant can land if user-authored planners become a real ask.
///
/// `PlannerAgent` is registered the same way `DeterministicPipelineAgent`
/// is — a host constructs an instance and registers it with the
/// `AgentRegistry` under `.firstParty` (or wherever) so the picker
/// surfaces it.
public struct PlannerAgent: Agent {

    public struct Config: Sendable, Equatable {
        /// Hard cap on per-step decode rounds across one turn. Counts
        /// every execution decode (one per attempted step, plus one
        /// per replan). Plan generation and final synthesis are
        /// counted separately and always allowed. Default 12 covers
        /// a 6-step plan with one full replan.
        public var maxStepDecodes: Int
        /// Max number of times the planner is allowed to revise the
        /// plan within one turn. Each revision counts against
        /// `maxStepDecodes` for its triggering step (the step that
        /// failed) — this cap just prevents the planner from looping
        /// on the same failing step forever. Default 1: one chance
        /// to recover, then the plan continues with the failure
        /// recorded.
        public var maxReplans: Int

        public init(maxStepDecodes: Int = 12, maxReplans: Int = 1) {
            self.maxStepDecodes = maxStepDecodes
            self.maxReplans = maxReplans
        }
    }

    public let id: AgentID
    public let metadata: AgentMetadata
    public let requirements: AgentRequirements
    public let defaultDecodingParams: DecodingParams
    public let plannerSystemPrompt: String
    public let config: Config

    public init(
        id: AgentID,
        metadata: AgentMetadata,
        requirements: AgentRequirements = AgentRequirements(),
        decodingParams: DecodingParams = DecodingParams(from: .defaults),
        plannerSystemPrompt: String,
        config: Config = Config()
    ) {
        self.id = id
        self.metadata = metadata
        self.requirements = requirements
        self.defaultDecodingParams = decodingParams
        self.plannerSystemPrompt = plannerSystemPrompt
        self.config = config
    }

    public func decodingParams(for context: AgentContext) -> DecodingParams {
        defaultDecodingParams
    }

    public func systemPrompt(for context: AgentContext) async throws -> String {
        // Surfaced when the picker activates the planner (the chat-VM
        // pushes this to the runner). The customLoop ignores it and
        // builds its own per-decode prompts; keeping this here lets a
        // host that bypasses customLoop (e.g. fallback path on a
        // missing decoder) still see the planner's authored intent.
        plannerSystemPrompt
    }

    public func customLoop(
        turn: AgentTurn,
        context: AgentContext
    ) async throws -> StepTrace? {
        guard let decode = context.decode else {
            throw AgentError.decoderMissing
        }
        let toolSpecs = try await toolsAvailable(for: context)
        let toolFamily = context.runner.templateFamily ?? .llama3
        let parser = ToolCallParser(family: ToolCallParser.Family(toolFamily))
        let params = decodingParams(for: context)
        var trace = StepTrace()

        // 1. Plan.
        let planText = try await decode(
            planningMessages(turn: turn, tools: toolSpecs),
            params
        )
        var stepDescriptions = PlanParser.parseSteps(from: planText)
        if stepDescriptions.isEmpty {
            // Fallback: model returned prose with no list shape. The
            // turn still needs to make progress, so we treat the
            // whole goal as a single-step plan. The execution decode
            // below will get the same tools available and likely
            // produce the answer directly.
            stepDescriptions = [turn.userText]
        }
        var ledger = PlanLedger(
            goal: turn.userText,
            steps: stepDescriptions.enumerated().map { idx, desc in
                PlanLedger.PlanStep(ordinal: idx + 1, description: desc)
            }
        )
        trace.steps.append(.assistantText("Plan drafted:\n\(ledger.renderForPrompt())"))

        // 2. Execute.
        var stepDecodesRemaining = config.maxStepDecodes
        while !ledger.isComplete {
            guard stepDecodesRemaining > 0 else {
                trace.steps.append(.budgetExceeded)
                return trace
            }
            stepDecodesRemaining -= 1
            ledger.beginCurrentStep()
            // Snapshot before mutation so the trace shows the step
            // the planner is about to run, not a pre-completed view.
            guard let activeStep = ledger.currentStep else { break }
            trace.steps.append(.assistantText(
                "Executing step \(activeStep.ordinal): \(activeStep.description)"
            ))

            let stepResponse = try await decode(
                executionMessages(
                    ledger: ledger,
                    tools: toolSpecs,
                    family: toolFamily
                ),
                params
            )

            if let match = parser.findFirstCall(in: stepResponse) {
                trace.steps.append(.toolCall(match.call))
                let toolResult = await invoke(
                    name: match.call.name,
                    arguments: match.call.arguments,
                    context: context
                )
                trace.steps.append(.toolResult(toolResult))

                if let err = toolResult.error {
                    ledger.failCurrentStep(errorMessage: err)
                    // Try to recover via replan when the replan
                    // budget allows. After the failure the cursor
                    // sits one past the failed step; `revise` will
                    // append fresh steps from there (so even a
                    // one-step plan whose only step failed gets a
                    // recovery attempt). Out-of-budget failures fall
                    // through and the loop continues with the next
                    // planned step (which may itself fail — that's
                    // fine, the synthesis step will still summarise
                    // what worked).
                    if ledger.replanCount < config.maxReplans,
                       stepDecodesRemaining > 0 {
                        stepDecodesRemaining -= 1
                        let revisionText = try await decode(
                            revisionMessages(ledger: ledger),
                            params
                        )
                        let revised = PlanParser.parseSteps(from: revisionText)
                        if !revised.isEmpty {
                            ledger.revise(remainingSteps: revised)
                            trace.steps.append(.assistantText(
                                "Plan revised:\n\(ledger.renderForPrompt())"
                            ))
                        }
                    }
                } else {
                    ledger.completeCurrentStep(output: toolResult.output)
                }
            } else {
                // No recognised tool call — treat the model's text as
                // the step's output. Useful for read-only plan steps
                // ("identify the relevant section", "summarise prior
                // step output") that don't need to call a tool.
                let trimmed = stepResponse.trimmingCharacters(in: .whitespacesAndNewlines)
                ledger.completeCurrentStep(output: trimmed)
            }
        }

        // 3. Synthesise.
        let finalText: String
        if stepDecodesRemaining > 0 {
            finalText = try await decode(
                synthesisMessages(ledger: ledger),
                params
            )
        } else {
            // Budget for synthesis was consumed by the execution
            // loop. Fall back to a deterministic summary so the user
            // still sees something — the alternative is a blank
            // reply, which is strictly worse.
            finalText = ledger.steps.compactMap { $0.output }.joined(separator: "\n\n")
        }
        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        trace.steps.append(.finalAnswer(trimmed))
        return trace
    }

    // MARK: - Prompt builders

    /// Planning prompt: ask the model to draft a numbered list. Tools
    /// are advertised in the system prompt so the planner knows what
    /// it has to work with when drafting steps; the actual step
    /// execution happens in subsequent decode rounds.
    private func planningMessages(
        turn: AgentTurn,
        tools: [ToolSpec]
    ) -> [TranscriptMessage] {
        var system = plannerSystemPrompt
        if !tools.isEmpty {
            system += "\n\nAvailable tools (call them in the execute phase):\n"
            for spec in tools {
                system += "- \(spec.name): \(spec.description)\n"
            }
        }
        system += "\n\nWhen the user gives you a goal, draft a short plan as a numbered list. One step per line. Each step should be small enough to execute in a single tool call or short reply. Do not execute the steps in this response — just list them. Do not include commentary."
        let userPrompt = "Goal: \(turn.userText)\n\nDraft the plan now."
        return [
            TranscriptMessage(role: .system, content: system),
            TranscriptMessage(role: .user, content: userPrompt),
        ]
    }

    /// Per-step execution prompt. Embeds the rendered ledger so the
    /// model sees prior step outputs as context, then asks for either
    /// a tool call or a brief text reply.
    private func executionMessages(
        ledger: PlanLedger,
        tools: [ToolSpec],
        family: TemplateFamily
    ) -> [TranscriptMessage] {
        let baseSystem = AgentController.composeSystemPrompt(
            base: plannerSystemPrompt,
            tools: tools,
            family: family
        )
        let userPrompt = """
        \(ledger.renderForPrompt())

        Execute the next pending step now. Either:
          - Emit a single tool call to one of the tools listed in your system prompt, OR
          - Reply with a brief plain-text result if the step does not require a tool.

        Do not skip ahead, do not repeat completed steps, do not add commentary.
        """
        return [
            TranscriptMessage(role: .system, content: baseSystem),
            TranscriptMessage(role: .user, content: userPrompt),
        ]
    }

    /// Replan prompt: the failing step is already recorded in the
    /// ledger; ask the model to issue a fresh numbered list to
    /// replace the remainder of the plan.
    private func revisionMessages(ledger: PlanLedger) -> [TranscriptMessage] {
        let userPrompt = """
        \(ledger.renderForPrompt())

        The last attempt failed. Revise the remaining plan: output a fresh numbered list of steps that should replace the work from the failed step onward. Keep the goal in mind. Output the new list only — no commentary.
        """
        return [
            TranscriptMessage(role: .system, content: plannerSystemPrompt),
            TranscriptMessage(role: .user, content: userPrompt),
        ]
    }

    /// Final synthesis: the model writes the user-visible reply
    /// using the completed step outputs as evidence.
    private func synthesisMessages(ledger: PlanLedger) -> [TranscriptMessage] {
        let userPrompt = """
        \(ledger.renderForPrompt())

        All steps that could be attempted are above. Write the final answer to the user's goal using the step outputs as evidence. Be concise. Note any failed steps explicitly so the user knows what could not be completed.
        """
        return [
            TranscriptMessage(role: .system, content: plannerSystemPrompt),
            TranscriptMessage(role: .user, content: userPrompt),
        ]
    }

    private func invoke(
        name: ToolName,
        arguments: String,
        context: AgentContext
    ) async -> ToolResult {
        guard let invoker = context.invokeTool else {
            return ToolResult(
                output: "",
                error: "tool invoker not wired by host"
            )
        }
        do {
            return try await invoker(name, arguments)
        } catch {
            return ToolResult(
                output: "",
                error: "tool dispatch failed: \(error)"
            )
        }
    }
}
