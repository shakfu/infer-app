# Agent implementation plan

Gap analysis and prioritised build-out for the agent feature, derived from
the design docs in this directory cross-referenced against the current state
of the codebase. Scope: the five `agent*.md` docs plus `workspaces.md`.
`plugins.md` is explicitly out of scope for this pass. Embedded Python is
out of scope (a separate POC, now closed).

Authored: 2026-04-25. Last updated: 2026-04-26 (M1–M5c shipped).

## Status snapshot (2026-04-26)

- **M1** schema v2 (kinds + contextPath + directory split + ToolAgent deletion) — shipped.
- **M2** `AgentEvent` async stream + diagnostic severity — shipped.
- **M3** picker polish (kind grouping, ⌘⌥1..9, autoExpandAgentTraces, streaming auto-expand) — shipped. Composer chip added then reverted; header is the single picker surface.
- **M4** multi-template families (`.qwen` / `.hermes` parsers, GGUF fingerprint, per-family `composeSystemPrompt`, fail-loud picker) + per-family tool-result role on `LlamaRunner.appendToolResultAndContinue` — shipped.
- **M5a-foundation** `AgentOutcome`, schema v3 (`fallback`, `budget`, `branch`, `refine`), `HandoffEnvelope`, `StepTrace.SegmentSpan`, `AgentRegistry.validateCompositionReferences()` — shipped.
- **M5a-runtime Phase A** `CompositionController` driver + `.single` dispatch wired through `ChatViewModel.send` via `runOneAgentTurn` — shipped.
- **M5a-runtime gutter renderer** — shipped.
- **M5a-runtime Phase B** live multi-segment dispatch (per-segment messages, agent-switching mid-turn via `AgentController.activateForSegment`, per-segment vault writes, lifecycle once per user turn) + demo `draft-then-edit` chain agent — shipped.
- **M5b** `Predicate` type, `branch` + `refine` schema fields and drivers — shipped.
- **M5c** orchestrator router (`.orchestrator` plan case, `OrchestratorDispatch` parser handling tool-call traces and inline `<tool_call>` / `<|python_tag|>` syntax, `AgentsInvokeTool` registered in `ToolRegistry`, demo `code-or-prose` orchestrator agent) — shipped end-to-end. Router emits `agents.invoke` → runtime tool loop intercepts it like any other tool → trace records a real `Step.toolCall(agents.invoke)` → `OrchestratorDispatch.parse` extracts target+input → driver dispatches to the candidate.

Test suite: 283 tests, 0 failures.

## Open follow-ups (not gated on the milestones above)

- Conversation reload from vault may need verification with Phase B's per-segment assistant rows (multi-segment turns now persist as N rows; renderer should pick them up but worth a manual check).
- Workspaces (`workspaces.md`) — partial scaffolding (`WorkspacePickerMenu.swift`) only; substrate work is independent of the agent track and not yet started.
- `plugins.md` — out of scope for this round.

## What each doc specifies

- **`agents.md`** — Foundation. Defines the `Agent` Swift protocol with
  seven hooks, an `AgentSession` actor that owns the per-turn loop, an
  `AgentRegistry` with user > plugin > firstParty precedence, three
  built-in conformances (`DefaultAgent`, `PromptAgent`, `ToolAgent`),
  `ToolRegistry`/`BuiltinTool`, `StepTrace` as the canonical per-turn
  record, multi-step ReAct loop with cooperative cancellation in four
  states, fingerprint-based template-family detection that fails loud,
  transcript schema (`ChatMessage.steps`, divider rows on switch), and
  a UI split between sidebar selection-for-use and an Agents library tab.
- **`agent_plan.md`** — Reconciliation. Splits user-facing vocabulary into
  **persona** (role + context, no tools) and **agent** (persona + tools or
  composition); the `Agent` protocol name is unchanged. Reverses the
  earlier "no DSL for composition" anti-goal; composition primitives are
  now in scope as a closed set. Sub-agents stay out except via a router
  primitive over a declared candidate set. **Marks `ToolAgent` for
  deletion.**
- **`agent_kinds.md`** — Schema v2. New required `kind: persona | agent`
  field, optional `contextPath` markdown sidecar, validation rules
  (kind/tools contradiction, path-traversal rejection), directory split
  (`Resources/personas/` vs `Resources/agents/` plus mirrored user dirs),
  kind-grouped picker, runtime guarantee that `kind: persona` returns an
  empty `toolsAvailable` regardless of declared `toolsAllow`.
