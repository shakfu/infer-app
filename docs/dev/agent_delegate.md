# Agent auto-selection and multi-hop delegation

Status: `delegate` primitive and the synthetic "Auto" header entry both implemented as of 2026-05-09 (`CompositionPlan.delegate`, `CompositionController.runDelegate`, `PromptAgent.DelegateSpec`, `AutoAgent`). Companion to `agent_composition.md` (which specifies the five composition primitives) and `agent_kinds.md` (persona vs agent classification). Captures a discussion thread on (a) how to add prompt-based agent auto-selection to the chat header, and (b) what it would take to extend orchestration so a single user turn can invoke multiple agents and feed one's output into the next via tool calling.

## Background: how agent selection works today

The active agent for a chat is **explicit**. The user picks it from `AgentPickerMenu` in the chat header (`projects/infer/Sources/Infer/ChatView/AgentPickerMenu.swift:14`), which calls `vm.switchAgent(to:)`. The picked agent stays active across turns until the user changes it. There is no prompt-based auto-selection at the top level.

Within a turn, the only "automatic" routing is intra-composition: an `orchestrator` agent (`CompositionPlan.orchestrator(router:candidates:)`, `projects/infer/Sources/InferAgents/CompositionPlan.swift:61`) runs a router agent first, parses an `agents.invoke` tool call out of its trace via `OrchestratorDispatch.parse` (`projects/infer/Sources/InferAgents/OrchestratorDispatch.swift:38`), and dispatches **one** named candidate. The chosen candidate's outcome is the composition's final result — there is no loop, no tool result fed back, no second hop.

Sequential multi-agent flow already exists, but as **data-driven plumbing**, not LLM-driven tool calling: `CompositionPlan.chain([A, B, C])` (`CompositionPlan.swift:24`) runs agents in order with each `.completed` text becoming the next user turn; `refine(producer:critic:)` does producer–critic feedback loops up to `maxIterations`. The driver moves text between agents directly — no LLM is asked which agent to invoke next.

## Question 1: prompt-based agent auto-selection

Two approaches, both reusing existing machinery.

### Approach A — Synthetic "Auto" orchestrator

Add a synthetic `Auto` entry to `AgentPickerMenu`. Selecting it constructs an on-the-fly `PromptAgent` whose `CompositionPlan` is `orchestrator(router: <built-in router>, candidates: <vm.availableAgents filtered by isCompatible>)`. The router's authored system prompt enumerates each candidate by id + description; the runtime exposes the synthetic `agents.invoke` tool (`BuiltinTools.swift:35`); the router emits one tool call naming a candidate; `CompositionController.runOrchestrator` (`CompositionController.swift:488`) dispatches it. No changes to `AgentController`, `OrchestratorDispatch`, or the runtime — only a builder that synthesises the composition from the current agent listing.

Trade-offs:
- + Zero new code paths. Every dispatch primitive already works.
- + Composability emerges for free: candidates can themselves be `chain` / `refine` / `branch`, so "Auto" can route to a composed sub-agent (see Question 2 below).
- − One router LLM call per user turn; latency and tokens add up on a local model.
- − No persistent active agent — the `AgentPickerMenu` label keeps saying "Auto" while the actual responder changes turn-to-turn. Need transcript attribution to be obvious (`agent_composition.md` already specifies per-segment attribution).
- − Router prompt grows with the agent library; quality degrades past ~10 candidates without categorisation.

### Approach B — Classify-then-switch

Before sending the first user message of a thread (or on detected topic shift), run a cheap pre-pass that picks an agent and calls `vm.switchAgent(to:)`. Two cheap-pass options:

1. **Embedding similarity.** Embed each agent's `description` once at registry load; embed the user prompt; pick `argmax(cos_sim)`. Local, fast (<50 ms with a small embedder), zero LLM cost.
2. **Small-model classifier.** A tiny LM (e.g. the smallest available local model) emits a single agent id from a constrained list. More flexible than similarity, but adds an inference call.

