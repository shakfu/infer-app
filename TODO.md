# TODO

Roughly prioritized by user-facing impact / effort ratio. Items within a tier are not strictly ordered.

## P0 — small, high value

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

- [ ] **Strip thinking from KV cache between turns.** Currently `messages[]` (used for chat-template rendering) holds the stripped assistant text, but the runner's KV cache holds the full decoded sequence including `<think>…</think>`. Each turn's reasoning lingers in the cache for every subsequent turn, so multi-turn conversations with reasoning models fill the context window 2–4× faster than the visible reply text suggests. Fix: at end of an assistant turn, replay the cleaned `messages[]` against the runner — `llama_memory_clear`, re-tokenize from the stripped template, decode the prefill (one batch, ~few hundred ms). Trade: a one-time re-prefill cost at end-of-turn for accurate multi-turn context accounting. Worth doing once reasoning models are common enough in usage to make the cache bloat noticeable.

- [ ] **Distinguish "decoded" from "visible" tokens in stats.** Today `generationTokenCount` (powering the tok/s readout) increments on every stream piece including thinking. After a 1000-token reasoning episode that produces a 50-token visible reply, the user sees "12 tok · 8 tok/s" but actually decoded 1050 tokens. Fix: track `visibleTokenCount` separately by counting tokens emitted by the `ThinkBlockStreamFilter`'s `feed()` return, alongside the existing total. Surface as "12 visible · 1050 generated · 8 tok/s" in the header (or behind a tooltip — UI-design decision). Honest about why a reply that looked instant took 30 seconds.

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

## Known foot-guns (document, don't necessarily fix)

- `~/.cache/huggingface/hub` grows unbounded; no eviction.

- Switching backends mid-session doesn't clear the other's loaded model from memory — intentional (so you can flip back without reloading) but worth documenting.

- `llama.xcframework` fetch is not re-run when `LLAMA_TAG` changes; you have to `rm -rf thirdparty/llama.xcframework` first.

- Infer target is pinned to Swift 5 language mode; any new code added should still be written Swift-6-concurrency-safe so the opt-out can be removed cleanly.
