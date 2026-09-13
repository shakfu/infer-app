import XCTest
@testable import InferCore

/// `URLProtocol` subclass that lets a test register a handler returning a
/// canned response + body. Used to drive `OpenAIClient` / `AnthropicClient`
/// without touching the network. Body is delivered as one chunk;
/// `URLSession.bytes(for:)` still splits it into lines for the SSE parser.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    /// Every request URL and body since `reset()`, in order.
    nonisolated(unsafe) static var urls: [URL] = []
    nonisolated(unsafe) static var bodies: [Data] = []

    static func reset() {
        handler = nil
        lastRequest = nil
        lastBody = nil
        urls = []
        bodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        if let url = request.url { Self.urls.append(url) }
        // URLProtocol receives the body via `httpBodyStream`, not `httpBody`,
        // when URLSession adapts the request internally. Read both.
        if let body = request.httpBody {
            Self.lastBody = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufSize = 4096
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buf, maxLength: bufSize)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            Self.lastBody = data
        }
        if let body = Self.lastBody, request.httpMethod == "POST" { Self.bodies.append(body) }

        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

func makeStubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    config.urlCache = nil
    return URLSession(configuration: config)
}

final class CloudClientsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - OpenAI

    func testOpenAIStreamsDeltas() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"Hello"}}]}

        data: {"choices":[{"delta":{"content":", world"}}]}

        data: [DONE]


        """
        StubURLProtocol.handler = { req in
            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (resp, Data(sse.utf8))
        }
        let client = OpenAIClient(
            apiKey: "sk-test",
            baseURL: URL(string: "https://api.test")!,
            session: makeStubSession()
        )

        var collected = ""
        for try await piece in client.streamChat(
            messages: [
                CloudChatMessage(role: .system, content: "be terse"),
                CloudChatMessage(role: .user, content: "hi"),
            ],
            model: "gpt-test",
            params: CloudGenerationParams(temperature: 0.5, topP: 0.9, maxTokens: 64)
        ) {
            collected += piece
        }
        XCTAssertEqual(collected, "Hello, world")

        // Verify request shape: system message stays inline, auth header set.
        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "be terse")
        // OpenAI body should NOT have a top-level "system" field.
        XCTAssertNil(json["system"])
    }

    func testOpenAISurfacesHTTPErrorWithScrubbedKey() async {
        StubURLProtocol.handler = { req in
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            // Imagine the upstream echoes the key (it shouldn't, but if it did).
            let body = #"{"error":"invalid key sk-test-1234567890abcdef"}"#
            return (resp, Data(body.utf8))
        }
        let client = OpenAIClient(
            apiKey: "sk-test-1234567890abcdef",
            baseURL: URL(string: "https://api.test")!,
            session: makeStubSession()
        )

        do {
            for try await _ in client.streamChat(
                messages: [CloudChatMessage(role: .user, content: "hi")],
                model: "gpt-test",
            params: CloudGenerationParams(temperature: 0.5, topP: 0.9, maxTokens: 64)
            ) {}
            XCTFail("expected throw")
        } catch let CloudError.http(status, body) {
            XCTAssertEqual(status, 401)
            XCTAssertFalse(body.contains("sk-test-1234567890abcdef"))
            XCTAssertTrue(body.contains("***"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Anthropic

    func testAnthropicMovesSystemPromptToTopLevel() async throws {
        let sse = """
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}

        data: {"type":"message_stop"}


        """
        StubURLProtocol.handler = { req in
            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (resp, Data(sse.utf8))
        }
        let client = AnthropicClient(
            apiKey: "sk-ant-test",
            baseURL: URL(string: "https://api.test")!,
            session: makeStubSession()
        )

        var collected = ""
        for try await piece in client.streamChat(
            messages: [
                CloudChatMessage(role: .system, content: "be terse"),
                CloudChatMessage(role: .user, content: "hi"),
            ],
            model: "claude-test",
            params: CloudGenerationParams(temperature: 0.5, topP: 0.9, maxTokens: 64)
        ) {
            collected += piece
        }
        XCTAssertEqual(collected, "hi")

        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let body = try XCTUnwrap(StubURLProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        // System prompt should be at top level, NOT in messages.
        XCTAssertEqual(json["system"] as? String, "be terse")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
    }

    func testAnthropicIgnoresUnknownEventTypes() async throws {
        let sse = """
        data: {"type":"message_start","message":{"id":"x"}}

        data: {"type":"ping"}

        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"a"}}

        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"b"}}

        data: {"type":"message_stop"}


        """
        StubURLProtocol.handler = { req in
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (resp, Data(sse.utf8))
        }
        let client = AnthropicClient(
            apiKey: "k",
            baseURL: URL(string: "https://api.test")!,
            session: makeStubSession()
        )
        var collected = ""
        for try await piece in client.streamChat(
            messages: [CloudChatMessage(role: .user, content: "hi")],
            model: "claude-test",
            params: CloudGenerationParams(temperature: 0.5, topP: 0.9, maxTokens: 32)
        ) {
            collected += piece
        }
        XCTAssertEqual(collected, "ab")
    }
    // MARK: - Request path

    func testOpenAIPathAppendsToVersionedBaseURL() async throws {
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("data: [DONE]\n\n".utf8))
        }
        let session = makeStubSession()
        for (base, expected) in [
            (CloudProvider.openAIBaseURL, "https://api.openai.com/v1/chat/completions"),
            (CloudProvider.openRouterBaseURL, "https://openrouter.ai/api/v1/chat/completions"),
            (URL(string: "http://localhost:11434/v1")!, "http://localhost:11434/v1/chat/completions"),
        ] {
            let client = OpenAIClient(apiKey: Self.testKey, baseURL: base, session: session)
            for try await _ in client.streamChat(
                messages: [CloudChatMessage(role: .user, content: "hi")],
                model: "path-test", params: CloudGenerationParams()
            ) {}
            XCTAssertEqual(StubURLProtocol.urls.last?.absoluteString, expected)
        }
        XCTAssertEqual(OpenAIClient(apiKey: Self.testKey).baseURL, CloudProvider.openAIBaseURL)
    }

    // MARK: - Rejected-parameter retry

    /// Long enough that key scrubbing leaves error messages intact.
    private static let testKey = "sk-test-0123456789abcdef"

    private static func status(_ code: Int, _ body: String, for req: URLRequest) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    private static func lastBodyJSON() -> [String: Any] {
        guard let data = StubURLProtocol.bodies.last,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    func testOpenAIDropsRejectedSamplingParamsAndRemembersPerModel() async throws {
        let okSSE = "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"
        StubURLProtocol.handler = { req in
            let body = Self.lastBodyJSON()
            if body["temperature"] != nil {
                return Self.status(400, #"{"error":{"message":"Unsupported value: 'temperature' does not support 0.8 with this model.","param":"temperature","code":"unsupported_value"}}"#, for: req)
            }
            if body["top_p"] != nil {
                return Self.status(400, #"{"error":{"message":"Unsupported parameter: 'top_p' is not supported with this model.","param":"top_p","code":"unsupported_parameter"}}"#, for: req)
            }
            return Self.status(200, okSSE, for: req)
        }
        let client = OpenAIClient(apiKey: Self.testKey, baseURL: URL(string: "https://retry.test/v1")!, session: makeStubSession())
        let model = "reasoning-\(UUID().uuidString)"
        func send() async throws -> String {
            var out = ""
            for try await piece in client.streamChat(
                messages: [CloudChatMessage(role: .user, content: "hi")],
                model: model, params: CloudGenerationParams(temperature: 0.8, topP: 0.95)
            ) { out += piece }
            return out
        }

        let first = try await send()
        XCTAssertEqual(first, "ok")
        XCTAssertEqual(StubURLProtocol.bodies.count, 3)
        XCTAssertNil(Self.lastBodyJSON()["temperature"])
        XCTAssertNil(Self.lastBodyJSON()["top_p"])

        // Second turn sends the relaxed body directly.
        let second = try await send()
        XCTAssertEqual(second, "ok")
        XCTAssertEqual(StubURLProtocol.bodies.count, 4)
    }

    func testAnthropicDropsDeprecatedTemperature() async throws {
        let okSSE = "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n"
        StubURLProtocol.handler = { req in
            if Self.lastBodyJSON()["temperature"] != nil {
                return Self.status(400, #"{"type":"error","error":{"type":"invalid_request_error","message":"`temperature` is deprecated for this model."}}"#, for: req)
            }
            return Self.status(200, okSSE, for: req)
        }
        let client = AnthropicClient(apiKey: Self.testKey, baseURL: URL(string: "https://retry.test")!, session: makeStubSession())
        var out = ""
        for try await piece in client.streamChat(
            messages: [CloudChatMessage(role: .user, content: "hi")],
            model: "claude-\(UUID().uuidString)", params: CloudGenerationParams(temperature: 0.8)
        ) { out += piece }
        XCTAssertEqual(out, "ok")
        XCTAssertEqual(StubURLProtocol.bodies.count, 2)
    }

    func testAnthropicSwitchesToAdaptiveThinkingWhenEnabledIsUnsupported() async throws {
        let okSSE = "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n"
        StubURLProtocol.handler = { req in
            if (Self.lastBodyJSON()["thinking"] as? [String: Any])?["type"] as? String == "enabled" {
                return Self.status(400, #"{"type":"error","error":{"type":"invalid_request_error","message":"\"thinking.type.enabled\" is not supported for this model. Use \"thinking.type.adaptive\" and \"output_config.effort\" to control thinking behavior."}}"#, for: req)
            }
            return Self.status(200, okSSE, for: req)
        }
        let client = AnthropicClient(apiKey: Self.testKey, baseURL: URL(string: "https://retry.test")!, session: makeStubSession())
        var out = ""
        for try await piece in client.streamChat(
            messages: [CloudChatMessage(role: .user, content: "hi")],
            model: "claude-\(UUID().uuidString)",
            params: CloudGenerationParams(maxTokens: 4096, thinkingBudgetTokens: 1024)
        ) { out += piece }
        XCTAssertEqual(out, "ok")
        let thinking = try XCTUnwrap(Self.lastBodyJSON()["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "adaptive")
        XCTAssertNil(thinking["budget_tokens"])
    }

    func testUnrelated400IsNotRetried() async {
        StubURLProtocol.handler = { req in
            Self.status(400, #"{"error":{"message":"max_tokens is too large","param":"max_completion_tokens","code":"invalid_value"}}"#, for: req)
        }
        let client = OpenAIClient(apiKey: Self.testKey, baseURL: URL(string: "https://retry.test/v1")!, session: makeStubSession())
        do {
            for try await _ in client.streamChat(
                messages: [CloudChatMessage(role: .user, content: "hi")],
                model: "m-\(UUID().uuidString)", params: CloudGenerationParams()
            ) {}
            XCTFail("expected throw")
        } catch let CloudError.http(status, body) {
            XCTAssertEqual(status, 400)
            XCTAssertTrue(body.contains("max_tokens is too large"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(StubURLProtocol.bodies.count, 1)
    }
}
