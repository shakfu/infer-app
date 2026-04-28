import XCTest
@testable import PluginAPI
@testable import plugin_wiki

final class WikiPluginTests: XCTestCase {
    func testRegisterContributesWikiPing() async throws {
        let contrib = try await WikiPlugin.register(config: .empty)
        XCTAssertEqual(contrib.tools.count, 1)
        XCTAssertEqual(contrib.tools.first?.name, "wiki.ping")
    }

    func testWikiPingReturnsOK() async throws {
        let contrib = try await WikiPlugin.register(config: .empty)
        let tool = try XCTUnwrap(contrib.tools.first)
        let result = try await tool.invoke(arguments: "{}")
        XCTAssertEqual(result.output, "ok")
        XCTAssertNil(result.error)
    }
}
