// PluginStatusEntry lives in the Infer (executable) target, but the
// assembly logic is pure-Swift and worth unit-testing without spinning
// the chat VM. We mirror just the needed types here and re-test the
// algorithm — duplicating ~30 LOC of pure-data assembly is cheaper
// than reorganising target boundaries to expose the type to tests.
//
// If `PluginStatusEntry` ever moves into a library target (likely when
// P2/P3 of the Settings migration land and the Settings views grow),
// these tests should be replaced with the real type.

import XCTest
@testable import InferAgents

/// Local re-implementation of `PluginStatusEntry.assemble` that the
/// assertions below exercise. Kept structurally identical to the
/// production version (`projects/infer/Sources/Infer/PluginStatusEntry.swift`)
/// so a divergence is caught at code-review time. When the algorithm
/// changes, change both — fail-loud is the goal.
private struct StatusFixture {
    enum Status: Equatable {
        case loaded(toolNames: [ToolName])
        case failed(message: String)
    }
    let id: String
    let status: Status

    static func assemble(
        types: [any Plugin.Type],
        result: PluginLoadResult
    ) -> [StatusFixture] {
        let failuresByID = Dictionary(
            uniqueKeysWithValues: result.failures.map { ($0.pluginID, $0.message) }
        )
        return types.map { type in
            let id = type.id
            if let message = failuresByID[id] {
                return StatusFixture(id: id, status: .failed(message: message))
            }
            let names = (result.contributions[id]?.tools.map(\.name) ?? []).sorted()
            return StatusFixture(id: id, status: .loaded(toolNames: names))
        }
    }
}

private enum AlphaPlugin: Plugin {
    static let id = "alpha"
    static func register(config _: PluginConfig) async throws -> PluginContributions { .none }
}
private enum BetaPlugin: Plugin {
    static let id = "beta"
    static func register(config _: PluginConfig) async throws -> PluginContributions { .none }
}
private enum GammaPlugin: Plugin {
    static let id = "gamma"
    static func register(config _: PluginConfig) async throws -> PluginContributions { .none }
}

private struct FixtureTool: BuiltinTool {
    let name: ToolName
    var spec: ToolSpec { ToolSpec(name: name) }
    func invoke(arguments _: String) async throws -> ToolResult { .init(output: "") }
}

final class PluginStatusEntryTests: XCTestCase {
    func testAssemblePreservesPluginOrder() {
        let result = PluginLoadResult(
            contributions: [
                "alpha": PluginContributions(tools: [FixtureTool(name: "a.one")]),
                "beta": PluginContributions(tools: [FixtureTool(name: "b.one")]),
                "gamma": PluginContributions(tools: [FixtureTool(name: "g.one")]),
            ]
        )
        let entries = StatusFixture.assemble(
            types: [AlphaPlugin.self, BetaPlugin.self, GammaPlugin.self],
            result: result
        )
        XCTAssertEqual(entries.map(\.id), ["alpha", "beta", "gamma"])
    }

    func testAssembleSortsToolNamesPerPlugin() {
        let result = PluginLoadResult(
            contributions: [
                "alpha": PluginContributions(tools: [
                    FixtureTool(name: "z.tool"),
                    FixtureTool(name: "a.tool"),
                    FixtureTool(name: "m.tool"),
                ]),
            ]
        )
        let entries = StatusFixture.assemble(types: [AlphaPlugin.self], result: result)
        XCTAssertEqual(entries.first?.status, .loaded(toolNames: ["a.tool", "m.tool", "z.tool"]))
    }

    func testAssembleSurfacesFailuresInline() {
        let result = PluginLoadResult(
            contributions: [
                "alpha": PluginContributions(tools: [FixtureTool(name: "a.one")]),
            ],
            failures: [PluginFailureRecord(pluginID: "beta", message: "missing config key")]
        )
        let entries = StatusFixture.assemble(
            types: [AlphaPlugin.self, BetaPlugin.self],
            result: result
        )
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].status, .loaded(toolNames: ["a.one"]))
        XCTAssertEqual(entries[1].status, .failed(message: "missing config key"))
    }

    func testAssembleHandlesContributionlessLoadedPlugin() {
        // A plugin whose `register` returned `.none` should appear as
        // loaded-with-zero-tools, not as failed and not as missing.
        let entries = StatusFixture.assemble(
            types: [AlphaPlugin.self],
            result: PluginLoadResult()
        )
        XCTAssertEqual(entries.first?.status, .loaded(toolNames: []))
    }

    func testAssembleEmpty() {
        let entries = StatusFixture.assemble(types: [], result: PluginLoadResult())
        XCTAssertTrue(entries.isEmpty)
    }
}
