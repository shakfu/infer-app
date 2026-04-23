# Testing plan

Status: partially implemented as of 2026-04-23. PR 1 (InferCore extraction, Settings + ChatTemplate tests, `make test`) is landed. PR 4 (MarkdownPrint extraction as `TranscriptMarkdown` with tests) is landed. `VoiceTrigger` has since been added to `InferCore` with tests. PRs 2, 3, 5, 6 remain open. This document is now a plan-of-record for the remaining work; historical PR descriptions are kept as-is for traceability but flagged below.

## Constraints shaping the plan

1. **Metal Toolchain dependency.** MLX ships Metal compute kernels that only Xcode's Metal toolchain can compile. `make build-infer` uses `xcodebuild` precisely because `swift build` fails on the MLX graph. Any test target that transitively imports `MLXLLM` / `MLXVLM` / `MLXLMCommon` inherits that constraint and cannot run under plain `swift test` in CI without the ~700 MB Metal Toolchain asset.

2. **Binary framework dependencies.** `llama.xcframework` and `whisper.xcframework` are fetched on demand by `scripts/fetch_llama_framework.sh` / `scripts/fetch_whisper_framework.sh`. A clean checkout has no `thirdparty/*.xcframework/` directories, so SwiftPM resolution will fail until fetch scripts run. CI must run them as a prestep or cache the artifacts.

3. **Single executable target.** `Package.swift` declares `Infer` as `.executableTarget`, not a library. To test internals, a test target uses `@testable import Infer` — this works for executable targets in Swift 5.5+, but types under test must be `internal` (not `fileprivate`/`private`) and any `@main` entry point stays in the executable.

4. **Model assets are heavy.** Real `.gguf` files are GBs; MLX model repos are hundreds of MB; whisper `tiny.en` is ~75 MB. None belong in CI by default. Fixture-based tests should fabricate the smallest possible artifact or mock the boundary.

5. **Swift 5 language mode opt-out.** The `Infer` target currently sets `.swiftLanguageMode(.v5)`. New test code should be Swift-6-concurrency-safe so it doesn't block the eventual drop of the opt-out (P2 in TODO.md).

## Goals

- **Catch regressions in logic that is not obvious by inspection** — chat-template rendering, message-delta tracking, settings persistence, audio format conversion, markdown/print pipeline, vault crypto round-trips.

- **Keep CI fast and hermetic.** Unit tests should run in under 30 s on a clean macOS runner without Metal Toolchain, without network, without model assets.

- **Do not test the external SDKs.** `MLXLLM.ChatSession`, `llama_decode`, `whisper_full`, `AVAudioFile`, `WKWebView` — all out of scope. Test *our* glue around them.

- **Do not chase coverage.** SwiftUI views, `@Observable` view models bound to UserDefaults, and the actor-wrapped runner surfaces are low-value to unit-test and expensive to stub. Prefer a narrow, high-signal suite.

## Two-tier architecture

### Tier 1 — `InferCore` library + `InferCoreTests` (the CI suite)

Extract pure logic into a new SwiftPM **library target** `InferCore` that depends on **no binary frameworks and no MLX/llama/whisper symbols**. The executable `Infer` target then depends on `InferCore` plus the existing binary stack.

Status of extraction (landed = in `InferCore` with tests; pending = candidate for later PR):

| Location                              | Status    | Reason it is unit-testable                              |
| ------------------------------------- | --------- | ------------------------------------------------------- |
| `InferCore/Settings.swift`            | landed    | Plain struct + `UserDefaults` keys; `load(from:)` / `save(to:)` take a `UserDefaults` parameter (default `.standard`) so tests inject a `suiteName:`-scoped instance. |
| `InferCore/ChatTemplate.swift`        | landed    | Pure string transform given a template + role/content.  |
| `InferCore/TranscriptMarkdown.swift`  | landed    | `swift-markdown`-only pipeline; skips the `WKWebView` leg. Replaces the "MarkdownPrint" name used in the original plan. |
| `InferCore/VoiceTrigger.swift`        | landed    | Wake-word / push-to-talk state machine; pure logic.     |
| `InferCore/AudioDecode.swift`         | pending   | Deterministic given a small fixture WAV (PR 2).         |
| `InferCore/WhisperModelCatalog.swift` | pending   | URL/path derivation; no I/O in the hot path (PR 2).     |
| `InferCore/VaultCrypto.swift`         | pending   | CryptoKit round-trip; no keychain in the pure layer (PR 3). |

`@testable import InferCore` in `InferCoreTests` targets. All tests run under `swift test` from `projects/infer/`.

**Rule of thumb for what moves:** if the file imports `MLXLLM`, `llama`, `CWhisperBridge`, `SwiftUI`, `AppKit`, `WebKit`, or `AVFoundation` at the top level, it stays in `Infer`. If a file mixes pure logic with a framework boundary, split at the boundary: the pure half moves, the thin adapter stays.

### Tier 2 — runner-level smoke tests (not shipped until needed)

A second test bundle would run **inside the Xcode project** via `xcodebuild test` to cover runner-level paths that legitimately need Metal, MLX, or a real model. Rather than ship a placeholder empty bundle, this tier is **deferred until a concrete runner-level regression motivates it**. Placeholder test targets rot; an empty bundle attracts "someone should fill this in" drift without any guard against breakage.

When the motivating regression appears, the bundle will land with at least:

- `LlamaRunnerSmokeTests` — load a tiny `.gguf` fixture from `Resources/test/`, assert a 1-token generation completes without crash. Gated by `INFER_HEAVY_TESTS=1` env var.

