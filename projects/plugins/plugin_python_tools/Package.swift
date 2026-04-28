// swift-tools-version: 6.1
import PackageDescription

// Embedded-Python tool plugin. Depends only on the leaf `plugin-api`
// package; the actual Python runtime ships as a relocatable
// Python.framework built by `scripts/buildpy.py` and bundled into
// `Infer.app/Contents/Frameworks/` by `make bundle`. Plugin code does
// not link against libpython — it spawns the framework's `python3`
// binary as a subprocess (Foundation `Process` + `Pipe`s).
//
// See `docs/dev/plugins.md` for the architecture; the framework
// build/bundle convention lives in the top-level `Makefile`
// (`fetch-python`, `bundle`).
let package = Package(
    name: "plugin_python_tools",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "plugin_python_tools", targets: ["plugin_python_tools"]),
    ],
    dependencies: [
        .package(path: "../../plugin-api"),
    ],
    targets: [
        .target(
            name: "plugin_python_tools",
            dependencies: [.product(name: "PluginAPI", package: "plugin-api")],
            path: "Sources/plugin_python_tools"
        ),
        .testTarget(
            name: "plugin_python_toolsTests",
            dependencies: ["plugin_python_tools"],
            path: "Tests/plugin_python_toolsTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
