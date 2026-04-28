// swift-tools-version: 6.1
import PackageDescription

// One SPM package per plugin. The plugin links only against the
// leaf `plugin-api` package; it knows nothing about the host's
// `InferAgents`, `Infer` executable, llama, MLX, or UI code. The
// host depends on this package via `.package(path:)` in the
// generator-managed section of `projects/infer/Package.swift`.
let package = Package(
    name: "plugin_wiki",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "plugin_wiki", targets: ["plugin_wiki"]),
    ],
    dependencies: [
        .package(path: "../../plugin-api"),
    ],
    targets: [
        .target(
            name: "plugin_wiki",
            dependencies: [.product(name: "PluginAPI", package: "plugin-api")],
            path: "Sources/plugin_wiki"
        ),
        .testTarget(
            name: "plugin_wikiTests",
            dependencies: ["plugin_wiki"],
            path: "Tests/plugin_wikiTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
