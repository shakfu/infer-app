# Testing plan

Status: proposal. No tests exist yet. This document sketches a staged plan to introduce a test suite without upending the build.

## Constraints shaping the plan

1. **Metal Toolchain dependency.** MLX ships Metal compute kernels that only Xcode's Metal toolchain can compile. `make build-infer` uses `xcodebuild` precisely because `swift build` fails on the MLX graph. Any test target that transitively imports `MLXLLM` / `MLXVLM` / `MLXLMCommon` inherits that constraint and cannot run under plain `swift test` in CI without the ~700 MB Metal Toolchain asset.
2. **Binary framework dependencies.** `llama.xcframework` and `whisper.xcframework` are fetched on demand by `scripts/fetch_llama_framework.sh` / `scripts/fetch_whisper_framework.sh`. A clean checkout has no `thirdparty/*.xcframework/` directories, so SwiftPM resolution will fail until fetch scripts run. CI must run them as a prestep or cache the artifacts.
3. **Single executable target.** `Package.swift` declares `Infer` as `.executableTarget`, not a library. To test internals, a test target uses `@testable import Infer` — this works for executable targets in Swift 5.5+, but types under test must be `internal` (not `fileprivate`/`private`) and any `@main` entry point stays in the executable.
4. **Model assets are heavy.** Real `.gguf` files are GBs; MLX model repos are hundreds of MB; whisper `tiny.en` is ~75 MB. None belong in CI by default. Fixture-based tests should fabricate the smallest possible artifact or mock the boundary.
5. **Swift 5 language mode opt-out.** The `Infer` target currently sets `.swiftLanguageMode(.v5)`. New test code should be Swift-6-concurrency-safe so it doesn't block the eventual drop of the opt-out (P2 in TODO.md).
6. **No commits from the assistant.** Per project rules, Claude authors code and docs but never commits. All test scaffolding is reviewed and committed by the user.

## Goals

- **Catch regressions in logic that is not obvious by inspection** — chat-template rendering, message-delta tracking, settings persistence, audio format conversion, markdown/print pipeline, vault crypto round-trips.
- **Keep CI fast and hermetic.** Unit tests should run in under 30 s on a clean macOS runner without Metal Toolchain, without network, without model assets.
- **Do not test the external SDKs.** `MLXLLM.ChatSession`, `llama_decode`, `whisper_full`, `AVAudioFile`, `WKWebView` — all out of scope. Test *our* glue around them.
- **Do not chase coverage.** SwiftUI views, `@Observable` view models bound to UserDefaults, and the actor-wrapped runner surfaces are low-value to unit-test and expensive to stub. Prefer a narrow, high-signal suite.

## Two-tier architecture

### Tier 1 — `InferCore` library + `InferCoreTests` (the CI suite)

Extract pure logic into a new SwiftPM **library target** `InferCore` that depends on **no binary frameworks and no MLX/llama/whisper symbols**. The executable `Infer` target then depends on `InferCore` plus the existing binary stack.

Candidates to move into `InferCore` (listed with source-of-truth):

| New location                         | Current home                                       | Reason it is unit-testable                              |
| ------------------------------------ | -------------------------------------------------- | ------------------------------------------------------- |
| `InferCore/Settings.swift`           | `ChatView.swift` (`InferSettings`, `PersistKey`)    | Plain struct + UserDefaults keys; round-trip test.      |
| `InferCore/ChatTemplate.swift`       | `LlamaRunner.swift` (`renderTemplate`, delta calc)  | Pure string transform given a template + role/content.  |
| `InferCore/AudioDecode.swift`        | `WhisperRunner.swift` (PCM16 mono 16kHz conversion) | Deterministic given a small fixture WAV.                |
| `InferCore/WhisperModelCatalog.swift`| `WhisperRunner.swift` (`WhisperModelChoice`, URLs)  | URL/path derivation; no I/O in the hot path.            |
| `InferCore/MarkdownPrint.swift`      | `PrintRenderer.swift` (markdown → HTML stage only)  | `swift-markdown` is a pure library; skip WKWebView leg. |
| `InferCore/VaultCrypto.swift`        | `Vault.swift` (encrypt/decrypt primitives)          | CryptoKit round-trip; no keychain in the pure layer.    |

`@testable import InferCore` in `InferCoreTests` targets. All tests run under `swift test` from `projects/infer/`.

**Rule of thumb for what moves:** if the file imports `MLXLLM`, `llama`, `CWhisperBridge`, `SwiftUI`, `AppKit`, `WebKit`, or `AVFoundation` at the top level, it stays in `Infer`. If a file mixes pure logic with a framework boundary, split at the boundary: the pure half moves, the thin adapter stays.

### Tier 2 — `InferAppTests` (local-only, Xcode-driven)

