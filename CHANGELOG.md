# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1]

### Added

- **SQLite-backed conversation vault.** Every new chat is persisted to `~/Library/Application Support/Infer/vault.sqlite` (WAL mode) via GRDB. FTS5 full-text search across all past conversations from a **History** sidebar tab with search-as-you-type (250 ms debounce), recent-conversations list, per-row delete, and a guarded "Clear vault…" action. Clicking a result loads that conversation into the UI; further turns append to the same vault row. Vault writes are best-effort and never block generation. Conversation row is created lazily on first `send()`; `reset()`, system-prompt changes, and `.md` import all start a fresh row on the next send.

- **whisper.cpp file transcription.** Drag audio or video onto the window (`.wav`, `.mp3`, `.m4a`, `.aac`, `.aiff`, `.caf`, `.flac`, `.mp4`, `.mov`, `.ogg`, `.opus`) → whisper transcribes → transcript appears in the composer prefixed with `[Transcript of <filename>]`. Fetched from `whisper.xcframework` v1.8.4 by `scripts/fetch_whisper_framework.sh` and bundled into `Infer.app/Contents/Frameworks/`. Default model is `base` (multilingual, 142 MB); `tiny` and `small` are also selectable. Models download to `~/Library/Application Support/Infer/whisper/ggml-<size>.bin` on first use with a progress bar in the sidebar and a banner above the composer. Translate-to-English toggle in the Voice tab. SFSpeechRecognizer live dictation is unchanged — whisper is file-only.

- **In-app voice recording.** Record / Stop button in the Voice tab captures the mic to a `.wav` at the input device's native format (`~/Library/Application Support/Infer/recordings/recording-YYYYMMDD-HHmmss.wav`) and auto-transcribes via whisper on stop. Live duration readout while recording; cancel (×) discards the in-flight file. "Reveal in Finder" and "Clear recordings…" (NSAlert-confirmed) actions alongside.

- **App icon.** Placeholder 1024×1024 squircle generated programmatically from `scripts/generate_app_icon.swift` (CoreGraphics → `iconutil`). Indigo→violet gradient with a three-input-to-one-output inference glyph. `bundle-infer` now copies `projects/infer/Resources/AppIcon.icns` into `Infer.app/Contents/Resources/`. Regeneratable via `make generate-icon`.

- **CWhisperBridge** C target in `Package.swift`. Narrow wrapper over `whisper.h` that exposes only primitive-typed functions, isolating whisper's bundled `ggml.h` from the Swift module graph so the Infer target can also import `llama` (which ships its own, incompatible `ggml.h`) without a Clang type-redefinition error.

- `VaultStore.shutdown()` and `WhisperRunner.shared.shutdown()` are wired into `AppDelegate.applicationWillTerminate` alongside the llama / MLX cleanups, giving the vault a deterministic WAL checkpoint on quit and releasing the whisper context.

- Collapsible right sidebar (⌘-toggled via a header button) with four sections, replacing the previous gear popover:

  - **Parameters**: Temperature / Top P sliders, Max tokens stepper-as-slider, collapsible System Prompt editor with Reset / Apply.

  - **Model**: segmented backend picker, per-backend "recent models" dropdown (paths for llama, HF ids for MLX), HF repo-id field, Load / Browse / Cancel button.

  - **Speech** (see below).

  - **Appearance**: Light / Dark / System segmented picker; default is Light.

- On-device speech dictation via `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`. Mic button on the left of the composer toggles recording; partial transcripts append to the current composer text via a configurable baseline so the user's existing draft is preserved.

- Text-to-speech for assistant responses via `AVSpeechSynthesizer`. Toggleable "Read responses aloud" with a voice picker (listing all installed macOS voices sorted by language) and a Preview / Stop pair. Auto-speaks the completed assistant message when enabled.

- Voice-send trigger phrase: say a configurable phrase (default `"send it"`) at the end of a dictation to strip it and auto-submit. Requires a word boundary so `"resend it"` doesn't match. Editable from the Speech sidebar.

