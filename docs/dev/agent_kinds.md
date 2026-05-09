# Agent kinds: persona vs agent

Status: shipped (schema v2 + v3, runtime, picker, validation), 2026-05-09. Originally drafted as a v2-schema proposal on 2026-04-25; the v3 follow-up added composition primitives (`chain`, `fallback`, `branch`, `refine`, `orchestrator`, `delegate`) — see `agent_composition.md` for the primitive inventory and `agent_delegate.md` for the multi-hop delegation primitive that powers the synthetic Auto picker entry. Companion to `agents.md` (the protocol + loop design) and `plugins.md` (tools + MCP). This doc specifies the **user-facing classification** between *personas* and *agents*, the schema changes to encode it, and the validation rules that keep the distinction honest.

## Why split the term

Today's substrate (`InferAgents/`) calls everything an `Agent`. Three concrete types conform: `DefaultAgent` (synthetic), `PromptAgent` (JSON-backed), `ToolAgent` (Swift-defined, currently unused). The carrier type does not determine capability — `clock-assistant.json` is a `PromptAgent` that uses tools by listing `builtin.clock.now` in `requirements.toolsAllow`, and the registered Swift implementation in `BuiltinTools.swift` runs on each invocation.

That conflation is fine for the implementer but confusing for the user. The user-facing question they actually ask is **"will this thing run code on my behalf?"** — and the answer should be obvious from the picker, not derivable only by reading JSON.

## Definitions

**Persona.** A named role + context configuration. Strictly:
- Has a `systemPrompt` (role / instructions).
- May attach an extended context document (markdown sidecar — see "Markdown sidecar" below).
- May override decoding params.
- **Does not declare tools.** Does not execute code beyond template rendering and decode.
- Cannot be chained, sequenced, or orchestrated.

**Agent.** A superset of persona. Adds:
- Tool use (`requirements.toolsAllow`, optional `toolsDeny`, `autoApprove`).
- Composability: an agent can be invoked by another agent (orchestration), placed in a sequence, or chained with conditional handoff.
- Loop hooks (already in `Agent.swift`: `toolsAvailable`, `transformToolResult`, `shouldContinue`, optional `run` override).

The relationship is **agent ⊇ persona**. Every persona is a degenerate agent (zero tools, single step). The split exists because the user-facing affordance is different: personas are safe-by-construction (no side effects), agents are not.

## Schema changes (PromptAgent / persona JSON)

Bump `schemaVersion` to `2`. Keep `1` loadable for one release.

### New required field: `kind`

```json
{
  "schemaVersion": 2,
  "kind": "persona",  // or "agent"
  ...
}
```

`kind` is **authored, not derived**. A file declaring `kind: "persona"` with a non-empty `toolsAllow` is a contradiction and must fail to load with `AgentError.invalidPersona("persona declares tools — use kind: \"agent\"")`. Symmetrically, `kind: "agent"` with empty `toolsAllow` and no composition fields loads but emits a warning ("agent has no tools or composition; consider kind: \"persona\"").

Default when reading a `schemaVersion: 1` file: `kind = "persona"` if `toolsAllow` is empty or absent, `kind = "agent"` otherwise. This auto-classifies the existing five bundled files correctly (clock-assistant → agent, others → persona) without requiring a hand-edit.

### New optional field: `contextPath` (persona + agent)

Long-form context belongs in markdown, not in an escaped JSON string. Add:

```json
{
  "kind": "persona",
  "systemPrompt": "You are a senior code reviewer.",
  "contextPath": "code-reviewer.md"
}
```

`contextPath` is resolved relative to the JSON file's directory. At decode time, `PromptAgent` reads the file and concatenates: final system prompt = `systemPrompt + "\n\n" + contents(contextPath)`. Missing file → `AgentError.invalidPersona("contextPath not found: \(path)")`. The sidecar is optional; `systemPrompt` alone remains valid.

Convention: `Resources/personas/<id>.json` + optional `Resources/personas/<id>.md` (see directory split below).

### New optional fields: composition (agent only)

Loader rejects them on `kind: "persona"`. Originally only `chain` and `orchestrator` were forward-declared in v2; the full set below ships under schema v3 with full runtime semantics in `CompositionController`. See `agent_composition.md` for the per-primitive design and `agent_delegate.md` for `delegate`.

