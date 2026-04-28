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
    /// No-op invoker used in fixtures whose plugins don't exercise
    /// cross-tool dispatch. Production callers wire this to the
    /// host's `ToolRegistry.invoke`.
    static let noopInvoker: ToolInvoker = { _, _ in
        ToolResult(output: "", error: "no invoker wired in this test")
    }

    enum NoOpPlugin: Plugin {
        static let id = "noop"
        static func register(config _: PluginConfig, invoker _: ToolInvoker) async throws -> PluginContributions {
            .none
        }
    }

    struct PluginRegisteredError: Error, Equatable {
        let id: String
    }

    enum FailingPlugin: Plugin {
        static let id = "failing"
        static func register(config _: PluginConfig, invoker _: ToolInvoker) async throws -> PluginContributions {
            throw PluginRegisteredError(id: id)
        }
    }

    enum ToolContributingPlugin: Plugin {
        static let id = "contributes"
        static func register(config _: PluginConfig, invoker _: ToolInvoker) async throws -> PluginContributions {
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
        static func register(config: PluginConfig, invoker _: ToolInvoker) async throws -> PluginContributions {
            await sink?.set(config.json)
            return .none
        }
    }

    /// Captures the `ToolInvoker` handed to `register` so a test can
    /// invoke it later (simulating a tool dispatch at chat-turn time
    /// rather than register time). `@escaping` is needed on `set`
    /// because storing the closure outlives the call.
    actor InvokerCapture {
        var invoker: ToolInvoker?
        func set(_ i: @escaping ToolInvoker) { invoker = i }
        func get() -> ToolInvoker? { invoker }
    }

    enum InvokerCapturingPlugin: Plugin {
        static let id = "invoker_capture"
        nonisolated(unsafe) static var sink: InvokerCapture?
        static func register(config _: PluginConfig, invoker: @escaping ToolInvoker) async throws -> PluginContributions {
            await sink?.set(invoker)
            return .none
        }
    }
}

final class PluginLoaderTests: XCTestCase {
    func testHappyPathReturnsContributionsKeyedByID() async throws {
        let result = await PluginLoader.loadAll(
            types: [LoaderFixturePlugins.NoOpPlugin.self,
                    LoaderFixturePlugins.ToolContributingPlugin.self],
            configs: [:],
            invoker: LoaderFixturePlugins.noopInvoker
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
            configs: [:],
            invoker: LoaderFixturePlugins.noopInvoker
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
            configs: ["capture": cfg],
            invoker: LoaderFixturePlugins.noopInvoker
        )
        let observed = await captured.get()
        XCTAssertEqual(observed, cfg.json)

        await captured.set(Data("never".utf8))
        _ = await PluginLoader.loadAll(
            types: [LoaderFixturePlugins.CapturingPlugin.self],
            configs: [:],
            invoker: LoaderFixturePlugins.noopInvoker
        )
        let fallback = await captured.get()
        XCTAssertEqual(fallback, PluginConfig.empty.json)
    }

    /// The load-bearing test for cross-plugin tool dispatch: a
    /// plugin captures the `ToolInvoker` during `register` and the
    /// invoker dispatches against the registry as it stands at
    /// *call time*, not register time. We simulate that by handing
    /// the plugin an invoker that resolves names through a fixture
    /// tool table populated AFTER `register` returned — equivalent
    /// to the host wiring tools into `ToolRegistry` after every
    /// plugin's contributions have been collected.
    func testInvokerSeesToolsRegisteredAfterPluginRegister() async throws {
        let capture = LoaderFixturePlugins.InvokerCapture()
        LoaderFixturePlugins.InvokerCapturingPlugin.sink = capture

        // Mutable table that the invoker dispatches against. Empty
        // at register time; populated below.
        actor ToolTable {
            var tools: [ToolName: any BuiltinTool] = [:]
            func register(_ t: any BuiltinTool) { tools[t.name] = t }
            func invoke(_ name: ToolName, _ args: String) async throws -> ToolResult {
                guard let t = tools[name] else { return ToolResult(output: "", error: "unknown: \(name)") }
                return try await t.invoke(arguments: args)
            }
        }
        let table = ToolTable()
        let invoker: ToolInvoker = { name, args in
            try await table.invoke(name, args)
        }

        // Register: invoker is captured but no tools exist yet.
        _ = await PluginLoader.loadAll(
            types: [LoaderFixturePlugins.InvokerCapturingPlugin.self],
            configs: [:],
            invoker: invoker
        )

        // *Now* register the tool — simulating the host's
        // post-register wiring step.
        await table.register(LoaderFixturePlugins.MarkerTool())

        // Pull the captured invoker and dispatch through it.
        let captured = await capture.get()
        XCTAssertNotNil(captured)
        let result = try await captured!("test.marker", "{}")
        XCTAssertEqual(result.output, "marker", "captured invoker resolves against current registry contents, not snapshot at register time")
    }
}
