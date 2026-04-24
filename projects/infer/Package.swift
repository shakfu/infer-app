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
