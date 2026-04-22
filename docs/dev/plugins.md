# Plugin system

Status: proposal. Nothing in this document is implemented. The sketch is deliberately scoped small — the first milestone is a single working tool call, not an extension marketplace.

## What a "plugin" means here

A plugin is a **unit of extensibility**: a packaging boundary that can bundle agents, tools, MCP servers, and (eventually) UI extensions. See `agents.md` for the agent side of this.

**All plugins are implemented internally — compiled into Infer from the source tree.** There is no dynamic loading, no third-party distribution, and no third-party trust tier. The plugin boundary exists for modularity (cohesive units of extension, separable for review and opt-out) and optionality (users enable only what they want), not for sandboxing untrusted code.

A plugin may ship any combination of:

| Kind                       | Example                                      | v1?                                                     |
| -------------------------- | -------------------------------------------- | ------------------------------------------------------- |
| Agents                     | a "research assistant" persona or code-backed agent | Yes. See `agents.md`.                            |
| **Tools (MCP server)**     | filesystem, web fetch, git                   | **Yes — primary focus of this document.**               |
| Tools (built-in Swift)     | `clock.now`, `calc.eval`                     | Yes, as needed by first-party agents.                   |
| Inference backends         | a third runner alongside Llama/MLX           | No. Runners intentionally do not share a protocol today. |
| UI / transcript extensions | custom renderers, export formats             | No. Additive but low-value; revisit later.              |

MCP subprocess servers are retained as a plugin shape **not because the code is untrusted** — it isn't; it's in-tree like everything else — but because:

1. It gives us access to the MCP ecosystem (filesystem, git, browser, many SaaS servers) without reimplementing each one in Swift.
2. Process isolation means a crashing tool doesn't take down Infer.
3. The stdio transport is a clean boundary for testing and observability.

The rest of this document focuses on the MCP-server path, since built-in Swift tools are comparatively trivial (a protocol conformance, registered with `ToolRegistry`).

## Why MCP rather than a bespoke protocol

- **Ecosystem.** Filesystem, git, shell, browser, and many SaaS servers already exist. Re-inventing the protocol means re-inventing those too.
- **Transport is solved.** MCP over stdio is a well-specified JSON-RPC variant. No TCP ports, no auth bootstrap, no sandbox transport to design.
- **Consent model is explicit.** MCP's per-tool invocation boundary maps cleanly onto a user-confirmation UI. Even though the server code is first-party, individual tool calls still have real-world effects (filesystem writes, network fetches) that the user should authorise per call.

The cost: Infer must implement a tool-calling loop in both runners, and the two runners have very different ergonomics for this (see constraints below).

## Constraints shaping the design

1. **Two runners, different tool-call surfaces.** `MLXRunner` delegates to `MLXLMCommon.ChatSession`, which does not currently expose a tool-call callback — hijacking the token stream to detect a tool-call tag is the practical path. `LlamaRunner` already hand-renders the chat template and consumes deltas; injecting a tool-call parse step into the existing loop is straightforward. Expect feature parity to lag: **`LlamaRunner` gets tool calls first.**
2. **Chat templates vary by model.** Tool-calling formats (OpenAI-style `<tool_call>` JSON, Llama 3.1 `<|python_tag|>`, Qwen `<tool_call>`, Hermes XML) are model-specific. The chat template embedded in the GGUF dictates the wire format. The plugin layer must be template-aware or restrict itself to models whose template Infer recognises.
3. **Subprocess lifecycle mirrors the runner lifecycle.** MCP servers are long-lived stdio subprocesses. They must be shut down in the same `applicationWillTerminate` path that already drains the runners (see `CLAUDE.md` "Critical lifecycle detail"). A leaked server process after app quit is a bug.
4. **Single-user desktop, not multi-tenant.** Every tool runs as the current user with the current user's permissions. The consent layer is about *user intent* (did you mean to write this file?) rather than *code trust* (is this plugin safe?) — since all plugin code is first-party, the latter is a code-review question, not a runtime one.
5. **Swift 6 concurrency.** New code lands Swift-6-clean so the existing `.swiftLanguageMode(.v5)` opt-out on `Infer` can still eventually be dropped (TODO.md P2).
6. **No commits from the assistant.** Per project rules, scaffolding is authored here but committed by the user.

## Architecture sketch