Trade-offs:
- + Cheaper at steady state once the first turn routes — subsequent turns reuse the active agent.
- + Stable active-agent identity. UI affordances (tools chip, persona name) remain coherent.
- − Re-classification policy is a real design decision: first turn only? every turn? on detected topic shift (and how is shift detected)? Get this wrong and the UX is either sticky (won't re-route when it should) or jittery (re-routes mid-conversation surprisingly).
- − Have to surface the auto-pick in the UI (e.g. an unobtrusive "Auto → infer.coder" chip on the first assistant message) so the user can override.
- − No multi-agent dispatch within a single turn — the classifier picks one agent and that agent runs (though *that* agent can itself be a composition).

### Recommendation

Start with **Approach A**. It exists end-to-end with a single builder; the orchestrator dispatch path is already wired and unit-testable. If router latency becomes the dominant complaint, layer Approach B in front of it as a cache: classify once at conversation start, only re-run the orchestrator router when the classifier's confidence is low or topic shift is detected.

## Question 2: can a single prompt invoke multiple agents and feed one's output into the next?

Yes for the deterministic case, no for the LLM-driven case — today.

### What works today

- **Sequential chain.** `CompositionPlan.chain([A, B])` runs A then B with A's text as B's input. Author-specified, no LLM-in-the-loop deciding the chain. Works with both Approaches A and B if the agent the router/classifier picks is itself a chain.
- **Producer–critic refinement.** `refine(producer:critic:maxIterations:acceptWhen:)` — bounded feedback loop, again author-specified.
- **One-hop orchestrator.** Router emits one `agents.invoke`; that candidate runs; done.

### What does not work today

A router that **reads candidate A's output and decides whether to call B** within the same user turn. The current `runOrchestrator` runs the router once, parses one dispatch, runs one candidate, and returns. There is no re-prompt of the router with the candidate's outcome as a tool result.

### Sketch: ReAct-style multi-hop orchestrator

Extend `CompositionPlan.orchestrator` (or add a sibling `delegate` primitive — see "Open questions" below) so the router runs in a loop, treating each candidate dispatch as a tool call whose result is fed back to the router until it stops emitting `agents.invoke`. Conceptually identical to `ReActAgent`'s tool loop, but the "tools" are other agents.

#### Loop shape

```
loop:
  router_outcome = runSingle(router, userText if first iter else <continuation prompt>)
  dispatch = OrchestratorDispatch.parse(router_outcome, candidates)
  if dispatch is nil:
      break  # router stopped invoking; its visible text is the final answer
  candidate_outcome = runSingle(dispatch.target, dispatch.input)
  append toolResult(name: "agents.invoke", content: finalText(candidate_outcome)) to router transcript
  if budget exhausted or iterations >= maxHops: break
return assembled outcome
```

Each iteration consumes from the same step budget that already gates compositions in `CompositionController`. The candidate's `.completed` text is wrapped as a synthetic tool result and appended to the router's running message list, so on the next iteration the router sees: original user text, its own prior assistant turn (with the `agents.invoke` call), the tool result, and is asked to continue.

#### Required changes

1. **Plan shape.** Either (a) add `maxHops` to `CompositionPlan.orchestrator(router:candidates:maxHops:)` with `maxHops: 1` preserving current behaviour, or (b) introduce a new variant `delegate(router:candidates:maxHops:)` and leave `orchestrator` as the one-shot dispatch. (b) is less risky — the existing one-shot semantics are useful in their own right (cheap routing) and shouldn't be conflated with a multi-hop loop. (We considered `react` as the variant name first because the loop pattern is ReAct-style; renamed to `delegate` to avoid confusion with the existing `ReActAgent` picker entry.)

2. **Router transcript carryover.** Today `runSingle` is called once per orchestrator turn with raw `userText`. A multi-hop loop needs the router agent to retain its message list across iterations, with synthetic tool results appended. Two implementation options:
   - Have `CompositionController` build the running message list itself and pass it via a new `runOne` overload that takes a prebuilt message list rather than a flat user-text string. Cleaner, but changes the `RunOne` closure shape used in tests.
   - Reuse the existing single-turn loop but inject a synthetic chat history into the router's `AgentContext` as a "scratchpad" the runtime concatenates ahead of the live user turn. Less invasive; risks confusing the router about what is "real" history.

3. **Tool-result rendering per template family.** The router needs to *see* the candidate's output formatted as a tool result it understands — `<tool_response>...</tool_response>` for Qwen/Hermes, `<|python_tag|>...<|eom_id|>` for Llama 3. `ToolStreamConsumer` and `ToolCallParser` already encode these; reuse the same family table.

4. **Dispatch parser changes.** `OrchestratorDispatch.parse` is per-router-turn and stateless — fine. But the loop needs to detect "router did not emit `agents.invoke` this iteration" and treat that as a clean termination (visible text becomes the final answer), distinct from "router emitted invalid JSON" (current behaviour: surface router output unchanged). Today these collapse into the same `dispatch == nil` branch; the loop should keep both as terminators but probably warn on the malformed case.

5. **Budget accounting.** Each router iteration plus each candidate dispatch is a step. The existing `budget: inout Int` already threads through `runSingle` and `runOrchestrator`; the loop just keeps decrementing.

6. **Transcript attribution.** Multi-hop produces multiple attributed segments per user turn. `agent_composition.md` already specifies this; the segment list grows as the loop iterates. UI needs to render a clear router → candidate → router → candidate → ... thread.

#### Termination

- Router emits no `agents.invoke` this iteration → its visible text is the final answer.
- `maxHops` reached → return the last candidate's `.completed` text (and surface a "max hops reached" notice in the trace).
- Step budget exhausted → existing `budgetExceededResult` path.
- Router emits `agents.invoke` naming a non-candidate id → log; treat as termination; surface router text. (Same as one-shot today.)

#### What this does *not* do

- **Parallel fan-out.** "Call A and B simultaneously, then merge" is a different primitive (`fanout` / `merge`) and not part of this proposal. The loop above is strictly sequential.
- **Agent-to-agent direct calls.** Only the router invokes candidates. Candidates do not see each other; they only see the input the router routed to them. (If a candidate is itself an orchestrator/delegate composition, that is fine — composition nests — but cross-candidate awareness is not introduced.)
- **Cross-turn router state.** The loop is one user turn. Next turn, the router starts fresh. Cross-turn memory remains out-of-scope per `agent_composition.md`.

### Open questions

1. **`orchestrator` vs new `delegate` primitive.** Recommend new primitive — see Required changes #1.
2. **Default `maxHops`.** Probably 4–6. Low enough to fail fast on a router that loops, high enough to support realistic outline → draft → critique → revise flows. Configurable per-agent via the JSON schema.
3. **Tool-result truncation.** Long candidate outputs blow up the router's context fast. Options: hard cap (e.g. 4 KB per tool result, with a "[truncated]" suffix), summariser sub-agent, or rely on the candidate to produce concise outputs. Hard cap is the simplest v1.
4. **Streaming UX.** Today the chat view streams from one runner at a time. A multi-hop loop alternates router and candidate streams. Need to decide whether the UI shows live streaming for the router's "thinking" turns or only renders the final candidate stream. Recommend: stream everything, attributed per segment, with a collapsible router-trace section.
5. **Loop detection.** A misbehaving router can re-invoke the same candidate with the same input forever (until budget). Cheap defence: hash `(target, input)` per iteration and break on repeats. Worth adding from day one.

## Mapping back to Approaches A and B

- **Approach A (Auto orchestrator)** with a one-shot orchestrator picks one agent per turn. Multi-agent flow within that turn only happens if the picked candidate is itself a `chain` / `refine` — author-specified, deterministic.
- **Approach A on top of the new `delegate` primitive** gives the user "type a prompt, watch the router compose multiple agents on the fly." This is the full version of the original question.
- **Approach B (classify-then-switch)** is orthogonal — it just picks the active top-level agent. Whether multi-agent flow happens within the turn depends on what that agent's composition is.

The cleanest staged rollout:
1. Build the synthetic Auto orchestrator over the existing one-shot `orchestrator` plan. (Approach A, today's machinery.)
2. Add the `delegate` primitive with a `maxHops` param; switch Auto to use it once stable. **(Done.)**
3. (Optional) Layer Approach B as a cache in front of Auto if router latency hurts.

The shipped Auto skipped step 1 — once `delegate` was in, building Auto on the multi-hop primitive directly was no harder than building it on one-shot, and avoided a deprecation step later.

## Implementation notes (2026-05-09)

The shipped `delegate` primitive resolves the open questions from the sketch as follows:

- **Plan shape:** new `CompositionPlan.delegate(router:, candidates:, maxHops:)` sibling of `.orchestrator`. The one-shot orchestrator semantics are preserved unchanged (cheap routing remains a useful primitive on its own).
- **Schema:** new optional `delegate: { router, candidates, maxHops }` field on `PromptAgent`. Validation rejects empty router/candidates, the router being its own candidate, and non-positive `maxHops`. `AgentRegistry.validateCompositionReferences` warns on dangling references.
- **Router transcript carryover:** chose option (b) from the sketch — a plain-text "Prior dispatches" scratchpad appended to the user text on iteration ≥ 2. Format is template-family-agnostic; the underlying chat template wraps it normally. No changes to `RunOne`'s closure shape, which keeps the unit-test seam intact.
- **Tool-result truncation:** hard cap at 4096 chars per dispatched output with a `[truncated]` suffix (`CompositionController.toolResultCharCap`).
- **Termination:** router emits no `agents.invoke` → its visible text is the final answer; `maxHops` reached → last candidate's text; loop detected (same `(target, input)` as the previous hop) → last candidate's text; budget exhausted → existing `.budgetExceeded` path; router fails/abandons → that outcome surfaces directly.
- **Loop detection** is single-step (compares against `history.last`). Stronger detection (full-history hash) was deferred — single-step catches the common pathology (router parroting the same call) without false positives on legitimate revisits.
- **Streaming UX** is still TODO — the chat view streams from one runner at a time, so the UI alternates router-thinking and candidate-output streams without explicit attribution; per-segment trace exists in `CompositionResult.unifiedTrace`, just not surfaced in the transcript yet.

Tests live in `Tests/InferAgentsTests/CompositionAdvancedTests.swift` under "Delegate (multi-hop) driver": multi-hop happy path, max-hops cap, loop detection, no-dispatch-on-first-hop fallback to one-shot semantics, scratchpad shape assertion, and two schema-rejection cases.

## Auto picker entry — implementation (2026-05-09)

The "Auto" entry in the chat-header picker (`AgentPickerMenu`) is backed by a synthetic compiled agent, `AutoAgent` (`projects/infer/Sources/InferAgents/AutoAgent.swift`), that doubles as the picker handle and the `.delegate` router. One agent rather than two because the `.delegate` invariant `router not in candidates` is satisfied by filtering Auto out of its own candidate set (`AutoAgent.candidateIds(from:)`).

### Per-turn dispatch

When `activeAgentId == AutoAgent.id`, `Generation.swift` builds:

- `plan = .delegate(router: AutoAgent.id, candidates: <every compatible non-Default, non-Auto listing>, maxHops: AutoAgent.maxHops)`
- `userText = AutoAgent.renderRouterInput(userText: <user prompt>, candidates: <listings>)` — prepends a `# Available agents` section followed by `# User request`. The router's static system prompt explains the protocol; the dynamic candidate list lives in user text so it can change between turns without re-pushing a system prompt.

If no compatible candidates exist, the plan degrades to `.single(AutoAgent.id)` — the protocol prompt covers "if no candidate fits, answer yourself," so the router still produces a sensible reply.

### Defaults and trade-offs

- `AutoAgent.maxHops = 4` — enough for outline → draft → critique → revise; low enough that a stuck router bails fast. Open question #2 from the original sketch.
- Candidate filter: drops Default (would defeat the routing point — Default is the no-agent baseline) and Auto itself; keeps personas. Personas are perfectly valid sub-responders since the router only needs each candidate to produce a `.completed` text.
- `AutoAgent` is template-family-agnostic (`backend = .any`, no `templateFamily`), so it appears compatible whatever model is loaded — the underlying router call still goes through whichever runner is active.
- `requirements.toolsAllow = ["agents.invoke"]` — the only tool the router needs. Other builtins are filtered out by `PromptAgent.toolsAvailable`'s allow-list logic, so the router's tool-call surface is intentionally tiny.

Unit tests live in `Tests/InferAgentsTests/AutoAgentTests.swift` (10 tests covering candidate filtering, listing render format, router-input composition, system prompt content, and the default-degradation case).

### Auto vs ReAct (picker disambiguation)

Both the **Auto** and **ReAct** entries in the chat header are tool-calling loops, and both are synthetic compiled agents (not JSON personas) — but they operate at different granularities and exist for different reasons. Worth disambiguating because the names are similar and the docs are easy to confuse.

| | **ReAct** (`ReActAgent`) | **Auto** (`AutoAgent`) |
|---|---|---|
| Granularity | One agent, many tools | One router, many *agents* |
| Tools available | Whatever's in the global tool catalog (clock, web search, wikipedia, RAG retrieve, builtin.* / plugin tools) | Only `agents.invoke` |
| What each "call" does | Invokes a fine-grained tool, gets a small structured result back, continues reasoning | Dispatches a *whole sub-turn* to another agent — that agent runs with its own system prompt, persona, tool allow-list, and possibly its own composition |
| Loop driver | `BasicLoop` with the ReAct rubric (`Thought:` / `Observation:` / `Final Answer:` sentinels) injected as a system-prompt addendum | `CompositionController.runDelegate` — multi-hop, scratchpad-mediated, terminates on no-dispatch / `maxHops` / loop detection / budget |
| Persona / voice | One model voice throughout the turn | Each segment carries its own agent's voice; transcript attributes per segment |
| When to use | "Answer this question; you may need to look things up" | "Pick the right specialist for this request, possibly chain a couple of them" |
| Example | "What time is it in Tokyo?" — model emits `Thought: I need the current time`, calls `builtin.clock.now`, observes, applies the timezone offset, writes `Final Answer:` | "Research $X and draft a blog post" — Auto dispatches `researcher` (which itself uses web/wiki tools), then `prose-editor`, and either lets the editor's draft stand or writes a wrap-up |

Both ship side-by-side; they're not alternatives to each other. A reasonable installation has Auto active most of the time (router decides who answers) and ReAct available for the cases where the user explicitly wants a tool-using single-agent loop without the extra router hop.

The composition primitive that powers Auto was originally named `react` (after the loop pattern) and renamed to `delegate` to keep it lexically distinct from `ReActAgent`. The pattern is still ReAct-style — the relationship is: `ReActAgent` is a single agent that calls fine-grained tools in a Reason-Act-Observe loop; `delegate` is a router agent that calls *whole sub-agents* in the same loop shape. Two different surfaces, same underlying control flow. Nothing else in the codebase routes to `delegate` today.