- **`agent_composition.md`** — Schema v3. Five composition primitives
  (`chain`, `branch`, `refine`, `orchestrator`, `fallback`) with a
  declarative `Predicate` set for branching. Cross-cutting: shared budget
  with `onBudgetLow`, handoff envelope via `<<HANDOFF>>` sentinel,
  `AgentOutcome` enum returned by `Agent.run`, runner-compatibility
  validation rejected at load time, multi-agent transcript attribution.
- **`agent-ux-plan.md`** — Phased UI plan. Phase 0: `displayLabel` on
  `AgentListing`, `AgentEvent` async stream from `AgentController`,
  bootstrap diagnostics. Phase 1 (P0): header agent picker with tool-count
  chip and "Manage…" jump, streaming tool-loop visualisation with
  auto-expand/collapse. Phase 2 (P1): inspector with six sections,
  preview-before-switch diff, direct-row-click activation, diagnostics
  surface. Phase 3 (P2): composer chip, transcript hover-detail,
  `⌘⇧A`/`⌘⇧I`/`⌘⌥1..9`, agent-aware composer hints.
- **`workspaces.md`** — Reframes "project folder" as composable workspace.
  Artifacts carry typed facets; workspaces are saved views (filters +
  pinned agents + default model). Path B (typed facets first, multi-window
  later) recommended. Open questions on terminology and persistence
  granularity.

## What is already built

Verified directly against the code, not inferred from doc presence.

### Built

- **Substrate.** `Agent` protocol with all seven hooks
  (`InferAgents/Agent.swift`). `AgentContext`, `AgentRequirements`,
  `AgentMetadata`, `LoopDecision`, `RunnerHandle`, `ToolSpec/Call/Result`,
  `ToolCatalog` (`AgentTypes.swift`, `AgentContext.swift`).
- **Built-in conformances.** `DefaultAgent`, `PromptAgent`, **and
  `ToolAgent`** (the latter still present despite being slated for deletion
  in `agent_plan.md` §2.3).
- **Registry and controller.** `AgentRegistry` actor with
  precedence-honouring `register`, JSON loader, `PersonaLoadError`
  diagnostics. `@MainActor AgentController` with `availableAgents`,
  `activeAgentId`, `activeDecodingParams`, `activeToolSpecs`,
  `libraryDiagnostics`, `bootstrap`, `switchAgent`.
- **Tools and parser (single-family, single-step).** `BuiltinTool` /
  `ToolRegistry`, `ClockNowTool`, `WordCountTool`, `ToolCallParser`. Parser
  knows only `.llama3` (`ToolCallParser.swift:15`).
- **Tool loop.** Single-step in `Infer/ChatViewModel/Generation.swift`
  (`maybeRunToolLoop`); three-stage direct stamping into `messages[i].steps`.
- **StepTrace persistence + transcript schema.** `StepTrace` and step
  cases. `ChatMessage.steps`, `agentName`, `agentLabel`, `.agentDivider`
  kind. Trace renderer with auto-expand on streaming.
- **Per-conversation agent binding.** `Conversation.agentId: AgentID?`
  exists at `Infer/ChatModels.swift:29` — the persisted binding the
  original `agents.md` PR-1 spec called for is in place.
- **UI surface — most of the structural pieces.**
  - **Header agent picker** (`Infer/ChatView/AgentPickerMenu.swift`,
    integrated in `ChatHeader.swift`) with "Manage agents…" footer.
  - Sidebar Agents library (`Sidebar/AgentsLibrarySection.swift`) with
    search, diagnostics banner, library groups by source, click-to-activate,
    full row menu, confirmation alert.
  - Inspector with all six sections and preview-before-switch
    (`Sidebar/AgentInspectorView.swift`).
  - Toast affordance and command menu (`⌘⇧A` Focus Agent Picker, `⌘⇧I`
    Inspect Active Agent) at `InferApp.swift:50-66`.
- **Workspaces UI surface, partial.** `WorkspacePickerMenu.swift` exists
  in `ChatView/`; substrate beneath it not audited in this pass.
- **Tests.** `InferAgentsTests/` covers `AgentController`, `AgentListing`,
  `AgentProtocol`, `AgentRegistry`, `BuiltinTools`, `DefaultAgent`,
  `PromptAgent`, `StepTrace`, `ToolCallParser`, `ToolRegistry`.

