# Agent architecture

Status: proposal, unimplemented as of 2026-04-23. Companion to `plugins.md`: that doc specifies how tools and MCP servers plug in; this one specifies what an *agent* is and how the tool-calling loop runs. PR numbering in this doc is internal to the agents track; when it references plugins work, it calls it out as `plugins.md PR N`.

## Terminology

The vocabulary matters because the existing code reuses some of these words loosely.

- **Runner.** The `LlamaRunner` or `MLXRunner` actor that owns a model and decodes tokens. One per backend. Not user-facing.

- **Agent.** A named configuration that drives a runner for a particular purpose: system prompt, tool allowlist, model preference, decoding params, tool-call template family. User-facing. Multiple agents per backend are expected.

- **Tool.** A single callable capability — `fetch_url`, `read_file`, a shell command. Exposed either by a built-in Swift implementation or by an MCP server (see `plugins.md`).

- **Plugin.** A unit of extensibility. A plugin may ship **any combination** of: agents, tools (built-in or via an MCP server), transcript renderers, export formats, sidebar panes. "Plugin" is the packaging boundary; "agent" is one kind of thing inside it. A user can also define an agent directly without packaging it as a plugin.

- **Turn.** One user message and the assistant's response to it. An agent may execute many *steps* within a single turn.

- **Step.** One decode-until-pause segment: either the model produces a tool call (which pauses the stream, runs the tool, and resumes) or it produces a final answer (which ends the turn).

The chat Infer ships today is implicitly a single built-in agent: "default assistant," no tools, no step loop. The architecture below generalises that, and today's behaviour becomes the zero-tool zero-step special case.

## Scope

Target is **multi-step local tool use** — scope (2) from the prior conversation. An agent can call tools repeatedly within one user turn until it produces a final answer or hits a step budget. No sub-agents, no cross-turn memory beyond the transcript itself, no autonomous background execution. Those are in "Anti-goals."

## Constraints shaping the design

1. **Local-first.** No cloud providers. Agents run on `LlamaRunner` or `MLXRunner`. API-key-gated services are out of scope as a product decision, not a technical one.

2. **Runner asymmetry persists.** `LlamaRunner` hand-renders the chat template and streams deltas; it is the natural home for tool-call parsing. `MLXRunner` goes through `ChatSession`, which has no tool-call hook today. Agents ship on llama first; MLX gets agents when its runner grows a tool-call seam (deferred — see `plugins.md`).

3. **Tool-call format is model-specific.** GGUF chat templates encode their own tool-call conventions (Llama 3.1 `<|python_tag|>`, Qwen `<tool_call>`, Hermes XML, etc.). An agent must declare a template family; detection is by fingerprint table over the GGUF's embedded Jinja template, not regex. If the loaded model's template doesn't match the agent's declared family, activation fails loudly — the agent picker shows the mismatch and refuses to select the agent until the user either loads a compatible model or explicitly ticks "override: use plain chat (no tools)." Silent degradation to chat was the prior design and was rejected: a user who enabled tools and saw nothing happen is a support ticket, not a feature.

4. **Cooperative cancellation only.** The existing `CancelFlag` in `LlamaRunner` only honours cancellation at await points. A multi-step loop must surface a stop request at three places: during decode (already handled), between steps (new), and during an in-flight MCP tool call (new — possibly `Process.terminate()`). None of this blocks the C decode loop.

5. **Agents are code, not just config.** The extension point is a Swift protocol. Custom agents can build the system prompt dynamically, filter tools per-turn, transform tool results, maintain agent-local state, and override the loop itself when the default shape doesn't fit. A JSON-backed "persona" implementation exists as a convenience for the simple case, but it is one concrete type conforming to the protocol — not the substrate. Determinism is a property of a given implementation, not a system-wide guarantee.

6. **Swift 6 concurrency-clean.** `Infer` is still on `.swiftLanguageMode(.v5)` (TODO.md P2). New agent/plugin code lands Swift-6-safe so the opt-out can be dropped.

## Agent protocol

The extension point is a Swift protocol in `InferAgents`. The protocol is deliberately narrow — a small set of hooks over a shared loop, rather than a god-type that owns everything. Custom implementations override only what they need.

