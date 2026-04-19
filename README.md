# infer

A macOS SwiftUI chat app with two local inference backends selectable at runtime:

- **llama.cpp** via `llama.xcframework`
- **MLX** via `mlx-swift-lm`

Built with Swift Package Manager and `xcodebuild`.

## Prerequisites

- macOS 14.0+
- Xcode 16.3+ with Swift 6.1+ (required by `mlx-swift-lm`)
- Metal Toolchain: `xcodebuild -downloadComponent MetalToolchain` (~700 MB, one-time)

## Build

```sh
# First run downloads llama.xcframework to thirdparty/
make bundle-infer         # -> build/Infer.app
make run-infer            # Open Infer.app
```

`make build-infer` uses `xcodebuild` (not `swift build`) because mlx-swift's Metal kernels can only be compiled by Xcode's Metal toolchain. The `llama.xcframework` is fetched by `scripts/fetch_llama_framework.sh` from the [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases); override the tag with `make build-infer LLAMA_TAG=bXXXX`.

At runtime the app offers two backends via a header picker:

- **llama.cpp** — click `Load Model…` and pick a local `.gguf` file.
- **MLX** — leave the HF repo id empty to use `LLMRegistry.gemma3_1B_qat_4bit` (~700 MB, downloaded on first use to `~/.cache/huggingface/hub/`), or paste any MLX-compatible HF id like `mlx-community/Qwen3-4B-4bit`.

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
| `build-infer` | Build the Infer chat app via `xcodebuild` |
| `bundle-infer` | Bundle as `build/Infer.app` (embeds `llama.framework` and MLX resource bundles including `default.metallib`) |
| `run-infer` | Bundle and open |
