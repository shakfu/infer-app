import XCTest
@testable import InferAgents

private struct EchoTool: BuiltinTool {
    let name: ToolName
    let spec: ToolSpec
    let onInvoke: @Sendable (String) -> ToolResult

    init(name: ToolName, description: String = "", onInvoke: @escaping @Sendable (String) -> ToolResult) {
        self.name = name
        self.spec = ToolSpec(name: name, description: description)
        self.onInvoke = onInvoke
    }

    func invoke(arguments: String) async throws -> ToolResult {
        onInvoke(arguments)
    }
}

final class ToolRegistryTests: XCTestCase {
    func testRegisterAndLookup() async {
        let reg = ToolRegistry()
        let tool = EchoTool(name: "a") { _ in ToolResult(output: "hi") }
        await reg.register(tool)

        let resolved = await reg.tool(named: "a")
        XCTAssertNotNil(resolved)
        let missing = await reg.tool(named: "missing")
        XCTAssertNil(missing)
    }

    func testBulkRegister() async {
        let reg = ToolRegistry()
        await reg.register([
            EchoTool(name: "a") { _ in ToolResult(output: "") },
            EchoTool(name: "b") { _ in ToolResult(output: "") },
        ])
        let names = await reg.allNames()
        XCTAssertEqual(names, ["a", "b"])
    }

    func testRegisterReplacesByName() async {
        let reg = ToolRegistry()
        await reg.register(EchoTool(name: "a") { _ in ToolResult(output: "first") })
        await reg.register(EchoTool(name: "a") { _ in ToolResult(output: "second") })
        let result = try? await reg.invoke(name: "a", arguments: "{}")
        XCTAssertEqual(result?.output, "second")
    }

    func testAllSpecsSortedByName() async {
        let reg = ToolRegistry()
        await reg.register([
            EchoTool(name: "z") { _ in ToolResult(output: "") },
            EchoTool(name: "a") { _ in ToolResult(output: "") },
            EchoTool(name: "m") { _ in ToolResult(output: "") },
        ])
        let specNames = await reg.allSpecs().map(\.name)
        XCTAssertEqual(specNames, ["a", "m", "z"])
    }

    func testInvokePassesArgumentsThrough() async throws {
        let reg = ToolRegistry()
        await reg.register(EchoTool(name: "echo") { args in
            ToolResult(output: args)
        })
        let result = try await reg.invoke(name: "echo", arguments: "{\"foo\":1}")
        XCTAssertEqual(result.output, "{\"foo\":1}")
    }

    func testInvokeUnknownToolThrows() async {
        let reg = ToolRegistry()
        do {
            _ = try await reg.invoke(name: "nope", arguments: "{}")
            XCTFail("expected throw")
        } catch let error as ToolError {
            XCTAssertEqual(error, .unknown("nope"))
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}