### Missing

- **`AgentEvent` async stream.** No `AgentEvent` type, no
  `AsyncStream<AgentEvent>` on `AgentController`. The seam UX plan Phase
  0.2 names a prerequisite is absent. `Generation.maybeRunToolLoop`
  mutates `messages[i].steps` directly in three stages.
- **Schema v2 (`agent_kinds.md`).** `AgentKind` enum not in `AgentTypes.swift`.
  `kind` and `contextPath` fields not parsed in `PromptAgent`.
  `currentSchemaVersion` is still v1. No runtime persona-tool-emptiness
  enforcement. Resource directory not split — all five JSONs still under
  `Resources/agents/`, no `Resources/personas/`. Library is grouped by
  source ("Built-in" / "First-party personas" / "User"), not by kind.
- **Schema v3 (`agent_composition.md`).** No `AgentOutcome`, no
  composition primitive fields, no `Predicate` decoding, no
  `CompositionController`, no cycle / runner-compatibility validation, no
  `<<HANDOFF>>` envelope handling, no per-segment `agentId` on
  `StepTrace.Step`, no multi-agent gutter rendering.
- **Multi-template families.** `TemplateFamily` enum lists `llama3, qwen,
  hermes, openai`, but `ToolCallParser.Family` only has `.llama3`.
  Template-family fingerprinting against the loaded GGUF is absent;
  compatibility check considers backend only. No "fail loud" picker
  behaviour for template mismatch.
- **Multi-step loop and richer cancellation.** Only single-step today.
  Between-step / in-tool / awaiting-consent cancellation states are
  absent because the multi-step loop and consent prompt don't exist.
- **Consent UI.** No consent modal anywhere. `autoApprove` on
  `AgentRequirements` is never read.
- **Picker polish from UX plan Phase 1 / Phase 3.** Tool-count chip on
  picker trigger; streaming auto-expand/collapse on `StepTraceDisclosure`;
  composer chip mirroring the picker; `⌘⌥1..9` quick-activate;
  agent-aware composer hints (`AgentRequirements.composerHint`); one-click
  backend-fix for incompatibility.
- **`ToolAgent` deletion.** Slated in `agent_plan.md` §2.3, still present.

## Drift between docs and code

- **Persona/agent vocabulary leaks ahead of schema.** Library section
  reads "First-party personas" but the *files* are under `Resources/agents/`
  and there is no `AgentKind` to enforce the distinction. UI is pretending
  the M1 work is done.
- **PR-1 picker location.** `agents.md` placed the picker in the sidebar;
  `agent-ux-plan.md` (newer) puts it in the chat header and demotes the
  sidebar to a library/inspector. Code matches the newer doc — header
  picker exists. The older doc is stale on this point.
- **`ToolAgent` deletion deferred.** `agent_plan.md` §2.3 says delete
  on PR 1.5 land; code retains `ToolAgent.swift` and a corresponding test.
- **Template-family handling.** `agents.md` mandates fingerprint-table
  classification of the loaded GGUF and a "fail loud" picker. Code has only
  backend-level compatibility. `clock-assistant.json` declares
  `templateFamily: llama3` with no matching runtime check.
- **Tool-call format coverage.** `agents.md` PR 3 expected qwen + hermes;
  code's `ToolCallParser.Family` only has `.llama3`, even though the
  `TemplateFamily` enum was scaffolded broader.
- **`AgentEvent` stream vs. direct mutation.** UX plan Phase 0.2 mandates
  the stream; code uses three-stage direct stamping. Final `StepTrace`
  shape ends up identical, but the seam is missing.
- **Composition anti-goal in `agents.md` not yet revised.** That doc still
  reads "No DSL for agent composition." `agent_plan.md` §7 schedules the
  edit for when PR 1.5 lands. Doc maintenance, not a code drift.
- **Workspaces.** `workspaces.md` is exploratory; some UI scaffolding
  exists (`WorkspacePickerMenu.swift`). Architectural migration to
  per-workspace `ChatViewModel`s and a facets table is not started. Out
  of scope for this roadmap; flagged so M1–M5 don't preclude either path.

## Build-out plan

Five milestones. M1–M3 close the largest doc-vs-code drift and unblock
everything else; M4 closes a long-standing functional drift; M5 is the
largest scope and is gated on the others.

