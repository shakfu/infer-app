# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
