
## P1 — RAG quality

Hybrid retrieval (vector + FTS5 + RRF), HyDE query reformulation, and cross-encoder reranking all shipped — see CHANGELOG. Remaining quality work:

## P1 — Reasoning model handling

Reasoning models (Qwen-3, DeepSeek-R1, etc.) emit `<think>…</think>` blocks that count as real tokens against `maxTokens`, the KV cache, and `generationTokenCount`. The visible reply is stripped via `ThinkBlockStreamFilter` (already shipped) and rendered behind a collapsible disclosure, but the underlying token accounting still includes the thinking content. These items address that asymmetry.

## P2 — Agent tool surface

Tools the chat-VM's `ToolRegistry` doesn't expose yet but should. Distinct from the agents subsystem follow-ups (P3) — those are about the loop / planner / composition machinery; these are concrete tool wrappers around capabilities the app already has internally. Agents only get value from tools that exist; each entry below has a directly attributable user payoff. Ordered roughly by leverage / implementation-cost ratio.

## Deferred — agent tool requests (intentionally not implemented)

Tool ideas evaluated and parked. Each has a real use case but the trade-offs land outside this app's design space. Documented here so they don't get re-proposed without the trade-off being re-checked against current state.

- **`shell.run` / `code.run.swift`.** Powerful, but the security model collapses into "user trusts the LLM" — there's no defensible allowlist scope between "useless" and "everything." MCP servers (e.g. `mcp-server-shell`) handle this through their own per-server consent layer, which is the better fit: the user explicitly opts in to a specific server, the server defines its own restrictions, and the per-server consent gate (already in place — see `MCPApprovalStore`) is the choke point. Same reasoning applies to `code.run.swift`: a real sandbox story for arbitrary Swift execution is hard, and "run untrusted code" is exactly the workflow MCP exists for.

- **`screenshot.take` / `image.ocr` / `image.describe`.** Vision-LLM territory. The clean version is "the model sees the image directly" via a vision-capable MLX model, not three separate tools that pretend the model can't. When a vision-capable model is loaded, the app should pass image attachments straight through to the runner instead of going through OCR / description tools. Tool-shaped wrappers for these would be a permanent compromise — re-evaluate if/when image attachments become a first-class chat input.

- **`calendar.events` / `reminders.list` / `notes.search`.** EventKit / NotesKit have nontrivial permission flows (TCC prompts, security-scoped resources) and Notes' database is private API. The same surface is reachable through MCP servers a user can opt into (e.g. an EventKit-backed MCP server in their own process), which keeps the permission grant scoped to the server rather than the whole app. Don't bake into the tool registry.

## P3 — Agents subsystem follow-ups

Consolidated and prioritised list of outstanding work on the agents subsystem (formerly tracked in `REVIEW.md`, now deleted — CHANGELOG.md has the per-change history of what shipped). Items are in priority order; each is independently shippable, and most are deferred pending real usage signal rather than blocked on technical work.

1. **Per-call human-in-the-loop approval gate.** Composition primitive (`gate` plan node) for tools that need explicit confirmation regardless of source. The MCP per-server consent gate covers "should this server launch at all?"; a `gate` would cover "should this specific call go through?" — pressing because MCP servers can call out to anything the user can, and write-side tools (filesystem write, GitHub create-issue) are sensitive even from approved servers. Design depends on observing how people actually use MCP in practice — what counts as sensitive depends on workflow.

2. **Branching / parallel plans.** `PlanLedger` is currently a flat ordered list. Lift to a DAG (each step has zero-or-more dependencies), execute independent steps concurrently via `TaskGroup`, gate on dependency completion. Final synthesis collects all leaf outputs. Big lift on the executor side; the prompt protocol also has to teach the model to emit a structured plan (probably JSON) instead of a numbered list.

3. **MCP resources capability.** Servers expose readable URIs (`resources/list`, `resources/read`, `resources/subscribe`). Map onto the existing `Retriever` shape — an MCP resource list can be one source feeding `AgentContext.retrieve` alongside the local vault. Decode `Resource` + `ResourceContent` shapes (text + blob), extend `MCPClient` with `listResources` / `readResource`, and add a `MCPResourceRetriever` adapter. Subscriptions can come later; one-shot reads cover most cases. The inbound-request dispatcher in `MCPClient` is the layer.

4. **MCP prompts capability.** Servers expose curated prompt templates (`prompts/list`, `prompts/get`). Most useful as an authored-prompts surface in the Agents tab — let a user pick "summarise email thread" from a Slack MCP server's prompt library and have it composed into the agent's system prompt at activation time. Schema is small; UI is the bulk of the work.

5. **MCP sampling capability.** Servers can request the host run an LLM decode on their behalf (`sampling/createMessage`) — used by servers that want to chain their own completions through the user's local model rather than spinning up their own. Extend `MCPClient` to handle the inbound request, route through the active `AgentRunner`, return the completion. Permission model: each sampling request needs explicit user approval (the server is asking the host to spend tokens on its behalf), so this depends on per-server consent + ideally the per-call gate above.

