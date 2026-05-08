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
        .package(url: "https://github.com/JohnSundell/Splash", from: "0.16.0"),
        // Highlightr (raspu, MIT) — Swift wrapper around highlight.js
        // running in JavaScriptCore. Used for non-Swift fenced code
        // blocks (Python / JS / Bash / etc.); Splash continues to
        // handle Swift because it produces nicer Swift-specific
        // tokenization. ~190 languages out of the box.
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
                .product(name: "Splash", package: "Splash"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "STTextView", package: "STTextView"),
                .product(name: "GRDB", package: "GRDB.swift"),
                "InferRAG",
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
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
