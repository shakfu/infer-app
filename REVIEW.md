# Agents Subsystem Review

Date: 2026-04-26
Scope: `projects/infer/Sources/InferAgents/`, `projects/infer/Tests/InferAgentsTests/`, bundled agent JSON in `projects/infer/Sources/Infer/Resources/agents/`, and integration touchpoints in `ChatViewModel`.

This review evaluates the architecture, implementation, current featureset, and practical utility of the agents subsystem, and surfaces gaps and risks worth addressing before further investment.

---

## 1. Executive Summary

The `InferAgents` module is a deliberately scoped, well-factored substrate for running policy-driven LLM personas and small multi-agent compositions on top of either the llama.cpp or MLX backends. It is roughly 3.3 kLoC of source against 3.6 kLoC of tests (test:code ~1.1:1) — unusually high coverage for a module at this stage.

Strengths:
- Narrow, principled `Agent` protocol with six hooks; data-only configuration via JSON.
- Strong typing: `AgentKind` separates safe `persona` (no tools) from `agent` (tools/composition) and the distinction is enforced at both load time and runtime.
- Six composition primitives (`single`, `chain`, `fallback`, `branch`, `refine`, `orchestrator`) implemented as pure data + driver, fully unit-testable without the inference backends.
- Clean concurrency model: actor-isolated registries and composition driver, `@MainActor` controller, `Sendable` value types throughout.
- Tolerant parsing with loud post-load validation (cycle detection, dangling reference checks).

Weaknesses:
- The default `Agent.run(turn:context:)` throws `loopNotAvailable`; the real per-turn loop lives in `ChatViewModel.Generation`, not in the agents module. The `Agent` protocol is therefore policy-only, and the substrate's lifecycle story is split across two modules.
- Tool ecosystem is essentially a demo (`clock.now`, `text.wordcount`, plus the synthetic `agents.invoke`). No filesystem, retrieval, HTTP, or MCP tools.
- No agent-side memory or RAG hook even though the host app owns a vector store.
- Inter-agent handoff is free-text sentinel parsing; brittle to model drift.
- Several hooks (`transformToolResult`, `shouldContinue`, dynamic `systemPrompt`) are protocol-level extension points that are not yet exercised by any conformance or test.

Net assessment: a solid foundation for personas and pre-defined small workflows, not yet a general agent runtime. The largest single gap between the substrate's ambitions and its current utility is the absence of useful tools; the second-largest is that the loop driver is not part of the module and the `Agent.run` contract is unfulfilled by default.

---

## 2. Architecture

### 2.1 Module layout

`Sources/InferAgents/` (17 files):

Core protocol and types
- `Agent.swift` — `Agent` protocol (six hooks), `LoopDecision`, `AgentError`.
- `AgentTypes.swift` — `AgentMetadata`, `AgentKind`, `TemplateFamily`, `BackendPreference`, `AgentRequirements`, `DecodingParams`, `AgentOutcome`, `AgentSource`.
- `AgentContext.swift` — `RunnerHandle`, `TranscriptMessage`, `ToolSpec`, `ToolCall`, `ToolResult`, `ToolCatalog`, `AgentContext`, `AgentTurn`.

Registry and control
- `AgentRegistry.swift` — actor; user/plugin/firstParty precedence; JSON discovery; cycle and dangling-reference validation.
- `AgentController.swift` (largest UI-facing surface) — `@MainActor`; owns `activeAgentId`, `availableAgents`, `activeDecodingParams`, `activeToolSpecs`; emits `AgentEffect`s consumed by `ChatViewModel`.
- `DefaultAgent.swift` — synthetic persona representing pre-agent-era settings.

Agent implementation
- `PromptAgent.swift` — JSON-backed persona/agent (schema v1/v2/v3), composition fields, sidecar markdown, path-traversal rejection.

