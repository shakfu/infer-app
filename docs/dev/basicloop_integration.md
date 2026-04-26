# BasicLoop integration: deferred work and recommendation

Date: 2026-04-26

This note records the analysis behind the decision to defer parts of the
`BasicLoop` integration, and the scope of what *is* worth doing in the next pass.

Three items are commonly cited as the natural follow-up to `BasicLoop` /
`AgentRunner` / `DeterministicPipelineAgent` shipping in `InferAgents`:

1. `LlamaRunner` / `MLXRunner` adopting `AgentRunner`.
2. Wiring `BasicLoop` into `ChatViewModel/Generation.swift`.
3. JSON schema for declaring deterministic pipelines outside Swift.

The first instinct is "small adapters, easy follow-up." On a closer reading
of the actual code, two of the three are larger than they look, and one is
premature. This note works through each.

---

## 1. `LlamaRunner` / `MLXRunner` adopting `AgentRunner`

### What `AgentRunner` expects

```swift
public protocol AgentRunner: Sendable {
    func decode(
        messages: [TranscriptMessage],
        params: DecodingParams
    ) -> AsyncThrowingStream<String, Error>
}
```

The contract is *stateless*: each `decode` call receives the full transcript
and returns a stream. No turn state is implied to live on the runner.

### What the existing runners actually expose

`LlamaRunner` (`Sources/Infer/LlamaRunner.swift`) and `MLXRunner`
(`Sources/Infer/MLXRunner.swift`) are both stateful actors:

- `setSystemPrompt(_:)`
- `setHistory(_:)`
- `sendUserMessage(_:maxTokens:) -> AsyncThrowingStream<String, Error>`
- plus internal KV-cache state (Llama) or `ChatSession` history (MLX) that
  evolves across calls.

They were built around the chat-VM's per-turn flow: load model once, set
system prompt once, then call `sendUserMessage` for each user turn so the
KV cache benefits from prefix sharing across the whole conversation.

### Two ways to bridge

#### a) Naive adapter

Wrap each runner in a small struct that, on every `decode` call:

1. Splits `messages` into `(system, prior turns, current user)`.
2. Calls `setSystemPrompt(system)`.
3. Calls `setHistory(prior)`.
4. Calls `sendUserMessage(current)` and forwards the stream.

This is correct but rewinds the KV cache on every external `decode` call —
the runner re-tokenizes the prior history each time. For a 4-turn
conversation that's roughly 4x the decode work over the conversation
relative to the chat-VM path.

Cost: ~30–50 lines per runner. Risk: low, additive.

Performance impact: irrelevant for CLI / batch / one-shot use cases (which
are the only callers `BasicLoop` actually has). Real for any future caller
that drives a multi-turn chat through `BasicLoop` + a real model.

#### b) Real integration

Refactor the runners' KV-reuse heuristics around an externally-supplied
transcript so prefix-shared KV survives across `decode` calls. The runner
needs to recognise "your new transcript is a strict prefix-extension of
your previous one" and avoid re-tokenizing the shared head.

Cost: substantial. Risk: medium. Touches the runners' most performance-
sensitive code path.

### Recommendation

Do (a) now. Document the KV rewind in the adapter's doc comment so future
callers are not surprised. Defer (b) until a real caller needs multi-turn
performance through `BasicLoop` — at which point the design pressure will
also tell us whether the right answer is a stateful `AgentRunner` variant,
a "session" intermediate, or something else.

---

## 2. Wiring `BasicLoop` into `Generation.swift`

### What `Generation.swift` does today

`ChatViewModel/Generation.swift` is ~766 lines. Its responsibilities, in
rough order:

- Per-turn user-message creation, vault row insertion.
- Composition driver invocation (`CompositionController.dispatch`) for
  the user turn.
- Per-segment `ChatMessage` creation, agent switching via
  `AgentController.activateForSegment`, per-segment vault writes.
- The inner decode + tool loop: stream from runner, accumulate, parse
  for tool call, invoke tool, transform result, re-stream.
- Think-block stream filter (`ThinkBlockStreamFilter`) splitting
  `<think>…</think>` from visible reply.
- KV compaction post-turn (Llama-only): re-submit visible-only
  transcript so think tokens don't eat context.
- Speech: TTS auto-arm on completion in voice-loop mode.
- Image attachment threading on the first segment.
- Net-vs-gen token counting; `generationStats` updates.
- Cancellation: net-token cap firing inside think blocks.

### What overlaps with `BasicLoop`

Only the inner decode + tool loop. Roughly ~150 of the ~766 lines.

The other ~600 lines are host-specific: vault, `ChatMessage` mutation on
`MainActor`, KV compaction, think filtering, speech, images. None of
these belong inside `InferAgents` — they are the SwiftUI-VM bundle that
the agent layer was deliberately extracted *away* from.

### What "consolidation" would actually mean

Two paths:

**Full replacement.** `BasicLoop.run` becomes the inner loop; events flow
out through `AgentEvent` callbacks; `Generation.swift` becomes a thin
observer that translates events into vault / UI / speech effects.

This is a real refactor:

- `BasicLoop` would need to grow think-block awareness and KV-compaction
  hooks, OR those concerns would have to move out of the loop entirely
  (into a stream filter wrapper around `AgentRunner`, and a post-turn
  hook on the runner respectively).
