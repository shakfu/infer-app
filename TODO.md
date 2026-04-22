# TODO

Roughly prioritized by user-facing impact / effort ratio. Items within a tier are not strictly ordered.

## P0 — small, high value

## P1 — feature completeness

- [ ] **Timestamps per message.** Stash `Date` on each `ChatMessage`, show as `HH:mm` in the gutter. Helps when triaging long sessions.

- [ ] **Multi-language syntax highlighting in chat.** Splash is Swift-only. Swap for Highlightr (highlight.js via JavaScriptCore) behind the existing `CodeSyntaxHighlighter` interface; the call site in `MessageRow` doesn't change.

- [ ] **Native syntax highlighting via SwiftTreeSitter (alternative path).** If we want to avoid the JavaScriptCore runtime that Highlightr pulls in, the native route is [SwiftTreeSitter](https://github.com/ChimeHQ/SwiftTreeSitter) + per-language parsers. Start narrow: bundle `tree-sitter-python` and `tree-sitter-swift` (the two languages most chat responses use), plus a highlights query per grammar copied from each parser repo's `queries/highlights.scm`. Implement `TreeSitterCodeHighlighter: CodeSyntaxHighlighter` that maps TS highlight capture names (`@keyword`, `@string`, `@function`, etc.) to SwiftUI `Color`s; fall back to plain monospaced `Text` for unknown languages. Cost: ~3 MB of bundled parser static libs per language, ~150 lines of Swift, and per-language grammar upkeep whenever syntax evolves. Pick this over Highlightr if coverage-by-handful (Python + Swift) is the real target and avoiding a JS runtime matters; pick Highlightr if paste-anything-highlights-it is the target.

- [ ] **Syntax highlighting in printed PDF.** Inject a highlight.js stylesheet + `<script>` call into `PrintRenderer.wrap(body:)` so the WKWebView HTML picks up colors before `createPDF` snapshots it. One-liner once the JS CDN is embedded as a resource.

- [ ] **Voice-loop mode.** Full hands-free cycle: after TTS finishes reading an assistant response, auto-arm the mic; the user dictates a reply, the existing voice-send trigger phrase submits it, and the TTS-on-completion hook reads the next response aloud. Toggle in the Speech sidebar section ("Continuous voice"). Builds on three already-shipped pieces (SFSpeechRecognizer dictation, AVSpeechSynthesizer readout, trigger-phrase send) — this one item is what makes Infer a legitimately novel local voice-chat app.

- [ ] **System prompt presets.** Named library of system prompts (Coding Assistant, Research, Concise, Creative, etc.). Small JSON file in `Application Support/` + a picker in the sidebar's System Prompt disclosure. Save-current-as and delete actions. Pairs naturally with the existing System Prompt field.

- [ ] **Cmd+F transcript search.** In-transcript find bar. Scroll to next/previous match with Cmd+G / Shift+Cmd+G, highlight matches in `MessageRow`. `AttributedString` with background-color runs on matched ranges works inside `MarkdownUI`.

- [ ] **Stop sequences.** User-defined strings in settings that halt generation when emitted. llama has per-token stop handling in the sampler loop; MLX takes `extraEOSTokens`. Handy for forcing structured output boundaries (e.g. `---`, `</answer>`).

- [ ] **Hold-to-talk (push-to-talk).** Alternative to the current mic-toggle: hold a hotkey (Fn or a configurable modifier) while Infer is key window → mic on for the hold duration, release → stop + submit. Add a sidebar setting "Dictation mode: Toggle | Push-to-talk". Toggle mode is easy to forget is on; PTT is what most dictation-savvy users expect.

- [ ] **TTS interrupt by voice.** While `AVSpeechSynthesizer` is speaking, run a lightweight `AVAudioEngine` level meter (no SFSpeechRecognizer). If input level exceeds a threshold (~-30 dBFS) for > 200 ms, call `synth.stopSpeaking(at: .immediate)` so the user can interject. Closes the voice loop — without this, TTS is rude.

- [x] **Whisper.cpp file-transcription backend.** whisper.cpp xcframework fetched by `scripts/fetch_whisper_framework.sh`, wrapped in `WhisperRunner` actor (`load(modelPath:)` / `transcribeFile(...)`), bundled into `Infer.app/Contents/Frameworks/`, cleanup wired into `AppDelegate.applicationWillTerminate`. `WhisperModelManager` downloads ggml models on demand into `Application Support/Infer/whisper/`. UX is drag-and-drop audio files into the chat, with a model picker + translate toggle in the Speech sidebar section.

- [ ] **Whisper.cpp as live-mic ASR backend.** Extends the file-transcription work above to the live mic path. Today the mic button is wired exclusively to `SFSpeechRecognizer`; swap it behind a segmented control (SFSpeechRecognizer vs Whisper) in the Speech sidebar section so the existing mic button can drive either backend. Needs a streaming/chunked capture path feeding `WhisperRunner` (SFSpeechRecognizer is continuous; whisper.cpp is batch — likely capture to a rolling buffer and transcribe on stop, or run fixed-window chunks for partial results).

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

- [ ] **Integrate AgentRunKit — phased.** See <https://github.com/Tom-Ryder/AgentRunKit> — Swift 6 agent SDK with tool calling, MCP client (stdio transport + tool discovery), streaming, and providers for OpenAI, Anthropic, MLX, and Apple Foundation Models. Pulls in zero deps at the core; `AgentRunKitMLX` needs the `mlx-swift-lm` we already ship. Cross-cutting constraints: bumps deployment target from macOS 14 → 15 (AgentRunKit minimum); `AgentRunKitFoundationModels` needs macOS 26 (skip); no llama.cpp provider exists upstream, so `LlamaRunner` stays on its current path unless/until we write a custom `Client` wrapper (deferred — see phase 4).

  - [ ] **Phase 1 — cloud providers (OpenAI + Anthropic).** Add two new `Backend` cases backed by AgentRunKit's providers. API keys stored in Keychain (extend `Vault.swift` or add a sibling). Sidebar gets a key-entry affordance per provider. Model list per provider is a plain string picker for now (no `/v1/models` call). `ChatViewModel` grows a third runner path parallel to `LlamaRunner`/`MLXRunner`; no tool-call support yet — treat assistant output as plain text even if the provider offers tools. Keep `LlamaRunner` outside the agent path (asymmetric but honest).
  - [ ] **Phase 2 — tool calling UI.** Extend `ChatMessage.Role` with `.tool` (and probably a `.toolCall` variant on assistant turns carrying params). Renderer shows the call + result as a collapsed disclosure block. Wire up a small built-in tool set via `Tool<Params, Out, Ctx>` — start with web search and file read; gate shell behind an explicit per-session opt-in. Only active when the selected backend supports tools (OpenAI/Anthropic from phase 1; MLX gets it when the underlying model supports it).
  - [ ] **Phase 3 — MCP servers.** Sidebar section listing configured MCP servers (stdio transport). Tool list populated from each server's discovery; merged into the active tool set per turn. Config persisted alongside other settings; secrets (if any) go through the same Keychain path as phase 1. Requires phase 2's UI to be useful.
  - [ ] **Phase 4 (optional) — llama.cpp as an AgentRunKit `Client`.** Only worth doing if the asymmetry from phase 1 causes duplication pain. Would let llama participate in tool-calling (phase 2), but llama models' tool-call quality is model-dependent and often poor, so the payoff is narrow.

## Known foot-guns (document, don't necessarily fix)

- `~/.cache/huggingface/hub` grows unbounded; no eviction.

- Switching backends mid-session doesn't clear the other's loaded model from memory — intentional (so you can flip back without reloading) but worth documenting.

- `llama.xcframework` fetch is not re-run when `LLAMA_TAG` changes; you have to `rm -rf thirdparty/llama.xcframework` first.

- Infer target is pinned to Swift 5 language mode; any new code added should still be written Swift-6-concurrency-safe so the opt-out can be removed cleanly.
