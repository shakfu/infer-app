# Cloud LLM backends — design analysis

Notes from a design discussion on adding OpenAI and Anthropic support to Infer.
Captures the SDK landscape, the Swift-vs-Python tradeoff, and the recommended
plugin shape. Not an implementation plan — decisions still open at the bottom.

## SDK landscape

Reference repos surveyed:

- [SwiftAnthropic](https://github.com/jamesrochabrun/SwiftAnthropic) — Swift, Anthropic API
- [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI) — Swift, OpenAI API
- [anthropic-sdk-python](https://github.com/anthropics/anthropic-sdk-python) — Python, Anthropic API (`pip install anthropic`); [official docs](https://platform.claude.com/docs/en/api/sdks/python)
- [openai-python](https://github.com/openai/openai-python) — Python, OpenAI API (base SDK)
- [openai-agents-python](https://github.com/openai/openai-agents-python) — Python, agent framework on top of `openai-python`
- [claude-agent-sdk-python](https://github.com/anthropics/claude-agent-sdk-python) — Python wrapper around the Claude Code CLI subprocess (different beast — see below)

Matrix:

|                    | OpenAI                        | Anthropic                                            |
|--------------------|-------------------------------|------------------------------------------------------|
| Swift API client   | MacPaw/OpenAI                 | SwiftAnthropic                                       |
| Python API client  | openai-python                 | anthropic                                            |
| Python agent layer | openai-agents (framework)     | hand-rolled loop on `anthropic`                      |
| Optional heavy     | —                             | claude-agent-sdk (CLI wrapper, separate concern)     |

## Swift vs. Python — the core tradeoff

**Native Swift SDKs (SwiftAnthropic, MacPaw/OpenAI):**
- Drop in as a third/fourth runner `actor` next to `LlamaRunner` / `MLXRunner`.
- Same `load / sendUserMessage / requestStop` surface; native
  `AsyncThrowingStream<String, Error>` maps 1:1.
- No `Python.framework` dependency, no PythonKit bridge, smaller bundle.

**Python SDKs (openai-python, anthropic):**
- Require the embedded interpreter; would re-add to `PY_PKGS`.
- Plain base SDKs offer no advantage over the Swift counterparts for raw
  API calls — they're dead weight on their own.
- The pull is `openai-agents-python` specifically: multi-step tool use,
  handoffs, tracing, guardrails. No Swift equivalent today.

Conclusion: use Swift SDKs for plain chat/streaming, reserve the Python path
for the things that actually justify the bundle cost (i.e., agent
orchestration).

## `claude-agent-sdk-python` — not what its name implies

Initially looked like the Anthropic analog of `openai-agents-python`. It isn't.
From its README: "The Claude Code CLI is automatically bundled with the
package." The SDK is a Python shim that spawns the `claude` Node CLI as a
subprocess.

Consequences for embedding into `Infer.app`:

1. **Node runtime required.** Claude Code is a Node CLI. Bundled binary still
   needs Node available — embed Node alongside Python, or require user install.
2. **Subprocess model.** Every `query()` spawns the `claude` binary.
   Sandboxing, code-signing, and entitlements for a third-party executable
   inside the app bundle become real distribution problems.
3. **Auth surface is Claude Code's**, not a plain API key — expects Claude
   Code's auth flow (subscription login or `ANTHROPIC_API_KEY` env).
4. **Different abstraction.** Not "build an agent from primitives" — it's
   "drive a fully-featured coding agent from Python." Tools default to the
   Claude Code toolset (Read/Write/Bash/Edit), which may or may not be what
   should be exposed inside Infer.

So `openai-agents-python` (pure Python orchestration on HTTP) and
`claude-agent-sdk-python` (Python shim + bundled Node CLI) are structurally
asymmetric. Treat them as separate concerns.

## Anthropic agent story without `claude-agent-sdk`

Anthropic's tool use lives in the Messages API itself, documented on the
[Python SDK docs page](https://platform.claude.com/docs/en/api/sdks/python).
The agent loop is a documented HTTP pattern — roughly:

1. Send messages with `tools=[...]`.
2. Detect `tool_use` content blocks in the response.
3. Dispatch to local handlers; append `tool_result` blocks.
4. Repeat until `stop_reason == "end_turn"`.

A few hundred lines on top of `anthropic` (or `SwiftAnthropic`) — no CLI, no
Node, no subprocess.

## Recommended shape

Two distinct mechanisms, not one. Word "plugin" applies only to the Python
path; the Swift runners are first-class backends.

| Layer                       | Mechanism                                  | Opt-in? |
|-----------------------------|--------------------------------------------|---------|
| OpenAI / Anthropic chat     | Swift runner actors, SPM deps              | No — always built |
| Agent orchestration         | Python plugin via `Python.framework`       | Yes — user opts in |

### Swift runners (always built)

- `OpenAIRunner`, `AnthropicRunner` — third and fourth `actor`s next to
  `LlamaRunner` / `MLXRunner`. Same `load / sendUserMessage / requestStop`
  surface, selected via the existing backend picker.
- Add SwiftAnthropic and MacPaw/OpenAI as SPM dependencies. No fetch step,
  no separate bundle artifact, no `Python.framework` involvement.
- This is the default path for cloud chat.

### Python agents plugin (opt-in)

- Triggered when the user enables agent features. Requires the embedded
  `Python.framework` produced by `scripts/fetch_python_framework.sh`.
- `PY_PKGS="openai-agents anthropic"`. `openai-agents` brings
  `openai-python` transitively; `anthropic` is the base for a small in-repo
  agent loop module (see "Anthropic agent story" above).
- Plain `openai-python` and `anthropic` as standalone deps offer no value
  over the Swift runners — they're only present here because
  `openai-agents` needs the former and the hand-rolled Anthropic loop needs
  the latter.

### Deferred

- **`claude-agent-sdk-python`** — revisit only if Claude-Code-style tool
  use (Bash/Read/Edit) inside Infer is desired, with Node bundling cost on
  the table.

This keeps the framework lean, avoids paying `Python.framework` cost just to
make HTTP calls that can be made natively in Swift, and reserves the Python
bundle for the orchestration features that actually justify it.

## Options considered for Anthropic agents

- **(a) Roll your own tool-use loop** on `SwiftAnthropic` or `anthropic`.
  Architecturally clean, no extra runtime. Asymmetric with OpenAI in that
  you're hand-rolling. *— Recommended default.*
- **(b) Accept the asymmetry**: ship `openai-agents-python` for OpenAI
  agents, ship plain SwiftAnthropic for Anthropic chat, no Anthropic agent
  framework initially. Add (a) later if needed.
- **(c) Bite the bullet on `claude-agent-sdk-python`**: accept Node
  bundling, subprocess sandboxing, and the Claude-Code-flavored agent. Only
  worth it if Claude Code's behavior specifically is wanted inside Infer.
- **(d) Provider-neutral framework** (Pydantic AI, LangChain, etc.) —
  handles both, but pulls a much bigger dependency tree and dilutes the
  "thin runner" architecture.

## Open decisions

1. **Runner protocol vs. duplication.** `CLAUDE.md` currently argues against
   a `LLMRunner` protocol because Llama and MLX diverge enough at `load()`
   to make abstraction leak. Adding two more runners (OpenAI, Anthropic) is
   the point where most codebases regret not having one. Decide upfront:
   introduce `LLMRunner` now, or accept four parallel actors.
2. **Plugin gating.** How does the user opt into the Python agents plugin?
   Settings toggle that triggers `fetch_python_framework.sh` with the right
   `PY_PKGS`, or a separate `make` target?
3. **API key storage.** Keychain vs. settings vs. env-only. Cloud backends
   need credentials; the local backends don't.
4. **Streaming surface.** Both Swift SDKs expose streaming; verify the
   delta shape matches the existing `AsyncThrowingStream<String, Error>`
   contract or adapt at the runner boundary.