A second test bundle runs **inside the Xcode project** via `xcodebuild test`. This is where tests that legitimately need Metal, MLX, or a real model go — and is also where UI smoke tests would live if we add them later.

Contents (initially empty; grow as needed):

- `LlamaRunnerSmokeTests` — load a tiny `.gguf` fixture from `Resources/test/`, assert a 1-token generation completes without crash. Gated by `INFER_HEAVY_TESTS=1` env var so it is opt-in.
- `MLXRunnerSmokeTests` — same idea against a ~10 MB MLX fixture repo if one can be located; otherwise skipped.
- `WhisperRunnerSmokeTests` — `tiny.en` + a 3-second PCM fixture; assert non-empty transcript.

These tests are **not run in CI** initially. They exist so that a developer can sanity-check a runner-level change locally before opening a PR.

## Concrete first PR (scope)

Keep the first test PR small and self-contained:

1. Add `InferCore` library target to `Package.swift`.
2. Move `InferSettings` + `PersistKey` from `ChatView.swift` to `InferCore/Settings.swift`. `ChatView.swift` imports `InferCore`.
3. Move `LlamaRunner.renderTemplate` and the `prevFormattedLen` delta helper into `InferCore/ChatTemplate.swift` as free functions or a small `struct`. `LlamaRunner` calls into them.
4. Add `InferCoreTests` target with:
   - `SettingsPersistenceTests` — write defaults, mutate each field, re-read, assert equality. Use a per-test `UserDefaults(suiteName:)` to avoid clobbering the developer's real defaults.
   - `ChatTemplateTests` — golden-file test: a fixture Jinja template + known message list → expected rendered string. One test per supported role ordering (system-only, system+user, system+user+assistant+user).
5. Add `make test` to the Makefile:
   ```
   test:
   	cd $(INFER_DIR) && swift test
   ```
6. Update `CLAUDE.md` to remove the "No tests exist yet. ... Do not fabricate a test command." note and point at `make test`.

No CI in this PR — CI is deliberately deferred to a separate PR once Tier 1 proves stable locally.

## Subsequent PRs (roughly in order)

- **PR 2:** Extract `AudioDecode` and `WhisperModelCatalog` into `InferCore`, add tests. Audio tests ship a 1-second 44.1 kHz stereo WAV fixture (~180 KB) and assert the 16 kHz mono Float32 conversion shape + a checksum.
- **PR 3:** Extract `VaultCrypto`. Tests: encrypt/decrypt round-trip, wrong-key rejection, tampered-ciphertext rejection. Key derivation stays in `Vault.swift` because it touches Keychain.
- **PR 4:** Extract `MarkdownPrint` (markdown → HTML). Golden HTML fixtures for code fences (Swift/other), tables, and links. Snapshot-style but text-only — no PDF, no `WKWebView`.
- **PR 5:** GitHub Actions workflow on `macos-14`:
  - Cache `~/Library/Caches/org.swift.swiftpm` and the `thirdparty/` fetched artifacts.
  - Steps: `make fetch-llama`, `make fetch-whisper`, `make test`.
  - Skip `make build-infer` (Metal Toolchain cost). Build is validated on developer machines pre-release.
- **PR 6:** Drop `.swiftLanguageMode(.v5)` on `Infer` by fixing `LlamaRunner.backendInitialized`. Tests from PR 2–4 guard the refactor.

## Anti-goals

- **Do not add a mocking framework.** Swift's protocol + struct ergonomics are enough; dragging in Cuckoo or Mockingbird is more weight than this suite justifies.
- **Do not write SwiftUI snapshot tests.** The UI is not the risky surface; the runners and the data path are.
- **Do not test `@MainActor` `ChatViewModel` end-to-end.** It is tightly coupled to UserDefaults and two runner actors; stubbing is expensive and the tests would break on every UI tweak. Test the dependencies it pulls in (`InferSettings`, template rendering, audio decode) and treat the view-model wiring as integration-verified by manual use.
- **Do not run network-fetching tests in CI.** `WhisperModelManager.ensureDownloaded` hits Hugging Face; mock the URL session at the boundary or skip entirely.
- **Do not weaken or skip failing tests to make CI green.** Per the global project rules, zero tolerance for test failures — find the root cause.

## Open questions

- Does `@testable import` work cleanly against an executable target that uses `@main` via `InferApp.swift`? Expected yes on Swift 6 tooling, but the first PR will confirm.
- Can we locate a small-enough MLX fixture model (tens of MB) for Tier 2? If not, `MLXRunner` smoke-test coverage stays deferred.
- Should `InferCore` be its own SwiftPM package rather than a target inside `projects/infer/Package.swift`? Separate package gives cleaner dependency boundaries but complicates `xcodebuild` wiring. Default to single-package, multi-target until there is a concrete reason to split.
