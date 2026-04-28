// swift-tools-version: 6.1
import PackageDescription

// Hacker News tool plugin. Pure Swift, no native deps; hits the
// public Algolia HN API (`https://hn.algolia.com/api/v1`) over
// HTTPS. Useful as a reference for "API-wrapper plugin" shape —
// future plugins of this kind (arXiv, GitHub, RSS, etc.) will copy
// this layout.
let package = Package(
    name: "plugin_hacker_news",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "plugin_hacker_news", targets: ["plugin_hacker_news"]),
    ],
    dependencies: [
        .package(path: "../../plugin-api"),
    ],
    targets: [
        .target(
            name: "plugin_hacker_news",
            dependencies: [.product(name: "PluginAPI", package: "plugin-api")],
            path: "Sources/plugin_hacker_news"
        ),
        .testTarget(
            name: "plugin_hacker_newsTests",
            dependencies: ["plugin_hacker_news"],
            path: "Tests/plugin_hacker_newsTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
