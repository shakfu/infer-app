// swift-tools-version: 6.1
import PackageDescription

// Spreadsheet I/O tool plugin. Owns:
//   - csv.write   (RFC 4180, pure Swift)
//   - tsv.write   (TSV with embedded-tab/newline escaping, pure Swift)
//   - xlsx.write  (libxlsxwriter — write-only, mature C lib)
//   - xlsx.read   (CoreXLSX — pure-Swift read-only parser)
//
// All four moved out of the main app target so a bespoke build that
// doesn't need tabular file I/O can drop this plugin from
// `projects/plugins/plugins.json` and shed:
//   - libxlsxwriter (C, BSD-2-Clause; pulls a `-lz` link)
//   - CoreXLSX + XMLCoder + ZIPFoundation (transitive Swift deps)
//
// The four tools travel together because XlsxWorksheet.Cell is the
// canonical scalar-cell type used by csv.write / tsv.write / xlsx.write,
// and validateRows / resolveSandboxedTarget / SpreadsheetJSONValue are
// shared across all three writers. Splitting the xlsx pair off would
// duplicate ~125 LOC of helpers; keeping them grouped costs nothing
// for users who want any tabular output and gives a clean drop-out
// for users who want none.
let package = Package(
    name: "plugin_spreadsheet_tools",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "plugin_spreadsheet_tools", targets: ["plugin_spreadsheet_tools"]),
    ],
    dependencies: [
        .package(path: "../../plugin-api"),
        // libxlsxwriter (jmcnamara, FreeBSD/BSD-2-Clause). Mature C lib;
        // write-only, paired with CoreXLSX (read-only) for the full
        // round-trip. Adds a `-lz` system link.
        .package(url: "https://github.com/jmcnamara/libxlsxwriter", from: "1.2.4"),
        // CoreXLSX (CoreOffice, Apache-2.0). Pure-Swift parse-only xlsx
        // reader; pulls XMLCoder + ZIPFoundation transitively.
        .package(url: "https://github.com/CoreOffice/CoreXLSX", from: "0.14.1"),
    ],
    targets: [
        .target(
            name: "plugin_spreadsheet_tools",
            dependencies: [
                .product(name: "PluginAPI", package: "plugin-api"),
                .product(name: "libxlsxwriter", package: "libxlsxwriter"),
                .product(name: "CoreXLSX", package: "CoreXLSX"),
            ],
            path: "Sources/plugin_spreadsheet_tools"
        ),
        .testTarget(
            name: "plugin_spreadsheet_toolsTests",
            dependencies: ["plugin_spreadsheet_tools"],
            path: "Tests/plugin_spreadsheet_toolsTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
