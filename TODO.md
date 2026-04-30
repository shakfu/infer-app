# TODO

Roughly prioritized by user-facing impact / effort ratio. Items within a tier are not strictly ordered.

## P0 — small, high value

- [ ] **Hardware-tier gate for heavy SD models (Z-Image-Turbo Q6_K).** On low-end Apple Silicon (M1-class base chip and/or <=8 GB unified memory), loading `z_image_turbo-Q6_K.gguf` saturates GPU + memory enough to freeze the WindowServer (mouse/keyboard stalls, screen freeze) on M1 Air-class machines. At model load in `StableDiffusionRunner`, detect host capability — `ProcessInfo.processInfo.physicalMemory` for RAM, `sysctlbyname("hw.model")` / `machdep.cpu.brand_string` for chip family — and refuse to load Q6_K on the low tier with a dialog pointing at a lighter quant (Q4_K_S / Q4_0). Allow override via an explicit "I understand the risk" toggle in the SD panel that persists per-model so the warning isn't repeated. Pair with shipping a smaller default quant so the bad path is opt-in rather than the default. Caveat on detection: keying purely on "M1" false-positives M1 Pro/Max 16GB+ — combine chip-family check with the memory threshold rather than chip alone. Related: the out-of-process SD execution item under P2 is the deeper fix; this gate is the cheap defensive layer that should land regardless.

## P1 — feature completeness

- [ ] **Timestamps per message.** Stash `Date` on each `ChatMessage`, show as `HH:mm` in the gutter. Helps when triaging long sessions.

- [ ] **Multi-language syntax highlighting in chat.** Splash is Swift-only. Swap for Highlightr (highlight.js via JavaScriptCore) behind the existing `CodeSyntaxHighlighter` interface; the call site in `MessageRow` doesn't change. NOTE: subsumed by the "WKWebView-per-message chat rendering" experiment below if that path is taken — highlight.js is already bundled in `WebAssets/` and would run inside the chat WebView automatically.

