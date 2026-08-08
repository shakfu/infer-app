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

    // MARK: - extraArgs screening

    /// `extraArgs` reaches the runner from agent config and ultimately
    /// from LLM-authored tool calls. There is no shell — arguments go
    /// through `Process.arguments` as an array — so these tests are not
    /// about injection. They pin that the flags which would let a render
    /// escape its temp directory or change what code executes are
    /// refused before a process is ever spawned.

    func testRejectsExecutionControlFlags() async throws {
        let quarto = try makeSuccessfulFakeQuarto()
        for arg in ["--execute", "--execute-debug", "--execute-params", "--execute-dir", "-P"] {
            do {
                _ = try await QuartoRunner().render(
                    markdown: "# hello", to: .html, quartoPath: quarto.path, extraArgs: [arg]
                )
                XCTFail("expected \(arg) to be refused")
            } catch let error as QuartoRunner.RenderError {
                guard case .disallowedArgument(let reported) = error else {
                    return XCTFail("expected disallowedArgument for \(arg), got \(error)")
                }
                XCTAssertEqual(reported, arg)
            }
        }
    }

    /// Output redirection is refused for two reasons: it writes outside
    /// the temp working directory, and it breaks the runner's assumption
    /// that the artifact lands next to its input.
    func testRejectsOutputRedirectionFlags() async throws {
        let quarto = try makeSuccessfulFakeQuarto()
        for arg in ["-o", "--output", "--output-dir"] {
            do {
                _ = try await QuartoRunner().render(
                    markdown: "# hello", to: .html, quartoPath: quarto.path, extraArgs: [arg, "/tmp/x"]
                )
                XCTFail("expected \(arg) to be refused")
            } catch let error as QuartoRunner.RenderError {
                guard case .disallowedArgument(let reported) = error else {
                    return XCTFail("expected disallowedArgument for \(arg), got \(error)")
                }
                XCTAssertEqual(reported, arg)
            }
        }
    }

    func testRejectsArbitraryFileReadingFlags() async throws {
        let quarto = try makeSuccessfulFakeQuarto()
        for arg in ["--metadata-file", "--profile"] {
            do {
                _ = try await QuartoRunner().render(
                    markdown: "# hello", to: .html, quartoPath: quarto.path, extraArgs: [arg, "/etc/passwd"]
                )
                XCTFail("expected \(arg) to be refused")
            } catch let error as QuartoRunner.RenderError {
                guard case .disallowedArgument = error else {
                    return XCTFail("expected disallowedArgument for \(arg), got \(error)")
                }
            }
        }
    }

    /// `--flag=value` is the spelling an exact-match check would miss.
    func testRejectsEqualsSpellingOfADeniedFlag() async throws {
        let quarto = try makeSuccessfulFakeQuarto()
        do {
            _ = try await QuartoRunner().render(
                markdown: "# hello",
                to: .html,
                quartoPath: quarto.path,
                extraArgs: ["--execute-params=/etc/passwd"]
            )
            XCTFail("expected the =value spelling to be refused")
        } catch let error as QuartoRunner.RenderError {
            guard case .disallowedArgument(let reported) = error else {
                return XCTFail("expected disallowedArgument, got \(error)")
            }
            XCTAssertEqual(reported, "--execute-params=/etc/passwd")
        }
    }

    /// `--no-execute` only ever reduces what runs, so denying it would
    /// be backwards. Pinned so a future prefix-match refactor of the
    /// deny-list cannot quietly swallow it.
    func testAllowsNoExecuteAndOrdinaryFlags() async throws {
        let quarto = try makeSuccessfulFakeQuarto()
        let result = try await QuartoRunner().render(
            markdown: "# hello",
            to: .html,
            quartoPath: quarto.path,
            extraArgs: ["--no-execute", "--toc"]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.outputURL.path))
    }

    func testEmptyExtraArgsAreAllowed() {
        XCTAssertNil(QuartoRunner.disallowedArgument(in: []))
        XCTAssertNil(QuartoRunner.disallowedArgument(in: ["--toc", "--self-contained"]))
    }

    /// The screen runs before the process is spawned, so a refused
    /// render must not have produced anything.
    func testRefusedRenderSpawnsNothing() async throws {
        let quarto = try makeSuccessfulFakeQuarto()
        let before = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).sorted()
        _ = try? await QuartoRunner().render(
            markdown: "# hello", to: .html, quartoPath: quarto.path, extraArgs: ["--execute"]
        )
        let after = try FileManager.default.contentsOfDirectory(atPath: tempDir.path).sorted()
        XCTAssertEqual(before, after, "a refused render must not spawn quarto or leave artifacts")
    }
}
