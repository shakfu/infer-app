# TODO

Roughly prioritized by user-facing impact / effort ratio. Items within a tier are not strictly ordered.

## P0 — small, high value

- [x] **Respect light/dark mode in the transcript.** Transcript background is currently hard-coded `Color.white`; switch to `Color(.textBackgroundColor)` so it adapts. Windows in dark mode currently show black text on white, which is jarring.
- [x] **Show MLX download progress.** First-time `#huggingFaceLoadModelContainer` can sit for minutes with just `"Downloading default…"` in the status line. `ModelContainer` loaders accept a progress callback — wire it to a determinate `ProgressView` in the header.
- [x] **Cancel in-flight model load.** Right now `Load` is fire-and-forget; no way to abort a stuck HF download or a slow `.gguf` mmap. Add a cancel affordance that flips back to the pre-load state. _(caveat: llama's synchronous mmap only aborts at the next await point)_
- [x] **System prompt / instructions field.** `ChatSession` and the llama wrapper both accept a system message; expose a small settings popover (persisted in `UserDefaults`).
- [x] **Generation parameters UI.** Expose `temperature`, `top_p`, `max_tokens`. Today both backends use hardcoded defaults; the llama runner uses `maxTokens: 512` and a fixed sampler chain.

## P1 — feature completeness

- [ ] **Save / load transcript** as `.md`. Reuse the Edit > Copy path: write the same markdown to a file, open a picker to reload into `messages`. Cheap, high utility.
- [ ] **Timestamps per message.** Stash `Date` on each `ChatMessage`, show as `HH:mm` in the gutter. Helps when triaging long sessions.
- [ ] **Tokens / sec readout.** Both runners know token count and wall clock; surface tok/s + total tokens in the footer while generating.
- [ ] **Regenerate last response.** Pop the last assistant message, rewind the backend's conversation state, re-send the previous user turn. On MLX: reset `ChatSession` and replay history up to that turn. On llama: rewind `prevFormattedLen` + pop the last two `messages` entries.
- [ ] **Multi-language syntax highlighting in chat.** Splash is Swift-only. Swap for Highlightr (highlight.js via JavaScriptCore) behind the existing `CodeSyntaxHighlighter` interface; the call site in `MessageRow` doesn't change.
- [ ] **Syntax highlighting in printed PDF.** Inject a highlight.js stylesheet + `<script>` call into `PrintRenderer.wrap(body:)` so the WKWebView HTML picks up colors before `createPDF` snapshots it. One-liner once the JS CDN is embedded as a resource.
- [ ] **Recent MLX model id history.** The HF id text field has no history; back it with a small `UserDefaults` array and a `Picker`/menu.

- [ ] **Add support Whisper.cpp** -- see <https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.4/whisper-v1.8.4-xcframework.zip>

## P2 — hygiene & infra

- [ ] **Drop `.swiftLanguageMode(.v5)` on the Infer target.** The only blocker is `LlamaRunner.backendInitialized: static var` tripping Swift 6 strict-concurrency. Replace with an `actor` or an `@MainActor`-isolated initializer, then remove the opt-out.
- [ ] **Tests for the runners.** Neither backend is tested. Start with: `LlamaRunner.renderTemplate` round-trip on a known chat template; `MLXRunner.load(hfId:)` happy path against a tiny fixture model if feasible, otherwise mock the `ModelContainer`.
- [ ] **CI.** GitHub Actions on macos-14 running `swift test` against `projects/infer`, plus a lint step. Leave `build-infer` out of CI initially — it needs the ~700 MB Metal Toolchain asset and HF downloads.
- [ ] **`make clean-infer` and `make clean-mlx-cache`.** First nukes `build/infer-xcode`; second rm -rf's `~/.cache/huggingface/hub` after confirmation. The HF cache can easily grow past 20 GB.
- [ ] **Troubleshooting section in README.** Document the three foot-guns hit during setup: Metal Toolchain not installed → `cannot execute tool 'metal'`; `WKWebView.printOperation` → blank PDF (hence the PDFKit indirection); `swift build` cannot build MLX (hence `xcodebuild`).
- [ ] **Pin exact dep versions in Package.swift.** Several `.package(..., from: "X")` will resolve forward and silently drift. For reproducible builds, pin with `.upToNextMinor(from:)` or explicit revisions in a `Package.resolved` committed to the repo.

## P3 — nice to have

- [ ] **VLM support.** `mlx-swift-lm` exposes `MLXVLM`; add a drag-target for images and route through `UserInput.Image`.
- [ ] **Curated MLX model picker.** Instead of a raw HF id text field, a dropdown populated from `LLMRegistry` entries + a "custom…" option.
- [ ] **Multi-conversation tabs.** Current design assumes one chat per window. `WindowGroup` + a document-based model would let ⌘T open a new conversation. Non-trivial refactor; only worth doing if the app becomes daily-driver.
- [ ] **Export conversation as rendered HTML / PDF.** Reuse `PrintRenderer`'s HTML template; add a "Save as…" alongside Print.
- [ ] **Better table rendering in print.** `HTMLFormatter` emits standard `<table>`; add zebra striping + caption support in the print CSS.
- [ ] **Error log panel.** Alerts disappear; a pull-up panel showing recent errors (with copy-to-clipboard) would help when iterating on models.

## Known foot-guns (document, don't necessarily fix)

- `~/.cache/huggingface/hub` grows unbounded; no eviction.
- Switching backends mid-session doesn't clear the other's loaded model from memory — intentional (so you can flip back without reloading) but worth documenting.
- `llama.xcframework` fetch is not re-run when `LLAMA_TAG` changes; you have to `rm -rf thirdparty/llama.xcframework` first.
- Infer target is pinned to Swift 5 language mode; any new code added should still be written Swift-6-concurrency-safe so the opt-out can be removed cleanly.
