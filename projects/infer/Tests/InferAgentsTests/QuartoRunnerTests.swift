import XCTest
@testable import InferAgents

final class QuartoRunnerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quarto-runner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Bash script masquerading as `quarto`. Reproduces the real CLI's
    /// "render input.qmd --to <fmt>" contract well enough to drive the
    /// runner without a real Quarto install: writes the expected output
    /// file in the cwd, prints two stderr lines so the streaming path
    /// has something to chunk, exits 0.
    private func makeSuccessfulFakeQuarto() throws -> URL {
        let path = tempDir.appendingPathComponent("quarto")
        let script = """
        #!/bin/bash
        # args: render input.qmd --to <fmt>
        echo "fake-quarto: starting render" >&2
        sleep 0.05
        echo "fake-quarto: writing output" >&2
        case "$4" in
            html|revealjs) ext=html ;;
            pdf) ext=pdf ;;
            docx) ext=docx ;;
            typst) ext=typ ;;
            latex) ext=tex ;;
            *) ext=out ;;
        esac
        cp "$2" "input.$ext" 2>/dev/null || echo "rendered" > "input.$ext"
        echo "fake-quarto: done" >&2
        exit 0
        """
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path.path
        )
        return path
    }

    private func makeFailingFakeQuarto() throws -> URL {
        let path = tempDir.appendingPathComponent("quarto")
        let script = """
        #!/bin/bash
        echo "fake-quarto: bad input" >&2
        echo "fake-quarto: aborting" >&2
        exit 1
        """
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path.path
        )
        return path
    }

    // MARK: - Simple async path

    func testSimpleRenderProducesOutputFile() async throws {
        let fake = try makeSuccessfulFakeQuarto()
        let runner = QuartoRunner()
        let result = try await runner.render(
            markdown: "# hello",
            to: .html,
            quartoPath: fake.path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
        XCTAssertTrue(result.log.contains("starting render"))
        XCTAssertTrue(result.log.contains("done"))
        // Cleanup: cached output lives under user's caches dir.
        try? FileManager.default.removeItem(at: result.outputURL)
    }

    func testSimpleRenderThrowsOnNonZeroExit() async throws {
        let fake = try makeFailingFakeQuarto()
        let runner = QuartoRunner()
        do {
            _ = try await runner.render(
                markdown: "# hello",
                to: .html,
                quartoPath: fake.path
            )
            XCTFail("expected failure")
        } catch let error as QuartoRunner.RenderError {
            if case .nonZeroExit(_, let log) = error {
                XCTAssertTrue(log.contains("bad input"))
            } else {
                XCTFail("expected nonZeroExit, got \(error)")
            }
        }
    }

    func testRenderRejectsMissingExecutable() async throws {
        let runner = QuartoRunner()
        do {
            _ = try await runner.render(
                markdown: "# hello",
                to: .html,
                quartoPath: "/no/such/quarto"
            )
            XCTFail("expected failure")
        } catch let error as QuartoRunner.RenderError {
            if case .quartoNotExecutable = error { return }
            XCTFail("expected quartoNotExecutable, got \(error)")
        }
    }

    // MARK: - Streaming path

    func testStreamingEmitsLogsThenFinished() async throws {
        let fake = try makeSuccessfulFakeQuarto()
        let runner = QuartoRunner()
        let stream = runner.renderStreaming(
            markdown: "# hi",
            to: .html,
            quartoPath: fake.path
        )
        var logs: [String] = []
        var finishedURL: URL?
        for try await event in stream {
            switch event {
            case .log(let line): logs.append(line)
            case .finished(let r): finishedURL = r.outputURL
            case .failed(let m, _): XCTFail("unexpected failure: \(m)")
            }
        }
        XCTAssertGreaterThanOrEqual(logs.count, 3)
        XCTAssertTrue(logs.contains(where: { $0.contains("starting render") }))
        XCTAssertNotNil(finishedURL)
        if let finishedURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: finishedURL.path))
            try? FileManager.default.removeItem(at: finishedURL)
        }
    }

    func testStreamingEmitsFailedOnNonZeroExit() async throws {
        let fake = try makeFailingFakeQuarto()
        let runner = QuartoRunner()
        let stream = runner.renderStreaming(
            markdown: "# hi",
            to: .html,
            quartoPath: fake.path
        )
        var sawFailure = false
        for try await event in stream {
            if case .failed(_, let log) = event {
                sawFailure = true
                XCTAssertTrue(log.contains("bad input"))
            }
        }
        XCTAssertTrue(sawFailure)
    }
}
