# Cohesive agent plan: reconciliation and implementation

Status: synthesis doc, 2026-04-25. This doc reconciles the five existing agent-related documents into a single coherent plan and lays out the implementation sequence:

- `agents.md` — original protocol + loop design (2026-04-23). Authoritative on protocol surface, loop semantics, and runner asymmetry.
- `plugins.md` — extensibility / MCP. Authoritative on tool source.
- `agent-ux-plan.md` — UI overhaul plan. Authoritative on UI sequencing.
- `agent_kinds.md` (2026-04-25) — introduces the persona / agent distinction as a *user-facing kind*. Schema v2.
- `agent_composition.md` (2026-04-25) — composition primitives (sequence, branch, refine, fallback, router). Schema v3.

The two new docs introduce semantics that conflict in places with the older docs. This doc is the reconciliation. Where there is a contradiction, this doc is authoritative going forward, and the corresponding existing doc is flagged for an edit (see "Doc maintenance" at the end).

## TL;DR

1. **Vocabulary.** `Agent` stays as the Swift protocol name. User-facing terminology splits into **persona** (context + role only) and **agent** (persona's surface + tools and/or composition). The protocol surface is unchanged; classification is metadata.

2. **Composition is in.** The "no DSL for agent composition" anti-goal in `agents.md` is revised. Declarative primitives (sequence, branch, refine, fallback, router) are in scope; arbitrary graph DSLs (LangGraph-style) remain out. Justification below.

3. **Sub-agents stay out, with a precise exception.** The router primitive is the only supported "agent invokes agent" path, and only via a declared candidate set — not arbitrary recursion. This is the tool-framed delegation that `agents.md` already permits as the escape hatch.

4. **`ToolAgent` is deprecated.** Under the persona/agent split, `PromptAgent` with `kind: "agent"` covers everything `ToolAgent` does today. `ToolAgent` is removed when schema v2 lands.

5. **Implementation slots into the existing PR sequence as PR 1.5 (kinds) and PR 5.5 (composition).** No re-ordering of `agents.md`'s existing PRs is required.

## 1. Vocabulary, settled

| Term | Meaning | Where it lives |
|---|---|---|
| `Agent` | The Swift protocol all conformances implement. Unchanged from `agents.md`. | `InferAgents/Agent.swift` |
| `AgentKind` | Enum: `.persona` \| `.agent`. New. | `InferAgents/AgentTypes.swift` (PR 1.5) |
| **persona** (user-facing) | A configuration with role + context, no tools, no code execution beyond decode, no composition. Kind = `.persona`. | JSON files under `Resources/personas/` and `~/Library/Application Support/Infer/personas/` |
| **agent** (user-facing) | Has the persona surface plus at least one of: tools, composition. Kind = `.agent`. | JSON files under `Resources/agents/` and `~/Library/Application Support/Infer/agents/` |
| Default | The synthetic baseline driven by live `InferSettings`. Treated as a persona for UX purposes. | `DefaultAgent` (synthetic, not a file) |

User-facing copy uses **persona** and **agent** consistently. When both are meant, write "personas and agents" or "agents and personas" — not the umbrella "agents." Internal/protocol-level discussion uses `Agent` (the type) without ambiguity because there is no other type with that name.

The relationship is **agent ⊇ persona**: every agent has the persona surface and adds capabilities. A persona is not "a kind of agent" in user-facing language; it is a sibling concept. (In code it conforms to the same protocol, but that's an implementation detail.)

## 2. Reconciling `agents.md`

### 2.1 Composition anti-goal — revised

**Old text** (`agents.md` Anti-goals):
> No DSL for agent composition. YAML pipelines, prompt graphs, LangChain-shaped chains — all out. An agent is one JSON file; a turn is one loop; if users want orchestration, they compose at the tool layer.

**Revised stance:**
> Declarative composition primitives — sequence, conditional branch, critic-refine, fallback, and router — are in scope. They are bounded, acyclic, runner-compatible, and operate within a single user turn under a shared step budget. They are not a new graph DSL: each primitive is a fixed JSON shape, not a free-form node-and-edge language. Turing-complete or open-ended graph DSLs (LangGraph, prompt-graphs, free-form node editors) remain out.

**Why the revision:**
- The original reasoning ("compose at the tool layer") works for one level but breaks down for the common patterns users already ask for (producer-critic loops, fallback, dispatcher routing). A user with no Swift access cannot "compose at the tool layer" — they can only edit JSON.
- The anti-goal was protecting against unbounded complexity. The composition primitives in `agent_composition.md` preserve that protection by being a **closed set** (five primitives, mutually exclusive per file, validated for cycles and runner compatibility) rather than a generative DSL.
- The "agent is one JSON file; a turn is one loop" framing survives intact: each composition is still one file, and the controller still drives the turn.

### 2.2 Sub-agents anti-goal — clarified

**Old text** (`agents.md` Anti-goals):
> No sub-agents. "Agent calls agent" is a rabbit hole of recursion budgets, prompt injection vectors, and cross-agent state. If genuinely needed, model it as a tool that the outer agent calls, not as a first-class nesting relation.

**Clarified stance:**
> Sub-agents remain out as a free-form recursion mechanism. The router primitive (`agent_composition.md`) is the supported tool-framed delegation: a meta-agent gets `invoke(agentID:, input:)` as a synthetic tool whose argument is a member of a *declared, validated candidate set*. This is consistent with the original anti-goal — "model it as a tool that the outer agent calls" — and avoids the rabbit hole because (a) the candidate set is closed at registry-load time, (b) no candidate may itself be the router (no direct cycles), (c) all candidates inherit the shared budget, (d) no cross-agent state crosses the boundary except the declared handoff envelope.

The other composition primitives (sequence, branch, refine, fallback) do not introduce nesting at all — the controller invokes each agent in turn at the same level, not one calling another.

### 2.3 `ToolAgent` — deprecated

`agents.md` lists `ToolAgent<Tools>` as "expected to be the typical way first-party agents are built." `agent_kinds.md` raised the question of whether `ToolAgent` still earns its keep once `PromptAgent` covers tool-using cases via `kind: "agent"`.

**Decision:** remove `ToolAgent` when schema v2 lands (PR 1.5). Reasoning:
- Every `ToolAgent` use-case is expressible as a `PromptAgent` with `kind: "agent"` and a `toolsAllow` list referencing globally registered tools.
- Tools are registered once in `BuiltinTools.swift` (or via plugins / MCP) and referenced by name from JSON. Inline tool declaration in Swift, the only thing `ToolAgent` uniquely enables, has no shipping consumer.
- If a future agent genuinely needs *dynamically computed* tools (depends on workspace state or runtime introspection), the answer is a custom `Agent` conformance — not `ToolAgent`. That conformance is on the order of 50 lines and only worth writing when the use case appears.

`ToolAgent.swift` is deleted; the file's own comment already notes it's a stub for protocol-shape exercise.

### 2.4 PR sequencing — slotted, not re-ordered

`agents.md` PR sequence is preserved. Two new PRs slot in:

| PR | Source | Scope |
|---|---|---|
| PR 1 | `agents.md` | Protocol, DefaultAgent, PromptAgent (v1), AgentRegistry, sidebar binding |
| **PR 1.5** | **`agent_kinds.md`** | **Schema v2: `AgentKind`, `contextPath` sidecar, directory split, `ToolAgent` removal, persona/agent UX grouping** |
| PR 2 | `agents.md` | ToolRegistry + 2 built-in tools + 1-step loop |
| PR 3 | `agents.md` | Qwen + Hermes template families |
| PR 4 | `agents.md` | MCP via PluginHost |
| PR 5 | `agents.md` | Multi-step loop |
| **PR 5.5** | **`agent_composition.md`** | **Schema v3: composition primitives. Sub-PRs in order: sequence + fallback (5.5a), refine + branch (5.5b), router (5.5c)** |
| PR 6 | `agents.md` | MLX tool-call (speculative) |
| PR 7 | `agents.md` | Persistent consent prefs |
| PR 8 | `agents.md` | Export with step trace |

PR 5.5 is split into three sub-PRs because the primitives have different complexity. Sequence + fallback is the smallest viable composition increment; refine + branch adds the predicate machinery; router adds dynamic candidate selection (largest blast radius).

## 3. Reconciling `agent-ux-plan.md`

The UX plan was written before the persona/agent split. Three concrete amendments:

### 3.1 Picker grouping by kind

`agent-ux-plan.md` Phase 1.1 (header agent picker) groups compatible / incompatible. With kinds, the menu structure becomes:

```
Personas
  Default
  Explainer
  Code reviewer
  Writing editor
  Brainstorm partner
Agents
  Clock assistant         [tools: 2]
  ─────
  Requires Llama 3.1 template
    (incompatible agents listed here, greyed)
```

Personas are listed first (most users want a role, not a tool-using flow), then agents with their tool-count chip, then incompatible items at the bottom with reason rows. Personas never appear under "incompatible" because they have no runner/template requirements — they work on any backend by construction.

### 3.2 Tool-count chip conditional on kind

`agent-ux-plan.md` Phase 1.3 specifies a `tools: N` chip in the header. For personas, `N = 0` always — show nothing instead, or show a small "persona" badge. The chip's purpose is to signal "this can run code"; on a persona, the absence of the chip is the affordance.

### 3.3 Inspector sections by kind

`agent-ux-plan.md` Phase 2.1 (agent inspector) defines six sections. Personas don't need the Tools section, the Compatibility/template-family row, or any Composition section. Inspector renders:

- **Persona view:** Header, System prompt, Context (if `contextPath`), Decoding overrides, Actions.
- **Agent view:** Header, System prompt, Context, **Tools**, **Composition** (if any), **Compatibility**, Decoding overrides, Actions.

Cleaner UX and signals the distinction visually without a separate inspector type.

### 3.4 Cross-cuts that don't change

- The streaming `AgentEvent` design (Phase 0.2) is unchanged. Personas emit a degenerate stream — `assistantChunk*` then `terminated(.finalAnswer)` — no tool events. Agents emit the full sequence.
- Diagnostics (Phase 0.3), preview-before-switch (Phase 2.2), composer chip (Phase 3.1), keyboard shortcuts (Phase 3.4) all apply to both kinds.

## 4. Reconciling `plugins.md`

`plugins.md` already states a plugin can ship "agents as code, agents as personas, MCP server, built-in tools, UI extensions." Two clarifications:

1. The "agents as personas" line uses the loose meaning of "agent." Under the new vocabulary, it becomes "personas (JSON, role + context only) and/or agents (JSON or Swift, with tools and/or composition)." A plugin manifest may declare any combination, and the loader uses the JSON `kind` field as authoritative regardless of where the file lives in the plugin.

2. **Plugin classification by content.** A plugin shipping only personas is a "persona pack" (no tool/code surface — safe by construction, no consent surface needed beyond the standard agent-switch confirmation). A plugin shipping any agents (or any tools) carries the standard plugin trust surface. The Plugins tab can show this classification.

No semantic change to the plugin trust model. Just sharper labels.

## 5. Implementation plan, end-to-end

This subsumes `agents.md` PR plan, `agent_kinds.md` implementation checklist, and `agent_composition.md` implementation checklist into one ordered list. Each PR is independently reviewable and shippable.

### PR 1 — Agent substrate (DONE per current `InferAgents/`)

Already in tree: `Agent` protocol, `DefaultAgent`, `PromptAgent` (schema v1), `ToolAgent` (stub, scheduled for deletion), `AgentRegistry`, `AgentController`, `StepTrace`, sidebar picker with per-conversation binding, agent attribution chip, four bundled personas + one bundled agent (clock-assistant — currently mis-classified as a persona file but functionally an agent).

### PR 1.5 — Persona / agent kinds (schema v2)

Implements `agent_kinds.md` end to end.

1. Add `AgentKind { case persona, agent }` to `AgentTypes.swift`. Add `kind` field to `PromptAgent`. Bump `currentSchemaVersion` to 2; v1 still loadable with auto-classification (kind = `.persona` if `toolsAllow` empty, else `.agent`).
2. Add `contextPath` field to `PromptAgent`. Loader concatenates sidecar markdown to `systemPrompt`. Reject path traversal.
3. Validation rules per `agent_kinds.md` §"Validation rules" (1–6).
4. Create `Resources/personas/` directory. Move `explainer.json`, `code-reviewer.json`, `writing-editor.json`, `brainstorm-partner.json` there. Add `"schemaVersion": 2, "kind": "persona"` to each. Update `Package.swift` resources list.
5. Update `clock-assistant.json` (still under `Resources/agents/`) with `"schemaVersion": 2, "kind": "agent"`.
6. Update `~/Library/Application Support/Infer/` loader to scan both `personas/` and `agents/` subdirectories. Existing files in the old `agents/` directory continue to load with auto-classification + a warning.
7. Override `PromptAgent.toolsAvailable(for:)` to return `[]` unconditionally when `kind == .persona`. Belt-and-braces: even a malicious or buggy plugin that registers a tool whose name matches a persona's prompt cannot get it invoked.
8. Delete `ToolAgent.swift`. No production references.
9. UX changes per §3 above: picker grouping, conditional tool-count chip, inspector sections by kind.
10. Tests: kind round-trip, contradiction rejection (`persona` + `toolsAllow`), v1 auto-classification, sidecar load + path-traversal rejection, runtime tool-empty enforcement on persona.

Cross-link `agents.md` and `agent_kinds.md` to this doc. Add cross-link to `agent-ux-plan.md` (header + 1.1 + 1.3 + 2.1 sections).

### PRs 2–5 — Tool loop (per `agents.md`)

No changes from `agents.md`. With kinds in place, these PRs touch only agents (not personas), which makes the test surface smaller.

### PR 5.5a — Composition: sequence + fallback (schema v3, part 1)

1. Add `AgentOutcome` enum returned by `Agent.run`. Refactor existing single-turn loop in `AgentController` to return it.
2. Add `chain: [AgentID]` and `fallback: [AgentID]` schema fields. Bump `currentSchemaVersion` to 3.
3. Implement `CompositionController` covering sequence and fallback. Shared budget via top-level `budget: { maxSteps, onBudgetLow }`. Cancellation propagation through `AgentContext`.
4. Add `InferSettings.maxAgentSteps` if not present.
5. Validation: cycle detection, runner-compatibility (single concrete value across composition), mutex enforcement (`chain` xor `fallback`).
6. Handoff envelope (variant c from `agent_composition.md`): `<<HANDOFF>>...<</HANDOFF>>` sentinel stripped from user-visible text, forwarded as structured handoff.
7. Extend `StepTrace` with per-segment attribution.
8. Update `MessageRow` / `ChatTranscript` to render multi-agent attribution.
9. Tests: chain success, chain mid-failure, fallback first-success, fallback all-fail, budget exhaustion, cancellation mid-composition.

### PR 5.5b — Composition: refine + branch (schema v3, part 2)

1. Add `branch` and `refine` schema fields.
2. Implement `Predicate` decoding and evaluation: `regex`, `jsonShape`, `toolCalled`, `stepBudgetExceeded`, `noToolCalls`.
3. Refine no-progress detector (byte-identical revision termination).
4. Validation: `refine.maxIterations >= 1`, structural predicate validation.
5. Tests: branch true/false paths, refine accept-on-iteration-2, refine max-iterations cap, refine no-progress termination.

### PR 5.5c — Composition: router (schema v3, part 3)

1. Add `orchestrator: { router, candidates }` schema field.
2. Implement synthetic `invoke(agentID:, input:)` tool injected into router's tool catalog. Router invocation goes through the existing `ToolRegistry` path so consent and tracing work without special-casing.
3. Validation: router `kind == .agent`, candidates resolve, no router-self-membership, no inter-router cycles.
4. Tests: router picks candidate A vs B, router fails-out when candidate fails, router consent flow.
5. Update `MessageRow` to label routed turns ("routed via dispatcher").

### PRs 6–8 — Per `agents.md`

Unchanged.

## 6. Decisions still open

These are flagged here so they're not lost in individual docs. None block PR 1.5; only PR 5.5 is gated.

1. **Composition structured handoff.** `agent_composition.md` open question 1: free text in v1 with sentinel-marked handoff slot. Confirm before PR 5.5a.
2. **Hidden composition leaves.** Should `infer.compose.essay`'s internal leaves appear in the picker? `agent_kinds.md` open question + `agent_composition.md` open question 2 both touch this. Suggested: add `hidden: true` flag on `AgentMetadata`, consumed by the picker.
3. **Per-step UI feedback during composition.** Stream segments live with attribution, or show only the final answer? Suggested: stream live (matches existing assistant-message streaming UX).
4. **Composition agent's own `systemPrompt`.** Required or optional when a composition primitive is present? Suggested: relax to optional.

## 7. Doc maintenance (concrete edits required)

When PR 1.5 lands:

- `agents.md` — Anti-goals section: replace "No DSL for agent composition" with the revised stance from §2.1 above. Replace "No sub-agents" with the clarified stance from §2.2. Built-in implementations subsection: remove `ToolAgent`. Concrete first PR: add cross-link to this doc and `agent_kinds.md`.
- `agent_kinds.md` — Open question 1 (`ToolAgent` removal) is resolved (delete). Update to reflect.
- `agent-ux-plan.md` — Phase 1.1, 1.3, 2.1: add "see `agent_plan.md` §3" cross-link and the kind-aware adjustments described there.
- `plugins.md` — "agents as personas" line: rewrite per §4 above.

When PR 5.5a lands:

- `agents.md` — PR sequence section: link out to PR 5.5a-c.
- `agent_composition.md` — Open questions section: mark resolved items.

## 8. What this doc does not change

- The `Agent` protocol surface in `Agent.swift`. `kind` is metadata on `PromptAgent`, not a protocol requirement. `DefaultAgent` is implicitly a persona; if a `kind: AgentKind { get }` requirement is ever added, default extensions can derive it.
- Runner asymmetry. MLX still gets agents only when its runner grows a tool-call seam (PR 6 in `agents.md`). Personas, by contrast, work on MLX from PR 1.5 since they need no tool-call hook.
- The "transcript is the memory" principle. Composition operates within a turn; no cross-turn state is introduced.
- Anti-goals not specifically addressed above (no autonomous background agents, no agent-authored model downloads, no mocking tool results) — all preserved.