6. **MCP HTTP / WebSocket transports.** Stdio is fine for local desktop servers; HTTP/SSE and WebSocket (per the MCP HTTP transport spec) cover hosted servers and dev workflows where a server runs on a different machine. Implement two new `MCPTransport` conformances; `MCPClient` consumes them unchanged. Configuration layer needs `transport: "stdio" | "http" | "websocket"` discriminator on `MCPServerConfig` plus URL + auth fields for the network variants.

7. **MCP server hot-reload.** Today `MCPHost.bootstrap` runs once at app start; the in-app UI's `Reload` button is the only way to pick up edits. Watch the mcp directory with `DispatchSourceFileSystemObject`, diff registered server IDs against the new file set, gracefully shut down removed servers and launch added ones. The `ToolRegistry.unregister(prefixed:)` API needed for clean tool sweeps already exists.

8. ~~**Sub-agent dispatch from a planner step.**~~ **Superseded** by the `delegate` composition primitive shipped 2026-05-09 (`CompositionPlan.delegate`, see `agent_composition.md` §6 and `agent_delegate.md`). Top-level multi-hop LLM-driven dispatch is now a first-class plan shape via `agents.invoke`; the synthetic `Auto` picker entry uses it. The "planner-as-controller" variant — a `PlannerAgent` step that routes to a peer mid-plan — is still possible but no longer the only path; whether to expose it depends on real usage signal showing that planner-internal dispatch differs meaningfully from a top-level `delegate` plan.

9. **JSON-backed planner schema (`PromptAgent` extension).** Right now `PlannerAgent` is a Swift conformance instantiated by the host. A schema-v4 `PromptAgent` variant could declare `kind: "planner"` plus knobs (`maxStepDecodes`, `maxReplans`, an authored planning prompt) so users can ship custom planners without touching Swift. Trade-off: making the policy hot-editable trades against the readability of a typed Swift conformance — wait until two or three real custom planners exist before committing to a wire format.

10. **Coverage for under-exercised `Agent` hooks.** A test conformance that overrides `transformToolResult` and dynamic per-context `systemPrompt` would close the coverage gap. `customLoop` is exercised by `PlannerAgent` and `DeterministicPipelineAgent`; `shouldContinue` has unit tests but no non-default conformance. ~half a day; pure test work.

11. **MCP live-launch smoke test.** CI exercises `StdioMCPTransport` only via `MockMCPTransport`. A tiny in-tree echo server (Swift script, ~50 lines) launched as a real subprocess in one integration test would catch transport-level regressions (NDJSON framing, EOF handling, stderr drain) the mock can't. Skip in CI by default if `gh` runners flake on subprocess spawning.

## P3 — Swarm-inspired borrowings