- `chain: [AgentID]` — sequential pipeline. Each agent's final answer becomes the next agent's user message. Step budget applies per agent. Cycles rejected at registry validation time.
- `fallback: [AgentID]` — try in order; first that doesn't `.failed` wins.
- `branch: { probe?, predicate, then, else }` — declarative conditional dispatch.
- `refine: { producer, critic, maxIterations, acceptWhen }` — bounded producer–critic loop.
- `orchestrator: { router: AgentID, candidates: [AgentID] }` — a router agent (itself an `agent`) selects one of `candidates` per turn via a synthetic `agents.invoke` tool. One-shot (single dispatch).
- `delegate: { router, candidates, maxHops }` — multi-hop variant of orchestrator: the router runs in a loop, each candidate's output feeds back as a synthetic tool result on the router's next turn, terminates on no-dispatch / `maxHops` / loop detection / budget.

At most one composition field may be set per agent (mutual exclusion enforced at decode). Cross-agent reference checks (existence, cycles where applicable) run at registry-load time.

## Validation rules (loader)

In priority order, evaluated at `PromptAgent` decode:

1. `schemaVersion` ∈ supported set, else `AgentError.unsupportedSchemaVersion`.
2. `kind` present (or auto-derived for v1).
3. `kind: "persona"` ⇒ `toolsAllow` is empty or absent, no composition fields (`chain`, `fallback`, `branch`, `refine`, `orchestrator`, `delegate`, `budget`). Else `invalidPersona("persona must not declare tools or composition")`.
4. `kind: "agent"` ⇒ at least one of `toolsAllow` or any composition field is present. Empty agent loads with a warning, not an error (allows iterative authoring).
5. `contextPath` (if present) resolves to a readable file under the same directory tree as the JSON. Path traversal (`..`) rejected.
6. Composition references (`chain[*]`, `fallback[*]`, `branch.{probe,then,else}`, `refine.{producer,critic}`, `orchestrator.{router,candidates[*]}`, `delegate.{router,candidates[*]}`) — structural validation at decode (non-empty strings, `maxHops > 0`, `maxIterations > 0`, router-not-in-candidates for orchestrator/delegate); existence checks + cycle detection happen at registry-time once all agents are loaded, since order of file load is undefined.

## Directory split

Today: `Resources/agents/*.json` (mixed personas + the one agent).

Proposed:

```
Resources/
  personas/
    explainer.json
    explainer.md            # optional sidecar
    code-reviewer.json
    writing-editor.json
    brainstorm-partner.json
  agents/
    clock-assistant.json
```

The `AgentController` bootstrap (`AgentController.swift`) loads from both directories. User-authored content under `~/Library/Application Support/Infer/` mirrors the same split:

```
Application Support/Infer/
  personas/
  agents/
```

Files in the wrong directory load with a warning ("file declares kind: agent but lives under personas/") but are not rejected — directory is a hint, `kind` is authoritative.

## Picker / sidebar grouping

`AgentsLibrarySection` (`Sidebar/AgentsLibrarySection.swift`) groups by `kind`:

```
Personas
  Explainer
  Code reviewer
  Writing editor
  Brainstorm partner
Agents
  Clock assistant
```

Visual cue: agents get a small "wrench" badge or similar to signal "this can run code." Personas get nothing (the absence is the affordance).

## Reclassification of bundled files

Concrete migration on land:

| File | Current location | New location | `kind` | `contextPath`? |
|---|---|---|---|---|
| `explainer.json` | `Resources/agents/` | `Resources/personas/` | `persona` | optional, not added in this PR |
| `code-reviewer.json` | `Resources/agents/` | `Resources/personas/` | `persona` | optional |
| `writing-editor.json` | `Resources/agents/` | `Resources/personas/` | `persona` | optional |
| `brainstorm-partner.json` | `Resources/agents/` | `Resources/personas/` | `persona` | optional |
| `clock-assistant.json` | `Resources/agents/` | `Resources/agents/` (unchanged) | `agent` | n/a |

Each persona file gains `"schemaVersion": 2, "kind": "persona"`. The clock-assistant file gains `"kind": "agent"`. No content changes beyond those two fields.

