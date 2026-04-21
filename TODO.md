# TODO

Roughly prioritized by user-facing impact / effort ratio. Items within a tier are not strictly ordered.

## P0 — small, high value

_(empty — all P0 items complete as of this commit)_

## P1 — feature completeness

- [ ] **Restore backend context when loading a transcript.** Currently `loadTranscript()` replaces UI messages but resets both backends — the model has no memory of the loaded turns. Fix asymmetrically: **(llama)** add `LlamaRunner.setHistory(_: [(role, content)])` that replaces the private `messages` array, renders the full template with `addAssistant: false`, tokenizes it, submits one `llama_decode` batch to pre-fill the KV cache, and updates `prevFormattedLen`. Cost: one prompt-sized decode on load (same as the first turn of a long chat). **(MLX)** `ChatSession` encapsulates history with no injection hook, so genuine resume requires abandoning `ChatSession` and driving `ModelContainer` directly with a manual prompt builder — significant `MLXRunner` rewrite. Short-term: show a clear banner in the transcript when a load happens on MLX ("Conversation loaded for review — the model does not have this context"). Once the llama path lands, only MLX shows the banner.

- [ ] **Timestamps per message.** Stash `Date` on each `ChatMessage`, show as `HH:mm` in the gutter. Helps when triaging long sessions.

- [ ] **Tokens / sec readout.** Both runners know token count and wall clock; surface tok/s + total tokens in the footer while generating.

- [ ] **Regenerate last response.** Pop the last assistant message, rewind the backend's conversation state, re-send the previous user turn. On MLX: reset `ChatSession` and replay history up to that turn. On llama: rewind `prevFormattedLen` + pop the last two `messages` entries.

- [ ] **Multi-language syntax highlighting in chat.** Splash is Swift-only. Swap for Highlightr (highlight.js via JavaScriptCore) behind the existing `CodeSyntaxHighlighter` interface; the call site in `MessageRow` doesn't change.

- [ ] **Syntax highlighting in printed PDF.** Inject a highlight.js stylesheet + `<script>` call into `PrintRenderer.wrap(body:)` so the WKWebView HTML picks up colors before `createPDF` snapshots it. One-liner once the JS CDN is embedded as a resource.

- [ ] **Voice-loop mode.** Full hands-free cycle: after TTS finishes reading an assistant response, auto-arm the mic; the user dictates a reply, the existing voice-send trigger phrase submits it, and the TTS-on-completion hook reads the next response aloud. Toggle in the Speech sidebar section ("Continuous voice"). Builds on three already-shipped pieces (SFSpeechRecognizer dictation, AVSpeechSynthesizer readout, trigger-phrase send) — this one item is what makes Infer a legitimately novel local voice-chat app.

- [ ] **Edit + resend last user message.** Pencil icon on the most recent user turn. Pops it off, rewinds backend conversation state (same mechanic as the Regenerate item above), re-populates the composer with the original text. Cheap once Regenerate lands — they share the rewind plumbing.

- [ ] **Seed + reproducibility.** Add a `seed: UInt64?` field to `InferSettings`. llama supports it via `llama_sampler_init_dist(seed)`; MLX exposes it through `GenerateParameters`. Optional (nil = random); when set, identical prompt + params + seed produces identical output. Essential for debugging model behavior and for comparing sampler settings.

- [ ] **System prompt presets.** Named library of system prompts (Coding Assistant, Research, Concise, Creative, etc.). Small JSON file in `Application Support/` + a picker in the sidebar's System Prompt disclosure. Save-current-as and delete actions. Pairs naturally with the existing System Prompt field.

- [ ] **Cmd+F transcript search.** In-transcript find bar. Scroll to next/previous match with Cmd+G / Shift+Cmd+G, highlight matches in `MessageRow`. `AttributedString` with background-color runs on matched ranges works inside `MarkdownUI`.