Composition
- `CompositionPlan.swift` — six-case enum and constructor `make(for:)`.
- `CompositionController.swift` — actor; six private drivers (`runSingle`/`runChain`/`runFallback`/`runBranch`/`runRefine`/`runOrchestrator`); takes a `@Sendable` `runOne` closure so it is fully testable without a runner.
- `Predicate.swift` — `regex`, `jsonShape`, `toolCalled`, `noToolCalls`, `stepBudgetExceeded`.
- `HandoffEnvelope.swift` — `<<HANDOFF target="…">>` … `<<END_HANDOFF>>` parser.
- `OrchestratorDispatch.swift` — extracts a router's dispatch decision either from a trace tool call to `agents.invoke` or by scanning visible text.

Tools
- `ToolRegistry.swift` — actor; `BuiltinTool` protocol; `register`/`invoke`/`allSpecs`.
- `BuiltinTools.swift` — `ClockNowTool`, `WordCountTool`, `AgentsInvokeTool`.
- `ToolCallParser.swift` — in-stream parser for Llama 3.1, Qwen, Hermes families.

Observability
- `StepTrace.swift` — immutable per-turn record with terminal cases and `SegmentSpan` attribution.
- `AgentEvent.swift` — six live signals (`assistantChunk`, `toolRequested`, `toolRunning`, `toolResulted`, `finalChunk`, `terminated`); `applyToTrace()` reconstructs traces from events.

### 2.2 Concurrency model

- Actors: `AgentRegistry`, `ToolRegistry`, `CompositionController`.
- `@MainActor`: `AgentController`.
- `Sendable` value types throughout; composition `runOne` is `@Sendable`.
- `AgentEvent` stream uses a `nonisolated` `AsyncStream.Continuation` so any isolation context can emit.
- One `@unchecked Sendable` exists in `ChatViewModel/Generation.swift` (`SegmentDispatchState`) — safe under MainActor single-threaded mutation but relies on convention.

This is consistent with the project's broader Swift concurrency posture (the `Infer` target is still `.swiftLanguageMode(.v5)` per `Package.swift`, but `InferAgents` itself is written so it can stay strict-Swift-6 clean).

### 2.3 Composition with the host app

`ChatViewModel` (`Sources/Infer/ChatViewModel/`) owns:
- `agentController: AgentController`
- A `bootstrapAgents()` step that registers builtin tools, loads first-party + user persona/agent JSON, and runs registry validation.
- A turn pipeline (`Generation.swift`) that translates user input into either a single-agent or composition-driven sequence of segments, consuming `AgentEvent`s for live UI updates and writing per-segment attribution into the vault.

`AgentEffect` is the boundary type: the controller never touches the runners directly. Instead it returns effects (`pushSystemPrompt`, `pushSampling`, `insertDivider`, `invalidateConversation`, `resetTranscript`) which the view-model applies. This keeps the agents module independent of the llama/MLX runners — a valuable boundary that should be preserved.

---

## 3. Implementation

### 3.1 Agent definition format

JSON, schema-versioned (`schemaVersion: 1 | 2 | 3`). Unknown fields within a known major version are ignored (forward-compatible at the data level); unknown major versions are rejected with `AgentError.unsupportedSchemaVersion`.

Minimum persona:
```json
{ "schemaVersion": 2, "kind": "persona", "id": "my.persona",
  "metadata": {"name": "My Persona"}, "requirements": {},
  "systemPrompt": "You are…" }
```

Full agent (v3) supports all six composition shapes via `chain`, `fallback`, `branch`, `refine`, and `orchestrator` fields plus `decodingParams`, `requirements` (backend, templateFamily, minContext, toolsAllow/Deny/autoApprove), and an optional `contextPath` markdown sidecar.

Constraints enforced at load time:
- `kind: persona` with non-empty `toolsAllow` or any composition field is rejected (`AgentError.invalidPersona`).
- `contextPath` rejects absolute paths and `..` segments.
- Composition references are validated post-load: missing IDs and cycles are surfaced as `PersonaLoadError` warnings (load succeeds; UI shows a banner).