- The chat-VM's net-token cap firing mid-think-block requires
  cooperation between the loop and the stream filter; replicating this
  in `BasicLoop` adds a feature `BasicLoop`'s other callers don't need.
- The current code is debugged against real models with real tool calls.
  Edge cases (think-block straddling tool-call boundaries, KV
  compaction interleaving with mid-turn cancellation) accumulated over
  multiple bug fixes that are not documented in tests.
- The integration test suite for `Generation.swift` is sparse — it
  relies on UI-driven validation that is not reproducible from the test
  harness. A consolidation regression would not be caught by `swift
  test`.

Risk: medium-high. Reward: code de-duplication, but not feature parity.
`Generation.swift` keeps doing things `BasicLoop` is not designed to do.

**Partial wiring (the slim slice).** Add one branch at the top of
`runOneSegment` in `Generation.swift`: if `agent.customLoop(turn:context:)`
returns a non-nil `StepTrace`, use it verbatim and skip the runner.

This is a much smaller change (~30 lines, one isolated branch) and
addresses a real correctness gap: today, a `DeterministicPipelineAgent`
activated in the chat UI does NOT short-circuit. The chat-VM falls through
to the LLM decode path, the model has nothing meaningful to do (no tools
in its system prompt for that agent's pipeline), and the user sees noise.

The test harness's `runOne` closure does honour `customLoop` (via
`BasicLoop.runOutcome`), which is why the `MixedAgentChainIntegrationTests`
work. The chat-VM's `runOne` does not. That asymmetry is the bug.

### Recommendation

Do the customLoop short-circuit. Defer full consolidation.

Concretely: add a branch in `Generation.runOneSegment` (or whichever
function ends up dispatching segments) that calls
`agent.customLoop(turn:context:)`. On non-nil:

- Materialise the trace's `finalAnswer` text into the segment's
  `ChatMessage`.
- Persist the segment to the vault as completed.
- Emit the trace's terminal step via `AgentController.emit(.terminated(...))`
  so observers see the same shape as for LLM-backed segments.
- Return `.completed(text:trace:)` to the composition driver.

On nil: fall through to the existing LLM path unchanged.

This is the minimum needed to make deterministic agents useful from the
chat UI. Full consolidation can wait until there is a concrete second
caller for `BasicLoop` against real models — at which point the design
pressure will be informed by that caller's needs rather than speculation.

---

## 3. JSON schema for deterministic pipelines

### What it would look like

A new schema version (v4) with a `kind: "deterministic"` branch:

```json
{
  "schemaVersion": 4,
  "kind": "deterministic",
  "id": "demo.fetch-and-extract",
  "metadata": {"name": "Fetch and extract"},
  "requirements": {"toolsAllow": ["http.fetch", "json.extract"]},
  "pipeline": [
    {
      "tool": "http.fetch",
      "arguments": "{\"url\":\"{{userText}}\"}",
      "bind": "raw"
    },
    {
      "tool": "json.extract",
      "arguments": "{\"payload\":{{raw}},\"path\":\"$.facts\"}",
      "bind": "facts"
    }
  ],
  "output": "{{facts}}"
}
```

Plus: template substitution syntax (`{{userText}}`, `{{bag-key}}`),
escaping rules for embedding bag values in JSON arguments, validation
(deterministic kind must have `pipeline`, must not have `systemPrompt` /
composition fields), `PromptAgent.customLoop` override that delegates to
`DeterministicPipelineAgent`.

Cost: ~150–250 lines including tests.

### Why defer

The `DeterministicPipelineAgent` Swift API exists and is exercised by
`DeterministicPipelineAgentTests` and `MixedAgentChainIntegrationTests`.
The only known user of "deterministic agents" today is those tests.

A JSON schema designed without a real authoring use case will encode
guesses about what users want to express:

- Is `{{var}}` substitution enough, or do users want JSONPath / jq?
- How are bag values escaped when interpolated into JSON arguments?
- Should pipelines support conditionals, loops, parallel steps?
- How does error handling express in the schema (try/catch per step)?

Designing this in advance of usage produces a configuration surface that
is either too rigid (real users hit walls) or too flexible (a mini
language nobody asked for). The Swift API can evolve trivially as we
learn; a JSON schema, once shipped, is a compatibility commitment.

### Recommendation

Defer until a real authoring need surfaces. Two heuristics for "real":

- A user (or this project's author) wants to write a deterministic
  pipeline and the Swift API requires a recompile / rebuild of the app.
- The same Swift pipeline shape is being written three or more times
  with only minor variations (signal that a declarative form would
  reduce duplication).

When that happens, the schema design is informed by the actual cases.
Until then, the Swift API is the right surface.

---

## Proposed scope for the next pass

In order:

1. **`LlamaRunner: AgentRunner`** — naive adapter (~50 lines), documented
   KV rewind caveat.
2. **`MLXRunner: AgentRunner`** — naive adapter (~30 lines).
3. **`customLoop` short-circuit in `Generation.swift`** — one branch
   (~30 lines), unblocks `DeterministicPipelineAgent` in the chat UI.

Total: ~110 lines, additive, no refactor of existing paths. Risk: low.

Out of scope for the next pass:

- Full `BasicLoop` ↔ `Generation.swift` consolidation. Revisit when
  there is a second real caller for `BasicLoop` against live models.
- JSON deterministic-pipeline schema. Revisit when there is a real
  authoring use case driving the shape.