- Composer expander: `>` chevron left of the text field; click or Shift+Return swaps the single-line `TextField` for a multi-line `TextEditor` (120–260pt). Auto-collapses after send. Cmd+Return always submits; Return submits when collapsed, inserts a newline when expanded.

- Auto-scroll pause: transcript follows the bottom during streaming only when the user is pinned there. Scrolling up unpins; a "↓ Jump to latest" capsule pill appears at the bottom and re-pins on tap. Sending a new message re-pins automatically.

- Context-window indicator in the header: progress bar + `used / total` token count for llama (exposes `llama_n_ctx`), approximate `~N tok` for MLX (char-count estimate). Bar tints orange >80%, red >95%.

- Per-message copy button: hover-reveal icon on each message row; copies that single turn to the pasteboard with a brief green-checkmark confirmation.

- `File > Open Transcript…` (⌘O) and `File > Save Transcript…` (⌘S): read / write the canonical markdown format produced by Copy as Markdown. Loading replaces the UI transcript and resets both backends (backend context is not restored — see TODO).

- `File > Export as HTML…` and `File > Export as PDF…` (⌘⇧E). Exports reuse the same styled HTML as Print. PDF export explicitly paginates the `WKWebView` tall-page output into paper-sized pages via `CGContext` / `CGPDFContext`, respecting `NSPrintInfo.shared.paperSize` (Letter or A4 per locale).

- Tokens/sec readout in the header during and after generation: `123 tok · 45.2 tok/s`, computed from stream-piece count and wall-clock. Accent color while generating, secondary once complete; cleared on Reset.

- Syntax highlighting in the print / export HTML pipeline via `highlight.js` (GitHub theme, loaded from the cdnjs CDN with an inline `hljs.highlightAll()` call). Graceful degradation when offline.

- Improved table styling in the print / export HTML: full-width, zebra-striped rows, header-row background, italic `<caption>` support.

- Info.plist: `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` strings so the OS can present the privacy prompts for dictation.

- `scripts/space_bullets.py`: argparse-based utility that inserts blank lines between adjacent markdown bullets; supports `--in-place`, `--recursive` (with a dry-run by default), `--glob`, and `--exclude` (default excludes `.git`, `.build`, `build`, `node_modules`, `.venv`, `venv`).

### Changed

- **Sidebar reorganized into icon tabs.** The sidebar is now four icon tabs at the top (Model, History, Voice, Appearance) instead of a single scrolling column of sections. The Model tab contains both Model and Parameters (both affect inference); single-content tabs drop their redundant section header. Selection is not persisted across launches.

- Transcript auto-scroll is now conditional on a `pinnedToBottom` flag derived from a bottom-sentinel `onAppear` / `onDisappear` inside the `LazyVStack`, replacing the previous unconditional `proxy.scrollTo(last.id)` on every token.

- `PrintRenderer` refactored: `transcriptHTML(_:)` is now a pure function reused by print / HTML export / PDF export. The `renderPDF(for:completion:)` pipeline is shared and keyed by `ObjectIdentifier` so concurrent operations no longer stomp on a single static `pending` slot.

- MLX model-download status shows an indeterminate spinner with "Resolving …" until the first byte-progress callback fires, then switches to the determinate bar labelled "Downloading …". Previously a misleading "0%" sat on screen during the HF metadata phase.

- `pre` blocks in exported / printed HTML now `white-space: pre-wrap` with `overflow-wrap: anywhere`; long code lines wrap within the page instead of overflowing and getting clipped by `createPDF`.

- Preferred color scheme defaults to Light and is persisted under `infer.appearance` via `@AppStorage`.

### Fixed

- Exported PDFs are now multi-page and correctly paper-sized. `WKWebView.createPDF` always emits a single tall page; the prior export implementation wrote that tall single page to disk (~17-inch height) or fit-scaled it onto one page (cutting off the top). Export now slices the tall source into paper-sized pages via a `CGContext` PDF consumer.

- Exported PDF layout width no longer depends on `NSPrintInfo.shared`'s current margin state. The `WKWebView` frame width is computed as `paperSize.width − 2*pageSideMargin` from a dedicated `pageSideMargin` constant, so Print and Export produce identical page geometry.