### 3.2 Loading and lifecycle

On VM init:
1. `ToolRegistry.register` builtin tools.
2. Build a `ToolCatalog` from registered specs.
3. `AgentController.bootstrap(...)` loads first-party (`Bundle.module/personas`, `Bundle.module/agents`) then user (`~/Library/Application Support/Infer/{personas,agents}/`).
4. `validateCompositionReferences()` runs; per-file diagnostics surface in console + Agents tab.
5. `availableAgents` listings refresh (`Default` always first).

On agent switch:
1. Resolve agent (fallback to `DefaultAgent` if missing).
2. Call `systemPrompt(for:)` and `toolsAvailable(for:)` to compose a backend-appropriate prompt + tool section.
3. Call `decodingParams(for:)` to derive sampling.
4. Emit `pushSystemPrompt` / `pushSampling` effects, which `ChatViewModel` forwards to the active runner (`LlamaRunner` or `MLXRunner`).

### 3.3 Execution paths

Single-agent turn (in `ChatViewModel.Generation`):
- Runner streams text; `ToolCallParser` watches for in-stream tool calls.
- Recognised calls are filtered against `toolsAvailable`, invoked via `ToolRegistry`, optionally transformed by `transformToolResult`, then re-injected.
- `shouldContinue` decides loop termination; `StepTrace` accumulates; `AgentEvent`s are emitted for UI.

Composition turn:
- `CompositionPlan.make(for:)` constructs a plan from the agent's config.
- `CompositionController.dispatch(plan:userText:budget:runOne:)` walks the plan; the VM-supplied `runOne` actually drives a single-agent segment.
- Outcomes propagate per the plan's semantics (chain forwards; fallback retries on `.failed`; branch follows the predicate; refine iterates producer/critic until `acceptWhen`; orchestrator dispatches via `OrchestratorDispatch`).
- Handoff envelopes are auto-followed.

### 3.4 Error handling

- Load-time JSON failures and schema violations produce per-file `PersonaLoadError`s; loads do not abort.
- Runtime errors in `shouldContinue` and `toolsAvailable` are caught and degrade gracefully (loop stops; tool catalog treated as empty).
- Tool exceptions become `ToolResult` with an `error` field, so the model can react.
- A handful of call sites use `try?` defaults (e.g., `(try? await agent.systemPrompt(for: ctx)) ?? ""`) which discards error context — see §6.

### 3.5 Persistence

- User persona/agent JSON in `~/Library/Application Support/Infer/{personas,agents}/`. No signing, no checksums; same trust model as any user file.
- Vault rows tag each turn with `agentId`; non-Default agents are visible in the system-prompt provenance.
- `StepTrace.SegmentSpan`s carry per-segment agent attribution for multi-agent turns.

---

## 4. Featureset (current state)

### 4.1 Working

Persona/agent definition
- Schema v1/v2/v3 JSON loading with tolerant decoding.
- Metadata, requirements, decoding overrides, system prompt, optional markdown sidecar.
- Persona-kind enforcement (no tools at load time and at runtime).

Selection and activation
- Source precedence (user > plugin > firstParty) with stable listings.
- Compatibility checks against active backend and template family with reason strings.
- Switching emits effects: divider insertion, transcript invalidation, sampling and system-prompt push.
- `DefaultAgent` synthetic persona tracks live `InferSettings`.

Tool calling (single agent)
- In-stream parsing for Llama 3.1, Qwen, and Hermes families.
- Allow/deny/auto-approve filtering.
- Result injection back into the transcript.
- `transformToolResult` hook available.

Composition (multi-agent)
- All six primitives implemented and unit-tested: `single`, `chain`, `fallback`, `branch`, `refine`, `orchestrator`.
- Sentinel-based handoff with auto-follow.
- Step-budget tracking with explicit `budgetExceeded` terminal step.
- Per-segment attribution in `StepTrace`.

