import XCTest
@testable import InferAgents

final class QuartoRenderToolTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quarto-tool-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeFakeQuarto() throws -> URL {
        let path = tempDir.appendingPathComponent("quarto")
        let script = """
        #!/bin/bash
        if [[ "$1" == "--version" ]]; then echo "1.9.37"; exit 0; fi
        echo "rendering..." >&2
        case "$4" in html|revealjs) ext=html ;; pdf) ext=pdf ;; docx) ext=docx ;; *) ext=out ;; esac
        echo "rendered body" > "input.$ext"
        echo "complete" >&2
        exit 0
        """
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path.path
        )
        return path
    }

    private func locator(pointingAt path: URL) -> QuartoLocator {
        QuartoLocator(override: path.path, commonPaths: [])
    }

    // MARK: - Simple invoke

    func testInvokeReturnsOutputPath() async throws {
        let fake = try makeFakeQuarto()
        let tool = QuartoRenderTool(locator: locator(pointingAt: fake))
        let result = try await tool.invoke(arguments: ##"{"markdown": "hi", "to": "html"}"##)
        XCTAssertNil(result.error)
        XCTAssertFalse(result.output.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.output))
        try? FileManager.default.removeItem(atPath: result.output)
    }

    func testInvokeReturnsErrorWhenQuartoMissing() async throws {
        let locator = QuartoLocator(
            override: "/does/not/exist",
            commonPaths: [],
            probe: { _, _ in (1, "") }
        )
        let tool = QuartoRenderTool(locator: locator)
        let result = try await tool.invoke(arguments: ##"{"markdown": "hi", "to": "html"}"##)
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("Quarto not found"))
    }

    func testInvokeRejectsUnknownFormat() async throws {
        let fake = try makeFakeQuarto()
        let tool = QuartoRenderTool(locator: locator(pointingAt: fake))
        let result = try await tool.invoke(arguments: ##"{"markdown": "x", "to": "lolcode"}"##)
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("unknown output format"))
    }

    func testInvokeRejectsMalformedJSON() async throws {
        let fake = try makeFakeQuarto()
        let tool = QuartoRenderTool(locator: locator(pointingAt: fake))
        let result = try await tool.invoke(arguments: "not-json")
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
    }

    // MARK: - Streaming invoke

    func testInvokeStreamingEmitsLogsAndResult() async throws {
        let fake = try makeFakeQuarto()
        let tool = QuartoRenderTool(locator: locator(pointingAt: fake))
        let stream = tool.invokeStreaming(arguments: ##"{"markdown": "hi", "to": "html"}"##)
        var logs: [String] = []
        var finalResult: ToolResult?
        for try await event in stream {
            switch event {
            case .log(let l): logs.append(l)
            case .progress: break
            case .result(let r): finalResult = r
            }
        }
        XCTAssertFalse(logs.isEmpty)
        XCTAssertTrue(logs.contains(where: { $0.contains("rendering") }))
        XCTAssertNotNil(finalResult)
        XCTAssertNil(finalResult?.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalResult!.output))
        try? FileManager.default.removeItem(atPath: finalResult!.output)
    }

    // MARK: - Registry integration

    func testStreamingRegistryDispatch() async throws {
        let fake = try makeFakeQuarto()
        let registry = ToolRegistry()
        await registry.register(QuartoRenderTool(locator: locator(pointingAt: fake)))
        let stream = await registry.invokeStreaming(
            name: "builtin.quarto.render",
            arguments: ##"{"markdown": "hi", "to": "html"}"##
        )
        var sawLog = false
        var sawResult = false
        for try await event in stream {
            switch event {
            case .log: sawLog = true
            case .progress: break
            case .result(let r):
                sawResult = true
                if !r.output.isEmpty { try? FileManager.default.removeItem(atPath: r.output) }
            }
        }
        XCTAssertTrue(sawLog)
        XCTAssertTrue(sawResult)
    }

    func testRegistryWrapsNonStreamingToolAsSingleEvent() async throws {
        let registry = ToolRegistry()
        await registry.register(WordCountTool())
        let stream = await registry.invokeStreaming(
            name: "builtin.text.wordcount",
            arguments: #"{"text": "one two three"}"#
        )
        var events: [ToolEvent] = []
        for try await event in stream { events.append(event) }
        XCTAssertEqual(events.count, 1)
        if case .result(let r) = events[0] {
            XCTAssertEqual(r.output, "3")
        } else {
            XCTFail("expected single .result event, got \(events)")
        }
    }
}
