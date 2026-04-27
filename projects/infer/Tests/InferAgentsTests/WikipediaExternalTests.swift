import XCTest
@testable import InferAgents

/// External-system tests that exercise both Wikipedia tools against
/// the real `en.wikipedia.org` API. Catches changes to the MediaWiki
/// JSON shape, rate-limit / 429 patterns, or schema additions that
/// our tolerant decoder might silently drop.
///
/// Skipped by default in `make test`; runs under `make test-integration`.
/// Auto-skips on network failure / non-2xx so the suite isn't flaky on
/// captive-portal CI. Opt out via `INFER_SKIP_WIKIPEDIA_EXTERNAL=1`.
final class WikipediaExternalTests: XCTestCase {

    private static let skipEnvKey = "INFER_SKIP_WIKIPEDIA_EXTERNAL"

    private func skipIfOptedOut() throws {
        if ProcessInfo.processInfo.environment[Self.skipEnvKey] == "1" {
            throw XCTSkip("\(Self.skipEnvKey) set; skipping live Wikipedia round-trip")
        }
    }

    /// "Ada Lovelace" is the load-bearing query: stable title, well-
    /// indexed, unambiguous, and unlikely to be deleted or merged.
    /// Same logic as the WebSearch external test — we don't pin
    /// ranking, only that *some* sane result comes back.
    func testRealSearchRoundTrip() async throws {
        try skipIfOptedOut()
        let tool = WikipediaSearchTool()
        let result: ToolResult
        do {
            result = try await tool.invoke(arguments: ##"{"query": "Ada Lovelace", "limit": 3}"##)
        } catch {
            throw XCTSkip("network failure: \(error)")
        }
        if let err = result.error, err.contains("HTTP") {
            throw XCTSkip("Wikipedia API returned non-2xx: \(err)")
        }
        XCTAssertNil(result.error, "got error: \(result.error ?? "")")
        let parsed = try JSONDecoder().decode([WikipediaSearchTool.SearchResult].self, from: Data(result.output.utf8))
        XCTAssertFalse(parsed.isEmpty, "expected at least one hit for 'Ada Lovelace'")
        let titles = parsed.map(\.title)
        XCTAssertTrue(
            titles.contains(where: { $0.contains("Lovelace") || $0.contains("Ada") }),
            "expected a Lovelace-related title in: \(titles)"
        )
        for hit in parsed {
            XCTAssertTrue(hit.url.hasPrefix("https://en.wikipedia.org/wiki/"))
            XCTAssertGreaterThan(hit.wordcount, 0)
        }
        print("[WikipediaExternal] search returned \(parsed.count) hits; first=\(parsed.first?.title ?? "")")
    }

    func testRealArticleLeadRoundTrip() async throws {
        try skipIfOptedOut()
        let tool = WikipediaArticleTool()
        let result: ToolResult
        do {
            result = try await tool.invoke(arguments: ##"{"title": "Ada Lovelace", "lead": true}"##)
        } catch {
            throw XCTSkip("network failure: \(error)")
        }
        if let err = result.error, err.contains("HTTP") {
            throw XCTSkip("Wikipedia API returned non-2xx: \(err)")
        }
        XCTAssertNil(result.error, "got error: \(result.error ?? "")")
        XCTAssertFalse(result.output.isEmpty)
        // Body should mention some load-bearing facts that have been
        // in the lead for years and are unlikely to change.
        let lower = result.output.lowercased()
        XCTAssertTrue(lower.contains("byron"), "lead missing 'byron'; output=\(result.output.prefix(200))")
        XCTAssertTrue(lower.contains("mathemat"), "lead missing 'mathemat'; output=\(result.output.prefix(200))")
        // Lead extracts are short — comfortably under 16 KB.
        XCTAssertLessThan(result.output.utf8.count, 16 * 1024)
        // Plain text only — no HTML chrome.
        XCTAssertFalse(result.output.contains("<a "))
        XCTAssertFalse(result.output.contains("<span"))
        print("[WikipediaExternal] article lead is \(result.output.utf8.count) bytes")
    }

    func testRealArticleMissingTitle() async throws {
        try skipIfOptedOut()
        let tool = WikipediaArticleTool()
        let result: ToolResult
        do {
            result = try await tool.invoke(arguments: ##"{"title": "Asdfghjkl Definitely Not An Article 472917"}"##)
        } catch {
            throw XCTSkip("network failure: \(error)")
        }
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("no Wikipedia article"))
    }
}
