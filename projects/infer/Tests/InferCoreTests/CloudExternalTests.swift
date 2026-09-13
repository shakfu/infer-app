import XCTest
@testable import InferCore

/// Real macOS keychain. Under `swift test` the binary is ad-hoc signed, so
/// this exercises the login-keychain fallback.
final class APIKeyStoreExternalTests: XCTestCase {
    func testSetUpdateGetClearRoundTrip() throws {
        let service = "com.infer.apikey.test.\(UUID().uuidString)"
        defer { APIKeyStore.clear(service: service, account: "acct") }

        XCTAssertNil(APIKeyStore.get(service: service, account: "acct"))
        try APIKeyStore.set("first", service: service, account: "acct")
        XCTAssertEqual(APIKeyStore.get(service: service, account: "acct"), "first")
        try APIKeyStore.set("second", service: service, account: "acct")
        XCTAssertEqual(APIKeyStore.get(service: service, account: "acct"), "second")
        APIKeyStore.clear(service: service, account: "acct")
        XCTAssertNil(APIKeyStore.get(service: service, account: "acct"))
    }
}

/// Live model-list endpoints. Each test skips when its key env var is unset.
final class CloudModelCatalogExternalTests: XCTestCase {
    private func key(_ name: String) throws -> String {
        guard let k = ProcessInfo.processInfo.environment[name], !k.isEmpty else {
            throw XCTSkip("\(name) not set")
        }
        return k
    }

    func testOpenAIListIsFilteredToChatModels() async throws {
        let ids = try await CloudModelCatalog.fetch(provider: .openai, apiKey: key("OPENAI_API_KEY"), session: .shared)
        XCTAssertFalse(ids.isEmpty)
        XCTAssertFalse(ids.contains { $0.contains("embedding") || $0.contains("tts") })
    }

    func testAnthropicListIsNonEmpty() async throws {
        let ids = try await CloudModelCatalog.fetch(provider: .anthropic, apiKey: key("ANTHROPIC_API_KEY"), session: .shared)
        XCTAssertTrue(ids.contains { $0.hasPrefix("claude-") })
    }

    func testOpenRouterListIsNonEmpty() async throws {
        let ids = try await CloudModelCatalog.fetch(provider: .openrouter, apiKey: key("OPENROUTER_API_KEY"), session: .shared)
        XCTAssertTrue(ids.contains { $0.contains("/") })
    }
}
