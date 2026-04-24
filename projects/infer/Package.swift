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
        .package(url: "https://github.com/jkrukowski/SQLiteVec", from: "0.0.9"),
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
        // Agent substrate. Pure Swift, depends only on InferCore (for
        // InferSettings reuse in DefaultAgent). No MLX/llama/UI deps so
        // the full surface is unit-testable under `swift test`.
        .target(
            name: "InferAgents",
            dependencies: ["InferCore"],
            path: "Sources/InferAgents"
        ),
        .testTarget(
            name: "InferAgentsTests",
            dependencies: ["InferAgents", "InferCore"],
            path: "Tests/InferAgentsTests"
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
        // Spike: smoke-test that sqlite-vector loads into GRDB and the
        // `vector_*` SQL functions round-trip. Run with `swift run
        // SqliteVectorSmoke`. Kept as a separate executable so it
        // doesn't pull the xcframework into the library test bundles
        // and so the spike can be deleted cleanly after RAG lands
        // without touching the main app target.
        // Spike: smoke-test that SQLiteVec's bundled SQLite + sqlite-vec
        // round-trip end-to-end. Run with `swift run SqliteVecSmoke`.
        // Throwaway — delete after RAG Phase 1 confirms the approach.
        .executableTarget(
            name: "SqliteVecSmoke",
            dependencies: [
                .product(name: "SQLiteVec", package: "SQLiteVec"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/SqliteVecSmoke"
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
            ],
            path: "Sources/Infer",
            exclude: ["Info.plist"],
            resources: [
                // First-party personas (`.firstParty` source). Loaded at
                // AgentController bootstrap via Bundle.module.
                .copy("Resources/agents"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
    ]
)
