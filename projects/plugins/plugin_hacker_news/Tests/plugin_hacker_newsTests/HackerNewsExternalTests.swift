import XCTest
@testable import PluginAPI
@testable import plugin_hacker_news

/// Tests that hit the real Algolia HN API. Auto-skipped when offline
/// (matches the project-wide `*ExternalTests` pattern). Run via
/// `make test-integration`.
///
/// HN's API is rock-solid public, so these are usually fast and
/// reliable; we still skip on connection failure rather than fail
/// the suite, since CI runners may not have outbound HTTPS.
final class HackerNewsExternalTests: XCTestCase {
    private let apiBase = URL(string: "https://hn.algolia.com/api/v1")!

    private func skipIfOffline() async throws {
        // Cheap reachability probe: HEAD the HN root with a short
        // timeout. If it fails, skip the rest of the suite.
        var request = URLRequest(url: URL(string: "https://hn.algolia.com")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 4
        do {
            _ = try await URLSession.shared.data(for: request)
        } catch {
            throw XCTSkip("HN API unreachable: \(error.localizedDescription)")
        }
    }

    func testSearchHitsRealAPI() async throws {
        try await skipIfOffline()
        let tool = HNSearchTool(apiBase: apiBase)
        let result = try await tool.invoke(arguments: #"{"query":"swift programming","limit":3}"#)
        XCTAssertNil(result.error)
        struct Item: Decodable {
            let id: String
            let hn_url: String
        }
        let items = try JSONDecoder().decode([Item].self, from: Data(result.output.utf8))
        XCTAssertGreaterThan(items.count, 0, "expected non-empty results for 'swift programming'")
        XCTAssertTrue(items[0].hn_url.hasPrefix("https://news.ycombinator.com/item?id="))
    }

    func testItemHitsRealAPI() async throws {
        try await skipIfOffline()
        // HN item id 1 is the very first story ever. Stable for our
        // purposes — it's not going anywhere.
        let tool = HNItemTool(apiBase: apiBase)
        let result = try await tool.invoke(arguments: #"{"id":1,"max_comment_depth":0}"#)
        XCTAssertNil(result.error)
        struct Item: Decodable {
            let id: Int
            let author: String?
        }
        let item = try JSONDecoder().decode(Item.self, from: Data(result.output.utf8))
        XCTAssertEqual(item.id, 1)
    }

    func testUserHitsRealAPI() async throws {
        try await skipIfOffline()
        // `pg` (Paul Graham) is a stable HN account.
        let tool = HNUserTool(apiBase: apiBase)
        let result = try await tool.invoke(arguments: #"{"username":"pg"}"#)
        XCTAssertNil(result.error)
        struct User: Decodable {
            let username: String
            let karma: Int
        }
        let user = try JSONDecoder().decode(User.self, from: Data(result.output.utf8))
        XCTAssertEqual(user.username, "pg")
        XCTAssertGreaterThan(user.karma, 1000)
    }

    func testUser404SurfacesError() async throws {
        try await skipIfOffline()
        let tool = HNUserTool(apiBase: apiBase)
        // A username this absurd shouldn't exist. Algolia returns
        // *either* HTTP 404 *or* HTTP 500 for unknown users (their
        // server quirk; we've observed both). The tool maps 404 to a
        // friendly "no HN user named X" message and falls through to
        // "fetch failed: HTTP <code>" otherwise. We only assert that
        // *some* error came back — pinning the exact message would
        // tie the test to Algolia's current behavior.
        let result = try await tool.invoke(arguments: #"{"username":"this-user-definitely-does-not-exist-zzzqx"}"#)
        XCTAssertNotNil(result.error, "expected an error for a clearly-fake username")
    }
}