```
ChatViewModel
    |
    +--> LlamaRunner / MLXRunner      (existing actors)
    |       ^
    |       | tool results injected back as a synthetic "tool" turn
    |       |
    +--> PluginHost   actor           <-- owns all MCP clients
             |
             +--> MCPClient (stdio)   <-- one per configured server
             +--> MCPClient (stdio)
             +--> ...
```

New types (all in a new `InferPlugins` SwiftPM target — pure Swift, no MLX/llama deps, testable under Tier 1):

- `PluginManifest` — decoded from `~/Library/Application Support/Infer/plugins.json`. Each entry: `name`, `command`, `args`, `env`, `enabled`, `autoApprove: [toolName]`.
- `MCPClient` — owns a `Process`, two `Pipe`s, and a JSON-RPC framing layer. Exposes `listTools() -> [ToolSpec]`, `call(tool:args:) -> ToolResult`, `shutdown()`.
- `PluginHost` — actor; aggregates `MCPClient`s, deduplicates tool names across servers (`server/tool` naming on collision), gates each call through a `ConsentPolicy`.
- `ConsentPolicy` — pure struct: given `(serverName, toolName, argsHash)` returns `.allow`, `.prompt`, or `.deny`. Backed by the manifest's `autoApprove` plus a per-session remember-my-choice map.
- `ToolCallParser` — pure parser: given a runner's streamed text and a template family (`llama3`, `qwen`, `hermes`, `openai`), emits `ToolCall` structs or passes text through. One parser per family; Infer's default is "none" (tool calls disabled) when the template is unrecognised.
- `ToolCallInjector` — formats a `ToolResult` back into the template's expected format and hands it to the runner as the next user-visible-but-role-tagged turn.

### Wire flow (happy path, LlamaRunner)

1. User sends a message. `LlamaRunner` renders the template, appends active tool specs from `PluginHost` into the system prompt (template-specific section), decodes.
2. As tokens stream, `ToolCallParser` watches the tail. On a complete tool-call tag, it pauses the stream (the existing `CancelFlag` mechanism; we add a non-error "paused" state) and emits the parsed call upward.
3. `PluginHost` checks consent. If `.prompt`, the UI shows a modal with `(server, tool, args)` and an "allow once / allow always / deny" triad. If `.deny`, a synthetic error result is injected.
4. `MCPClient.call(...)` runs the tool. Result is normalised to text.
5. `ToolCallInjector` appends the tool turn to the runner's message buffer and resumes decoding. The model sees its own tool call followed by the tool result and continues generating.

MLXRunner support is deferred until the above shape is validated; when it lands it will likely require either forking `ChatSession` or reaching under it to drive `generate(...)` directly.

## Consent model

Plugin code is first-party. The consent layer is about *user intent*, not code trust: the model is an unreliable agent inside a trusted app, and real-world side effects need human authorisation.

- **Default-disabled.** Plugins start disabled. The user opts in per plugin in Settings → Plugins.
- **Per-tool consent.** Every call prompts unless the user has ticked "always allow this tool for this plugin". Consent is scoped to `(plugin, tool)`.
- **Argument preview.** The consent prompt shows the full JSON arguments. No truncation — if they don't fit, the user scrolls. Hiding args to fit a dialog is how you trick users into approving `rm -rf $HOME`.
- **Tool output is model-visible input.** Tool results are rendered in the transcript with the same escaping the assistant channel already uses. Do not interpret tool output as Markdown until we are sure the renderer cannot execute arbitrary links/iframes. (`swift-markdown-ui` is generally fine, but re-check when wiring this.) Remember: the point of escaping is not to defend against the tool, it's to defend against a malicious *document the tool fetched* trying to inject instructions into the model.

## Concrete first PR (scope)

Keep the first plugin PR small enough to review in one sitting. It lands a working end-to-end path for **one** server, **one** template family, **one** runner.

1. Add `InferPlugins` SwiftPM library target. No MLX/llama dependencies.
2. Implement `MCPClient` over stdio (`Process` + `Pipe` + `JSONDecoder`). Support `initialize`, `tools/list`, `tools/call`, `shutdown`. Skip resources, prompts, sampling for now.
3. Implement `ToolCallParser.llama3` only. Gate the feature to models whose template string matches a known Llama 3.1 signature; otherwise tools are silently unavailable (logged, not errored).
4. Wire `PluginHost` into `ChatViewModel` and extend `LlamaRunner` with a tool-call hook. MLXRunner gains a stub that says "tools not yet supported on MLX" in logs.
5. Ship a hard-coded single-plugin demo: the reference MCP filesystem server pointed at `~/Desktop` only. No UI for adding plugins yet.
6. Consent UI: a single `Alert` with `(server, tool, args)` and allow/deny. No "always allow" persistence yet.
7. Tests in `InferPluginsTests`:
   - `MCPClientTests` — spawn a trivial Swift fixture process that speaks MCP; assert list/call/shutdown round-trips.
   - `ToolCallParserTests` — golden-file test: streamed Llama 3.1 output with and without a tool call.
   - `ConsentPolicyTests` — decision table.