```swift
public protocol Agent: Sendable {
    /// Stable identifier. Used for registry keying, transcript attribution, consent scoping.
    var id: AgentID { get }

    /// Human-facing name and description for the picker.
    var metadata: AgentMetadata { get }

    /// Declared backend preference and template family. The registry uses these to gate
    /// activation against the loaded model.
    var requirements: AgentRequirements { get }

    /// Decoding parameters applied when this agent is active. Overrides InferSettings for the turn.
    func decodingParams(for context: AgentContext) -> DecodingParams

    /// Build the system prompt for a turn. Default implementation returns a static string;
    /// dynamic agents can inspect context (time of day, recent transcript, tool availability)
    /// and recompute per turn.
    func systemPrompt(for context: AgentContext) async throws -> String

    /// Choose which tools are exposed to the model this turn, from the full set the
    /// ToolRegistry offers. Default: static allowlist from AgentRequirements.
    func toolsAvailable(for context: AgentContext) async throws -> [ToolSpec]

    /// Optionally transform a tool result before it is injected back into the runner's
    /// transcript. Default: pass through. Useful for trimming, summarising, or redacting.
    func transformToolResult(_ result: ToolResult, call: ToolCall,
                             context: AgentContext) async throws -> ToolResult

    /// Decide whether to continue the loop after this step. Default: continue until
    /// finalAnswer, step budget, or cancellation. Override to add custom terminators
    /// (e.g. "stop when the assistant has emitted a URL").
    func shouldContinue(after step: StepTrace.Step,
                        context: AgentContext) async -> LoopDecision

    /// Optional escape hatch: the agent runs its own loop entirely. Default implementation
    /// calls into the shared AgentSession.defaultLoop(...). Overriding is rare; provided
    /// for agents whose shape doesn't match the standard tool-call loop (e.g. a planner
    /// that decodes in two phases: plan, then execute).
    func run(turn: AgentTurn, context: AgentContext) async throws -> StepTrace
}
```

Supporting types (sketched):

- `AgentContext` — read-only handle passed to every hook. Contains: a minimal `RunnerHandle` (backend id, template family, `maxContext`, current token count) rather than the runner actor itself; a `ToolCatalog` view of the tool registry already filtered by the plugin-level consent layer; a read-only snapshot of the transcript so far; the step counter; and agent-local `AgentStateStore`. Explicitly **not** in `AgentContext`: the `Runner` actor reference (would leak decode-loop internals), `InferSettings` (agents override via `decodingParams`, not by reading user prefs), `PluginHost` (tools go through `ToolCatalog`), the `ChatViewModel`, or any mutable UI state. The absence list is load-bearing: once an implementation takes a dependency on something here, the shape is frozen, so the surface stays deliberately thin.

- `AgentRequirements` — `backend: BackendPreference`, `templateFamily: TemplateFamily?`, `minContext: Int?`, `toolsAllow: [ToolName]`, `toolsDeny: [ToolName]`, `autoApprove: [ToolName]`.

- `AgentMetadata` — `name`, `description`, optional `icon`, optional `author`.

- `LoopDecision` — `.continue` / `.stop(reason)` / `.stopAndSummarise`.

- `ToolSpec`, `ToolCall`, `ToolResult` — shared with `plugins.md`.

### Built-in implementations

`InferAgents` ships a handful of conformances that cover the common shapes without writing code:

- `PromptAgent` — JSON-backed persona. Reads a JSON file, conforms to `Agent` with static implementations of every hook. This is the "persona pack" case. Users and plugins can author these without touching Swift. The schema is itself a versioned, user-facing API — the file's `schemaVersion` field drives forward-compatible parsing; unknown fields in a known major version are ignored with a warning, major version bumps require a migration step shipped alongside. A minimal example:

  ```json
  {
    "schemaVersion": 1,
    "id": "code-reviewer",
    "metadata": {
      "name": "Code reviewer",
      "description": "Reviews diffs for obvious issues.",
      "icon": null,
      "author": "first-party"
    },
    "requirements": {
      "backend": "llama",
      "templateFamily": "llama3",
      "minContext": 8192,
      "toolsAllow": ["builtin.clock.now"],
      "toolsDeny": [],
      "autoApprove": []
    },
    "decodingParams": { "temperature": 0.2, "topP": 0.9, "maxTokens": 2048 },
    "systemPrompt": "You are a meticulous code reviewer..."
  }
  ```

  Every field except `schemaVersion`, `id`, `metadata.name`, and `systemPrompt` has a default. Semantics changes to existing fields (e.g. `toolsAllow` gaining glob support) ride a minor version bump and a documented default; breaking renames require a major bump and keep the prior major loadable for one release.

