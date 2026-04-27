import XCTest
@testable import InferAgents

/// External-system tests that exercise `QuartoLocator` and
/// `QuartoRunner` against the **real** `quarto` binary on the host's
/// PATH (or wherever the locator finds it). Auto-skip on machines
/// without Quarto, so the suite stays green on CI runners that don't
/// install it.
///
/// **Naming convention.** The `External` suffix is load-bearing: the
/// `make test` target uses `--skip ExternalTests` to keep the fast
/// path under three seconds, and `make test-integration` uses
/// `--filter ExternalTests` to run *only* this sort of test. Suites
/// that test cross-module *integration* in pure Swift should not use
/// this suffix — they belong on the fast path. Use `External` only
/// when the test hits a real binary, network endpoint, or model file.
///
/// What these catch that the bash-shim tests can't:
/// - The real CLI's `--version` output shape (currently a bare semver
///   like `1.9.37` on its own line). If a future Quarto release adds a
///   prefix or banner, the locator's `version` field will reflect that
///   change here before any user notices.
/// - The real CLI's stderr cadence during `quarto render`. The runner's
///   line-by-line stderr drain has to cope with whatever Quarto
///   actually emits — typst startup chatter, pandoc diagnostics, etc.
/// - The real output-file naming convention (`input.<ext>` next to
///   the source). If Quarto ever moves to per-format subdirs or
///   timestamped names, this test fails loudly.
///
/// Opt-out: set `INFER_SKIP_QUARTO_EXTERNAL=1` in the env to skip even
/// when Quarto is installed (useful for fast local iteration without
/// reaching for `make test`).
final class QuartoExternalTests: XCTestCase {

    private static let skipEnvKey = "INFER_SKIP_QUARTO_EXTERNAL"

    /// Resolves a real Quarto install or returns nil. The skip-check
    /// uses the production locator so this test also serves as a smoke
    /// for "does the locator's PATH probe actually find Quarto on a
    /// fresh dev machine."
    private func locateRealQuarto() async -> QuartoLocator.Install? {
        if ProcessInfo.processInfo.environment[Self.skipEnvKey] == "1" {
            return nil
        }
        return await QuartoLocator().resolve()
    }

    /// XCTest's `XCTSkip` is the right primitive for "this environment
    /// can't run this test." Wrapping the skip in a helper keeps the
    /// per-test boilerplate to one line.
    private func requireQuarto() async throws -> QuartoLocator.Install {
        guard let install = await locateRealQuarto() else {
            throw XCTSkip(
                "Quarto not on PATH and \(Self.skipEnvKey) not set; " +
                "install via `brew install quarto` to run integration tests."
            )
        }
        return install
    }

    // MARK: - Locator