- SFSpeechRecognizer fast-path: when permission is already authorized, `start()` now uses synchronous `authorizationStatus()` and skips the async `requestAuthorization` round-trip, so the mic button transitions to `.recording` on the same runloop as the tap. Added an `isStarting` re-entrancy guard so rapid double-clicks during the first-time permission flow can't corrupt state.

- SFSpeechRecognizer no longer forces `requiresOnDeviceRecognition = true` unconditionally; it's now gated on `supportsOnDeviceRecognition`. Non-benign errors are surfaced to the Speech sidebar (previously swallowed).

## [0.1.0]

### Added

- SwiftUI chat app with two inference backends selectable at runtime via a header picker.

  - `llama.cpp` backend: loads a local `.gguf` file through `llama.xcframework` (downloaded by `scripts/fetch_llama_framework.sh`).

  - MLX backend: loads any MLX-compatible Hugging Face repo id via `mlx-swift-lm` (Mode 1 integration using `#huggingFaceLoadModelContainer`); defaults to `LLMRegistry.gemma3_1B_qat_4bit`.

- `scripts/fetch_llama_framework.sh`: downloads a tagged `llama-<tag>-xcframework.zip` from the llama.cpp releases and installs `thirdparty/llama.xcframework` (default tag `b8848`).

- Makefile targets: `fetch-llama`, `build-infer`, `bundle-infer`, `run-infer`.

- Markdown rendering for assistant messages via `swift-markdown-ui` with the `gitHub` theme.

- Swift syntax highlighting for fenced code blocks via `Splash` (other languages render monospaced/themed but uncolored).

- Hyperlinks in assistant messages open in the default browser (custom `OpenURLAction` routing to `NSWorkspace.shared.open`).

- Auto-load the last successfully loaded model on app launch (backend + path/HF id persisted in `UserDefaults`).

- `Edit > Copy Transcript as Markdown` (⇧⌘C): copies the full session as markdown (one `## <role>` block per message, separated by `---`).

- `File > Print Transcript…` (⌘P): renders the transcript through `swift-markdown`'s `HTMLFormatter` into a styled HTML document, loads it in an off-screen `WKWebView`, snapshots via `createPDF(configuration:)`, and prints through `PDFDocument.printOperation` for reliable pagination.

- Header settings popover (gear icon) with:

  - System prompt (multi-line `TextEditor`), applied to `ChatSession(instructions:)` on MLX and prepended as role=`system` on llama.

  - `temperature` and `top_p` sliders — rebuild the llama sampler chain / MLX `GenerateParameters` without requiring re-load.

  - `max_tokens` stepper, applied per-send on both backends.

  - Settings persist across launches in `UserDefaults`.

- Determinate progress bar for MLX model downloads via the `progressHandler` variant of `#huggingFaceLoadModelContainer`.

- `Cancel` button in the header while a load is in flight; cancels the load `Task` and rolls the UI back to the pre-load state.

### Changed

- Migrated from CMake to Swift Package Manager.

- `make build-infer` uses `xcodebuild` (not `swift build`) because mlx-swift's Metal kernels can only be compiled by Xcode's Metal toolchain; this requires the separate Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`, ~700 MB, one-time).

- `bundle-infer` embeds `llama.framework` (from the `macos-arm64_x86_64` xcframework slice) into `Infer.app/Contents/Frameworks/` and copies SPM-emitted resource bundles (including `mlx-swift_Cmlx.bundle` containing `default.metallib`) into `Infer.app/Contents/Resources/`.

- Transcript background now uses `Color(.textBackgroundColor)` so it follows the system light/dark appearance.

### Notes

- First MLX model load downloads to `~/.cache/huggingface/hub/` (standard HF cache layout; override with `HF_HOME`).

- Prerequisites: Xcode 16.3+ / Swift 6.1+ (required by `mlx-swift-lm`).

- Load cancellation for the llama backend is cooperative: `llama_model_load_from_file` is a synchronous C call, so `Task.cancel()` only takes effect at the next Swift await point (fine for HF downloads, best-effort for large `.gguf` mmap).

- Changing the system prompt resets the conversation on both backends (history is lost); sampler param changes (`temperature`, `top_p`) do not.