- [ ] **Stop sequences.** User-defined strings in settings that halt generation when emitted. llama has per-token stop handling in the sampler loop; MLX takes `extraEOSTokens`. Handy for forcing structured output boundaries (e.g. `---`, `</answer>`).

- [ ] **Hold-to-talk (push-to-talk).** Alternative to the current mic-toggle: hold a hotkey (Fn or a configurable modifier) while Infer is key window → mic on for the hold duration, release → stop + submit. Add a sidebar setting "Dictation mode: Toggle | Push-to-talk". Toggle mode is easy to forget is on; PTT is what most dictation-savvy users expect.

- [ ] **TTS interrupt by voice.** While `AVSpeechSynthesizer` is speaking, run a lightweight `AVAudioEngine` level meter (no SFSpeechRecognizer). If input level exceeds a threshold (~-30 dBFS) for > 200 ms, call `synth.stopSpeaking(at: .immediate)` so the user can interject. Closes the voice loop — without this, TTS is rude.

- [ ] **Whisper.cpp speech-to-text backend.** Current speech input uses `SFSpeechRecognizer` (on-device) which is mechanically free but constrained by Apple's model quality and locale coverage. Add whisper.cpp as an alternative via the xcframework at <https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.4/whisper-v1.8.4-xcframework.zip>, fetched by a new `scripts/fetch_whisper_framework.sh` mirroring `fetch_llama_framework.sh`. Wrap behind a `WhisperRunner` actor with `load(modelPath:)` / `transcribe(audioURL:) -> String`; bundle the framework into `Infer.app/Contents/Frameworks/` from `bundle-infer`; wire cleanup into `AppDelegate.applicationWillTerminate`. UX: segmented control (SFSpeechRecognizer vs Whisper) in the Speech sidebar section; on first whisper use, download a ggml model (start with `tiny.en` ~75 MB) into `Application Support/`. Reuse the existing mic button — only the ASR backend changes.

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

- [ ] **VLM support.** `mlx-swift-lm` exposes `MLXVLM`; add a drag-target for images and route through `UserInput.Image`.

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

- [ ] **Integrate AgentRunKit for tools / MCP / cloud providers.** See <https://github.com/Tom-Ryder/AgentRunKit> — Swift 6 agent SDK with tool calling, MCP client (stdio transport + tool discovery), streaming, and providers for OpenAI, Anthropic, MLX, and Apple Foundation Models. Pulls in zero deps at the core; `AgentRunKitMLX` needs the `mlx-swift-lm` we already ship. Three possible drivers, do any that stick: **(a)** cloud providers — add OpenAI/Anthropic backends alongside llama+MLX (new `Backend` cases, a provider picker in the sidebar, API-key storage in Keychain); **(b)** tool calling — wire up a handful of `Tool<Params, Out, Ctx>` (web search, file read, maybe shell) and surface tool-call turns distinctly in the transcript (current `ChatMessage` is user/assistant/system only — would need a `.tool` role and a renderer that shows params+result); **(c)** MCP — let users connect Infer to local MCP servers via a sidebar section, tool list populated dynamically. Constraints: bumps deployment target from macOS 14 → 15 (AgentRunKit minimum); `AgentRunKitFoundationModels` needs macOS 26 (skip for now); AgentRunKit has no llama.cpp provider, so either keep `LlamaRunner` outside the agent path (asymmetric) or write a custom `Client` wrapper around it (~half the work of adopting the library). Decide which of (a)/(b)/(c) is actually wanted before starting.

## Known foot-guns (document, don't necessarily fix)

- `~/.cache/huggingface/hub` grows unbounded; no eviction.

- Switching backends mid-session doesn't clear the other's loaded model from memory — intentional (so you can flip back without reloading) but worth documenting.

- `llama.xcframework` fetch is not re-run when `LLAMA_TAG` changes; you have to `rm -rf thirdparty/llama.xcframework` first.

- Infer target is pinned to Swift 5 language mode; any new code added should still be written Swift-6-concurrency-safe so the opt-out can be removed cleanly.
