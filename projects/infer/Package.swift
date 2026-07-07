// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Infer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.25.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.8.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.2.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        // Highlightr (raspu, MIT) — Swift wrapper around highlight.js
        // running in JavaScriptCore. Used by the chat transcript for
        // arbitrary-language fenced code blocks; ~190 languages out
        // of the box. The wiki editor uses tree-sitter instead and
        // does not depend on Highlightr.
        .package(url: "https://github.com/raspu/Highlightr", from: "2.3.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown", from: "0.7.0"),
        // STTextView (Marcin Krzyzanowski, MIT) — TextKit 2 NSTextView
        // replacement used by the wiki page editor. Markdown-focused
        // editor base (same author as MarkEdit); cleaner range / hit-
        // testing APIs and a plugin model for change subscription
        // than raw NSTextView.
        .package(url: "https://github.com/krzyzanowskim/STTextView", from: "2.2.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // SQLiteVec (jkrukowski, MIT) — Swift wrapper around sqlite-vec
        // (Alex Garcia, MIT). Bundles its *own* SQLite amalgamation
        // with `SQLITE_CORE`, with sqlite-vec statically registered via
        // `sqlite3_auto_extension`. Sidesteps Apple's system-SQLite
        // restriction on loading extensions (sqlite3_enable_load_extension
        // is stripped; sqlite3_auto_extension is a stub). The bundled
        // SQLite is independent of GRDB's (which keeps using Apple's
        // for the main vault). RAG data lives in a separate .sqlite
        // file opened via SQLiteVec's Database type.
        //
        // Vendored locally at `thirdparty/SQLiteVec/` because the
        // upstream public headers include `sqlite3ext.h`, which
        // xcodebuild's module-map generator then merges into the
        // workspace's Clang search path — colliding with GRDB's
        // shim (which expects Apple's system SQLite without the
        // extension macro block). In the vendored copy, `sqlite3ext.h`
        // is moved out of `include/` so it's no longer a public header
        // while still available to `sqlite-vec.c` via the local
        // quoted include.
        .package(path: "../../thirdparty/SQLiteVec"),
        // tree-sitter-qmd (Quarto-flavored markdown). Vendored at
        // thirdparty/tree-sitter-qmd/ — upstream ships the SwiftPM
        // package in a subdirectory of a Rust monorepo, so we extract
        // and reference it as a local path package. SwiftTreeSitter
        // is added explicitly so SPM resolves a single version
        // (tree-sitter-qmd's Package.swift declares its own dep on it).
        .package(path: "../../thirdparty/tree-sitter-qmd"),
        // Vendored tree-sitter-python — patched Package.swift (no
        // Swift deps on the library target) so it composes with
        // ChimeHQ/SwiftTreeSitter without product-name collision.
        .package(path: "../../thirdparty/tree-sitter-python"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.9.0"),
        // SwiftTerm (Miguel de Icaza, MIT) — pure-Swift terminal
        // emulator + PTY. SPIKE: embedded terminal pane for agent
        // command transparency. Declares `swiftLanguageVersions: [.v5]`;
        // SPM compiles it in its own (Swift 5) mode inside this `.v6`
        // package, so concurrency friction only appears at the API
        // boundary in our code — kept main-actor-confined (the views
        // are AppKit `NSView`s) to avoid Sendable churn.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0"),
        // libxlsxwriter and CoreXLSX moved into
        // projects/plugins/plugin_spreadsheet_tools — that plugin owns
        // csv.write / tsv.write / xlsx.write / xlsx.read and the heavy
        // xlsx deps that come with them. Drop the plugin from
        // plugins.json to shed both deps + the `-lz` link.

        // Leaf plugin-author SPM package. Defines the `Plugin` protocol
        // and the tool primitives (`BuiltinTool`, `ToolSpec`, etc.)
        // that plugins under `projects/plugins/plugin_<name>/` compile
        // against. Pure Swift, zero runtime deps. Re-exported from
        // `InferAgents` (`@_exported import PluginAPI`) so existing
        // code that imports `InferAgents` keeps working unchanged.
        .package(path: "../plugin-api"),
        // BEGIN_GENERATED_PLUGINS_PACKAGES
        // Managed by `scripts/gen_plugins.py`. Do not hand-edit between
        // the BEGIN/END markers; rerun `make plugins-gen` after editing
        // `projects/plugins/plugins.json`.
        .package(path: "../plugins/plugin_hacker_news"),
        .package(path: "../plugins/plugin_python_tools"),
        .package(path: "../plugins/plugin_spreadsheet_tools"),
        // END_GENERATED_PLUGINS_PACKAGES
    ],
    targets: [
        // Pure-Swift library for logic that does not depend on binary
        // frameworks (llama, whisper, MLX). Exists so it can be unit-tested
        // under `swift test` without the Metal Toolchain or fetched xcframeworks.
        .target(
            name: "InferCore",
            path: "Sources/InferCore",
            resources: [
                // Bundled JSON config files. Loaded via Bundle.module
                // at runtime; user can override per-file by dropping
                // a same-named JSON in `~/Library/Application Support/
                // Infer/`. See `CloudRecommendedModels` for the loader
                // pattern that should be repeated for any future
                // configurable-via-JSON entity (providers, etc.).
                .process("Resources/CloudModels.json"),
                .process("Resources/CloudProviders.json"),
                .process("Resources/LocalModels.json"),
            ]
        ),
        .testTarget(
            name: "InferCoreTests",
            dependencies: ["InferCore"],
            path: "Tests/InferCoreTests"
        ),
        // Agent substrate. Depends on InferCore (for `InferSettings`
        // reuse in DefaultAgent) and PluginAPI (for the BuiltinTool
        // primitives). No MLX/llama/UI deps so the full surface stays
        // unit-testable under `swift test` without the Metal Toolchain
        // or any fetched xcframeworks. Tabular file I/O (xlsx/csv/tsv)
        // moved out of this target to plugin_spreadsheet_tools to drop
        // the libxlsxwriter + CoreXLSX deps from a baseline build.
        .target(
            name: "InferAgents",
            dependencies: [
                "InferCore",
                .product(name: "PluginAPI", package: "plugin-api"),
            ],
            path: "Sources/InferAgents"
        ),
        .testTarget(
            name: "InferAgentsTests",
            dependencies: ["InferAgents", "InferCore"],
            path: "Tests/InferAgentsTests"
        ),
        // RAG vector store. Lives in its own target so SQLiteVec's
        // bundled SQLite C headers stay module-private — if they were
        // in the same compile unit as GRDB's GRDBSQLite shim (which
        // assumes Apple's system SQLite), `sqlite3ext.h`'s macro
        // aliases collide with GRDB's direct function references.
        // Separate target = separate module map = no header leakage.
        .target(
            name: "InferRAG",
            dependencies: [
                .product(name: "SQLiteVec", package: "SQLiteVec"),
            ],
            path: "Sources/InferRAG"
        ),
        .testTarget(
            name: "InferRAGTests",
            dependencies: ["InferRAG"],
            path: "Tests/InferRAGTests"
        ),
        // Pure-Swift nucleus of the chat view-model that *can* live
        // outside the executable target: `ChatRunner` protocol
        // (testable surface for the chat-side runners) and
        // `TranscriptStore` (value-typed message-list with the
        // edit/resend, regenerate, and stream-append operations the
        // chat-VM performs on `messages: [ChatMessage]`). No MLX /
        // llama / SwiftUI deps so the suite runs under `swift test`
        // without the Metal toolchain. The concrete runners
        // (Llama/MLX/Cloud) now conform to `ChatRunner`; the cloud
        // conformance + headless orchestration live in `InferSession`.
        .target(
            name: "InferAppCore",
            path: "Sources/InferAppCore"
        ),
        .testTarget(
            name: "InferAppCoreTests",
            dependencies: ["InferAppCore"],
            path: "Tests/InferAppCoreTests"
        ),
        // Headless chat orchestration for the cloud backend. The first
        // shared consumer of the `ChatRunner` seam outside the SwiftUI
        // executable: `ChatSession` drives `CloudRunner` (which lives in
        // InferCore) through `respondToUser` with no SwiftUI / AppKit /
        // MLX / llama deps, so it builds under plain `swift build` and is
        // unit-tested against a stub `CloudClient`. The `CloudRunner:
        // ChatRunner` conformance moved here from the `Infer` target so
        // both the app (which depends on this) and `infer-cli` share it
        // without duplicating the conformance. Local-backend runners
        // (Llama/MLX) keep their conformances in the executable target
        // because they carry the binary-framework deps.
        .target(
            name: "InferSession",
            dependencies: ["InferCore", "InferAppCore"],
            path: "Sources/InferSession"
        ),
        .testTarget(
            name: "InferSessionTests",
            dependencies: ["InferSession", "InferCore"],
            path: "Tests/InferSessionTests"
        ),
        // Non-interactive CLI over InferSession's cloud backend, built for
        // scriptability and CI. Cloud-only by design: it links no
        // MLX/llama/Metal code, so it builds with
        // `swift build --product infer-cli` without the Metal Toolchain or
        // the fetched xcframeworks. Reads a prompt from arguments or stdin,
        // streams the reply to stdout (or emits one JSON object), and uses
        // the process exit code to signal success/failure.
        .executableTarget(
            name: "infer-cli",
            dependencies: ["InferSession", "InferCore"],
            path: "Sources/infer-cli"
        ),
        // Combined ggml-stack frameworks. One shared `Ggml` xcframework
        // ships libggml*.dylib (base + cpu + metal + blas backends);
        // `LlamaCpp` / `Whisper` / (future) `StableDiffusion` are thin
        // xcframeworks layered on top whose module maps `use Ggml`. This
        // collapses the prior dual-ggml problem (where llama.framework and
        // whisper.framework each shipped their own libggml.dylib and
        // collided when both modules were imported into one target).
        .binaryTarget(
            name: "Ggml",
            path: "../../thirdparty/Ggml.xcframework"
        ),
        .binaryTarget(
            name: "LlamaCpp",
            path: "../../thirdparty/LlamaCpp.xcframework"
        ),
        .binaryTarget(
            name: "Whisper",
            path: "../../thirdparty/Whisper.xcframework"
        ),
        .binaryTarget(
            name: "StableDiffusion",
            path: "../../thirdparty/StableDiffusion.xcframework"
        ),
        // Narrow C bridge over whisper.cpp. Originally a workaround for
        // dual-ggml symbol collisions between the upstream llama and
        // whisper xcframeworks; with the unified Ggml framework that
        // rationale is gone, but the bridge is kept for now because its
        // narrow C surface is convenient and removing it is a separate
        // refactor.
        .target(
            name: "CWhisperBridge",
            dependencies: ["Whisper", "Ggml"],
            path: "Sources/CWhisperBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Infer",
            dependencies: [
                "InferCore",
                "InferAgents",
                "Ggml",
                "LlamaCpp",
                "CWhisperBridge",
                "StableDiffusion",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-qmd"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "STTextView", package: "STTextView"),
                .product(name: "GRDB", package: "GRDB.swift"),
                "InferRAG",
                "InferAppCore",
                "InferSession",
                .product(name: "PluginAPI", package: "plugin-api"),
                // BEGIN_GENERATED_PLUGINS_PRODUCTS
                // Managed by `scripts/gen_plugins.py`. Do not hand-edit
                // between the BEGIN/END markers; rerun `make plugins-gen`
                // after editing `projects/plugins/plugins.json`.
                .product(name: "plugin_hacker_news", package: "plugin_hacker_news"),
                .product(name: "plugin_python_tools", package: "plugin_python_tools"),
                .product(name: "plugin_spreadsheet_tools", package: "plugin_spreadsheet_tools"),
                // END_GENERATED_PLUGINS_PRODUCTS
            ],
            path: "Sources/Infer",
            exclude: ["Info.plist"],
            resources: [
                // First-party personas and agents (`.firstParty` source).
                // Loaded at AgentController bootstrap via Bundle.module.
                // Split per `docs/dev/agent_kinds.md`: persona JSONs (no
                // tools) live under `personas/`, tool-using agent JSONs
                // under `agents/`. Loader globs both directories.
                .copy("Resources/personas"),
                .copy("Resources/agents"),
                // Tree-sitter highlights query for Python — staged
                // here by the `tree-sitter-python` fetcher so the
                // wiki editor can load it via Bundle.module without
                // crossing target boundaries.
                .copy("Resources/python_highlights.scm"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        // External tests that exercise the real LlamaCpp chat-format
        // bridge (`chatfmt_apply`) through `LlamaRunner.renderTemplate`.
        // Depends on the `Infer` target (reached via `@testable import`)
        // because `renderTemplate` lives there; it therefore links the
        // full MLX/llama stack. The `*ExternalTests` suite-name suffix
        // keeps it off the fast `make test` path (`--skip ExternalTests`)
        // and on `make test-integration` (`--filter ExternalTests`) —
        // appropriate because it hits a real binary framework, not pure
        // Swift.
        .testTarget(
            name: "InferRunnerExternalTests",
            dependencies: ["Infer"],
            path: "Tests/InferRunnerExternalTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