Validation and diagnostics
- Cycle and dangling-reference detection across composition fields.
- Per-file load diagnostics surfaced in UI.
- `TemplateFamily` fingerprinting from Jinja heuristics.

Observability
- `AgentEvent` stream with six live signals.
- Trace reconstruction from event log (`applyToTrace`).

Bundled demos (`Sources/Infer/Resources/agents/`):
- `clock-assistant.json` (single agent + tools)
- `draft-then-edit.json` (chain)
- `refine-prose.json` (producer-critic refine)
- `branch-by-topic.json` (regex branch)
- `code-or-prose.json` (orchestrator)

### 4.2 Stubbed, partial, or absent

- `Agent.run(turn:context:)` default throws `loopNotAvailable`; the real loop lives in `ChatViewModel.Generation`. The protocol is policy-only today.
- OpenAI-style structured tool calls: `.openai` template family currently falls back to Llama-3 syntax in the parser.
- Tool catalogue is demo-grade: `clock.now`, `text.wordcount`, and the synthetic `agents.invoke`. No filesystem, retrieval, HTTP, shell, or MCP integration.
- No agent-side memory hook; the host app's vector store is not exposed to agents.
- No cost/latency/token telemetry per agent or per tool.
- No human-in-the-loop approval gate inside compositions; the only approval surface is the static `autoApprove` list at the agent-config level.
- No UI preview or dry-run for compositions before execution.
- Several hooks (`transformToolResult`, `shouldContinue`, dynamic `systemPrompt`) are not exercised by any current conformance or test beyond defaults.

---

## 5. Utility

### 5.1 What this is well-suited for today

- Curated personas with safe-by-construction tool isolation (role-play, style, voice).
- Small, pre-declared multi-agent workflows where the structure is known up front (draft → edit, producer → critic, branch by topic, route between two specialists).
- Local, offline experimentation with composition primitives without leaving the user's machine — composition is data-driven and runs against either backend.
- A research substrate: the testable `runOne`-closure design means new dispatch policies can be prototyped quickly.

### 5.2 What it is not yet useful for

- General "give the agent a goal and let it figure out the steps" workflows. There is no planner, no goal/subgoal tracking, and no dynamic plan revision.
- Tool-using agents that need to read files, search the vault, hit HTTP, or invoke MCP. The tool registry is open but unpopulated.
- Long-horizon tasks that need persistent memory across turns or sessions. Per-turn `AgentContext` is built fresh from transcript snapshots; nothing is carried beyond.
- Adversarial or production environments where the persona/JSON layer is treated as untrusted input. Path-traversal is checked but the broader hardening story (signed bundles, per-source capability scoping at the OS level) is absent.

### 5.3 Highest-leverage gaps to close

1. Populate the tool registry with a handful of genuinely useful tools: filesystem read (sandboxed), vector-store query, vault search, fetch URL. Without these, compositions are demos.
2. Decide whether `Agent.run` is part of the contract or whether the loop driver should live entirely in `ChatViewModel`. The current split is confusing — the protocol advertises a method that nothing supplies.
3. Replace free-text `<<HANDOFF>>` parsing with a structured tool call (`agents.handoff`) once the tool route is real. The 2026-04-26 design note already anticipates this.
4. Add a memory/RAG hook to `AgentContext` (e.g., an `async` retrieval callback) so agents can pull from the existing vector store without each conformance reinventing it.
5. Add per-turn telemetry: token counts, tool latency, success/failure outcome counts. Without this it is impossible to compare agents or compositions empirically.

---

## 6. Code quality

### 6.1 Test coverage