- `DefaultAgent` — what Infer currently ships: no tools, no loop, system prompt from `InferSettings`. The synthetic "Default" entry in the picker.

- `ToolAgent<Tools>` — generic over a tool set declared at construction. A first-party agent defined in a few lines of Swift. Expected to be the typical way first-party agents are built.

Custom agents — first-party or in-tree plugin-shipped — conform to `Agent` directly and override whatever hooks they need.

### How agents are loaded

All agents are in-tree: either compiled `Agent` conformances (first-party or plugin-shipped Swift code) or JSON personas bundled alongside them. There is no third-party distribution tier and no dynamic loading. The registry treats all sources uniformly; the only distinction that matters at runtime is **precedence on id collision**: user-authored JSON overrides plugin-shipped JSON overrides built-in conformances.

JSON personas exist because they are the cheapest way to add a new agent — no rebuild, no Swift — not because of a trust distinction. They sit in `~/Library/Application Support/Infer/agents/` (user) or inside a plugin's resource bundle (plugin-shipped). Anything a persona can't express, a code-backed `Agent` conformance can.

### The synthetic Default

The current Infer UI corresponds to `DefaultAgent`, constructed at launch from `InferSettings`. Migration is a one-liner: the settings panel edits the fields that feed `DefaultAgent`. Existing transcripts are attributed to `DefaultAgent` by absence of an explicit agent id.

## Architecture

```
ChatViewModel
    |
    v
AgentSession   actor per-turn (new)
    |          owns: active agent, step counter, transcript delta buffer
    |
    +--> Runner (Llama or MLX)
    |       emits: token stream + "paused for tool call" events
    |
    +--> ToolRegistry
            |
            +--> BuiltinTools (Swift structs; e.g. clock, calc)
            +--> PluginHost  (from plugins.md; one MCPClient per configured server)
```

New types (all in a new `InferAgents` SwiftPM library target — pure Swift, no MLX/llama deps, Tier-1 testable):

- `Agent` protocol and supporting types (see above).

- `PromptAgent`, `DefaultAgent`, `ToolAgent` — built-in conformances.

- `AgentRegistry` — actor; loads first-party conformances, JSON personas from `~/Library/Application Support/Infer/agents/` and plugin bundles, and any in-tree code-backed plugin agents. Deduplicates by `id` with precedence: user overrides plugin overrides first-party.

- `AgentSession` — actor; created per user turn. Holds the active `Agent`, the step counter, the runner reference, the `ToolRegistry`, and an `AgentStateStore`. Drives the default loop via `AgentSession.defaultLoop(agent:context:)`, which the `Agent.run` default implementation calls.

- `StepTrace` — the canonical per-turn record: ordered list of `assistantText`, `toolCall(name, args)`, `toolResult(output, error?)`, terminating with `finalAnswer(text)` or `error`/`cancelled`/`budgetExceeded`. This is what the transcript renderer reads; it is also what persists to disk.

- `ToolRegistry` — merges built-in tools with MCP-exposed tools from `PluginHost`. Names are namespaced: `builtin.<name>`, `mcp.<server>.<tool>`. Collisions are impossible by construction.

- `BuiltinTool` protocol — three methods: `name`, `schema` (JSON Schema for params), `invoke(args:) async throws -> String`. Kept narrow on purpose so a plugin can add built-in tools without pulling in MCP machinery.

### The loop (per user turn)

```
1. ChatViewModel.send(userText) -> AgentSession.run(userText)

2. AgentSession:
   a. Compose system prompt = agent.systemPrompt + toolRegistry.toolSpecSection(family)
   b. Append user message to the runner's transcript.
   c. Decode. While decoding:

        - Every N tokens, feed the tail through ToolCallParser(family).

        - On a complete tool-call: pause decode, emit StepTrace.toolCall, break.

        - On stream end without a tool-call: emit StepTrace.finalAnswer, return.
   d. Consent-check the call (per-plugin + per-agent autoApprove).
   e. Invoke tool via ToolRegistry. Emit StepTrace.toolResult (or error).
   f. Inject result as the next template turn (template-family-specific formatting).
   g. step++ ; if step >= maxSteps: emit StepTrace.budgetExceeded, return.
   h. Resume decoding. Go to (c).

3. Persist StepTrace with the turn.
```