8. Lifecycle: extend `AppDelegate.applicationWillTerminate` to drain `PluginHost.shutdown()` before the existing runner shutdown. Budget: 500 ms on top of the existing 2 s.

Out of PR 1: plugin discovery UI, manifest editing, MLX support, additional template families, persistent consent, resources/prompts/sampling support, tool-result Markdown rendering.

## Subsequent PRs (roughly in order)

- **PR 2:** Settings → Plugins pane. Add / remove / enable / disable servers. Manifest persistence. `autoApprove` list editable per server.
- **PR 3:** `ToolCallParser.qwen` and `.hermes`. Template detection matrix.
- **PR 4:** Persistent consent (`allow always` for `(server, tool)` → manifest).
- **PR 5:** MLX tool-call support. Either upstream a `ChatSession` hook or drop to `generate(...)` inside `MLXRunner`.
- **PR 6:** MCP `resources/` support — let servers expose documents the user can `@mention` into a turn. This is where the transcript UI starts to change shape.
- **PR 7:** MCP `sampling/` support — servers can call back into the model. Requires a recursion budget and a separate consent lane ("server wants to ask the model N tokens about X"). Defer until a concrete use case appears.

## Anti-goals

- **No dynamic plugin loading (for now).** Swift *can* do this — `Bundle.load()`, ABI stability since 5.0, module stability via `.swiftinterface`. The blocker isn't technical feasibility; it's the cost/benefit. Dynamic loading requires:
  - Compiling `InferAgents` / `InferPlugins` with `-enable-library-evolution` (resilient ABI, small runtime cost, stricter rules on what changes are breaking).
  - Freezing the `Agent` / `Tool` / `ToolSpec` surface as a public API contract — every future tweak becomes a compatibility event.
  - A signing/notarisation story for third-party plugin authors, or weakening the hardened runtime via `com.apple.security.cs.disable-library-validation`.
  - Accepting that a loaded dylib shares Infer's crash domain and full entitlements, with no OS-enforced sandbox — the consent layer is the only boundary.

  None of this is hard. All of it is premature: there are no third-party plugins, the `Agent` protocol is weeks old, and the subprocess/MCP path already covers ecosystem-sourced tools with OS process isolation for free. Revisit when a concrete third-party plugin exists and its author is asking for this.
- **No third-party plugin distribution.** Not a marketplace, not a `plugins.json` pointing at random binaries. Contributions happen via the repo.
- **No cross-platform plugin API.** Infer is macOS-only; the plugin API can assume POSIX pipes and `Process`.
- **No abstraction over MCP.** If MCP changes, we change with it. Wrapping it in an Infer-flavoured protocol just to "keep options open" adds maintenance without buying anything.
- **Do not make tool calls the default.** A user with no plugins enabled must see zero behavioural change — no extra system-prompt text, no latency, no UI affordance.

## Open questions

- **Template detection reliability.** GGUF chat templates are free-form Jinja. Matching "this is Llama 3.1" robustly probably needs a small fingerprint table rather than a regex. How many false positives can we tolerate before tool calls go to a model that will happily hallucinate the syntax?
- **Streaming UX during a tool call.** The assistant pauses mid-stream while the tool runs. Show a spinner? Show the parsed call? Collapse the raw `<tool_call>` tokens retroactively once the call completes? First PR will do the simplest thing (show a placeholder row) and iterate.
- **Cancellation during a tool call.** The user hits stop while an MCP call is in flight. Do we kill the subprocess (`Process.terminate()`), or wait for the current call to return and drop the result? Leaning terminate, but only after the call has been running longer than some threshold.
- **Consent fatigue.** If a model calls `read_file` twenty times in a turn, twenty prompts is unusable. A per-turn "allow for this turn" option is probably needed by PR 4.
- **Who owns the MCP client code long-term?** If an official `swift-mcp` library appears, delete ours and depend on it. Until then, the in-tree implementation is the minimum viable subset, not a general-purpose SDK.