18 test files, ~3.6 kLoC. Coverage strengths:
- All six composition primitives, including budget exhaustion.
- Schema parsing for all three versions, including tolerance and rejection cases.
- All five predicate types.
- All three template-family parsers.
- Registry precedence, cycle detection, persona/agent kind invariants.
- Bundled demos exercised end-to-end in `BundledAgentDemoTests`.

Coverage gaps:
- `transformToolResult` and `shouldContinue` hooks are not directly tested beyond defaults.
- `Agent.systemPrompt` and `toolsAvailable` are tested only for `PromptAgent`; no test exercises a custom conformance with dynamic context-dependent behaviour.
- No concurrent-composition stress test; composition is structurally sequential, but contention on the registries under realistic load is untested.

### 6.2 Concurrency hazards

- Actor isolation is consistent across `AgentRegistry`, `ToolRegistry`, `CompositionController`, `@MainActor` for `AgentController`.
- The single `@unchecked Sendable` in `ChatViewModel/Generation.swift` (`SegmentDispatchState`) is correct only under the implicit MainActor invariant; worth a comment or explicit isolation annotation.
- The `AsyncStream` continuation pattern in `AgentEvent` is correct (nonisolated emission).

### 6.3 Code smells

- `try?` swallowing: several call sites discard errors when computing `systemPrompt` or `toolsAvailable`. Either log via the existing console diagnostics path or surface a `PersonaLoadError`-style warning.
- `AgentID` is a `typealias String` with no newtype wrapper. Schema decoding validates non-empty, but in-process APIs accept any `String`. A wrapper would be cheap and would prevent passing arbitrary strings as IDs.
- `Predicate.evaluate` recompiles regex on every call; cache the compiled `NSRegularExpression` (or migrate to `Regex<Output>`).
- Path-traversal rejection in `PromptAgent` does not resolve symlinks; for first-party + user JSON this is acceptable, but worth documenting as the threat-model boundary.
- `ToolCall.arguments` is kept as a JSON string for forward compatibility — sound choice, but every tool implementation must re-parse. A small `ToolArguments` decoding helper would reduce boilerplate.

### 6.4 Integration gaps

- No documented contract for what `ChatViewModel.Generation` is expected to do on behalf of the agents module. The `Agent.run` default throwing `loopNotAvailable` is a silent handoff to the VM. Either implement a real default (e.g., a `BasicLoop` driver inside `InferAgents`) or remove `run` from the protocol and clearly position `Agent` as policy-only.
- Vault integration writes `agentId` per turn but the transcript renderer's awareness of `SegmentSpan` was not directly verified in this review. Worth a smoke test that a chained turn renders both segments with correct attribution.
- The host's vector store is invisible to agents. Adding even a read-only retrieval hook in `AgentContext` would unlock the most obvious "useful agent" use cases.

---

## 7. File-by-file inventory

Source (`projects/infer/Sources/InferAgents/`)

| File | Purpose |
|------|---------|
| `Agent.swift` | `Agent` protocol (six hooks); `LoopDecision`; `AgentError.loopNotAvailable`. |
| `AgentTypes.swift` | `AgentMetadata`, `AgentKind`, `TemplateFamily`, `BackendPreference`, `AgentRequirements`, `DecodingParams`, `AgentOutcome`, `AgentSource`. |
| `AgentContext.swift` | `RunnerHandle`, `TranscriptMessage`, `ToolSpec`, `ToolCall`, `ToolResult`, `ToolCatalog`, `AgentContext`, `AgentTurn`. |
| `AgentRegistry.swift` | Actor-isolated registry; user/plugin/firstParty precedence; JSON load; cycle detection. |
| `AgentController.swift` | `@MainActor` controller; emits `AgentEffect`s; owns active agent state. |
| `DefaultAgent.swift` | Synthetic persona representing pre-agent settings. |
| `PromptAgent.swift` | JSON-backed persona/agent (v1/v2/v3) with composition fields and sidecar markdown. |
| `CompositionPlan.swift` | Six-case enum and `make(for:)` constructor. |
| `CompositionController.swift` | Actor-isolated dispatch driver with six private drivers and a `@Sendable runOne` closure. |
| `Predicate.swift` | `regex`, `jsonShape`, `toolCalled`, `noToolCalls`, `stepBudgetExceeded`. |
| `HandoffEnvelope.swift` | `<<HANDOFF target="…">>` … `<<END_HANDOFF>>` parser. |
| `OrchestratorDispatch.swift` | Router dispatch resolution from trace tool calls or visible text. |
| `ToolRegistry.swift` | `BuiltinTool` protocol and actor-isolated registry. |
| `BuiltinTools.swift` | `ClockNowTool`, `WordCountTool`, `AgentsInvokeTool`. |
| `ToolCallParser.swift` | In-stream parser for Llama 3.1, Qwen, Hermes families. |
| `StepTrace.swift` | Per-turn record with terminal cases and `SegmentSpan`. |
| `AgentEvent.swift` | Six live signals; `applyToTrace()` reconstruction. |

