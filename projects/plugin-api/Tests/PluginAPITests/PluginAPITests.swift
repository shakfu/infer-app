import XCTest
@testable import PluginAPI

final class PluginConfigTests: XCTestCase {
    struct WikiConfig: Decodable, Equatable {
        let source: String
        let limit: Int
    }

    func testDecodeReturnsEmbeddedValues() throws {
        let json = #"{"source":"https://en.wikipedia.org","limit":10}"#
        let config = PluginConfig(json: Data(json.utf8))
        let decoded = try config.decode(WikiConfig.self)
        XCTAssertEqual(decoded, WikiConfig(source: "https://en.wikipedia.org", limit: 10))
    }

    func testEmptyDecodesIntoStructWithNoRequiredFields() throws {
        struct Empty: Decodable {}
        _ = try PluginConfig.empty.decode(Empty.self)
    }

    func testDecodeThrowsOnMissingRequiredKey() {
        let json = #"{"source":"x"}"#
        let config = PluginConfig(json: Data(json.utf8))
        XCTAssertThrowsError(try config.decode(WikiConfig.self))
    }
}

enum LoaderFixturePlugins {
    enum NoOpPlugin: Plugin {
        static let id = "noop"
        static func register(config _: PluginConfig) async throws -> PluginContributions {
            .none
        }
    }

    struct PluginRegisteredError: Error, Equatable {
        let id: String
    }

    enum FailingPlugin: Plugin {
        static let id = "failing"
        static func register(config _: PluginConfig) async throws -> PluginContributions {
            throw PluginRegisteredError(id: id)
        }
    }

    enum ToolContributingPlugin: Plugin {
        static let id = "contributes"
        static func register(config _: PluginConfig) async throws -> PluginContributions {
            PluginContributions(tools: [MarkerTool()])
        }
    }

    struct MarkerTool: BuiltinTool {
        let name: ToolName = "test.marker"
        var spec: ToolSpec { ToolSpec(name: name, description: "marker") }
        func invoke(arguments _: String) async throws -> ToolResult {
            ToolResult(output: "marker")
        }
    }

    actor ConfigCapture {
        var json: Data?
        func set(_ d: Data) { json = d }
        func get() -> Data? { json }
    }

    enum CapturingPlugin: Plugin {
        static let id = "capture"
        nonisolated(unsafe) static var sink: ConfigCapture?
        static func register(config: PluginConfig) async throws -> PluginContributions {
            await sink?.set(config.json)
            return .none
        }
    }
}

final class PluginLoaderTests: XCTestCase {
    func testHappyPathReturnsContributionsKeyedByID() async throws {
        let result = await PluginLoader.loadAll(
            types: [LoaderFixturePlugins.NoOpPlugin.self,
                    LoaderFixturePlugins.ToolContributingPlugin.self],
            configs: [:]
        )
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.contributions["noop"]?.tools.count, 0)
        XCTAssertEqual(result.contributions["contributes"]?.tools.count, 1)
        XCTAssertEqual(result.contributions["contributes"]?.tools.first?.name, "test.marker")
    }

    func testFailingPluginRecordsErrorAndDoesNotBlockRemaining() async throws {
        let result = await PluginLoader.loadAll(
            types: [LoaderFixturePlugins.FailingPlugin.self,
                    LoaderFixturePlugins.ToolContributingPlugin.self],
            configs: [:]
        )
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.pluginID, "failing")
        XCTAssertNotNil(result.contributions["contributes"], "remaining plugin's contributions still recorded after the prior one threw")
        XCTAssertNil(result.contributions["failing"])
    }

    func testConfigLookupByIDFallsBackToEmpty() async throws {
        let captured = LoaderFixturePlugins.ConfigCapture()
        LoaderFixturePlugins.CapturingPlugin.sink = captured

        let cfg = PluginConfig(json: Data(#"{"k":1}"#.utf8))
        _ = await PluginLoader.loadAll(
            types: [LoaderFixturePlugins.CapturingPlugin.self],
            configs: ["capture": cfg]
        )
        let observed = await captured.get()
        XCTAssertEqual(observed, cfg.json)

        await captured.set(Data("never".utf8))
        _ = await PluginLoader.loadAll(
            types: [LoaderFixturePlugins.CapturingPlugin.self],
            configs: [:]
        )
        let fallback = await captured.get()
        XCTAssertEqual(fallback, PluginConfig.empty.json)
    }
}
