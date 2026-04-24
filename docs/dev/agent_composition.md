# Agent composition

Status: proposal, unimplemented as of 2026-04-25. Companion to `agents.md` (protocol + single-turn loop) and `agent_kinds.md` (persona vs agent classification, where `chain` and `orchestrator` are forward-declared in the schema as no-ops). This doc specifies what composition primitives exist, the cross-cutting policy decisions they force, and a v1 scope.

## Scope

Composition only applies to **agents** (in the sense defined by `agent_kinds.md` — i.e. things that already declare tools or composition). Personas cannot be composed; they are leaves by construction. The unit of composition is a single user turn: the user sends one message, the composed agents collectively produce one assistant response (which may comprise multiple attributed segments — see "Transcript attribution" below).

Out-of-scope by product decision:
- Cross-turn agent state / memory beyond the transcript.
- Sub-agents that outlive the turn that spawned them.
- Cloud-mediated coordination of any kind.

## Primitives

Ordered by payoff / complexity. Five proposed for v1; two deferred.

### 1. Sequence (pipeline)

`A → B → C`. Each agent's final answer becomes the next's user message. Already forward-declared as `chain: [AgentID]` in the v2 persona/agent schema.

```json
{
  "kind": "agent",
  "chain": ["infer.outline", "infer.draft", "infer.proofread"]
}
```

Simplest, most useful. Deterministic given seeds. No back-edges; cycles rejected at validation.

### 2. Conditional handoff

`A → if predicate(output) then B else C`.

Predicates are **declarative only** — no arbitrary Swift closures from JSON, since that is a code-execution surface. Supported predicate kinds:

- `regex: "..."` over the final answer text.
- `jsonShape: { ... }` — output parses as JSON and matches a shape (subset of JSON Schema: required keys, types).
- `toolCalled: "builtin.x.y"` — agent emitted a call to the named tool during the turn.
- `stepBudgetExceeded: true` — agent ran out of steps before producing a final answer.
- `noToolCalls: true` — agent answered without calling any tool.

```json
{
  "kind": "agent",
  "branch": {
    "agent": "infer.draft",
    "if": { "regex": "TODO" },
    "then": "infer.draft-completer",
    "else": "infer.proofread"
  }
}
```

### 3. Critic / refine loop

`A produces, B critiques, A revises`, bounded by N iterations. Special case of conditional handoff with a back-edge — given a dedicated primitive because the back-edge is the whole point and the bound is mandatory (otherwise it's a foot-gun).

```json
{
  "kind": "agent",
  "refine": {
    "producer": "infer.essay-writer",
    "critic": "infer.essay-critic",
    "maxIterations": 3,
    "acceptWhen": { "regex": "^APPROVED" }
  }
}
```

The critic returns a structured judgement; iteration stops when `acceptWhen` matches the critic's output, when `maxIterations` is hit, or when the producer's revision is byte-identical to the previous round (no-progress detector).

### 4. Router (orchestrator)

A meta-agent gets `invoke(agentID:, input:)` as a synthetic tool, picks one candidate per turn. Already forward-declared.

```json
{
  "kind": "agent",
  "orchestrator": {
    "router": "infer.dispatcher",
    "candidates": ["infer.code-helper", "infer.writing-helper", "infer.research-helper"]
  }
}
```

Most flexible — subsumes (1) and (2) at the cost of one extra LLM call to make the routing decision. Worth shipping *both* declarative chains and a router: declarative is deterministic and cheap, router is dynamic and expensive.

### 5. Fallback

`try A, if A fails-or-empties within budget → try B`.

```json
{
  "kind": "agent",
  "fallback": ["infer.precise-tool-user", "infer.general-chat"]
}
```

Smallest possible reliability primitive; doesn't need a router. Uses the `AgentOutcome` enum (see "Failure semantics" below) to decide whether to fall through.

### 6. Guard (deferred to v2)

`pre-guard → A → post-guard`. Pre-guard can reject the user message ("this looks like a prompt injection"); post-guard can redact the answer. By convention always a persona that returns a structured ok/reject signal. Keeps safety logic composable instead of baked into every persona's prompt. Deferred because the convention for "guard's structured output" needs a small standalone design pass.

## Things deliberately not included

- **Parallel fan-out / quorum / voting.** Locally infeasible: one model is loaded at a time. Two agents with different model preferences cannot run concurrently; same-model parallelism doesn't reduce wall-time because both contend for the same GPU. Revisit only if a runner ever exposes concurrent decode contexts (mlx-swift-lm doesn't).
- **Map-reduce over shards.** Same constraint, plus overlaps with what RAG already does for chunked input.
- **Hierarchical delegation beyond one level.** A router-of-routers works in principle but the debugging story is awful and the model has to learn a recursive tool grammar. One level (router → leaves) is the practical ceiling for local models.
- **Cross-turn agent state / memory.** Out of scope per `agents.md`.

## Cross-cutting rules

These have to be decided once for all primitives. They are the actually hard part.

### Handoff envelope

What does B receive when A finishes?