Tests (`projects/infer/Tests/InferAgentsTests/`)

`AgentControllerTests`, `AgentEventTests`, `AgentKindTests`, `AgentListingTests`, `AgentProtocolTests`, `AgentRegistryTests`, `BuiltinToolsTests`, `BundledAgentDemoTests`, `CompositionAdvancedTests`, `CompositionControllerTests`, `CompositionFoundationTests`, `DefaultAgentTests`, `PredicateTests`, `PromptAgentTests`, `StepTraceTests`, `TemplateFamilyTests`, `ToolCallParserTests`, `ToolRegistryTests`.

Bundled agent JSON (`projects/infer/Sources/Infer/Resources/agents/`)

| File | Shape | Notes |
|------|-------|-------|
| `clock-assistant.json` | single agent + tools | Demonstrates tool gating. |
| `draft-then-edit.json` | chain | `brainstorm → writing-editor`. |
| `refine-prose.json` | refine | producer=writing-editor, critic=prose-critic. |
| `branch-by-topic.json` | branch | Regex predicate; code vs prose dispatch. |
| `code-or-prose.json` | orchestrator | Router + two candidates. |

---

## 8. Recommendations

Short term (low cost, high payoff)
1. Add a vector-store retrieval hook to `AgentContext` and route the host app's existing store through it; ship one bundled agent that uses it.
2. Add real tools: a sandboxed `fs.read`, a vault search tool, and a URL fetcher with a strict allowlist. Without tools, compositions are demos.
3. Cache compiled regexes in `Predicate`.
4. Replace `try?` swallows in agent activation with logged warnings.
5. Add a smoke test that a chained turn renders both segments with correct `SegmentSpan` attribution end-to-end.

Medium term
6. Resolve the `Agent.run` ambiguity. Either implement a default `BasicLoop` inside `InferAgents` (so the protocol is honest), or remove the method and document `Agent` as policy-only with the loop owned by the host.
7. Replace free-text handoff with a structured `agents.handoff` tool call now that the design note (2026-04-26) anticipates it.
8. Add per-turn telemetry (tokens, tool latency, outcomes) and surface it in the Agents tab.
9. Introduce a typed `AgentID` newtype.

Longer term
10. A real planner agent kind (goal + subgoal tracking, dynamic plan revision) — this is where the substrate's data-driven composition starts to pay off.
11. MCP integration alongside the native `BuiltinTool` registry.
12. Human-in-the-loop approval gates as a first-class composition primitive (e.g., a `gate` plan node).

---

## 9. Bottom line

The agents subsystem is a thoughtful, well-tested substrate. It is correctly scoped as policy + composition rather than a full agent runtime. To convert that substrate into something users would reach for, the immediate priorities are real tools, a memory/RAG hook, and resolving the `Agent.run` contract. The composition machinery, validation, and observability are already in good shape and will repay further investment.