    func testRealLocatorFindsQuartoAndCapturesVersion() async throws {
        let install = try await requireQuarto()

        // Path is executable. (`isExecutableFile` is what the locator
        // already checks — re-asserting here documents the contract.)
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: install.url.path),
            "locator returned a non-executable path: \(install.url.path)"
        )

        // Version probe succeeded and returned a non-empty string. We
        // don't pin a specific version (the user upgrades Quarto on
        // their own cadence) but assert the shape: leading digit, at
        // least one dot, no whitespace inside the captured token —
        // matches `1.9.37`, `2.0.0-rc.1`, etc., and would catch a
        // future release that prefixed the line with a banner.
        let version = try XCTUnwrap(install.version, "version probe returned nil")
        XCTAssertFalse(version.isEmpty, "version string is empty")
        XCTAssertFalse(version.contains(" "), "version contains whitespace: \(version)")
        XCTAssertTrue(version.contains("."), "version has no dot: \(version)")
        let firstChar = try XCTUnwrap(version.first)
        XCTAssertTrue(firstChar.isNumber, "version doesn't start with a digit: \(version)")

        // Diagnostic — surfaces the resolved install in the test log
        // so a CI failure caused by a Quarto upgrade is obvious without
        // needing to re-run locally.
        print("[QuartoExternal] resolved \(install.url.path) version \(version)")
    }

    func testLocatorOverrideWithRealQuartoRoundTrips() async throws {
        let install = try await requireQuarto()
        let pinned = QuartoLocator(override: install.url.path, commonPaths: [])
        let viaOverride = await pinned.resolve()
        XCTAssertEqual(viaOverride?.url.path, install.url.path)
        XCTAssertEqual(viaOverride?.version, install.version)
    }

    // MARK: - Runner

    /// Smoke test the simple async render path against the real CLI.
    /// Uses the most boring possible input — one line of markdown to
    /// HTML — so the test stays fast (sub-second on a warm Quarto) and
    /// doesn't depend on optional toolchain components like Typst.
    func testRealRunnerRendersHTML() async throws {
        let install = try await requireQuarto()
        let runner = QuartoRunner()
        let result = try await runner.render(
            markdown: "# integration smoke\n\nhello from XCTest.\n",
            to: .html,
            quartoPath: install.url.path
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.outputURL.path),
            "rendered file is missing at \(result.outputURL.path)"
        )
        let body = try String(contentsOf: result.outputURL, encoding: .utf8)
        XCTAssertTrue(
            body.contains("integration smoke"),
            "rendered HTML doesn't contain the heading text"
        )
        XCTAssertTrue(body.localizedCaseInsensitiveContains("<html"))

        // Cleanup — the runner staged the file under
        // ~/Library/Caches/quarto-renders/; we don't want to leave
        // megabytes of test artifacts behind.
        try? FileManager.default.removeItem(at: result.outputURL)
    }

    /// Verify the streaming path actually emits log events from the
    /// real CLI. Quarto prints progress lines to stderr during render
    /// (typst startup, pandoc invocation, etc.); we don't pin specific
    /// messages but assert at least one `.log` event arrives before
    /// `.finished`. If a future Quarto release falls completely silent
    /// on stderr for HTML, the streaming UI would show no progress —
    /// this test catches that regression.
    /// Full data-path validation for the streaming progress UI: real
    /// Quarto → `QuartoRenderTool.invokeStreaming` → registry →
    /// `ToolStreamConsumer` → progress callback. This is the exact
    /// chain the chat VM's `latestToolProgress` flows through, minus
    /// the SwiftUI render. If `onProgress` is called with at least one
    /// non-empty string, the disclosure's "running … / <last line>"
    /// row will populate at runtime.
    ///
    /// Doesn't (and can't) verify the visual rendering itself —
    /// SwiftUI assertions need an app harness. But it covers every
    /// non-UI wire: tool argument parsing, the locator resolving via
    /// production probe, the runner's stderr-line drain, the tool's
    /// log forwarding, the registry's streaming dispatch, and the
    /// consumer's callback invocation order.
    func testStreamingProgressFullDataPath() async throws {
        let install = try await requireQuarto()

        let registry = ToolRegistry()
        await registry.register(QuartoRenderTool(
            locator: QuartoLocator(override: install.url.path, commonPaths: [])
        ))

        let progressBox = ProgressBox()
        let result = await ToolStreamConsumer.consume(
            registry: registry,
            name: "builtin.quarto.render",
            arguments: ##"{"markdown": "# full-chain smoke\n\nbody.\n", "to": "html"}"##,
            onProgress: { line in progressBox.append(line) },
            onEvent: { _ in }
        )

        XCTAssertNil(result.error, "real Quarto render returned an error: \(result.error ?? "")")
        XCTAssertFalse(result.output.isEmpty, "tool returned an empty output path")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.output),
            "tool reported a path that doesn't exist: \(result.output)"
        )

        let lines = progressBox.lines
        XCTAssertFalse(
            lines.isEmpty,
            "real Quarto produced zero progress lines through the full chain — disclosure would stay silent"
        )
        // Diagnostic — the first / last lines tell us what the user
        // actually sees in the disclosure, so a flaky CI failure is
        // easier to debug from the test log alone.
        print("[QuartoExternal] progress lines: \(lines.count); first=\(lines.first ?? ""); last=\(lines.last ?? "")")

        try? FileManager.default.removeItem(atPath: result.output)
    }

    /// Thread-safe sink for `ToolStreamConsumer`'s progress callback.
    /// The callback is `@Sendable`, so we can't capture a plain `var`.
    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        var lines: [String] {
            lock.lock(); defer { lock.unlock() }; return _lines
        }
        func append(_ s: String) {
            lock.lock(); _lines.append(s); lock.unlock()
        }
    }

    /// pptx round-trip: render a slide-shaped `.qmd` source via the
    /// real Quarto CLI and confirm a `.pptx` file lands on disk. This
    /// is the smoke test for the format the user actually asks for
    /// when they say "make me a presentation" — we want to catch the
    /// case where Quarto starts requiring an extra package, changes
    /// the output filename convention, or rejects pptx with the
    /// current installed version.
    ///
    /// Uses the slide-source shape the agent's system prompt
    /// teaches: `#` for section, `##` for slide, bullets for body.
    /// The fact that THIS exact source renders cleanly is what
    /// validates the agent's prompt advice — if a future Quarto
    /// release rejects it, we want a failing test, not a confused
    /// user.
    func testRealRunnerRendersPPTX() async throws {
        let install = try await requireQuarto()
        let runner = QuartoRunner()
        let source = """
        ---
        title: "Integration smoke"
        author: "XCTest"
        ---

        # Section

        ## First slide

        - alpha
        - beta
        - gamma

        ## Second slide

        - one
        - two
        """
        let result = try await runner.render(
            markdown: source,
            to: .pptx,
            quartoPath: install.url.path
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.outputURL.path),
            "rendered pptx is missing at \(result.outputURL.path)"
        )
        XCTAssertEqual(result.outputURL.pathExtension, "pptx")
        // Sanity-check the file isn't a 0-byte placeholder. PPTX files
        // are zip archives — every real one is at least a few KB.
        let attrs = try FileManager.default.attributesOfItem(atPath: result.outputURL.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 1024, "pptx file is suspiciously small (\(size) bytes)")

        try? FileManager.default.removeItem(at: result.outputURL)
    }

    func testRealRunnerStreamingEmitsAtLeastOneLog() async throws {
        let install = try await requireQuarto()
        let runner = QuartoRunner()
        let stream = runner.renderStreaming(
            markdown: "# streaming smoke\n",
            to: .html,
            quartoPath: install.url.path
        )
        var logs: [String] = []
        var finishedURL: URL?
        for try await event in stream {
            switch event {
            case .log(let line): logs.append(line)
            case .finished(let r): finishedURL = r.outputURL
            case .failed(let m, let log):
                XCTFail("real Quarto render failed: \(m)\n---\n\(log)")
            }
        }
        XCTAssertNotNil(finishedURL, "stream ended without a .finished event")
        XCTAssertFalse(
            logs.isEmpty,
            "real Quarto produced zero stderr lines — streaming UI would be silent"
        )
        if let finishedURL { try? FileManager.default.removeItem(at: finishedURL) }
    }
}
