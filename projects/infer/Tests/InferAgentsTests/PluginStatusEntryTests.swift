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
    struct Tool: Equatable {
        let name: ToolName
        let description: String
    }
    enum Status: Equatable {
        case loaded(tools: [Tool])
        case failed(message: String)
    }
    let id: String
    let status: Status
    let configJSON: Data

    static func assemble(
        types: [any Plugin.Type],
        result: PluginLoadResult,
        configs: [String: PluginConfig] = [:]
    ) -> [StatusFixture] {
        let failuresByID = Dictionary(
            uniqueKeysWithValues: result.failures.map { ($0.pluginID, $0.message) }
        )
        return types.map { type in
            let id = type.id
            let configJSON = configs[id]?.json ?? PluginConfig.empty.json
            if let message = failuresByID[id] {
                return StatusFixture(id: id, status: .failed(message: message), configJSON: configJSON)
            }
            let tools = (result.contributions[id]?.tools ?? [])
                .map { Tool(name: $0.name, description: $0.spec.description) }
                .sorted { $0.name < $1.name }
            return StatusFixture(id: id, status: .loaded(tools: tools), configJSON: configJSON)
        }
    }
}

private enum AlphaPlugin: Plugin {
    static let id = "alpha"
    static func register(config _: PluginConfig, invoker _: ToolInvoker) async throws -> PluginContributions { .none }
}
private enum BetaPlugin: Plugin {
    static let id = "beta"
    static func register(config _: PluginConfig, invoker _: ToolInvoker) async throws -> PluginContributions { .none }
}
private enum GammaPlugin: Plugin {
    static let id = "gamma"
    static func register(config _: PluginConfig, invoker _: ToolInvoker) async throws -> PluginContributions { .none }
}

private struct FixtureTool: BuiltinTool {
    let name: ToolName
    let descriptionText: String
    init(name: ToolName, description: String = "") {
        self.name = name
        self.descriptionText = description
    }
    var spec: ToolSpec { ToolSpec(name: name, description: descriptionText) }
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

    func testAssembleSortsToolsByName() {
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
        guard case .loaded(let tools) = entries.first?.status else {
            return XCTFail("expected loaded status")
        }
        XCTAssertEqual(tools.map(\.name), ["a.tool", "m.tool", "z.tool"])
    }

    func testAssembleCarriesToolDescriptions() {
        let result = PluginLoadResult(
            contributions: [
                "alpha": PluginContributions(tools: [
                    FixtureTool(name: "a.tool", description: "hi"),
                ]),
            ]
        )
        let entries = StatusFixture.assemble(types: [AlphaPlugin.self], result: result)
        guard case .loaded(let tools) = entries.first?.status else {
            return XCTFail("expected loaded status")
        }
        XCTAssertEqual(tools.first?.description, "hi")
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
        if case .failed(let message) = entries[1].status {
            XCTAssertEqual(message, "missing config key")
        } else {
            XCTFail("expected failed status for beta")
        }
    }

    func testAssembleHandlesContributionlessLoadedPlugin() {
        let entries = StatusFixture.assemble(
            types: [AlphaPlugin.self],
            result: PluginLoadResult()
        )
        if case .loaded(let tools) = entries.first?.status {
            XCTAssertTrue(tools.isEmpty)
        } else {
            XCTFail("expected loaded status with no tools")
        }
    }

    func testAssembleAttachesConfigJSON() {
        let cfg = PluginConfig(json: Data(#"{"hello":"world"}"#.utf8))
        let entries = StatusFixture.assemble(
            types: [AlphaPlugin.self],
            result: PluginLoadResult(),
            configs: ["alpha": cfg]
        )
        XCTAssertEqual(entries.first?.configJSON, cfg.json)
    }

    func testAssembleFallsBackToEmptyConfig() {
        let entries = StatusFixture.assemble(
            types: [AlphaPlugin.self],
            result: PluginLoadResult()
        )
        XCTAssertEqual(entries.first?.configJSON, PluginConfig.empty.json)
    }

    func testAssembleEmpty() {
        let entries = StatusFixture.assemble(types: [], result: PluginLoadResult())
        XCTAssertTrue(entries.isEmpty)
    }
}