### M1 — Schema v2: persona/agent kinds, `contextPath`, directory split

**Size:** M.

**Why first.** Closes the largest naming/concept drift, which is already
leaking into the UI. Unblocks the UX plan's kind-aware grouping. Gates
schema v3 (composition). Purely additive in code (no loop changes). Smaller
risk than the prior plan revision suggested because per-conversation
`Conversation.agentId` is already on the persisted model — no `VaultStore`
migration required.

**Builds:**

- Add `AgentKind { case persona, agent }` to `InferAgents/AgentTypes.swift`.
- Add `kind: AgentKind` and optional `contextPath: String` to `PromptAgent`
  (`InferAgents/PromptAgent.swift`); bump `currentSchemaVersion` to `2`,
  keep `1` in `supportedSchemaVersions` with auto-classification (kind =
  `.persona` if `toolsAllow` empty else `.agent`).
- Validation rules from `agent_kinds.md` §"Validation rules" in
  `PromptAgent.init(from:)`. Path-traversal rejection on `contextPath`.
- Override `PromptAgent.toolsAvailable(for:)` to return `[]` when
  `kind == .persona` regardless of `toolsAllow`.
- Delete `InferAgents/ToolAgent.swift` and update tests that exercise it.
- Move four persona JSONs (`brainstorm-partner.json`, `code-reviewer.json`,
  `explainer.json`, `writing-editor.json`) from
  `Sources/Infer/Resources/agents/` to a new
  `Sources/Infer/Resources/personas/`. Edit each to add
  `"schemaVersion": 2, "kind": "persona"`. Edit `clock-assistant.json` to
  `"schemaVersion": 2, "kind": "agent"`.
- Update `Package.swift` resources list to include `Resources/personas/`.
- Update `ChatViewModel/Agents.swift` `firstPartyPersonaURLs()` to glob
  both `personas/` and `agents/`. Update `userAgentsDirectory()` and
  `loadUserPersonas` to scan both `personas/` and `agents/` user subdirs.
- Update `Sidebar/AgentsLibrarySection.swift` to group by kind ("Personas"
  / "Agents") rather than by source; preserve a secondary source label
  per row. Apply the same grouping to `ChatView/AgentPickerMenu.swift`.
- Inspector kind-aware section visibility per `agent_plan.md` §3.3 — hide
  Tools / Compatibility for personas in `Sidebar/AgentInspectorView.swift`.
- Tests: kind round-trip, contradiction rejection, v1 auto-classify,
  `contextPath` load, path-traversal rejection, runtime persona-tool
  emptiness.

**Files touched:** `InferAgents/AgentTypes.swift`,
`InferAgents/PromptAgent.swift`, delete `InferAgents/ToolAgent.swift`,
`Infer/Resources/agents/*.json` (move + edit), `Infer/Resources/personas/*.json`
(new), `Infer/ChatViewModel/Agents.swift`,
`Infer/Sidebar/AgentsLibrarySection.swift`,
`Infer/Sidebar/AgentInspectorView.swift`,
`Infer/ChatView/AgentPickerMenu.swift`, `Package.swift`,
`Tests/InferAgentsTests/PromptAgentTests.swift` and a new
`AgentKindTests.swift`.

### M2 — `AgentEvent` async stream

**Size:** M.

**Why second.** UX plan Phase 0.2 names this the prerequisite for live
streaming, header-picker tool-count behaviour, and any composition UI
later. Refactor only — final `StepTrace` shape stays bytewise identical, so
persistence is unchanged. Decoupling event emission from
`messages[].steps` mutation also makes M5's per-segment attribution trivial.

**Builds:**

- New `InferAgents/AgentEvent.swift` with cases per `agent-ux-plan.md`
  §0.2 (`assistantChunk`, `toolRequested`, `toolRunning`, `toolResulted`,
  `finalChunk`, `terminated(StepTrace.Step)`).
- `AgentController` exposes `events: AsyncStream<AgentEvent>` (or per-`runTurn`
  returns one).
- Refactor `Infer/ChatViewModel/Generation.swift` `maybeRunToolLoop` to
  emit events instead of three direct `messages[i].steps` stamps. Consumer
  updates `messages[i].steps` incrementally and asserts final trace
  bytewise equality in tests.
- `AgentLibraryDiagnostic` already exists as `AgentRegistry.PersonaLoadError`;
  reconcile with the doc's three-severity model — either extend the type
  or strike severity from the doc (open question 2 below).
