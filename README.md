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
# First run downloads llama.xcframework, whisper.xcframework, and
# KaTeX + highlight.js (for offline math/syntax rendering in PDF/print)
# into thirdparty/.
make bundle-infer         # -> build/Infer.app
make run-infer            # Open Infer.app
```

`make build-infer` uses `xcodebuild` (not `swift build`) because mlx-swift's Metal kernels can only be compiled by Xcode's Metal toolchain. The `llama.xcframework` is fetched by `scripts/fetch_llama_framework.sh` from the [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases); override the tag with `make build-infer LLAMA_TAG=bXXXX`. The `whisper.xcframework` is fetched by `scripts/fetch_whisper_framework.sh` from the [whisper.cpp releases](https://github.com/ggml-org/whisper.cpp/releases); override with `WHISPER_TAG=vX.Y.Z`. `KaTeX` + `highlight.js` are fetched by `scripts/fetch_webassets.sh` (override versions via `KATEX_VERSION` / `HLJS_VERSION`) into `thirdparty/webassets/` and bundled into `Infer.app/Contents/Resources/WebAssets/` — no CDNs at runtime.

At runtime the app offers two backends via a header picker:

- **llama.cpp** — click `Load Model…` and pick a local `.gguf` file.

- **MLX** — leave the HF repo id empty to use `LLMRegistry.gemma3_1B_qat_4bit` (~700 MB, downloaded on first use to `~/.cache/huggingface/hub/`), or paste any MLX-compatible HF id like `mlx-community/Qwen3-4B-4bit`.

## Speech

The **Voice** sidebar tab exposes live dictation, TTS, a hands-free voice loop, and whisper file transcription.

- **Live dictation** — mic button on the composer uses Apple's on-device `SFSpeechRecognizer`. Partial transcripts stream into the composer. Two auto-submit triggers (independent, whichever fires first wins):

  - **Voice-send phrase** — say the configured phrase (default `"send it"`) at the end of a dictation.

  - **Silence timeout** — set "Or send after silence: N sec" and the in-flight turn submits after N seconds without new speech.

- **Text-to-speech** — toggle "Read responses aloud" to have `AVSpeechSynthesizer` speak each completed assistant reply; voice pickable from all installed system voices.

- **Continuous voice (voice loop)** — toggle on for a hands-free cycle: TTS reads the assistant reply, then the mic auto-arms so you can dictate the next turn. Submitting (via phrase or silence) kicks off the next generation, and the loop continues. Force-enables TTS; turning TTS off clears the loop.

  - **Barge-in** sub-toggle (on by default when in loop mode): talk over the TTS to interrupt it — the mic swings straight into dictation without waiting for the reply to finish. Runs a dedicated `AVAudioEngine` tap that fires when input level stays above `-30 dBFS` for ≥ 200 ms. **Use headphones** — on laptop speakers the TTS audio leaks back into the built-in mic and self-triggers. Disable the sub-toggle for speaker use.

  - **Stop Speech** (⌘⇧.) — menu shortcut under `Speech > Stop Speaking` shuts up TTS mid-sentence. Works regardless of loop/barge-in state; handy on speakers.

- **File transcription (whisper.cpp)** — drag any audio or video file onto the window, or press **Record** to capture the mic to a `.wav`, and whisper transcribes the result into the composer. Model choice (`tiny` / `base` / `small`, all multilingual), translate-to-English toggle, and recordings actions (Reveal in Finder, Clear recordings…) live in the same tab. Whisper models download on first use to `~/Library/Application Support/Infer/whisper/`; recordings are saved to `~/Library/Application Support/Infer/recordings/`.

## Conversation vault

Every new chat is saved to `~/Library/Application Support/Infer/vault.sqlite` (GRDB + FTS5). The **History** sidebar tab has search-as-you-type across all past messages and a recent-conversations list; clicking a result loads it into the UI. Markdown transcript save/load is still available via `File > Save/Open Transcript…` but is independent of the vault.

Loading a conversation (from the History tab or `File > Open Transcript…`) restores the model's KV cache from the loaded messages, so follow-up turns have full prior context. Cost is one prompt-sized decode at load time on both backends.

## Conversation actions

Hover over the latest turn of either role to reveal inline actions:

- **Regenerate** (assistant row, circular arrow) — resample a new reply for the same user turn.

- **Edit + resend** (user row, pencil) — pop the last user/assistant pair back into the composer for editing before resending.

Both rewind the backend's KV cache and re-prefill from the truncated transcript. Available only when the VM is idle and the last two messages are a user→assistant pair.

## Reproducibility (seed)

The Parameters sidebar section has a **Seed** row. Leave the field empty (or press Clear) for a fresh random seed per generation (default). Enter a number or press Random to pin a fixed `UInt64` seed: identical prompt + params + seed produces identical output on a given backend. Useful for A/B-ing sampler settings or debugging model behavior. Persisted across launches.

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
| `fetch-webassets` | Download KaTeX + highlight.js to `thirdparty/webassets/` (versions via `KATEX_VERSION=...` / `HLJS_VERSION=...`) |
| `clean-infer` | Remove only `build/infer-xcode` (xcodebuild derived data) |
| `clean-mlx-cache` | Remove `$HF_HOME/hub` (MLX model cache) after confirmation |
| `generate-icon` | Regenerate `projects/infer/Resources/AppIcon.icns` from `scripts/generate_app_icon.swift` |
| `build-infer` | Build the Infer chat app via `xcodebuild` |
| `bundle-infer` | Bundle as `build/Infer.app` (embeds `llama.framework`, `whisper.framework`, MLX resource bundles including `default.metallib`, `AppIcon.icns`, and `WebAssets/` with KaTeX + highlight.js) |
| `run-infer` | Bundle and open |
