import XCTest
@testable import InferCore

/// Wire-shape tests for `OpenAIImageClient`. Reuses `StubURLProtocol`
/// from `CloudClientsTests.swift` (same module, internal access).
final class CloudImageClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeStubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    /// Verifies the request body contains the expected fields and the
    /// response's b64_json is decoded into the result's `data`. Does
    /// not validate the bytes are a real PNG — that would conflate this
    /// test with the runner's image-encoding path.
    func testOpenAIImageHappyPathRequestShapeAndResponseDecode() async throws {
        let payload: Data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let b64 = payload.base64EncodedString()
        let respJSON = """
        {"data":[{"b64_json":"\(b64)","revised_prompt":"a clearer prompt"}]}
        """

        StubURLProtocol.handler = { req in
            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (resp, Data(respJSON.utf8))
        }

        let client = OpenAIImageClient(
            apiKey: "sk-test",
            baseURL: URL(string: "https://api.test")!,
            session: makeStubSession()
        )

        let params = CloudImageParams(
            model: "gpt-image-1",
            size: .s1024x1024,
            quality: .high,
            outputFormat: .png,
            background: .opaque,
            n: 1
        )
        let results = try await client.generate(prompt: "a calm beach", params: params)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.data, payload)
        XCTAssertEqual(results.first?.revisedPrompt, "a clearer prompt")
        XCTAssertEqual(results.first?.width, 1024)
        XCTAssertEqual(results.first?.height, 1024)

        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(req.url?.path, "/v1/images/generations")

        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-image-1")
        XCTAssertEqual(json["prompt"] as? String, "a calm beach")
        XCTAssertEqual(json["size"] as? String, "1024x1024")
        XCTAssertEqual(json["quality"] as? String, "high")
        XCTAssertEqual(json["background"] as? String, "opaque")
        XCTAssertEqual(json["n"] as? Int, 1)
        // `response_format` is a DALL-E-era parameter; gpt-image-1
        // rejects it. Verify we don't send it.
        XCTAssertNil(json["response_format"])
    }

    /// Default params (auto / auto / png / auto) should omit
    /// `quality` and `background` from the body but keep `size: auto`
    /// and the default-format `output_format: png` only when explicitly
    /// non-default. Verifies the omission rules are honoured.
    func testOpenAIImageOmitsDefaultOptionalFields() async throws {
        let payload = Data([0x89, 0x50, 0x4E, 0x47])
        let respJSON = #"{"data":[{"b64_json":"\#(payload.base64EncodedString())"}]}"#

        StubURLProtocol.handler = { req in
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (resp, Data(respJSON.utf8))
        }
        let client = OpenAIImageClient(
            apiKey: "sk-test",
            baseURL: URL(string: "https://api.test")!,
            session: makeStubSession()
        )
        _ = try await client.generate(
            prompt: "x",
            params: CloudImageParams()  // all defaults
        )

        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["size"] as? String, "auto")
        XCTAssertNil(json["quality"])
        XCTAssertNil(json["background"])
        XCTAssertNil(json["output_format"])  // png is the default-omit case
    }

    func testOpenAIImageSurfacesHTTPErrorWithScrubbedKey() async {
        StubURLProtocol.handler = { req in
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            // Imagine the upstream echoes the key; verify scrubbing.
            let body = #"{"error":"invalid key sk-test-1234567890abcdef"}"#
            return (resp, Data(body.utf8))
        }
        let client = OpenAIImageClient(
            apiKey: "sk-test-1234567890abcdef",
            baseURL: URL(string: "https://api.test")!,
            session: makeStubSession()
        )

        do {
            _ = try await client.generate(prompt: "x", params: CloudImageParams())
            XCTFail("expected throw")
        } catch let CloudError.http(status, body) {
            XCTAssertEqual(status, 401)
            XCTAssertFalse(body.contains("sk-test-1234567890abcdef"))
            XCTAssertTrue(body.contains("***"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
