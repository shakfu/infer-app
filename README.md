# infer

A macOS SwiftUI chat app with two local inference backends selectable at runtime:

- **llama.cpp** via `llama.xcframework`
- **MLX** via `mlx-swift-lm`

Plus, local speech-to-text via `whisper.cpp` (file drop and in-app recording), on-device dictation via `SFSpeechRecognizer`, TTS, a searchable SQLite vault of all conversations, and Markdown/PDF/HTML transcript export.

Built with Swift Package Manager and `xcodebuild`.

## Prerequisites

- macOS 14.0+
- Xcode 16.3+ with Swift 6.1+ (required by `mlx-swift-lm`)
- Metal Toolchain: `xcodebuild -downloadComponent MetalToolchain` (~700 MB, one-time)

## Build

```sh
# First run downloads llama.xcframework and whisper.xcframework into thirdparty/
make bundle-infer         # -> build/Infer.app
make run-infer            # Open Infer.app
```

`make build-infer` uses `xcodebuild` (not `swift build`) because mlx-swift's Metal kernels can only be compiled by Xcode's Metal toolchain. The `llama.xcframework` is fetched by `scripts/fetch_llama_framework.sh` from the [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases); override the tag with `make build-infer LLAMA_TAG=bXXXX`. The `whisper.xcframework` is fetched by `scripts/fetch_whisper_framework.sh` from the [whisper.cpp releases](https://github.com/ggml-org/whisper.cpp/releases); override with `WHISPER_TAG=vX.Y.Z`.

At runtime the app offers two backends via a header picker:

- **llama.cpp** — click `Load Model…` and pick a local `.gguf` file.
- **MLX** — leave the HF repo id empty to use `LLMRegistry.gemma3_1B_qat_4bit` (~700 MB, downloaded on first use to `~/.cache/huggingface/hub/`), or paste any MLX-compatible HF id like `mlx-community/Qwen3-4B-4bit`.

## Speech

The **Voice** sidebar tab exposes three features:

- **Live dictation** — mic button on the composer uses Apple's on-device `SFSpeechRecognizer`. Partial transcripts stream into the composer. Say the voice-send phrase (default `"send it"`) to auto-submit.
- **Text-to-speech** — toggle "Read responses aloud" to have `AVSpeechSynthesizer` speak each completed assistant reply; voice pickable from all installed system voices.
- **File transcription (whisper.cpp)** — drag any audio or video file onto the window, or press **Record** to capture the mic to a `.wav`, and whisper transcribes the result into the composer. Model choice (`tiny` / `base` / `small`, all multilingual), translate-to-English toggle, and recordings actions (Reveal in Finder, Clear recordings…) live in the same tab. Whisper models download on first use to `~/Library/Application Support/Infer/whisper/`; recordings are saved to `~/Library/Application Support/Infer/recordings/`.

## Conversation vault

Every new chat is saved to `~/Library/Application Support/Infer/vault.sqlite` (GRDB + FTS5). The **History** sidebar tab has search-as-you-type across all past messages and a recent-conversations list; clicking a result loads it into the UI. Markdown transcript save/load is still available via `File > Save/Open Transcript…` but is independent of the vault.

## Clean

```sh
make clean              # Remove build/
```

## Makefile Targets

| Target | Description |
|---|---|
| `build` | Alias for `build-infer` |
| `clean` | Remove `build/` |
| `fetch-llama` | Download `thirdparty/llama.xcframework` (tag via `LLAMA_TAG=...`) |
| `fetch-whisper` | Download `thirdparty/whisper.xcframework` (tag via `WHISPER_TAG=...`) |
| `generate-icon` | Regenerate `projects/infer/Resources/AppIcon.icns` from `scripts/generate_app_icon.swift` |
| `build-infer` | Build the Infer chat app via `xcodebuild` |
| `bundle-infer` | Bundle as `build/Infer.app` (embeds `llama.framework`, `whisper.framework`, MLX resource bundles including `default.metallib`, and `AppIcon.icns`) |
| `run-infer` | Bundle and open |