- (a) Just A's final text — simple, lossy. B can't see what tools A called.
- (b) A's `StepTrace` + final text — complete, but B's prompt context bloats fast in long pipelines.
- (c) A's final text + an optional structured handoff slot A can populate (`handoff: String?` returned alongside the final answer). Best of both; requires personas to opt in.

**Decision: (c)**, defaulting to A's final text when no handoff is set. Schema additions: a new optional sentinel in agent prompts (`<<HANDOFF>>...<</HANDOFF>>`) that the controller strips from the user-visible text and forwards as the structured handoff to the next agent. Personas that don't emit the sentinel behave as (a).

### Step budget accounting

Per-agent or shared?

- Per-agent is intuitive but composes badly: a chain of 5 agents at 10 steps each = 50 steps the user didn't authorize.
- Shared is honest but requires a controller-level accumulator and back-pressure decisions ("agent C only has 2 steps left — abort or continue with shrunken budget?").

**Decision: shared budget, declared at the top-level composition**, defaulting to `InferSettings.maxAgentSteps` (a setting that doesn't exist yet — to be added). Each child agent inherits remaining budget via `AgentContext`. When remaining < some threshold, the controller may either abort or continue with the shrunken budget; behaviour is configured per composition with `onBudgetLow: "abort" | "continue"` (default `continue`).

### Cancellation propagation

A user `requestStop` must propagate through the composition tree. The controller holds a per-composition `CancelFlag`; each child agent's `run` checks it between steps via `AgentContext`. Already feasible — `Agent.shouldContinue(after:context:)` can read it. The C decode loop's existing cancellation seam is unchanged.

### Model swaps mid-composition

If A requires Llama and B requires MLX, what happens?

- Reject at registry-validation time? Users will hate it because it forbids legitimate flows.
- Swap models on the fly? Each swap is ~5–30 s and blows the KV cache. Composition becomes painful.

**Decision: reject at validation time for v1.** All agents in a composition must share a compatible runner (`requirements.backend` reduces to a single concrete value across the composition, accounting for `.any`). Cross-runner composition is a v2 follow-up that requires a model-swap manager that doesn't exist yet.

### Failure semantics

When does an agent in a composition count as "failed"?

- Hard errors (tool throws, decode error): obvious failure.
- Soft signals: empty final answer, step budget hit, model template mismatch. Need explicit per-primitive policy — fallback treats "empty answer" as failure; refine doesn't.

**Decision: introduce `AgentOutcome` returned by every `Agent.run`:**

```swift
public enum AgentOutcome: Sendable {
    case completed(text: String, handoff: String?)
    case failed(reason: String)
    case aborted(reason: String)   // user-initiated stop
}
```

Composition primitives pattern-match on it. Specifically:
- Sequence: any non-`completed` outcome aborts the chain and surfaces the failure to the user.
- Conditional handoff: predicate evaluation happens only on `completed`; non-completed outcomes propagate.
- Refine: critic returning `failed` aborts; producer returning `failed` aborts.
- Fallback: `failed` triggers the next candidate; `aborted` propagates immediately (don't retry on user-initiated stop).
- Router: a candidate's `failed` is reported back to the router as a synthetic tool error, so the router can choose a different candidate or give up.

### Transcript attribution

Multi-agent turns produce multiple assistant segments. The transcript needs per-segment attribution (which agent produced this) so the user understands what they're reading. `StepTrace` already records steps with agent context; the missing piece is `MessageRow` rendering — a small "via X → Y → Z" gutter line above multi-agent assistant messages, with each name expandable to show that agent's `StepTrace`.

### Determinism

Router-based composition is non-deterministic by construction (the router's choice depends on sampler state). Declarative compositions (sequence, conditional, fallback) are deterministic given seeds. Worth labelling routed turns in the transcript ("routed via dispatcher") so users know — important for bug reports and reproduction.

## Schema additions (PromptAgent v3)

Bumps `schemaVersion` to `3`. v2 remains loadable for one release. New optional fields, all of which require `kind: "agent"`:

| Field | Type | Notes |
|---|---|---|
| `chain` | `[AgentID]` | already forward-declared in v2 |
| `branch` | `{ agent, if: Predicate, then: AgentID, else: AgentID }` | — |
| `refine` | `{ producer, critic, maxIterations, acceptWhen: Predicate }` | `maxIterations` required |
| `orchestrator` | `{ router, candidates: [AgentID] }` | already forward-declared in v2 |
| `fallback` | `[AgentID]` | order matters; first wins |
| `budget` | `{ maxSteps: Int, onBudgetLow: "abort" \| "continue" }` | optional; defaults to `InferSettings.maxAgentSteps` and `continue` |

`Predicate` is the JSON shape from "Conditional handoff" above (one of `regex`, `jsonShape`, `toolCalled`, `stepBudgetExceeded`, `noToolCalls`).

**Mutual exclusion:** at most one of `chain`, `branch`, `refine`, `orchestrator`, `fallback` may be set. Combining them is a future feature (composition of compositions); for v1, an agent JSON declares exactly one composition shape (or none — in which case it's a leaf agent that just uses its own tools).

## Validation rules

In addition to the v2 rules in `agent_kinds.md`:

1. Mutual exclusion of composition primitives (above).
2. All referenced `AgentID`s must resolve at registry-load time (after all files are read). Forward references are fine within the load batch.
3. No cycles: the graph formed by `chain`, `branch.then/else`, `refine.producer/critic`, `fallback` references must be acyclic. Router candidates are not part of the cycle check (the router is dynamic — a router whose candidates include itself would loop, but it's the router's responsibility to terminate, just like any tool-using agent).
4. Runner compatibility: the set `{requirements.backend for each agent in composition}` must reduce to a single concrete value when `.any` is treated as a wildcard.
5. `refine.maxIterations` ≥ 1; recommend ≤ 5; warn above.
6. `fallback` length ≥ 2 (a fallback of one is just the agent itself).

## Examples

### A drafting pipeline

```json
{
  "schemaVersion": 3,
  "kind": "agent",
  "id": "infer.compose.essay",
  "metadata": { "name": "Essay composer" },
  "requirements": { "backend": "llama", "templateFamily": "llama3" },
  "chain": ["infer.outline", "infer.draft", "infer.proofread"]
}
```

### A producer-critic loop

```json
{
  "schemaVersion": 3,
  "kind": "agent",
  "id": "infer.compose.refined-essay",
  "refine": {
    "producer": "infer.draft",
    "critic": "infer.essay-critic",
    "maxIterations": 3,
    "acceptWhen": { "regex": "^APPROVED" }
  }
}
```

### Tool-user with chat fallback

```json
{
  "schemaVersion": 3,
  "kind": "agent",
  "id": "infer.compose.helpful",
  "fallback": ["infer.tool-user", "infer.general-chat"]
}
```

## v1 scope (recommended)

If composition lands in one PR, ship: **sequence, conditional handoff, fallback, refine** — all sharing one budget, with handoff envelope (c), runner-compatibility validation, and `AgentOutcome`. Router and guard ship in v2 once the basic primitives have surfaced the cross-cutting decisions in real use.

Reasoning: router can be approximated by hand-written conditional handoffs while we learn what real workloads look like; guard needs a small extra design pass for the structured-output convention. Sequence and fallback are unambiguously useful from day one. Refine is the most-asked-for "agent" pattern in the wild and worth shipping early.

## Open questions

1. **Should `AgentOutcome.completed.handoff` be free text or structured (JSON)?** Free text is simplest; structured forces a per-agent output schema. Suggested answer: free text in v1, with the convention that personas/agents can emit JSON-in-text if they want, parsed by the consumer agent's prompt. Promote to structured when a real workflow proves the need.

2. **Should compositions themselves appear in the agent picker, or only their leaves?** A "compose-only" agent like `infer.compose.essay` is invokable as a top-level chat persona today — the user picks it and it runs the chain transparently. Argument for hiding leaves: declutter the picker. Argument for showing both: power users want to invoke pieces directly. Suggested answer: show all agents; a hidden boolean (`hidden: true`) lets compositions hide their internal-only leaves.

3. **Per-step UI feedback during composition.** Today the chat surface streams one assistant response. With a chain of agents, should the UI show "now running A…", "now running B…" as separate transient messages, or just the final answer with attribution after the fact? Suggested answer: stream each completed-segment with attribution as it lands; the user sees the chain unfold rather than waiting for the whole composition.

4. **Recovery from a failed leaf in a chain.** Currently sequence aborts on any non-completed outcome. Should chain support a `onFailure` per step (try once, then continue with the previous output)? Suggested answer: no for v1 — that's reinventing fallback inside chain. If you need it, wrap the step in a `fallback` and reference that.

5. **Do composition agents need their own `systemPrompt`?** A pure composition (just a `chain`) has no LLM call of its own. Today `PromptAgent` requires `systemPrompt` non-empty. Suggested answer: relax the requirement when a composition primitive is present; an empty `systemPrompt` plus `chain` is a valid "pure controller" agent.

## Implementation checklist

When this PR is picked up:

1. Add `AgentOutcome` enum (`AgentTypes.swift`) and refactor the existing single-turn `Agent.run` to return it.
2. Add the schema fields to `PromptAgent` decode path. Bump `currentSchemaVersion` to `3`.
3. Add validation rules 1–6. Tests in `InferAgentsTests` covering: cycle rejection, runner-compatibility rejection, mutex violation, predicate decoding.
4. Implement `CompositionController` in `InferAgents` that owns: shared budget, cancellation flag, the `run` loop for each primitive (sequence/branch/refine/fallback). Router uses the existing `ToolRegistry` with a synthetic `invoke` tool.
5. Wire `AgentController` to detect a composition agent and dispatch to `CompositionController`.
6. Extend `StepTrace` with per-segment attribution (which agent produced each step).
7. Update `MessageRow` / `ChatTranscript` to render multi-agent attribution.
8. Add `InferSettings.maxAgentSteps` if not present.
9. Cross-link from `agents.md` and `agent_kinds.md`.
