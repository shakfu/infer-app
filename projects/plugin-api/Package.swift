// swift-tools-version: 6.1
import PackageDescription

// Leaf SPM package: zero non-Swift-stdlib dependencies. Defines the
// surface plugins (under `projects/plugins/plugin_<name>/`) compile
// against, plus the tool-protocol primitives that travel between
// plugins and the host. See `docs/dev/plugins.md`.
let package = Package(
    name: "plugin-api",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PluginAPI", targets: ["PluginAPI"]),
    ],
    targets: [
        .target(
            name: "PluginAPI",
            path: "Sources/PluginAPI"
        ),
        .testTarget(
            name: "PluginAPITests",
            dependencies: ["PluginAPI"],
            path: "Tests/PluginAPITests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