Triggered by an audit of [christopherkarani/Swarm](https://github.com/christopherkarani/Swarm) (Swift agent-orchestration framework). See `docs/dev/agents.md` §"Coordination patterns" for the comparison; these are the individual ideas worth picking up as their respective subsystems get touched. Not a migration plan — Infer's design centre is different and the platform floor doesn't match — just cherry-picks.

1. **`@Tool` macro for compile-time tool-spec generation.** Today `BuiltinTool` conformances hand-author a `ToolSpec` next to each tool, with the JSON schema described in prose in the `description`. Swarm's `@Tool` / `@Parameter` macros generate `ToolSpec` from the Swift struct's stored properties at compile time, so `description` is the only authored field and renames stay in sync. Cost: a small `SwiftSyntax` macro module; the existing `BuiltinTool` protocol stays as the runtime contract, the macro just synthesises the `var spec` getter. Worth it once we hit ~20 hand-authored tools (currently ~15 + plugin tools); also enforces tighter coupling between argument decoding and the schema the model sees, removing a class of "schema says X but invoke parses Y" bugs.

2. **Unified `InferenceProvider` abstraction across runners.** Today `LlamaRunner` (actor wrapping llama.cpp), `MLXRunner` (actor wrapping mlx-swift-lm), and the cloud paths (Anthropic / OpenAI / OpenAI-compatible) diverge enough that `CLAUDE.md` explicitly notes a protocol abstraction would leak — `load(...)` takes a local `.gguf` path on llama vs an HF repo id on MLX, and the cloud paths don't load anything at all. Swarm collapses these behind one `inferenceProvider:` parameter (`.foundationModels()`, `.anthropic(key:)`, `.ollama(model:)`, etc.) at the cost of accepting some leakiness. Worth revisiting after the Swift 6 strict-concurrency migration (P2 below) — that work touches every runner anyway, and a thin per-call protocol (just `complete(messages:tools:settings:) -> AsyncThrowingStream<Token>` plus `transformToolResult`) would let composition / agent code stop branching on `Backend` everywhere. Don't try to unify `load(...)` — that's where the leakiness actually lives; protocolise the per-turn surface only.

3. **Durable workflow / composition checkpointing for crash recovery.** Swarm's `.durable.checkpoint(id:policy:)` + filesystem checkpoint store lets a workflow resume after a process crash from the last completed step. Infer composition runs are entirely in-memory today — a crash mid-`chain` or mid-`delegate` loses every segment that completed. Useful for long-running compositions (research-then-draft-then-review pipelines that take minutes), less useful for the typical chat turn. Implementation: serialise `CompositionResult.segments` + `budget` + the in-flight router scratchpad to a JSON file under `~/Library/Application Support/Infer/composition-checkpoints/<turn-id>/` after each segment; on app launch, expose "Resume crashed turn" if any checkpoints remain. Gate behind a per-composition opt-in (`PromptAgent.budget.checkpoint: true`) so the default path stays cheap.

4. **Markdown-first agent / persona authoring (`AGENTS.md` + `agents/<id>.md`).** Swarm authors agents as markdown files with frontmatter for the structured fields. Infer's JSON personas already accept a markdown sidecar via `contextPath` (`agent_kinds.md`), but the structured fields still require JSON. Inverting that — markdown body + YAML frontmatter for the structured bits — would make personas more authorable for users who don't think in JSON, especially for the long-form `systemPrompt` which suffers from JSON string escaping today. Loader change is contained: detect `.md` files in the personas/agents directory, parse frontmatter into the same `PromptAgent` Codable shape used for JSON, treat the body as the system prompt (concatenated with frontmatter `systemPrompt` if both are present, matching the current `contextPath` semantics). Also a workspace-level `AGENTS.md` analogue could carry per-workspace defaults the chat picks up — useful for project-specific personas without polluting the global library.

5. **`parallel` composition primitive — with constraints.** Originally rejected as an anti-goal in `agents.md` on debuggability + transcript-attribution grounds. Worth reconsidering with explicit constraints that defang the original objections:

   - **Capability gate.** Local backends (`llama.cpp`, `MLX`) cannot meaningfully run two agents concurrently against the same model — KV cache + GPU contention serialises them anyway and probably regresses throughput. Restrict `parallel` to (a) cloud providers where each branch hits an independent endpoint (Anthropic / OpenAI / etc. with their own per-key rate limits), or (b) the explicit case where each branch targets a *different* loaded backend (one llama, one cloud, one MLX). Reject the plan at validation time on local-only when branches would share a runner.

   - **Provider portability.** The merge step (`merge: .structured` in Swarm) needs to handle the case where branches may return at very different times — fastest-wins, all-must-complete, and structured-merge are three distinct policies. Adopt all three with explicit names: `parallel(branches:, merge: .firstCompleted)`, `.allCompleted`, `.structuredMerge(synthesiser: AgentID)` — the last variant runs an extra LLM hop to integrate the branch outputs.

   - **Budget accounting.** Each branch consumes from the same step budget; the user authorises N steps for the turn, not N × branch-count. A 3-way parallel with a budget of 6 means 2 steps per branch, not 6 each. Validation should warn when (`branches.count` > `budget`).

   - **Transcript attribution.** Per-segment attribution (`SegmentSpan` in `unifiedTrace`) extends naturally to parallel: spans get an explicit "branch" tag, the renderer shows them stacked or tabbed rather than sequentially. The existing per-segment voice/agent metadata carries through.

   - **Cancellation.** A branch that completes first (under `.firstCompleted`) must cancel siblings — wire `Task.cancel()` through the branch tasks. The existing `CancelFlag` actor pattern handles this.

   New `CompositionPlan.parallel(branches: [AgentID], merge: ParallelMerge)` + `PromptAgent.ParallelSpec`. Driver runs branches via `withThrowingTaskGroup`, applies the merge policy, returns one `CompositionResult` with all branch segments. The hardest design surface is the structured-merge synthesiser — it's basically a one-shot orchestrator over the branch outputs, so reusing `.orchestrator` semantics for that step is plausible.

## Image generation — alternative-backend tracking & follow-ups

Image generation shipped in 0.1.9 (local SD via `StableDiffusionRunner` wrapping stable-diffusion.cpp; SD-1.x / SDXL / Z-Image / Flux multi-file workflows in a dedicated Image tab) and 0.1.10 (cloud `gpt-image-1` peer + curated Gallery window). The current sd.cpp path is the production backend; items here track alternative backends worth swapping or augmenting with as upstream maturity changes, plus the cross-cutting concerns the in-process path papered over rather than solved.

Tracking items:

## Known foot-guns (document, don't necessarily fix)

- `~/.cache/huggingface/hub` grows unbounded; no eviction.

- Switching backends mid-session doesn't clear the other's loaded model from memory — intentional (so you can flip back without reloading) but worth documenting.

- Infer target is pinned to Swift 5 language mode; any new code added should still be written Swift-6-concurrency-safe so the opt-out can be removed cleanly.