Two knobs worth calling out:

- **Parse cadence N.** Parsing the tail every token is wasteful; every N tokens adds latency to tool-call detection. Start at N=8 with a re-parse on stream end. Measure before tuning.

- **Consent and the loop.** The consent prompt (from `plugins.md`) is a UI modal, which is inherently async and user-paced. The loop pauses on it. A "remember for this turn" option is probably required the moment anyone runs an agent that reads three files in a row — plan for it in the first UI pass, even if the persisted-preference work lands later.

### Cancellation semantics

Stop button behaviour per state:

| Loop state         | Action                                                                             |
| ------------------ | ---------------------------------------------------------------------------------- |
| Decoding           | Existing `CancelFlag` path. Emit `StepTrace.cancelled`, keep partial `assistantText`. |
| Between steps      | Skip next decode. Emit `StepTrace.cancelled`.                                      |
| In a tool call     | `MCPClient.cancel(callId)` if supported; else `Process.terminate()` after a 1 s grace; else fire-and-forget-and-discard. Emit `StepTrace.toolResult(error: cancelled)`. |
| Awaiting consent   | Dismiss the prompt as `deny`. Emit `StepTrace.toolResult(error: cancelled)`.       |

## Transcript schema changes

`ChatMessage.Role` gains `.tool` and `.toolCall`. But rather than two new flat cases, the cleaner move is:

```swift
struct ChatMessage {
  enum Role { case system, user, assistant }
  // existing fields
  var steps: [StepTrace]?   // non-nil only on assistant messages produced by an agent
}
```

Rendering:

- Assistant messages with `steps == nil` render exactly as today.

- Assistant messages with `steps != nil` render the final-answer text as the main body and collapse the tool-call trace into a disclosure group above it. Raw `<tool_call>` tokens never appear in the rendered body — they are consumed by the parser and replaced by structured rows.

**Persistence migration.** Transcripts already persist (Vault, print, export). `steps` is an additive optional field; old transcripts decode with `steps == nil` and render unchanged. Export formats (HTML/PDF via `PrintRenderer`) need a pass to include the trace or explicitly drop it — first implementation drops it, PR N adds a "include tool trace" toggle.

## Relationship to plugins

All plugins are in-tree (see `plugins.md`). A plugin is a packaging boundary — a cohesive, separately-toggleable unit of extension — not a trust tier. It can ship any of:

- **Agents as code** — Swift types conforming to `Agent`. The full protocol surface.

- **Agents as personas** — `PromptAgent` JSON files bundled in the plugin's resources. Cheaper to author; limited to what the protocol's default hooks express.

- **MCP server** — registered in the plugin's manifest, tools auto-exposed through `PluginHost`/`ToolRegistry`. The primary route for tool capability, since it gives access to the MCP ecosystem.

- **Built-in tools (Swift)** — types conforming to `BuiltinTool`. Used when a tool is Swift-native and doesn't justify a subprocess.

- **UI extensions** — transcript renderers, export formats, sidebar panes. Out of scope for v1; reserved in the plugin manifest schema.

A plugin with only a persona and no tools is legal and useful: it's a persona pack. A plugin with only an MCP server and no agent is also legal: its tools become available to any existing agent whose allowlist references them.

## User interface

The UI separates **using** an agent (frequent, reversible, instant) from **managing** agents (rare, deliberate, exploratory). Conflating them is the root cause of "launch dialog" and "tab-as-picker" designs that feel wrong for this architecture — an agent is a configuration that shapes the next turn's decode, not a process, so there is no launch moment.

### Selection-for-use: sidebar, next to Models

The active agent for the current conversation lives in the sidebar next to the model picker. Clicking switches agents instantly: transcript inherits with a divider row (see Decisions), no modal dialog, no confirmation. Compatible agents appear as selectable rows; incompatible ones are grouped under a disabled "Requires other model" section with a reason row ("Requires Llama 3.1 template — current: Qwen 2.5"). Reason text is visible inline, not on hover, so it survives a11y and touch contexts.