- Tests: event sequences for no-tool, tool success, tool error, cancel
  mid-tool. Bytewise-equal final-trace regression test.

**Files touched:** new `InferAgents/AgentEvent.swift`,
`InferAgents/AgentController.swift`,
`Infer/ChatViewModel/Generation.swift`, new
`Tests/InferAgentsTests/AgentEventTests.swift`.

### M3 — Picker polish (not structural)

**Size:** S–M (downgraded — picker exists already).

**Why third.** Largest visible-user-value gain in the agents track that
remains. Depends on M2 (events) for the tool-count chip and streaming
auto-expand/collapse, and on M1 (kinds) for sectioned grouping in the
dropdown.

**Builds:**

- Tool-count chip on the picker trigger
  (`Infer/ChatView/AgentPickerMenu.swift`); lights up only when
  `kind == .agent`.
- Kind-grouped sections in the dropdown ("Personas" first, then "Agents",
  then incompatible).
- `StepTraceDisclosure` rewrite: auto-expand while streaming, auto-collapse
  ~500 ms after `terminated`, spinner row between `toolRequested` and
  `toolResulted`. Pull `isStreaming` from the event terminator state
  introduced in M2.
- New `Settings.autoExpandAgentTraces` persisted via existing `PersistKey`.
- Composer agent chip (Phase 3.1) reusing `AgentPickerMenu` in
  `Infer/ChatView/ChatComposer.swift`.
- `⌘⌥1..9` quick-activate for the first nine compatible agents.
- Transcript hover-detail on `AgentDividerRow`
  (`Infer/ChatView/ChatTranscript.swift`) reusing the inspector's diff
  helper (`DecodingParams.describe`).

**Files touched:** `Infer/ChatView/AgentPickerMenu.swift`,
`Infer/ChatView/ChatHeader.swift`, `Infer/ChatView/ChatComposer.swift`,
`Infer/ChatView/ChatTranscript.swift`, `Infer/InferApp.swift` (shortcuts),
wherever `PersistKey` lives.

### M4 — Multi-template families + GGUF template fingerprinting

**Size:** M.

**Why fourth.** Closes a long-standing functional drift: agents declaring
`templateFamily: qwen` silently work as plain chat today because the parser
only knows llama3 and the picker only checks backend. Required before
composition is reasonable to ship (composition with mismatched template
family fails opaquely). Independent of M3 — can ship in parallel.

**Builds:**

- Extend `InferAgents/ToolCallParser.swift` `Family` enum with `.qwen`
  and `.hermes` (and openai if practical); implement `findFirstCall` per
  family.
- Fingerprint table over the loaded GGUF's embedded Jinja template — lives
  in `LlamaRunner` (or a sibling helper there), since `InferAgents/` must
  not depend on the llama framework. Returns one of
  `{llama3, qwen, hermes, openai, unknown}`.
- Surface the fingerprint into `AgentController.isCompatible` — extend the
  signature to take backend *and* template family; fail when
  `listing.templateFamily != detected`. Optional override affordance per
  `agents.md` constraint 3.
- Update `AgentController.composeSystemPrompt` to dispatch by template
  family rather than hard-coding the Llama 3.1 `<|python_tag|>` prelude.
- UI: incompatible-reason row in picker and library now distinguishes
  "Requires Llama 3.1 template — current: Qwen 2.5" vs. backend reasons.
- Tests in `Tests/InferAgentsTests/ToolCallParserTests.swift`.

**Files touched:** `InferAgents/ToolCallParser.swift`,
`InferAgents/AgentController.swift`, `InferAgents/AgentTypes.swift`
(compat helper), wherever the llama template loader lives in `LlamaRunner`,
`Tests/InferAgentsTests/ToolCallParserTests.swift`.

### M5 — Schema v3: composition primitives

**Size:** L. Sequenced as three sub-PRs.

**Why last.** Largest scope; depends on M1 (kinds), M2 (events for
per-segment streaming), and M4 (single-runner-compat validation). Maps
directly onto `agent_plan.md` PR 5.5a/b/c. Gated on the composition open
questions below.

**M5a — sequence + fallback (foundation).**

- `AgentOutcome` enum in `InferAgents/AgentTypes.swift`. Refactor
  `Agent.run` (currently throws `loopNotAvailable`) and the
  `Generation.maybeRunToolLoop` consumer to plumb `AgentOutcome`.
