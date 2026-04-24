# Agent kinds: persona vs agent

Status: proposal, unimplemented as of 2026-04-25. Companion to `agents.md` (the protocol + loop design) and `plugins.md` (tools + MCP). This doc specifies the **user-facing classification** between *personas* and *agents*, the schema changes to encode it, and the validation rules that keep the distinction honest.

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

Reserved field names; loader rejects them on `kind: "persona"`:

- `chain: [AgentID]` — sequential pipeline. Each agent's final answer becomes the next agent's user message. Step budget applies per agent. Cycles rejected at registry validation time.
- `orchestrator: { router: AgentID, candidates: [AgentID] }` — a router agent (itself an `agent`) selects one of `candidates` per turn via a synthetic `invoke(agentID:, input:)` tool injected into its tool catalog.

Both are *forward-declared* in the schema so the JSON shape is stable; the runtime semantics ship in a follow-up (see "Out of scope" below). Loader validates structure (referenced ids exist, no cycles) but the controller treats them as no-ops until composition is implemented.

## Validation rules (loader)

In priority order, evaluated at `PromptAgent` decode:

1. `schemaVersion` ∈ supported set, else `AgentError.unsupportedSchemaVersion`.
2. `kind` present (or auto-derived for v1).
3. `kind: "persona"` ⇒ `toolsAllow` is empty or absent, no `chain`, no `orchestrator`. Else `invalidPersona("persona must not declare tools or composition")`.
4. `kind: "agent"` ⇒ at least one of `toolsAllow`, `chain`, `orchestrator` is present. Empty agent loads with a warning, not an error (allows iterative authoring).
5. `contextPath` (if present) resolves to a readable file under the same directory tree as the JSON. Path traversal (`..`) rejected.
6. Composition references (`chain[*]`, `orchestrator.router`, `orchestrator.candidates[*]`) — structural validation only at decode (non-empty strings); existence checks happen at registry-time once all agents are loaded, since order of file load is undefined.

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
- Composition runtime — `chain` and `orchestrator` are forward-declared in the schema only; the controller treats them as no-ops. Implementing real chaining/orchestration is a follow-up doc (`docs/dev/agent_composition.md`, not yet written).
- `ToolAgent` itself — its existence becomes more questionable once `PromptAgent` covers tool-using cases via `kind: "agent"`. Decision deferred; see "Open question" below.

## Out of scope (deferred)

- **Composition runtime.** `chain` execution, orchestrator routing, handoff envelopes, per-step budget accounting across agents. Schema is forward-declared so files authored against this PR remain valid when composition lands.
- **Persona inheritance.** A persona that extends another persona (`extends: <id>`, prompt concatenation). Discussed and rejected for now — keeps the schema flat. Revisit if persona libraries grow past ~20 entries.
- **Per-persona model pinning.** `requirements.modelHint` (HF id or local path) so a persona can request "load this model when activated." Useful but orthogonal; tracked separately.
- **Tool consent UX changes.** `autoApprove` semantics already exist in `requirements`; no changes here.

## Open questions

1. **Should `ToolAgent` be deleted?** Under this proposal, every shipping agent can be a `PromptAgent` with `kind: "agent"`. `ToolAgent` only uniquely enables *inline Swift declaration of `[ToolSpec]`*, which is also achievable by registering tools globally and listing them in JSON. Argument for keeping: agents whose tool list is *computed* (e.g. depends on workspace state) need code. Argument for removing: YAGNI until such an agent exists.

2. **Do personas need an explicit "no tools, ever" guarantee at the runtime layer**, or is the loader-time rejection enough? A malicious or buggy plugin could register a tool that a persona's prompt then asks the model to invoke by name. Loader rejection prevents the persona from declaring the tool; runtime gating in `Agent.toolsAvailable(for:)` would prevent invocation even if the model emits the call. Suggested answer: yes — `PromptAgent.toolsAvailable` returns `[]` unconditionally when `kind == .persona`, regardless of `toolsAllow`. Belt and braces.

3. **Sidecar format beyond markdown?** Could imagine `.txt` (plain), `.json` (structured), or templated markdown (Mustache-style variable substitution). Suggested answer: markdown only for v2; revisit if a use case appears.

## Implementation checklist

When this PR is picked up, the work is:

1. Add `AgentKind` enum (`AgentTypes.swift`) and `kind` field on `PromptAgent`. Bump `currentSchemaVersion` to `2`, keep `1` in `supportedSchemaVersions`.
2. Add `contextPath` field + sidecar loader in `PromptAgent.init(from:)`. Reject path traversal.
3. Add validation rules 1–6 above. Tests in `InferAgentsTests`.
4. Forward-declare `chain` and `orchestrator` schema fields. Structural validation only.
5. Move four persona JSONs from `Resources/agents/` to `Resources/personas/`. Update `AgentController` bootstrap to load both directories. Update `Package.swift` resources list.
6. Edit four persona JSONs + clock-assistant JSON to add `schemaVersion: 2` and `kind`.
7. Group by kind in `AgentsLibrarySection`. Add badge/affordance for agents.
8. Override `PromptAgent.toolsAvailable` to enforce empty tool set when `kind == .persona` (open question 2 — recommend yes).
9. Update `docs/dev/agents.md` to reference this doc and the new vocabulary.