Agents are **per-conversation state**, not a global setting. Each conversation remembers its agent; switching the active conversation restores that conversation's agent. This matches how users actually work ("this chat is with code-reviewer; that one is with default") and makes the sidebar an *indicator* of the current conversation's binding, not a floating global.

### Management: Agents tab, after Models

A new "Agents" tab lands after the Models tab in the existing tab structure. It is a **library / inspector**, not a picker:

- Sections for **User**, **Plugin-shipped**, **First-party** (matching the JSON precedence ordering described earlier, displayed for transparency even though the runtime distinction is cosmetic per `plugins.md`).

- Each row shows name, description, template family, backend preference, and tool allowlist summary.

- Selecting a row reveals the full config read-only, plus actions: **Open in Finder** (user agents only), **Duplicate as user agent** (any agent → seed a new JSON file in `~/Library/Application Support/Infer/agents/`), **Reveal in transcript** (jumps to most recent conversation using this agent, if any).

- No "Launch" button. Using an agent happens in the sidebar; the Agents tab is for browse/inspect/author. This split mirrors VS Code's extensions tab vs the active-editor status bar, and keeps per-use friction at zero.

Authoring agents is explicitly a file-editing workflow in v1: JSON in an external editor, reload picked up on next launch (or via a "Reload agents" button in the tab). An in-app form editor is deferred until non-developer authoring is a real use case — duplicating every schema field in a form is a large ongoing cost against a thin benefit.

### Rejected: modal configuration dialog on selection

A launch dialog was considered and rejected. Reasons: (1) it duplicates the JSON as a second source of truth and forces a decision on whether edits write back; (2) modal-per-selection is untenable friction for an action users take many times per session; (3) it implies a "launch" moment the architecture does not have. Per-session overrides, if ever needed, go behind a gear icon on the sidebar row clearly marked as session-only and non-persistent — not on the roadmap for v1.

### Rejected: hierarchical menu by category as primary surface

A category-indexed menu was considered and rejected as the *primary* selector. Reasons: (1) no `category` field in the `PromptAgent` schema, and adding one invites a taxonomy fight no one wins; (2) menu rows show name + icon only, which hides the metadata (description, requirements, tools) users actually need to choose; (3) menus are commands, not state — users lose track of what's currently selected. A command-palette launcher (`⌘⇧A`, fuzzy-searchable with inline metadata on focus) is a reasonable *additive* surface for power users with many agents; deferred until there are enough agents to justify it.

### PR-1-scope UI surface

Only these pieces land with PR 1 (no tool loop, no step trace to render):

1. **Sidebar agent picker** above the model picker. Current-conversation binding. Compatible / incompatible grouping with reason rows. Divider row on switch.

2. **Agents tab** after Models. Read-only inspector; sections by source; Open-in-Finder and Duplicate-as-user-agent actions. Reload button. No form editor.

3. **Agent attribution on assistant messages.** Small chip showing the producing agent's name on each assistant message. Redundant within a run of same-agent replies but correct across switches, and cheaper than scrolling to find the nearest divider row.

4. **Default handling.** The synthetic `DefaultAgent` appears in both the sidebar and the tab as "Default" in a separate top row / section, visually distinct from user-authored agents.

Everything else — step progress, tool-call rows, consent modal, disclosure groups for traces, budget banner, cancel-state variants — is undesigned on purpose and belongs to PR 2 when the loop actually runs. Designing loop UI against an imagined loop shape before the loop exists is how mockups diverge from implementation.

### Open UI questions (PR 2+)

- **Step progress indicator.** Counter badge (`3/10`), inline strip, or collapsible drawer? A progress bar overclaims — the budget is a ceiling, not a prediction. Lean counter.

- **Raw tool-call token leakage.** Parser runs every N=8 tokens, so partial `<tool_call>` syntax may render briefly before being swallowed. Hide-then-replace (feels glitchy) vs suppress-tail-speculatively (adds latency). Neither is clean; both are honest options.

- **Tool-row in-flight states.** Parsed-awaiting-consent, consented-running (needs spinner + elapsed time for long MCP calls), returned. Three distinct visual treatments required.

