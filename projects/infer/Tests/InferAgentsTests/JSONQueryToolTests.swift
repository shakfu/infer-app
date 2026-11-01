import XCTest
@testable import InferAgents

final class JSONQueryToolTests: XCTestCase {
    private let doc = #"""
    {"name":"infer","stars":12,"ratio":0.1,"ok":true,"gone":null,"a.b":"dotted",
     "items":[{"id":1,"tag":"x"},{"id":2},{"id":3,"tag":"z"}],
     "grid":[[1,2],[3]]}
    """#

    private func args(_ payload: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }

    private func run(_ query: String, json: String? = nil) async throws -> ToolResult {
        try await JSONQueryTool().invoke(arguments: args(["query": query, "json": json ?? doc]))
    }

    private func assertOutput(_ query: String, _ expected: String, line: UInt = #line) async throws {
        let result = try await run(query)
        XCTAssertNil(result.error, line: line)
        XCTAssertEqual(result.output, expected, line: line)
    }

    private func assertError(_ query: String, contains text: String, line: UInt = #line) async throws {
        let result = try await run(query)
        XCTAssertEqual(result.output, "", line: line)
        XCTAssertTrue(result.error?.contains(text) == true, "got \(result.error ?? "nil")", line: line)
    }

    // MARK: - Selection

    func testScalarsRenderAsPrimitives() async throws {
        try await assertOutput(".name", "infer")
        try await assertOutput(".stars", "12")
        try await assertOutput(".ratio", "0.1")
        try await assertOutput(".ok", "true")
        try await assertOutput(".gone", "null")
    }

    func testContainersRenderAsJSON() async throws {
        try await assertOutput(".items[1]", #"{"id":2}"#)
        try await assertOutput(".grid", "[[1,2],[3]]")
    }

    func testNumbersKeepTheirValue() async throws {
        let json = #"[0.1,3.0,1e20,12345678901234567890,123456789012345678901234567890,true,false]"#
        let result = try await run(".", json: json)
        XCTAssertEqual(result.output, "[0.1,3.0,1e+20,12345678901234567890,123456789012345678901234567890,true,false]")
    }

    func testNestedStringsAreEscapedAndKeysSorted() async throws {
        let result = try await run(".", json: #"{"b":"a\"b\nc","a":["https://x.test/"]}"#)
        XCTAssertEqual(result.output, #"{"a":["https://x.test/"],"b":"a\"b\nc"}"#)
    }

    func testRootSpellings() async throws {
        let json = #"{"a":1}"#
        for query in [".", "$", "$.", ""] {
            let result = try await run(query, json: json)
            XCTAssertEqual(result.output, json, "query: \(query)")
        }
    }

    func testAlternatePathSpellings() async throws {
        try await assertOutput("items[0].id", "1")
        try await assertOutput("$.items[0].id", "1")
        try await assertOutput(".items.[0].id", "1")
        try await assertOutput(#"["a.b"]"#, "dotted")
    }

    func testTopLevelArray() async throws {
        let result = try await run("[1]", json: "[10,20]")
        XCTAssertEqual(result.output, "20")
    }

    // MARK: - Wildcard

    func testWildcardProjectsAndSkipsMisses() async throws {
        try await assertOutput(".items[*].id", "[1,2,3]")
        try await assertOutput(".items[*].tag", #"["x","z"]"#)
    }

    func testNestedWildcardsFlatten() async throws {
        try await assertOutput(".grid[*][*]", "[1,2,3]")
    }

    /// A single-match wildcard still returns an array, so the result shape
    /// depends on the query and not on the data.
    func testWildcardAlwaysReturnsArray() async throws {
        let result = try await run(".a[*].b", json: #"{"a":[{"b":"only"}]}"#)
        XCTAssertEqual(result.output, #"["only"]"#)
    }

    func testWildcardWithNoMatchesIsEmptyArray() async throws {
        try await assertOutput(".items[*].missing", "[]")
    }

    // MARK: - Misses and bad input

    func testMissesNameTheCause() async throws {
        try await assertError(".missing", contains: "no key 'missing'")
        try await assertError(".items[9]", contains: "array has 3 elements")
        try await assertError(".name.first", contains: "a string")
        try await assertError(".name[*]", contains: "needs an array")
    }

    /// A missing key is an error and an explicit null is a value, so the model
    /// can tell the two apart.
    func testNullValueDiffersFromMissingKey() async throws {
        let present = try await run(".gone")
        XCTAssertNil(present.error)
        let absent = try await run(".absent")
        XCTAssertNotNil(absent.error)
    }

    func testMalformedQueries() async throws {
        for query in [".a..b", ".a[", ".a[x]", ".a[-1]", #".a["b]"#, ".a[0]b"] {
            let result = try await run(query)
            XCTAssertTrue(result.error?.contains("invalid query") == true, "query: \(query), got \(result)")
        }
    }

    func testArgumentValidation() async throws {
        let tool = JSONQueryTool()
        let notObject = try await tool.invoke(arguments: "[]")
        XCTAssertNotNil(notObject.error)
        let noQuery = try await tool.invoke(arguments: #"{"json":"{}"}"#)
        XCTAssertEqual(noQuery.error, "missing string argument: query")
        let neither = try await tool.invoke(arguments: #"{"query":"."}"#)
        XCTAssertEqual(neither.error, "pass exactly one of json or url")
        let both = try await tool.invoke(arguments: #"{"query":".","json":"{}","url":"https://x.test/"}"#)
        XCTAssertEqual(both.error, "pass exactly one of json or url")
        let badJSON = try await run(".", json: "{nope")
        XCTAssertEqual(badJSON.error, "json argument is not valid JSON")
    }

    func testAcceptsJSONAsNestedValue() async throws {
        let result = try await JSONQueryTool().invoke(arguments: #"{"query":".a","json":{"a":7}}"#)
        XCTAssertEqual(result.output, "7")
    }

    func testLongOutputIsTruncatedWithMarker() async throws {
        let long = String(repeating: "x", count: JSONQueryTool.maxBytes + 10)
        let result = try await run(".s", json: try args(["s": long]))
        XCTAssertTrue(result.output.hasPrefix("xxx"))
        XCTAssertTrue(result.output.hasSuffix("narrow the query ...]"))
        XCTAssertLessThan(result.output.utf8.count, JSONQueryTool.maxBytes + 100)
    }

    // MARK: - URL source

    private func stubbedFetcher(body: String, contentType: String = "application/json") -> URLFetchTool {
        JSONQueryStubProtocol.response = (body, contentType)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JSONQueryStubProtocol.self]
        return URLFetchTool(allowedHosts: ["api.test"], session: URLSession(configuration: config))
    }

    func testURLSourceStripsHeaderAndQueries() async throws {
        let tool = JSONQueryTool(fetcher: stubbedFetcher(body: #"{"tag_name":"v1\n\nv2"}"#))
        let result = try await tool.invoke(arguments: args(["query": ".tag_name", "url": "https://api.test/x"]))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, "v1\n\nv2")
    }

    func testURLSourceEnforcesFetchAllowlist() async throws {
        let tool = JSONQueryTool(fetcher: stubbedFetcher(body: "{}"))
        let result = try await tool.invoke(arguments: args(["query": ".", "url": "https://evil.test/x"]))
        XCTAssertEqual(result.error, "host 'evil.test' is not on the allowlist")
    }

    func testURLSourceReportsNonJSONBody() async throws {
        let tool = JSONQueryTool(fetcher: stubbedFetcher(body: "<html>", contentType: "text/html"))
        let result = try await tool.invoke(arguments: args(["query": ".", "url": "https://api.test/x"]))
        XCTAssertTrue(result.error?.contains("not valid JSON") == true)
    }

    /// A body over the `http.fetch` cap is cut mid-document, so it must fail
    /// rather than return a value from partial data.
    func testURLSourceRejectsTruncatedBody() async throws {
        let filler = String(repeating: "x", count: URLFetchTool.maxBytes)
        let tool = JSONQueryTool(fetcher: stubbedFetcher(body: try args(["s": filler])))
        let result = try await tool.invoke(arguments: args(["query": ".s", "url": "https://api.test/x"]))
        XCTAssertTrue(result.error?.contains("cap") == true)
    }

    func testURLSourceWithoutFetcherIsAnError() async throws {
        let result = try await JSONQueryTool().invoke(arguments: args(["query": ".", "url": "https://api.test/x"]))
        XCTAssertTrue(result.error?.contains("not configured") == true)
    }
}

private final class JSONQueryStubProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (body: String, contentType: String) = ("", "")

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": Self.response.contentType]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