- [ ] **WKWebView-per-message chat rendering (experiment, branch).** Unify live chat with the PDF/print pipeline so math, multi-language syntax highlighting, tables, and inline HTML (`<sub>` / `<sup>` / etc.) all render in the transcript — not just in export. Replace `MarkdownUI` with a pooled `WKWebView` NSViewRepresentable for assistant messages (user/system rows stay as plain `Text`). Reuse the existing `PrintRenderer.wrap(body:)` HTML template minus print-specific CSS; `loadHTMLString` with `baseURL = Bundle.main.resourceURL` so the bundled `WebAssets/` (KaTeX + highlight.js) resolve. Per-message dynamic height: JS posts `document.body.scrollHeight` via a `WKScriptMessageHandler`; the NSViewRepresentable resizes its frame. Concrete pieces: `WebMessageView: NSViewRepresentable` with a `WKWebViewPool` (reuse views as they scroll off; SwiftUI's lazy vstack already unloads). Gotchas: native `.textSelection(.enabled)` is lost (emulate via CSS `user-select: text` + a Copy button per message — already there); `MarkdownUI`'s GitHub theme is replaced with a hand-rolled stylesheet matching chat aesthetics; live-streaming updates need an efficient path (inject text into the DOM via `evaluateJavaScript` rather than reloading the whole HTML on each token). Memory: a pool of ~10–20 WebViews should suffice for typical transcript lengths; profile before scaling. **Experiment first** on a branch — measure streaming smoothness, memory growth over a long session, and scroll jank before committing to it as the default. If the experiment looks good, it subsumes the Highlightr / SwiftTreeSitter items above.

- [ ] **Native syntax highlighting via SwiftTreeSitter (alternative path).** If we want to avoid the JavaScriptCore runtime that Highlightr pulls in, the native route is [SwiftTreeSitter](https://github.com/ChimeHQ/SwiftTreeSitter) + per-language parsers. Start narrow: bundle `tree-sitter-python` and `tree-sitter-swift` (the two languages most chat responses use), plus a highlights query per grammar copied from each parser repo's `queries/highlights.scm`. Implement `TreeSitterCodeHighlighter: CodeSyntaxHighlighter` that maps TS highlight capture names (`@keyword`, `@string`, `@function`, etc.) to SwiftUI `Color`s; fall back to plain monospaced `Text` for unknown languages. Cost: ~3 MB of bundled parser static libs per language, ~150 lines of Swift, and per-language grammar upkeep whenever syntax evolves. Pick this over Highlightr if coverage-by-handful (Python + Swift) is the real target and avoiding a JS runtime matters; pick Highlightr if paste-anything-highlights-it is the target.

- [ ] **System prompt presets.** Named library of system prompts (Coding Assistant, Research, Concise, Creative, etc.). Small JSON file in `Application Support/` + a picker in the sidebar's System Prompt disclosure. Save-current-as and delete actions. Pairs naturally with the existing System Prompt field.

- [ ] **Cmd+F transcript search.** In-transcript find bar. Scroll to next/previous match with Cmd+G / Shift+Cmd+G, highlight matches in `MessageRow`. `AttributedString` with background-color runs on matched ranges works inside `MarkdownUI`.

- [ ] **Stop sequences.** User-defined strings in settings that halt generation when emitted. llama has per-token stop handling in the sampler loop; MLX takes `extraEOSTokens`. Handy for forcing structured output boundaries (e.g. `---`, `</answer>`).

- [ ] **Hold-to-talk (push-to-talk).** Alternative to the current mic-toggle: hold a hotkey (Fn or a configurable modifier) while Infer is key window → mic on for the hold duration, release → stop + submit. Add a sidebar setting "Dictation mode: Toggle | Push-to-talk". Toggle mode is easy to forget is on; PTT is what most dictation-savvy users expect.

- [x] **Whisper.cpp file-transcription backend.** whisper.cpp xcframework fetched by `scripts/fetch_whisper_framework.sh`, wrapped in `WhisperRunner` actor (`load(modelPath:)` / `transcribeFile(...)`), bundled into `Infer.app/Contents/Frameworks/`, cleanup wired into `AppDelegate.applicationWillTerminate`. `WhisperModelManager` downloads ggml models on demand into `Application Support/Infer/whisper/`. UX is drag-and-drop audio files into the chat, with a model picker + translate toggle in the Speech sidebar section.

- [ ] **Whisper.cpp as live-mic ASR backend.** Extends the file-transcription work above to the live mic path. Today the mic button is wired exclusively to `SFSpeechRecognizer`; swap it behind a segmented control (SFSpeechRecognizer vs Whisper) in the Speech sidebar section so the existing mic button can drive either backend. Needs a streaming/chunked capture path feeding `WhisperRunner` (SFSpeechRecognizer is continuous; whisper.cpp is batch — likely capture to a rolling buffer and transcribe on stop, or run fixed-window chunks for partial results).

## P1 — RAG quality

Surfaced by the first end-to-end tests of Phase 5 RAG on real corpora. The pipeline is correct; these items all target retrieval / presentation quality, which dense-embedding-only search leaves on the table. Ordered roughly by payoff.

- [ ] **Hybrid retrieval (vector + FTS5).** Dense retrieval misses passages where the query uses generic terms (e.g. "vector database") but the answer uses proper nouns ("SQLiteVec", "vec0") or vice versa. Add an FTS5 virtual table over `chunks.content` (same `content='chunks', content_rowid='id'` pattern the vault already uses on messages), run keyword search in parallel with vector search, fuse via Reciprocal Rank Fusion (k=60, equal weights). Deduplicate by chunk id, return top-K by fused score. Requires a one-shot backfill for existing stores. ~2 days. **Highest leverage on the first-test failures.**

- [ ] **Larger chunks for prose.** 512 chars ≈ one paragraph; a scene or section spans 3–5. For narrative or argumentative documents, 1024/100 often retrieves better context. Changes existing indexes, forces re-ingest. Could be a per-workspace setting later; for MVP, bump the default and leave the workspace metadata's `chunk_size` column as the source of truth.

- [ ] **Structural / section metadata.** Detect markdown `## Heading` boundaries during ingestion and store heading paths alongside chunks (e.g. `rag.plan.md > 3.1 Schema`). Inject the path as a prefix in the prompt's context block so the model sees "chunk from section X of file Y" — dramatically improves orientation on "summarize" / "where in X" queries. For plain `.txt` novels, detect `Chapter N` or `PART N` markers with a fallback regex. Medium effort; changes the chunk schema.

- [ ] **Query reformulation (HyDE-style).** "Summarize the book" embeds poorly against any single chunk because the query has no specific vocabulary overlap with the body. Rewrite the query through the chat model before embedding: generate a hypothetical ideal answer, embed *that*, use it for retrieval. Big quality bump on broad questions; adds one LLM call per query. Gate behind a per-workspace setting so users can opt out for latency-sensitive flows.

- [ ] **Reranking.** Pull top-30 by fused hybrid retrieval, rerank with a cross-encoder (`bge-reranker-base`, ~280 MB, downloadable through the same HF flow as the embedder). Cross-encoders read both query and chunk *together* and score true relevance, catching the "topical-but-not-answerful" chunks the similarity-based path keeps surfacing. ~3 days including UI for model download; highest ceiling but most cost (~200 ms per query).

## P1 — Reasoning model handling

Reasoning models (Qwen-3, DeepSeek-R1, etc.) emit `<think>…</think>` blocks that count as real tokens against `maxTokens`, the KV cache, and `generationTokenCount`. The visible reply is stripped via `ThinkBlockStreamFilter` (already shipped) and rendered behind a collapsible disclosure, but the underlying token accounting still includes the thinking content. These items address that asymmetry.

- [x] **Strip thinking from KV cache between turns.** At end-of-turn for assistant messages with captured `thinkingText`, `Generation.swift` calls `compactKVForVisibleHistory()`. The VM converts `messages[]` (stripped text) to runner-friendly tuples and calls each backend's existing `setHistory` — llama clears `llama_get_memory` and decodes the prefill; MLX rebuilds `ChatSession` from the supplied history. Logged at `debug` level under source `runner`: `compacted KV cache (stripped think blocks) in Nms`. Failures fall through to a warning; the cache still holds the raw sequence, the next turn just costs more. `refreshTokenUsage` runs after compaction so the header percentage drops to reflect the stripped state.

- [x] **Distinguish "decoded" from "visible" tokens in stats.** `ChatViewModel.visibleTokenCount` increments per non-empty `ThinkBlockStreamFilter.feed()` return alongside the raw `generationTokenCount`. `generationStats` now returns `(tokens, visible, tps)`. The header `generationRateView` splits its display: `12 vis · 1050 gen · 8 tok/s` when the two diverge (i.e. reasoning emitted think blocks), `1050 tok · 8 tok/s` when they're equal (non-reasoning models — no behaviour change). Tooltip explains the split. Vault still stores the raw `tokens` count (representing actual decode work).

## P2 — Agent tool surface

Tools the chat-VM's `ToolRegistry` doesn't expose yet but should. Distinct from the agents subsystem follow-ups (P3) — those are about the loop / planner / composition machinery; these are concrete tool wrappers around capabilities the app already has internally. Agents only get value from tools that exist; each entry below has a directly attributable user payoff. Ordered roughly by leverage / implementation-cost ratio.

### High-value, higher implementation cost

- [ ] **`whisper.transcribe`.** Audio/video → transcript text. The `whisper.xcframework` is already in the bundle via `make fetch-whisper` and `WhisperRunner` already handles file transcription for the Speech sidebar drag-drop flow — exposing it as a tool is mostly tool-spec scaffolding + sandbox plumbing on top of existing infrastructure. Composes with `fs.read` (audio file in `~/Documents`) for prompts like "transcribe this voice memo and summarise the action items." Streaming-friendly — whisper emits partial transcripts during decoding, which fits the `StreamingBuiltinTool` shape (`.log` events per partial → final `.result` with the full transcript), so the chat disclosure shows live progress on long files. Args: `{path, model?, translate?: bool, language?}`. Same allowed-roots sandbox as `fs.read`. Open question: model selection — wire to the same `WhisperModelManager` that the UI uses, default to whatever model is currently downloaded.

- [ ] **`workspace.ingest`.** Add a URL or file to the active workspace's RAG corpus on demand. Closes the loop that's currently open: the agent can fetch a doc via `http.fetch`, but can't make it part of future retrieval — the user has to drag it into the workspace UI. The ingestion pipeline + embedding + FTS + chunk-store infra all exist; the missing piece is exposing `WorkspaceManager.ingest(url:)` (or equivalent) as a tool. Args: `{source, kind?: "url"|"file"}` where `source` is a URL or file path. Permission shape: tool can only ingest into the *currently active* workspace (no cross-workspace writes from a tool call). Returns `{chunks, sourceURI}` so the model can confirm and cite. Pairs naturally with the `research-assistant` agent: search → fetch → ingest → "now I can answer follow-ups about this doc from your vault."

### Reasonable but bounded

- [ ] **`json.query`.** Tiny JSONPath / jq-lite over strings. Args: `{json, query}`. Mostly useful for piping `http.fetch` output through — without it, the agent has to paraphrase 20 KB of JSON in its context to reason about a single field. Pure-Swift implementation: a JSONPath subset (`.foo`, `.foo.bar`, `.foo[0]`, `.foo[*].bar`) covers ~80% of practical queries and is ~150 LOC. Don't pull a full jq dependency; the cost-benefit doesn't pencil out for a tool that mostly extracts a few fields. Returns the matched value as JSON (so the model can pipe it through another tool if needed) or as a primitive when the result is a scalar.

- [ ] **`vault.recent`.** "What did we discuss yesterday about X" — backed by the existing GRDB conversation vault (separate from `vault.search` which queries the *current workspace's RAG corpus*; this queries past *conversations*). Args: `{query?, since?: "1d"|"1w"|"YYYY-MM-DD", limit?}`. Returns `[{conversationId, title, snippet, timestamp}]`. The vault FTS5 index over messages is already in place (used by the History sidebar); this is just exposing it as a tool surface. Useful for continuity prompts: "remind me what we settled on for the schema migration last week."

- [ ] **`mlx.embed` / `reranker.score`.** Expose the embedding + rerank models as tools. Niche — agents don't usually need raw vectors — but useful for evaluation harnesses, "compare these two snippets semantically" prompts, and as a building block for custom retrieval workflows authored as `DeterministicPipelineAgent` chains. The infrastructure (`EmbeddingRunner`, `RerankerRunner`) is fully wired for the RAG pipeline; tool-ifying is a thin spec wrapper. Args: `mlx.embed: {text}` → `{vector: [Float], model: "..."}`. `reranker.score: {query, document}` → `{score: Double}`. Caveat: each call materialises a vector or runs a cross-encoder pass — agents calling this in a tight loop will hit perf walls, so the spec should explicitly tell the model "use this for one-off comparisons, not bulk processing."

## Deferred — agent tool requests (intentionally not implemented)

Tool ideas evaluated and parked. Each has a real use case but the trade-offs land outside this app's design space. Documented here so they don't get re-proposed without the trade-off being re-checked against current state.

- **`shell.run` / `code.run.swift`.** Powerful, but the security model collapses into "user trusts the LLM" — there's no defensible allowlist scope between "useless" and "everything." MCP servers (e.g. `mcp-server-shell`) handle this through their own per-server consent layer, which is the better fit: the user explicitly opts in to a specific server, the server defines its own restrictions, and the per-server consent gate (already in place — see `MCPApprovalStore`) is the choke point. Same reasoning applies to `code.run.swift`: a real sandbox story for arbitrary Swift execution is hard, and "run untrusted code" is exactly the workflow MCP exists for.

- **`screenshot.take` / `image.ocr` / `image.describe`.** Vision-LLM territory. The clean version is "the model sees the image directly" via a vision-capable MLX model, not three separate tools that pretend the model can't. When a vision-capable model is loaded, the app should pass image attachments straight through to the runner instead of going through OCR / description tools. Tool-shaped wrappers for these would be a permanent compromise — re-evaluate if/when image attachments become a first-class chat input.

- **`calendar.events` / `reminders.list` / `notes.search`.** EventKit / NotesKit have nontrivial permission flows (TCC prompts, security-scoped resources) and Notes' database is private API. The same surface is reachable through MCP servers a user can opt into (e.g. an EventKit-backed MCP server in their own process), which keeps the permission grant scoped to the server rather than the whole app. Don't bake into the tool registry.

## P2 — hygiene & infra

- [ ] **Drop `.swiftLanguageMode(.v5)` on the Infer target.** The only blocker is `LlamaRunner.backendInitialized: static var` tripping Swift 6 strict-concurrency. Replace with an `actor` or an `@MainActor`-isolated initializer, then remove the opt-out.

- [ ] **Tests for the runners.** Neither backend is tested. Start with: `LlamaRunner.renderTemplate` round-trip on a known chat template; `MLXRunner.load(hfId:)` happy path against a tiny fixture model if feasible, otherwise mock the `ModelContainer`.

- [ ] **CI.** GitHub Actions on macos-14 running `swift test` against `projects/infer`, plus a lint step. Leave `build-infer` out of CI initially — it needs the ~700 MB Metal Toolchain asset and HF downloads.

- [ ] **`make clean-infer` and `make clean-mlx-cache`.** First nukes `build/infer-xcode`; second rm -rf's `~/.cache/huggingface/hub` after confirmation. The HF cache can easily grow past 20 GB.

- [ ] **Troubleshooting section in README.** Document the three foot-guns hit during setup: Metal Toolchain not installed → `cannot execute tool 'metal'`; `WKWebView.printOperation` → blank PDF (hence the PDFKit indirection); `swift build` cannot build MLX (hence `xcodebuild`).

- [ ] **Pin exact dep versions in Package.swift.** Several `.package(..., from: "X")` will resolve forward and silently drift. For reproducible builds, pin with `.upToNextMinor(from:)` or explicit revisions in a `Package.resolved` committed to the repo.

- [ ] **Window size & position persistence.** SwiftUI `WindowGroup` doesn't restore frame state across launches. Observe `NSWindow` frame changes via `NSWindowDelegate` or `didChangeNotification`, persist to `UserDefaults`, restore on `applicationDidFinishLaunching`. Small code, noticeable QoL.

- [ ] **Per-model last-used system prompt.** Users tend to pair a specific system prompt with a specific model (a code-assist prompt for a Qwen Coder, a concise prompt for a small instruct model). Key system prompts by `backend + modelId` in `UserDefaults` and auto-restore on model load — with a "don't restore" escape hatch in settings.

- [ ] **Log file export.** Debug panel with the last N log lines from both runners (model load status, generation stats, errors), with a "Copy" and a "Save to file…" action. Makes bug reports and model-behavior investigations much easier.

- [ ] **Run Stable Diffusion out of process.** `StableDiffusionRunner` is currently in-process and saturates CPU + GPU during generation — Z-Image-Turbo specifically can make macOS unresponsive enough that windows can't be dragged. Quick wins already shipped (cap `n_threads` at half cores, drop the detached Task to `.utility`, expose a Threads stepper in the panel) buy enough headroom for SD-1.x / SDXL, but Z-Image runs the Qwen3-4B text encoder *and* a chunky DiT through Metal, and OS scheduler hints can't preempt long-running Metal compute kernels. Subprocess execution is the real fix: spawn the bundled `sd` CLI via `Process` (same pattern as `QuartoRenderTool` / `QuartoLocator`) so the OS schedules its CPU + GPU work independently of the Infer.app process and the WindowServer keeps its slice. Concrete shape: replace `StableDiffusionRunner`'s `new_sd_ctx` / `generate_image` calls with a `Process` invocation of the `sd` binary that ships in the leejet release zip; map the existing `load(...)` parameters to CLI flags (`--diffusion-model`, `--vae`, `--llm`, `--cfg-scale`, `--offload-to-cpu`, `-W`, `-H`, `-p`, `-n`, `--steps`, `--sampling-method`, `--seed`); parse progress lines from stderr (sd-cpp prints `[step/steps]` per step) into the existing `SDProgress.step` events; the binary writes a PNG to a temp dir, then we move it into `~/Library/Application Support/Infer/Generated Images/` and write the JSON sidecar (gallery path keeps working unchanged since it's file I/O). Wins: process isolation for resource-greedy compute, real cancel (`Process.terminate()` actually stops generation — sd-cpp's public C API has no in-flight cancel hook today), no symbol-collision risk if a future SD release ever diverges from the bundled ggml. Costs: ~100 ms process startup amortised over 5–30s generations (negligible), losing the in-process C API surface (no consequence — the runner only uses generate-image), needing to ship the `sd` binary in `Contents/Resources/` and locate it via `Bundle.main.path(forResource:)`. Defer until the in-process path becomes a real blocker — for SD 1.x / SDXL the quick wins are likely sufficient; revisit if Z-Image / Flux usage drives sustained complaints.

## P3 — nice to have

- [ ] **Multi-platform target restructure.** Prerequisite (or companion) to the iOS port: split the single `Infer` executable target into a shared library + thin platform shells. Shape: `InferCore` (pure logic, already separate) + `InferKit` (new: SwiftUI views, ViewModel, runners — cross-platform) + `InferMac` (executable: menu commands, `AppDelegate`, NSAlert usage, `NSPrintInfo`) + `InferIOS` (future: `UIPrintInteractionController`, iOS entry point). `Package.swift` declares platforms `.macOS(.v14), .iOS(.v17)` on the shared library; platform executables pin their own. Requires teasing ~20 AppKit call sites out of the current view/VM layer (most already funneled through `FileDialogs.swift`; remaining: `NSPasteboard`, `NSImage`, `NSAlert`, `NSWorkspace`). Worth doing only when iOS is a committed near-term goal — until then the current layout ships on macOS and the AppKit spots stay inline. Estimate: ~3–5 days restructure + tracking-down of hidden AppKit transitive uses; then the iOS port item becomes the "fill in `InferIOS`" task.

- [ ] **iOS / iPadOS port.** Most of the work is AppKit → cross-platform swaps, not the inference backends. What works with little or no change: `llama.xcframework` (iOS slices ship), `mlx-swift-lm` (iOS support), `whisper.xcframework`, GRDB, swift-markdown-ui, Splash, `AVAudioEngine` / `SFSpeechRecognizer` / `AVSpeechSynthesizer`. Real work, ranked: (1) replace `NSOpenPanel` / `NSSavePanel` / `NSAlert` / `NSImage` / `NSPasteboard` / `NSWorkspace` across ~8 files with SwiftUI `.fileImporter` / `.fileExporter`, `.alert`, `UIImage`, `UIPasteboard`, `UIApplication.open`; (2) printing: `PDFDocument.printOperation` → `UIPrintInteractionController` (PDF export via `WKWebView.createPDF` is cross-platform); (3) iPhone layout — the 280pt sidebar doesn't fit; refactor to `NavigationStack` or drawer on compact width (iPadOS works as-is); (4) menu/shortcut Commands are macOS + iPadOS only; iPhone loses Stop Speech (⌘⇧.), ⌘O / ⌘S, etc. — move critical ones into toolbar buttons; (5) GGUF folder picker needs security-scoped bookmarks; (6) model-size realism — gemma3-1B-qat-4bit (~700 MB) is fine on iPads with 8+ GB RAM, tight on iPhones; restrict default registry to small quants; (7) Package.swift + scheme: add `.iOS(.v17)` platform and a separate executable target or a shared library with two thin shells. Estimate: ~1–2 weeks iPad-first, ~1 more week for iPhone layout.

- [ ] **Curated MLX model picker.** Instead of a raw HF id text field, a dropdown populated from `LLMRegistry` entries + a "custom…" option.

- [ ] **Multi-conversation tabs.** Current design assumes one chat per window. `WindowGroup` + a document-based model would let ⌘T open a new conversation. Non-trivial refactor; only worth doing if the app becomes daily-driver.

- [ ] **Export conversation as rendered HTML / PDF.** Reuse `PrintRenderer`'s HTML template; add a "Save as…" alongside Print.

- [ ] **Better table rendering in print.** `HTMLFormatter` emits standard `<table>`; add zebra striping + caption support in the print CSS.

- [ ] **Error log panel.** Alerts disappear; a pull-up panel showing recent errors (with copy-to-clipboard) would help when iterating on models.

- [ ] **Dual-backend compare mode.** Run the same prompt through llama and MLX simultaneously, render two columns side-by-side in the transcript. Genuinely useful for picking models/quants. Needs a split-view toggle and a second transcript column wired to the "other" runner; settings apply to both. Not trivial, but compelling as a power-user feature.

- [ ] **Grammar / JSON mode for llama.cpp.** Expose `llama_sampler_init_grammar` (GBNF) with a small editor in the sidebar. MLX can approximate with structured-output constraints via `GenerateParameters`. Turns Infer into a lightweight tool for structured extraction (build a GBNF → get guaranteed-valid JSON out).

- [ ] **Keyboard shortcut help sheet.** `Cmd+/` opens a modal listing all shortcuts (Send, Stop, Regenerate, Copy Transcript, Dictate, etc.). Discoverability of Cmd+Return is currently poor — new users have no way to find it short of reading the source.

- [ ] **Drop `.gguf` / `.md` onto window to load.** `.onDrop` for `public.file-url`: route `.gguf` → `loadLlamaPath`, `.md` → transcript import. Removes an open-panel dialog for the common case.

- [ ] **Resizable sidebar.** Sidebar is currently fixed at 280pt. Add a draggable splitter (persist width in `UserDefaults`). SwiftUI `NavigationSplitView` would give this for free but requires a bigger restructure; a custom `HSplitView`-like implementation is a few lines.

- [ ] **Cmd+/Cmd-/Cmd+0 to zoom transcript font.** Persist the scale factor. Useful for print-scale reading and for older users.

- [ ] **Token probabilities visualization.** Color-code tokens by logprob in a debug view (greens = high confidence, reds = low). llama exposes `llama_get_logits`; MLX has `topLogprobs` on `GenerateParameters`. Niche but a real differentiator — most GUI clients treat the model as a black box.

- [ ] **Design an in-tree tool-calling agent architecture.** Local-centric: llama-first, MLX second, no cloud providers. Covers tool-call parsing per template family, MCP client over stdio, consent model, and transcript schema for tool turns. Sketch lives at `docs/dev/plugins.md`; expand into a fuller agent-architecture doc covering multi-step loops, cancellation, and agent state before implementation.

## P3 — Agents subsystem follow-ups

Consolidated and prioritised list of outstanding work on the agents subsystem (formerly tracked in `REVIEW.md`, now deleted — CHANGELOG.md has the per-change history of what shipped). Items are in priority order; each is independently shippable, and most are deferred pending real usage signal rather than blocked on technical work.

1. **Per-call human-in-the-loop approval gate.** Composition primitive (`gate` plan node) for tools that need explicit confirmation regardless of source. The MCP per-server consent gate covers "should this server launch at all?"; a `gate` would cover "should this specific call go through?" — pressing because MCP servers can call out to anything the user can, and write-side tools (filesystem write, GitHub create-issue) are sensitive even from approved servers. Design depends on observing how people actually use MCP in practice — what counts as sensitive depends on workflow.

2. **Branching / parallel plans.** `PlanLedger` is currently a flat ordered list. Lift to a DAG (each step has zero-or-more dependencies), execute independent steps concurrently via `TaskGroup`, gate on dependency completion. Final synthesis collects all leaf outputs. Big lift on the executor side; the prompt protocol also has to teach the model to emit a structured plan (probably JSON) instead of a numbered list.

3. **MCP resources capability.** Servers expose readable URIs (`resources/list`, `resources/read`, `resources/subscribe`). Map onto the existing `Retriever` shape — an MCP resource list can be one source feeding `AgentContext.retrieve` alongside the local vault. Decode `Resource` + `ResourceContent` shapes (text + blob), extend `MCPClient` with `listResources` / `readResource`, and add a `MCPResourceRetriever` adapter. Subscriptions can come later; one-shot reads cover most cases. The inbound-request dispatcher in `MCPClient` is the seam.

4. **MCP prompts capability.** Servers expose curated prompt templates (`prompts/list`, `prompts/get`). Most useful as an authored-prompts surface in the Agents tab — let a user pick "summarise email thread" from a Slack MCP server's prompt library and have it composed into the agent's system prompt at activation time. Schema is small; UI is the bulk of the work.

5. **MCP sampling capability.** Servers can request the host run an LLM decode on their behalf (`sampling/createMessage`) — used by servers that want to chain their own completions through the user's local model rather than spinning up their own. Extend `MCPClient` to handle the inbound request, route through the active `AgentRunner`, return the completion. Permission model: each sampling request needs explicit user approval (the server is asking the host to spend tokens on its behalf), so this depends on per-server consent + ideally the per-call gate above.

6. **MCP HTTP / WebSocket transports.** Stdio is fine for local desktop servers; HTTP/SSE and WebSocket (per the MCP HTTP transport spec) cover hosted servers and dev workflows where a server runs on a different machine. Implement two new `MCPTransport` conformances; `MCPClient` consumes them unchanged. Configuration layer needs `transport: "stdio" | "http" | "websocket"` discriminator on `MCPServerConfig` plus URL + auth fields for the network variants.

7. **MCP server hot-reload.** Today `MCPHost.bootstrap` runs once at app start; the in-app UI's `Reload` button is the only way to pick up edits. Watch the mcp directory with `DispatchSourceFileSystemObject`, diff registered server IDs against the new file set, gracefully shut down removed servers and launch added ones. The `ToolRegistry.unregister(prefixed:)` API needed for clean tool sweeps already exists.

8. **Sub-agent dispatch from a planner step.** Today a `PlanStep` resolves to either a tool call or a bare text reply. Allow a step to route to a registered peer agent (probably by surfacing a synthetic `agents.invoke`-style tool the planner can call from inside an execute decode). The composition primitives (`chain`, `orchestrator`) already cover hand-offs at the workflow level; this is the "planner as a controller" variant. Watch out for cycles (planner → planner → planner) — bound by the existing step-budget machinery.

9. **JSON-backed planner schema (`PromptAgent` extension).** Right now `PlannerAgent` is a Swift conformance instantiated by the host. A schema-v4 `PromptAgent` variant could declare `kind: "planner"` plus knobs (`maxStepDecodes`, `maxReplans`, an authored planning prompt) so users can ship custom planners without touching Swift. Trade-off: making the policy hot-editable trades against the readability of a typed Swift conformance — wait until two or three real custom planners exist before committing to a wire format.

10. **Coverage for under-exercised `Agent` hooks.** A test conformance that overrides `transformToolResult` and dynamic per-context `systemPrompt` would close the coverage gap. `customLoop` is exercised by `PlannerAgent` and `DeterministicPipelineAgent`; `shouldContinue` has unit tests but no non-default conformance. ~half a day; pure test work.

11. **MCP live-launch smoke test.** CI exercises `StdioMCPTransport` only via `MockMCPTransport`. A tiny in-tree echo server (Swift script, ~50 lines) launched as a real subprocess in one integration test would catch transport-level regressions (NDJSON framing, EOF handling, stderr drain) the mock can't. Skip in CI by default if `gh` runners flake on subprocess spawning.

## Deferred — image generation (track upstream maturity)

Parked as premature (2026-04-25). Rationale: no natural pull from the current chat/agent/RAG spine; every candidate backend is markedly less mature than the LLM equivalents (stable-diffusion.cpp lags llama.cpp — confirmed by wrapping pain in `~/projects/personal/cyllama`; `mlx-swift-examples` SD isn't a library product; FLUX Swift ports are single-maintainer); unified-memory pressure against an already-loaded LLM + Whisper + embedder + reranker forces an unload/reload policy that doesn't exist. Revisit when (a) the tool-calling agent loop can invoke non-text verbs cleanly, or (b) one of the upstreams below ships a stable library product.

Tracking items:

- [ ] **Watch for an MLX image-gen library split.** Upstream recently split the LM/VLM code out of `mlx-swift-examples` into `mlx-swift-lm` (proper SwiftPM library — already our dependency). StableDiffusion stayed behind as an example target (pipeline sources — UNet, VAE, CLIP, scheduler, tokenizer — live under `Applications/StableDiffusionExample/`, not exposed as a `.library` product). The LM split is the template; when upstream does the same for image gen (e.g. a hypothetical `mlx-swift-diffusion`), the vendor-and-own-churn cost drops to near zero. Check: https://github.com/ml-explore/mlx-swift-examples `Package.swift` products list; also watch ml-explore org for a new diffusion-focused repo.

- [ ] **Watch `argmaxinc/DiffusionKit` Swift-side maturity.** MLX-backed, claims SD3 + FLUX.1-schnell. Swift surface currently lags the Python surface. Re-evaluate when the Swift API is documented at parity with Python and tagged past 1.0. https://github.com/argmaxinc/DiffusionKit

- [ ] **Watch `mzbac/flux.swift` and `VincentGourbin/flux-2-swift-mlx`.** Single-maintainer FLUX ports on mlx-swift. Useful as reference implementations even if we don't depend on them directly; revisit if either picks up co-maintainers or ships a stable tag. https://github.com/mzbac/flux.swift · https://github.com/VincentGourbin/flux-2-swift-mlx

- [ ] **Watch stable-diffusion.cpp maturity (cyllama wrap).** `~/projects/personal/cyllama` already wraps it; the wrap is painful because upstream API churns and lacks llama.cpp-grade stability. Not a blocker here — Infer has no cyllama dependency — but relevant signal: if sd.cpp stabilizes, a llama.cpp-style xcframework path (mirroring `thirdparty/llama.xcframework` / `whisper.xcframework`) becomes plausible as a third backend alongside any MLX choice.

- [ ] **Pre-req: memory arbitration across runners.** Before any image backend lands, runners need a coordinated "unload on pressure" story so SDXL/FLUX (~7–24 GB resident) can coexist with a loaded LLM. Today each runner owns its lifecycle independently; a central `ResourceArbiter` (or convention) is needed. Scope this when image gen is no longer deferred.

- [ ] **Pre-req: agent tool-calling loop.** If image gen lands as an agent tool (framing (2) from the investigation — prompt → image-tool → inline render) rather than a separate Images tab, the in-tree tool-calling architecture (see P3 "Design an in-tree tool-calling agent architecture") must exist first.

## Known foot-guns (document, don't necessarily fix)

- `~/.cache/huggingface/hub` grows unbounded; no eviction.

- Switching backends mid-session doesn't clear the other's loaded model from memory — intentional (so you can flip back without reloading) but worth documenting.

- `llama.xcframework` fetch is not re-run when `LLAMA_TAG` changes; you have to `rm -rf thirdparty/llama.xcframework` first.

- Infer target is pinned to Swift 5 language mode; any new code added should still be written Swift-6-concurrency-safe so the opt-out can be removed cleanly.