- `WhisperRunnerSmokeTests` — `tiny.en` + a 3-second PCM fixture; assert non-empty transcript.

- `MLXRunnerSmokeTests` if and only if a small-enough MLX fixture repo (tens of MB) can be located.

Fixture sourcing is the blocker, not the test code. A ~5 MB `.gguf` built from a toy model is the smallest useful llama fixture; anything from Hugging Face is gigabytes. Until someone produces one, Tier 2 stays unshipped.

### Future targets: `InferAgents`, `InferPlugins`

Both `agents.md` and `plugins.md` propose pure-Swift library targets with no MLX/llama dependency. They follow the **same Tier 1 rules as `InferCore`** — tests under `swift test`, `@testable` imports, no network, no binary frameworks. Explicitly:

- `InferAgentsTests` tests the `Agent` protocol's default-hook behaviour, `PromptAgent` JSON round-trip (including `schemaVersion` handling per `agents.md`), `AgentRegistry` precedence, and transcript migration. No runner is instantiated.

- `InferPluginsTests` tests `MCPClient` round-trips against a fixture subprocess that speaks MCP (a small Swift binary built as a test helper target — `Process` is Swift-stdlib, no frameworks needed), `ToolCallParser` golden-file tests per template family, and `ConsentPolicy` decision tables. The subprocess fixture counts as a build-time artefact, not a network dependency.

The rule of thumb (import-list test in the Tier 1 section) applies identically: if a future file in these targets imports `MLXLLM`, `llama`, `SwiftUI`, `AppKit`, or `WebKit`, it belongs in `Infer`, not in the library target.

## PR history and remaining work

**PR 1 — landed.** `InferCore` library target, `InferSettings` + `PersistKey` moved out of `ChatView.swift`, `ChatTemplate` extracted from `LlamaRunner`, `InferCoreTests` with `SettingsPersistenceTests` (per-test `UserDefaults(suiteName:)`) and `ChatTemplateTests` (golden-file per role ordering), `make test` target added, `CLAUDE.md` updated to point at `make test`.

**PR 4 (out of order) — landed.** `TranscriptMarkdown` (markdown → HTML) extracted into `InferCore`. The name was `MarkdownPrint` in the original plan; renamed to match call-site intent. Golden HTML fixtures for code fences, tables, and links. No PDF, no `WKWebView`. Additionally, `VoiceTrigger` was extracted and tested under the same rules though it was not in the original plan.

**Remaining PRs (still roughly in order):**

- **PR 2 (open):** Extract `AudioDecode` and `WhisperModelCatalog` into `InferCore`. Audio tests ship a 1-second 44.1 kHz stereo WAV fixture (~180 KB) and assert the 16 kHz mono Float32 conversion shape + a checksum.

- **PR 3 (open):** Extract `VaultCrypto`. Tests: encrypt/decrypt round-trip, wrong-key rejection, tampered-ciphertext rejection. Key derivation stays in `Vault.swift` because it touches Keychain.

- **PR 5 (open): GitHub Actions workflow on `macos-14`.**

  - Cache `~/Library/Caches/org.swift.swiftpm` and the `thirdparty/` fetched artifacts.

  - Cache key must include `LLAMA_TAG` and `WHISPER_TAG` (resolved from the Makefile or pinned in a workflow variable). A manual tag bump otherwise serves stale frameworks from cache and either breaks the build or — worse — passes with the wrong binaries. `hashFiles()` over the fetch scripts is not sufficient because the tag is a runtime variable, not a file.

  - Steps: `make fetch-llama`, `make fetch-whisper`, `make test`.

  - Skip `make build-infer` (Metal Toolchain cost). Build is validated on developer machines pre-release.

- **PR 6 (open):** Drop `.swiftLanguageMode(.v5)` on `Infer` by fixing `LlamaRunner.backendInitialized`. Tests from PR 2, 3 (and the landed PR 1, PR 4) guard the refactor.

## Anti-goals

- **Do not add a mocking framework.** Swift's protocol + struct ergonomics are enough; dragging in Cuckoo or Mockingbird is more weight than this suite justifies.

- **Do not write SwiftUI snapshot tests.** The UI is not the risky surface; the runners and the data path are.

- **Do not test `@MainActor` `ChatViewModel` end-to-end.** It is tightly coupled to UserDefaults and two runner actors; stubbing is expensive and the tests would break on every UI tweak. Test the dependencies it pulls in (`InferSettings`, template rendering, audio decode) and treat the view-model wiring as integration-verified by manual use.

- **Do not run network-fetching tests in CI.** `WhisperModelManager.ensureDownloaded` hits Hugging Face; mock the URL session at the boundary or skip entirely.

- **Do not weaken or skip failing tests to make CI green.** Per the global project rules, zero tolerance for test failures — find the root cause.

## Open questions

- Can we locate small-enough fixture models (tens of MB) for Tier 2 — a toy `.gguf`, a minimal MLX repo? Until yes, Tier 2 stays unshipped (see the Tier 2 section above).

- Should `InferCore` (and the future `InferAgents` / `InferPlugins`) be their own SwiftPM packages rather than targets inside `projects/infer/Package.swift`? Separate packages give cleaner dependency boundaries but complicate `xcodebuild` wiring. Default to single-package, multi-target until there is a concrete reason to split.

- How should CI handle the `LLAMA_TAG` / `WHISPER_TAG` cache invalidation in practice — pin the tag in the workflow YAML (explicit, duplicates the Makefile value) or parse it from the Makefile at workflow time (no duplication, adds a parse step)? Decide at PR 5.