- **Copy / share granularity.** "Copy answer" and "Copy with trace" as two menu items rather than one ambiguous default.

- **Consent modal batching.** Even with per-turn allow, a planner-style agent that queues N reads up front could show one batch-approval modal. Requires loop lookahead that streaming autoregressive decode doesn't have today; file under "possible once planner agents exist."

## Concrete first PR (scope)

Agents ship **before** tool-calling. The personas path is useful on its own, sidesteps the template-family problem entirely, and makes the transcript-schema change small and reviewable.

1. Add `InferAgents` SwiftPM library target. No MLX/llama deps.

2. Define the `Agent` protocol, supporting types (`AgentContext`, `AgentRequirements`, `AgentMetadata`, `LoopDecision`), and `StepTrace` (only `.finalAnswer` emitted this PR).

3. Ship three built-in conformances: `DefaultAgent` (today's behaviour), `PromptAgent` (JSON-backed persona loaded from `~/Library/Application Support/Infer/agents/*.json`), and a stub `ToolAgent` with no registered tools (exercised in PR 2).

4. `AgentRegistry` actor: first-party conformances registered at launch, JSON personas discovered from disk, precedence rules enforced.

5. UI surface per the "PR-1-scope UI surface" subsection above: sidebar picker with per-conversation binding, Agents library tab after Models, agent-name chip on assistant messages, synthetic Default treatment. Selecting an agent routes through `Agent.decodingParams` and `Agent.systemPrompt` for the conversation.

6. `ChatMessage.steps: [StepTrace]?` added as nil-default optional. Also: `Conversation.agentId: AgentID?` so per-conversation agent binding persists.

7. Tests in `InferAgentsTests`:

   - `AgentProtocolTests` — default-hook behaviour on a minimal conformance; override composition.

   - `PromptAgentTests` — JSON round-trip, invalid-schema rejection, default-value backfill, bridging to the `Agent` protocol.

   - `AgentRegistryTests` — user-overrides-plugin-overrides-first-party precedence, id collision resolution.

   - `TranscriptMigrationTests` — old on-disk transcript decodes with `steps == nil`.

Out of PR 1: any tool calls, any loop steps, any MCP wiring, `AgentStateStore` (deferred until a concrete agent needs it), the `run` override path (the default implementation is the only path exercised).

## Subsequent PRs (roughly in order)

- **PR 2:** `ToolRegistry` + `BuiltinTool` protocol + two trivial built-ins (`clock.now`, `text.wordcount`). No MCP, no template parsing yet. Loop runs with `maxSteps: 1` — exactly one tool call per turn. Llama-only; Llama-3.1 template family only. This is the smallest slice that validates the full loop.

- **PR 3:** `ToolCallParser.qwen` + `.hermes`. Agent config can target any of the three.

- **PR 4:** `PluginHost` from `plugins.md` wired into `ToolRegistry`. Agents can reference MCP tools by name. Per-call consent UI.

- **PR 5:** Multi-step loop (`maxSteps > 1`). UI shows step progress. Per-turn "allow for this turn" consent.

- **PR 6 (speculative):** MLX tool-call support. Requires driving `generate(...)` directly instead of `ChatSession`, which is a research-project-shaped piece of work, not a reviewable PR — may never land. The product commitment is: on MLX, tool-requiring agents are hidden from the picker with a reason row ("MLX backend does not support tools"). That is the supported end state, not a transitional gap. If PR 6 ships, the filter relaxes; if it doesn't, MLX remains a tools-off backend indefinitely.

- **PR 7:** Persistent consent preferences; `autoApprove` editable in Settings.

- **PR 8:** Export/print includes the step trace behind a toggle.

## Anti-goals

- **No sub-agents.** "Agent calls agent" is a rabbit hole of recursion budgets, prompt injection vectors, and cross-agent state. If genuinely needed, model it as a tool that the outer agent calls, not as a first-class nesting relation.

- **No autonomous background agents.** Every step in Infer runs in response to a user turn. No cron-like agents, no "watch this folder," no long-running agent processes. If that's the feature, it is a different product.

- **No cross-turn agent memory beyond the transcript.** The transcript *is* the memory. An agent that wants more should write to a tool-backed store (MCP filesystem, a notes tool) and retrieve explicitly — which is debuggable and user-visible, unlike a hidden vector store.

- **No agent-authored model downloads.** An agent can *hint* at a preferred model; it cannot trigger a download. Model acquisition stays user-initiated.

- **No DSL for agent composition.** YAML pipelines, prompt graphs, LangChain-shaped chains — all out. An agent is one JSON file; a turn is one loop; if users want orchestration, they compose at the tool layer.

- **No mocking of tool results for "demo mode."** Tool results are real or the call didn't happen. Anything else rots the transcript as a debugging artefact.

## Decisions (previously open)

- **Template-family detection: fingerprint, fail loud.** A fingerprint table over the GGUF's embedded Jinja template classifies into `{llama3, qwen, hermes, openai, unknown}`. Agents declare a required family in `AgentRequirements.templateFamily`; on mismatch at activation, the agent picker refuses selection and surfaces the conflict with a "use plain chat (no tools)" override. Covered in constraint 3.

- **Agent switching mid-session: inherit transcript, divider row.** `LlamaRunner` re-renders from scratch under the new system prompt (discarding `prevFormattedLen`); `MLXRunner` takes the same `ChatSession` reset it already takes on `systemPrompt` change. Revisit when MLX leaves `ChatSession` (post-PR-6).

- **Step-budget semantics: hard stop, visible banner.** On `budgetExceeded` the turn ends without a "wrap up" decode pass, and the transcript gains a banner row ("step budget exhausted; N/M tool calls used"). A wrap-up pass is prompt engineering that doesn't generalise across model families, and a silent end leaves the user guessing why the assistant stopped mid-thought.

- **`AgentStateStore` scope: turn-scoped only, no session scope.** Session-scoped agent state is in direct tension with the "transcript is the memory" anti-goal — it would introduce a hidden, non-user-visible store whose contents shape future turns. Agents that want continuity must round-trip through the transcript or through a tool-backed store (MCP filesystem, notes tool). This is a scope decision, not a deferral: session-scoped state is not on the roadmap.

- **"Default" agent: synthetic in PR 1, materialised when PR 2 lands `ToolAgent`.** Synthetic derivation from `InferSettings` is cheapest now; the materialised JSON becomes the reference persona example once user-authored agents are a real thing to compare against.

## Open questions

- **MLX steady state.** PRs 1–5 ship llama-only agents with tools. PR 6 (MLX tool-call support, requires dropping `ChatSession` or reaching under it) is open-ended enough that "MLX backend: tools not supported" is best treated as a supported steady state for the MLX picker rather than a transitional embarrassment. Confirm messaging in the UI: agent picker filters out tool-requiring agents when MLX is active, and the reason row explains why.

- **Structured tool output.** MCP tools can return structured content (not just text). v1 flattens to text before the model sees it. Is there value in exposing the structure to the renderer (e.g. table results rendered as tables)? Defer until a tool actually exercises this.

- **Consent-fatigue path from day one.** Per `plugins.md`'s own open question, per-call prompts collapse under any agent that reads three files. The first UI pass should include a per-turn "allow this tool for this turn" affordance even though persisted preferences land later (plugins.md PR 4 / agents PR 7). Tracking here because the agent loop is what surfaces the modal; scope lives in `plugins.md`.

## Appendix: agent patterns in circulation

Reference material for where Infer's design sits in the broader landscape. These are design patterns, not a standards list — naming varies by paper/framework, and real systems usually blend several. Infer's default loop is a ReAct-style single-agent loop with tool-use fine-tuning; the `Agent.run` escape hatch (see protocol sketch above) is the seam where other patterns can be experimented with without rewriting the substrate.

### Loop / control patterns

- **ReAct** (Yao et al., 2022 — [arxiv:2210.03629](https://arxiv.org/abs/2210.03629)). Interleaves `Thought → Action → Observation` in one decode. Model writes a rationale, emits a tool call, reads the result, continues. Default "tool-calling agent" in most frameworks. Cheap (one loop, one template) and prone to rationalisation: the written "Thought" can drift from the actual next Action.

- **Plan-and-Execute / Plan-Solve** (Wang et al., 2023). Two-phase: a planner decode produces an ordered subtask list; an executor loop works through them, optionally re-planning. Less token-efficient than ReAct, more robust on multi-step tasks because the plan is explicit and auditable. Variants: BabyAGI, LangGraph planner subgraphs.

- **Reflexion** (Shinn et al., 2023 — [arxiv:2303.11366](https://arxiv.org/abs/2303.11366)). Agent runs a trajectory; a separate critic reads trajectory + outcome and writes a self-critique into a memory buffer that conditions the next attempt. Works where there is a terminal success/fail signal (code, games). Not useful for open-ended chat.

- **Tree-of-Thoughts / LATS** (Yao 2023; Zhou et al., 2023). Branches the ReAct loop into a tree with a value function to prune. Much more compute; sometimes better on puzzle-style tasks. Rarely pays for itself in production.

- **CodeAct** (Wang et al., 2024 — [arxiv:2402.01030](https://arxiv.org/abs/2402.01030)). Tools are exposed as a Python REPL rather than discrete JSON calls. Model emits code; sandbox executes; stdout feeds back. Collapses "many tools" into "one tool (exec)" and leverages the model's code training. Used by Claude computer-use, OpenDevin, and Manus-style agents.

### Memory / state patterns

- **Transcript-as-memory.** No state beyond chat history. Simplest and debuggable — what Infer commits to (anti-goal: no cross-turn memory beyond the transcript).

- **Scratchpad / working memory.** Hidden text buffer the agent reads/writes each turn. Easy to build, hard to keep faithful: content drifts, tokens accumulate.

- **Retrieval-augmented (RAG agents).** External vector/keyword store; a `search` tool retrieves chunks into context. Closer to a tool pattern than an agent pattern — any loop shape can use it.

- **Structured memory** (MemGPT / Letta, Generative Agents — Park et al. 2023). Typed memory with explicit read/write ops: "core memory," "archival memory," "summaries." Worth it given a clear schema; premature otherwise.

### Coordination patterns

- **Single agent with tools.** What Infer is designing.

- **Orchestrator + workers (supervisor / sub-agent).** One agent delegates turns to specialists. LangGraph supervisors, OpenAI Swarm, AutoGen GroupChat manager. Explicitly rejected as a first-class feature in the Anti-goals — if genuinely needed, modelled as a tool call, not a nesting relation.

- **Peer-to-peer multi-agent.** Agents message each other freely (AutoGen, CAMEL). Demos well; hard to reason about failure modes. Almost always worse than a single agent with the union of capabilities.

- **Role-play / debate.** Two or more agents argue and a judge picks. Mostly a benchmark-gaming technique; users don't want to read a debate.

### Policy / decision patterns

- **Tool-use fine-tuned models.** "Function calling" post-trained into the weights (OpenAI tools, Anthropic tool use, Llama 3.1 `<|python_tag|>`, Qwen `<tool_call>`, Hermes XML). Loop shape is ReAct-ish but tool-call syntax is templated rather than prompt-engineered. This is what Infer's template-family detection is selecting for (constraint 3).

- **Constrained decoding / grammar-guided** (Outlines, Guidance, llama.cpp grammars). Tool-call syntax is enforced at decode time via a JSON-schema or CFG-constrained sampler. Orthogonal to loop shape — any pattern above can use it. Candidate for a future hardening pass once the fingerprint-based detection proves unreliable at the edges.

- **Policy-gradient / RL-trained agents** (WebGPT, SWE-RL). Not built at inference time; these are training artefacts. Out of scope for a local-inference app.

### Contract Net (classical, often confused)

Contract Net Protocol (Smith, 1980 — pre-LLM classical DAI / FIPA): a manager broadcasts a task spec, worker agents bid, the manager awards, the worker reports. It is a **coordination** pattern for multi-agent systems, not an LLM loop shape. The name is sometimes reused loosely in LLM-era work for "declare a schema and call a tool that satisfies it," but that is a rebrand of structured tool-calling, not the original protocol. Noted here because the question comes up.

### What actually ships

Production LLM agents today are overwhelmingly ReAct-style single-agent loops with tool-use fine-tuning, optionally wrapped in a Plan-Execute outer loop for long tasks, and optionally CodeAct-style (exec as the tool) for coding / computer use. The rest is niches or active research. For Infer, the ReAct-style single-agent-with-tools loop is the correct default; `Agent.run` exists so a Plan-Execute or CodeAct-shaped agent can be built as a conformance without changing the substrate.