## What this PR does not change

- `Agent` protocol surface in `Agent.swift` — unchanged. `kind` is metadata on `PromptAgent` / its JSON, not a protocol requirement. `DefaultAgent` is implicitly a persona; `ToolAgent` is implicitly an agent. If a `kind: AgentKind { get }` requirement is added later, default extensions can derive it from existing properties.
- `ToolRegistry` / `BuiltinTools` — unchanged. Tools remain registered globally and referenced by name from `toolsAllow`.
- ~~Composition runtime — `chain` and `orchestrator` are forward-declared in the schema only; the controller treats them as no-ops.~~ **Shipped under v3.** All six primitives (`chain`, `fallback`, `branch`, `refine`, `orchestrator`, `delegate`) execute via `CompositionController`. See `agent_composition.md`.
- `ToolAgent` itself — its existence becomes more questionable once `PromptAgent` covers tool-using cases via `kind: "agent"`. Decision deferred; see "Open question" below.

## Out of scope (deferred)

- ~~**Composition runtime.** `chain` execution, orchestrator routing, handoff envelopes, per-step budget accounting across agents.~~ **Shipped under v3 (M5a–M5c).** See `agent_composition.md` and `agent_delegate.md`.
- **Persona inheritance.** A persona that extends another persona (`extends: <id>`, prompt concatenation). Discussed and rejected for now — keeps the schema flat. Revisit if persona libraries grow past ~20 entries.
- **Per-persona model pinning.** `requirements.modelHint` (HF id or local path) so a persona can request "load this model when activated." Useful but orthogonal; tracked separately.
- **Tool consent UX changes.** `autoApprove` semantics already exist in `requirements`; no changes here.

## Open questions

1. **Should `ToolAgent` be deleted?** Under this proposal, every shipping agent can be a `PromptAgent` with `kind: "agent"`. `ToolAgent` only uniquely enables *inline Swift declaration of `[ToolSpec]`*, which is also achievable by registering tools globally and listing them in JSON. Argument for keeping: agents whose tool list is *computed* (e.g. depends on workspace state) need code. Argument for removing: YAGNI until such an agent exists.

2. **Do personas need an explicit "no tools, ever" guarantee at the runtime layer**, or is the loader-time rejection enough? A malicious or buggy plugin could register a tool that a persona's prompt then asks the model to invoke by name. Loader rejection prevents the persona from declaring the tool; runtime gating in `Agent.toolsAvailable(for:)` would prevent invocation even if the model emits the call. Suggested answer: yes — `PromptAgent.toolsAvailable` returns `[]` unconditionally when `kind == .persona`, regardless of `toolsAllow`. Belt and braces.

3. **Sidecar format beyond markdown?** Could imagine `.txt` (plain), `.json` (structured), or templated markdown (Mustache-style variable substitution). Suggested answer: markdown only for v2; revisit if a use case appears.

## Implementation checklist

All shipped under schema v2 (kind, contextPath, sidecar) and v3 (full composition primitives). Original v2 plan retained below as historical record:

1. ✅ Add `AgentKind` enum (`AgentTypes.swift`) and `kind` field on `PromptAgent`. Bump `currentSchemaVersion` to `2`, keep `1` in `supportedSchemaVersions`. *(v3 since.)*
2. ✅ Add `contextPath` field + sidecar loader in `PromptAgent.init(from:)`. Reject path traversal.
3. ✅ Add validation rules 1–6 above. Tests in `InferAgentsTests`.
4. ✅ Forward-declare `chain` and `orchestrator` schema fields. Structural validation only. *(v3 expanded to all six primitives with full runtime in `CompositionController`.)*
5. ✅ Move four persona JSONs from `Resources/agents/` to `Resources/personas/`. Update `AgentController` bootstrap to load both directories. Update `Package.swift` resources list.
6. ✅ Edit four persona JSONs + clock-assistant JSON to add `schemaVersion: 2` and `kind`.
7. ✅ Group by kind in `AgentsLibrarySection`. Add badge/affordance for agents.
8. ✅ Override `PromptAgent.toolsAvailable` to enforce empty tool set when `kind == .persona` (open question 2 — yes, shipped).
9. ✅ Update `docs/dev/agents.md` to reference this doc and the new vocabulary.
