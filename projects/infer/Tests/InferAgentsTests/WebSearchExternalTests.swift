import XCTest
@testable import InferAgents

/// External-system test: hits real `html.duckduckgo.com` to verify the
/// scraper's regex still works against today's DDG markup. The whole
/// reason this test exists is that DDG can rev their HTML at any time
/// and silently break the parser; this catches the change before the
/// next user complaint.
///
/// Skipped by default in `make test`; runs under `make test-integration`.
/// Auto-skips when offline or DDG returns a non-2xx (rate-limited /
/// blocked) so the suite isn't flaky on a captive-portal CI.
///
/// Opt out even when online via `INFER_SKIP_WEB_SEARCH_EXTERNAL=1`.
final class WebSearchExternalTests: XCTestCase {

    private static let skipEnvKey = "INFER_SKIP_WEB_SEARCH_EXTERNAL"

    private func skipIfOptedOut() throws {
        if ProcessInfo.processInfo.environment[Self.skipEnvKey] == "1" {
            throw XCTSkip("\(Self.skipEnvKey) set; skipping live DDG round-trip")
        }
    }

    /// Pick a query whose top result is overwhelmingly stable across
    /// time and not in danger of being demoted: the official Swift
    /// language site has been the top hit for "swift programming
    /// language" for over a decade. We don't assert on which result is
    /// first — only that *some* result comes back with a non-empty
    /// title and an https URL — so we're robust to ranking shifts.
    func testRealDDGRoundTrip() async throws {
        try skipIfOptedOut()
        let tool = WebSearchTool(backend: .duckDuckGo)
        let result: ToolResult
        do {
            result = try await tool.invoke(arguments: ##"{"query": "swift programming language", "limit": 5}"##)
        } catch {
            throw XCTSkip("network failure / DDG blocked: \(error)")
        }
        if let err = result.error {
            // Distinguish parser-level failure (test should fail) from
            // network / 503 / rate-limit failure (should skip).
            if err.contains("search failed") {
                throw XCTSkip("DDG returned a non-2xx status: \(err)")
            }
            XCTFail("unexpected error from web.search: \(err)")
            return
        }
        let parsed = try JSONDecoder().decode([WebSearchTool.SearchResult].self, from: Data(result.output.utf8))
        XCTAssertFalse(parsed.isEmpty, "DDG returned zero results — parser may be broken against current DDG markup")
        for r in parsed {
            XCTAssertFalse(r.title.isEmpty, "title should not be empty")
            XCTAssertTrue(r.url.hasPrefix("http"), "URL should be http(s): \(r.url)")
        }
        print("[WebSearchExternal] DDG returned \(parsed.count) results; first=\(parsed.first?.title ?? "")")
    }
}
