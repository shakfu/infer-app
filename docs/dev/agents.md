# Agent architecture

Status: proposal. Nothing in this document is implemented. Companion to `plugins.md`: that doc specifies how tools and MCP servers plug in; this one specifies what an *agent* is and how the tool-calling loop runs.

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
3. **Tool-call format is model-specific.** GGUF chat templates encode their own tool-call conventions (Llama 3.1 `<|python_tag|>`, Qwen `<tool_call>`, Hermes XML, etc.). An agent must declare a template family; if the loaded model's template doesn't match, tool calling is disabled for that agent (logged, not errored) and the agent degrades to plain chat.
4. **Cooperative cancellation only.** The existing `CancelFlag` in `LlamaRunner` only honours cancellation at await points. A multi-step loop must surface a stop request at three places: during decode (already handled), between steps (new), and during an in-flight MCP tool call (new — possibly `Process.terminate()`). None of this blocks the C decode loop.
5. **Agents are code, not just config.** The extension point is a Swift protocol. Custom agents can build the system prompt dynamically, filter tools per-turn, transform tool results, maintain agent-local state, and override the loop itself when the default shape doesn't fit. A JSON-backed "persona" implementation exists as a convenience for the simple case, but it is one concrete type conforming to the protocol — not the substrate. Determinism is a property of a given implementation, not a system-wide guarantee.
6. **Swift 6 concurrency-clean.** `Infer` is still on `.swiftLanguageMode(.v5)` (TODO.md P2). New agent/plugin code lands Swift-6-safe so the opt-out can be dropped.
7. **No commits from the assistant.** Per project rules.

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

- `AgentContext` — read-only handle passed to every hook: the active runner, the tool registry (already filtered by the plugin-level consent layer), the transcript so far, the step counter, agent-local state storage (`AgentStateStore`, scoped to the turn by default; opt-in to session-scoped).
- `AgentRequirements` — `backend: BackendPreference`, `templateFamily: TemplateFamily?`, `minContext: Int?`, `toolsAllow: [ToolName]`, `toolsDeny: [ToolName]`, `autoApprove: [ToolName]`.
- `AgentMetadata` — `name`, `description`, optional `icon`, optional `author`.
- `LoopDecision` — `.continue` / `.stop(reason)` / `.stopAndSummarise`.
- `ToolSpec`, `ToolCall`, `ToolResult` — shared with `plugins.md`.

### Built-in implementations

`InferAgents` ships a handful of conformances that cover the common shapes without writing code:

- `PromptAgent` — JSON-backed persona. Reads a JSON file, conforms to `Agent` with static implementations of every hook. This is the "persona pack" case. Users and plugins can author these without touching Swift.
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

## Concrete first PR (scope)

Agents ship **before** tool-calling. The personas path is useful on its own, sidesteps the template-family problem entirely, and makes the transcript-schema change small and reviewable.

1. Add `InferAgents` SwiftPM library target. No MLX/llama deps.
2. Define the `Agent` protocol, supporting types (`AgentContext`, `AgentRequirements`, `AgentMetadata`, `LoopDecision`), and `StepTrace` (only `.finalAnswer` emitted this PR).
3. Ship three built-in conformances: `DefaultAgent` (today's behaviour), `PromptAgent` (JSON-backed persona loaded from `~/Library/Application Support/Infer/agents/*.json`), and a stub `ToolAgent` with no registered tools (exercised in PR 2).
4. `AgentRegistry` actor: first-party conformances registered at launch, JSON personas discovered from disk, precedence rules enforced.
5. Sidebar: agent picker above the model picker. Selecting an agent routes through `Agent.decodingParams` and `Agent.systemPrompt` for the session.
6. `ChatMessage.steps: [StepTrace]?` added as nil-default optional.
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
- **PR 6:** MLX tool-call support (requires driving `generate(...)` directly rather than `ChatSession`; non-trivial). Until this lands, agents with `backend: "mlx"` and non-empty `tools.allow` are rejected with a clear error.
- **PR 7:** Persistent consent preferences; `autoApprove` editable in Settings.
- **PR 8:** Export/print includes the step trace behind a toggle.

## Anti-goals

- **No sub-agents.** "Agent calls agent" is a rabbit hole of recursion budgets, prompt injection vectors, and cross-agent state. If genuinely needed, model it as a tool that the outer agent calls, not as a first-class nesting relation.
- **No autonomous background agents.** Every step in Infer runs in response to a user turn. No cron-like agents, no "watch this folder," no long-running agent processes. If that's the feature, it is a different product.
- **No cross-turn agent memory beyond the transcript.** The transcript *is* the memory. An agent that wants more should write to a tool-backed store (MCP filesystem, a notes tool) and retrieve explicitly — which is debuggable and user-visible, unlike a hidden vector store.
- **No agent-authored model downloads.** An agent can *hint* at a preferred model; it cannot trigger a download. Model acquisition stays user-initiated.
- **No DSL for agent composition.** YAML pipelines, prompt graphs, LangChain-shaped chains — all out. An agent is one JSON file; a turn is one loop; if users want orchestration, they compose at the tool layer.
- **No mocking of tool results for "demo mode."** Tool results are real or the call didn't happen. Anything else rots the transcript as a debugging artefact.

## Open questions

- **Template-family detection.** GGUF chat templates are free-form Jinja; reliably recognising "this is Llama 3.1" probably needs a fingerprint table. How does `AgentRegistry` warn the user when the active model doesn't match the agent's declared `templateFamily`? Silent degradation (tools unavailable) or hard error at agent-activation time?
- **Agent switching mid-session.** If the user switches agents mid-conversation, does the new agent inherit the transcript or start fresh? "Inherit" is less surprising but risks feeding system-prompt assumptions of agent A into agent B's first reply. Leaning inherit, with a visible divider row in the transcript.
- **Decoding-param overrides and MLX.** `MLXRunner` rebuilds `ChatSession` when `systemPrompt`/`temperature`/`topP` change, losing history. Agent switching would trigger the same reset. Acceptable for v1; revisit when MLX tool-calling lands (PR 6), at which point `MLXRunner` likely has to drop `ChatSession` anyway.
- **Where does the "Default" agent live?** Synthetic (derived from `InferSettings` at load) or materialised (a real JSON file shipped with the app)? Synthetic is less code now; materialised is a cleaner mental model once user-authored agents exist. Default to synthetic for PR 1, reconsider at PR 2.
- **Structured tool output.** MCP tools can return structured content (not just text). v1 flattens to text before the model sees it. Is there value in exposing the structure to the renderer (e.g. table results rendered as tables)? Defer until a tool actually exercises this.
- **Step-budget semantics.** On `budgetExceeded`, does the assistant get one final "wrap up what you have" decode pass, or does the turn just end? Leaning final pass with a marker system message ("You have used all tool calls; answer from what you have."), but that is itself a prompt-engineering choice that may not hold across model families.
