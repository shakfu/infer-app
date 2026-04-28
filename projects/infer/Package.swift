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
        .package(url: "https://github.com/swiftlang/swift-markdown", from: "0.7.0"),
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
        // libxlsxwriter (jmcnamara, FreeBSD/BSD-2-Clause). Mature C
        // library for producing real `.xlsx` files — multi-sheet,
        // formulas, cell formatting. Pinned to a tagged release for
        // reproducibility (the upstream tags every release as `vX.Y.Z`
        // and SPM accepts that form via `from:`). Builds from source
        // via the upstream's own Package.swift; only external link is
        // `-lz` (zlib, present on every macOS host). Used by the
        // `xlsx.write` builtin tool — see Tools/XlsxWriter.swift for
        // the Swift shim and Tools/SpreadsheetWriteTools.swift for
        // the tool itself.
        .package(url: "https://github.com/jmcnamara/libxlsxwriter", from: "1.2.4"),
        // CoreXLSX (CoreOffice, Apache-2.0). Pure-Swift parse-only
        // xlsx reader; complements libxlsxwriter (write-only) for the
        // `xlsx.read` tool. Pulls XMLCoder + ZIPFoundation
        // transitively — both pure Swift, both well-maintained.
        // Pinned `from: "0.14.1"` per the upstream README's example.
        .package(url: "https://github.com/CoreOffice/CoreXLSX", from: "0.14.1"),
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
        .package(path: "../plugins/plugin_wiki"),
        .package(path: "../plugins/plugin_python_tools"),
        // END_GENERATED_PLUGINS_PACKAGES
    ],
    targets: [
        // Pure-Swift library for logic that does not depend on binary
        // frameworks (llama, whisper, MLX). Exists so it can be unit-tested
        // under `swift test` without the Metal Toolchain or fetched xcframeworks.
        .target(
            name: "InferCore",
            path: "Sources/InferCore"
        ),
        .testTarget(
            name: "InferCoreTests",
            dependencies: ["InferCore"],
            path: "Tests/InferCoreTests"
        ),
        // Agent substrate. Depends on InferCore (for `InferSettings`
        // reuse in DefaultAgent) and libxlsxwriter (for the
        // `xlsx.write` tool). No MLX/llama/UI deps — `libxlsxwriter`
        // compiles from source via SPM and only links `-lz`, so the
        // full surface stays unit-testable under `swift test` without
        // the Metal Toolchain or any fetched xcframeworks.
        .target(
            name: "InferAgents",
            dependencies: [
                "InferCore",
                .product(name: "PluginAPI", package: "plugin-api"),
                .product(name: "libxlsxwriter", package: "libxlsxwriter"),
                .product(name: "CoreXLSX", package: "CoreXLSX"),
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
        .binaryTarget(
            name: "llama",
            path: "../../thirdparty/llama.xcframework"
        ),
        .binaryTarget(
            name: "whisper",
            path: "../../thirdparty/whisper.xcframework"
        ),
        // Narrow C bridge over whisper.cpp. Isolates whisper's ggml headers
        // from the Swift-visible module graph so the Infer target can also
        // import 'llama' (which ships its own, incompatible ggml.h) without
        // a Clang type-redefinition error.
        .target(
            name: "CWhisperBridge",
            dependencies: ["whisper"],
            path: "Sources/CWhisperBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Infer",
            dependencies: [
                "InferCore",
                "InferAgents",
                "llama",
                "CWhisperBridge",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "Splash", package: "Splash"),
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "GRDB", package: "GRDB.swift"),
                "InferRAG",
                .product(name: "PluginAPI", package: "plugin-api"),
                // BEGIN_GENERATED_PLUGINS_PRODUCTS
                // Managed by `scripts/gen_plugins.py`. Do not hand-edit
                // between the BEGIN/END markers; rerun `make plugins-gen`
                // after editing `projects/plugins/plugins.json`.
                .product(name: "plugin_wiki", package: "plugin_wiki"),
                .product(name: "plugin_python_tools", package: "plugin_python_tools"),
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