- `InferSettings.maxAgentSteps` added to `InferCore`.
- New `InferAgents/CompositionController.swift` actor: shared budget,
  cancellation, sequence and fallback drivers.
- Schema v3 fields `chain`, `fallback`, `budget` in `PromptAgent`. Bump
  `currentSchemaVersion` to `3`; v2 stays loadable.
- Cycle detection + runner-compatibility validation at registry-load time
  (after all files read) in `AgentRegistry`.
- Handoff envelope: `<<HANDOFF>>` sentinel-stripping in
  `CompositionController` (opt-in per the open question).
- Per-segment attribution: extend `StepTrace.Step` with optional `agentId`
  or wrap steps in a per-agent segment wrapper. Update `ChatTranscript`
  rendering with the multi-agent gutter.
- Wire `AgentController.switchAgent` / `Generation.maybeRunToolLoop` to
  detect a composition agent and dispatch to `CompositionController`.

**M5b — branch + refine.**

- `Predicate` decoding (regex / jsonShape / toolCalled / stepBudgetExceeded
  / noToolCalls) in new `InferAgents/Predicate.swift`. Evaluator over an
  `AgentOutcome`.
- Branch and refine drivers in `CompositionController`. Refine no-progress
  detector (byte-identical revision termination).

**M5c — router.**

- Synthetic `invoke(agentID:, input:)` `BuiltinTool` injected into the
  router's catalog at composition setup. Router invocation goes through the
  existing `ToolRegistry` path so M2's events flow, consent flows, and
  tracing flow without special-casing.
- Router validation (router `kind == .agent`, candidates resolve, no
  router-self-membership, no inter-router cycles).
- Picker label "routed via dispatcher" on routed turns (per
  `agent_composition.md` §"Determinism").

**Files touched:** `InferAgents/AgentTypes.swift`,
`InferAgents/PromptAgent.swift`, new
`InferAgents/CompositionController.swift`, new
`InferAgents/Predicate.swift`, `InferAgents/AgentRegistry.swift`,
`InferAgents/StepTrace.swift`, `InferCore/InferSettings.swift`,
`Infer/ChatViewModel/Generation.swift`,
`Infer/ChatView/ChatTranscript.swift`, plus extensive test files under
`Tests/InferAgentsTests/`.

## Out of scope for this roadmap

- **Workspaces.** Per `workspaces.md` itself, an architectural migration
  with five open questions still unresolved. UI scaffolding exists
  (`WorkspacePickerMenu.swift`); substrate work is independent of M1–M5.
- **MCP / `PluginHost` / consent UI / persistent consent prefs.** Out of
  scope per task instruction (no `plugins.md`).
- **Phase 3 polish that doesn't piggyback M3.** Library quicksearch is
  already shipped. Agent-aware composer hints (`composerHint`) and
  one-click backend-fix can be folded into M3 or M4 opportunistically.
- **PR 8 export-with-trace.** Pure `PrintRenderer` work; not a gap in the
  agents substrate.

## Decisions

Resolved 2026-04-26.

1. **M3 scope.** Polish only (tool-count chip, kind-grouped sections,
   streaming auto-expand/collapse, composer chip, `⌘⌥1..9`, transcript
   hover-detail). The picker itself is not rewritten.
2. **Composition envelope and streaming (gates M5a).**
    - Handoff envelope: free text in v1 with `<<HANDOFF>>` sentinel.
      Structured envelope deferred.
    - Per-step UI feedback: stream segments live with per-agent
      attribution.
    - `systemPrompt` is optional when composition is present; pure
      controllers do not need to declare one.
3. **Diagnostic severity.** Extend `AgentRegistry.PersonaLoadError` (or
   the public diagnostic type it surfaces through `AgentController`) with
   a `severity: .skipped | .warning` field. The UX plan is the newer doc;
   adding the field is smaller than rewriting it.
4. **`composerHint` field.** Defer. Add only when a concrete agent
   declares it. Not in M3.
5. **Template-family fingerprint placement.** `LlamaRunner` (and any
   future runner) detects the template family from the loaded GGUF and
   pushes it into `AgentController` via a small setter on
   `RunnerHandle`. `InferAgents` stays free of llama / MLX dependencies.
   `AgentController.isCompatible` consumes both backend and detected
   template family.
