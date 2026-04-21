// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Infer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.0.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.8.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.2.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        .package(url: "https://github.com/JohnSundell/Splash", from: "0.16.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown", from: "0.7.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
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
                "llama",
                "CWhisperBridge",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "Splash", package: "Splash"),
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/Infer",
            exclude: ["Info.plist"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
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
