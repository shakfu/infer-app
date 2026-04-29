import XCTest
@testable import InferCore

final class CloudProviderTests: XCTestCase {
    func testKeychainAccountStableForBuiltins() {
        XCTAssertEqual(CloudProvider.openai.keychainAccount, "openai")
        XCTAssertEqual(CloudProvider.anthropic.keychainAccount, "anthropic")
    }

    func testKeychainAccountForCompatNormalizes() {
        let url = URL(string: "http://localhost:11434/v1")!
        let p1 = CloudProvider.openaiCompatible(name: "Ollama (local)", baseURL: url)
        let p2 = CloudProvider.openaiCompatible(name: "ollama-local", baseURL: url)
        // Lowercased, non-allowed chars collapsed to a single dash, trailing
        // dashes trimmed.
        XCTAssertEqual(p1.keychainAccount, "compat.ollama-local")
        XCTAssertEqual(p2.keychainAccount, "compat.ollama-local")
    }

    func testEnvVarNameNilForCompat() {
        XCTAssertEqual(CloudProvider.openai.envVarName, "OPENAI_API_KEY")
        XCTAssertEqual(CloudProvider.anthropic.envVarName, "ANTHROPIC_API_KEY")
        XCTAssertNil(
            CloudProvider.openaiCompatible(
                name: "x",
                baseURL: URL(string: "https://example.com")!
            ).envVarName
        )
    }

    func testEndpointPolicyAcceptsHTTPS() {
        XCTAssertTrue(CloudEndpointPolicy.isAcceptable(URL(string: "https://api.example.com")!))
        XCTAssertTrue(CloudEndpointPolicy.isAcceptable(URL(string: "https://api.example.com/v1")!))
    }

    func testEndpointPolicyAcceptsLoopbackHTTP() {
        XCTAssertTrue(CloudEndpointPolicy.isAcceptable(URL(string: "http://localhost:11434/v1")!))
        XCTAssertTrue(CloudEndpointPolicy.isAcceptable(URL(string: "http://127.0.0.1:8080")!))
    }

    func testEndpointPolicyRejectsPlainHTTP() {
        XCTAssertFalse(CloudEndpointPolicy.isAcceptable(URL(string: "http://api.example.com")!))
        XCTAssertFalse(CloudEndpointPolicy.isAcceptable(URL(string: "http://10.0.0.1")!))
    }

    func testEndpointPolicyRejectsOtherSchemes() {
        XCTAssertFalse(CloudEndpointPolicy.isAcceptable(URL(string: "ftp://example.com")!))
        XCTAssertFalse(CloudEndpointPolicy.isAcceptable(URL(string: "file:///etc/passwd")!))
    }

    func testRecommendedModelsBuiltinsNonEmpty() {
        XCTAssertFalse(CloudRecommendedModels.suggestions(for: .openai).isEmpty)
        XCTAssertFalse(CloudRecommendedModels.suggestions(for: .anthropic).isEmpty)
        XCTAssertTrue(
            CloudRecommendedModels.suggestions(
                for: .openaiCompatible(name: "x", baseURL: URL(string: "https://x")!)
            ).isEmpty
        )
    }

    func testKeyScrubbingRemovesFullKey() {
        let key = "sk-test-1234567890abcdef"
        let body = "Error: invalid key sk-test-1234567890abcdef in header"
        let scrubbed = CloudClients.scrubKey(from: body, apiKey: key)
        XCTAssertFalse(scrubbed.contains(key))
        XCTAssertTrue(scrubbed.contains("***"))
    }

    func testKeyScrubbingRemovesPrefixForLongKeys() {
        let key = "sk-ant-api03-VERY-LONG-KEY-DATA"
        let body = "auth failed for sk-ant-a..."
        // First 8 chars of the key = "sk-ant-a"; that should be replaced.
        let scrubbed = CloudClients.scrubKey(from: body, apiKey: key)
        XCTAssertFalse(scrubbed.contains("sk-ant-a"))
    }

    func testKeyScrubbingNoOpForShortKey() {
        // Short keys (< 12 chars) skip prefix scrubbing to avoid replacing
        // arbitrary substrings that just happen to overlap.
        let key = "shortkey"
        let body = "error message mentioning shortkey and shortk only"
        let scrubbed = CloudClients.scrubKey(from: body, apiKey: key)
        // Full-key match is still scrubbed.
        XCTAssertFalse(scrubbed.contains("shortkey"))
        // Prefix "shortk" stays — partial scrubbing is gated to long keys.
        XCTAssertTrue(scrubbed.contains("shortk only"))
    }

    func testKeyScrubbingEmptyKey() {
        let body = "some response body"
        XCTAssertEqual(CloudClients.scrubKey(from: body, apiKey: ""), body)
    }
}
