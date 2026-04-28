import XCTest
@testable import PluginAPI
@testable import plugin_python_tools

/// Tests that actually spawn the embedded Python interpreter. Match
/// the project-wide convention: any suite that touches an external
/// binary / model / network endpoint is named `*ExternalTests` so
/// `make test` (which uses `--skip ExternalTests`) doesn't require
/// the dependency to be installed. Run via `make test-integration`.
///
/// Inside this suite, each test calls `try resolveOrSkip()` so a
/// machine without `thirdparty/Python.framework` skips the test
/// individually rather than failing the suite — same shape as
/// `QuartoExternalTests`.
final class PythonExternalTests: XCTestCase {
    private func resolveOrSkip() throws -> URL {
        do {
            return try PythonToolsPlugin.resolvePythonPath(override: nil)
        } catch {
            throw XCTSkip("Python.framework not present (run `make fetch-python` to install): \(error)")
        }
    }

    func testRunHelloWorldRoundTrip() async throws {
        let pythonPath = try resolveOrSkip()
        let runner = PythonRunner(pythonPath: pythonPath)
        let result = try await runner.run(code: "print('hi')", timeoutSeconds: 10)
        XCTAssertEqual(result.stdout, "hi\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
    }

    func testStderrIsCapturedSeparately() async throws {
        let pythonPath = try resolveOrSkip()
        let runner = PythonRunner(pythonPath: pythonPath)
        let code = "import sys; sys.stderr.write('warn\\n'); print('out')"
        let result = try await runner.run(code: code, timeoutSeconds: 10)
        XCTAssertEqual(result.stdout, "out\n")
        XCTAssertEqual(result.stderr, "warn\n")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testNonZeroExitCodeIsReported() async throws {
        let pythonPath = try resolveOrSkip()
        let runner = PythonRunner(pythonPath: pythonPath)
        let result = try await runner.run(code: "import sys; sys.exit(42)", timeoutSeconds: 10)
        XCTAssertEqual(result.exitCode, 42)
        XCTAssertFalse(result.timedOut)
    }

    func testTimeoutKillsRunawayProcess() async throws {
        let pythonPath = try resolveOrSkip()
        let runner = PythonRunner(pythonPath: pythonPath)
        let started = Date()
        let result = try await runner.run(
            code: "import time; time.sleep(10)",
            timeoutSeconds: 1
        )
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(result.timedOut, "expected timed_out=true")
        XCTAssertLessThan(elapsed, 5, "wall clock should be near the timeout, not the sleep")
    }

    func testEvalToolReturnsRepr() async throws {
        let pythonPath = try resolveOrSkip()
        let runner = PythonRunner(pythonPath: pythonPath)
        let tool = PythonEvalTool(runner: runner)
        let result = try await tool.invoke(arguments: #"{"expression":"2 + 3"}"#)
        XCTAssertNil(result.error)
        XCTAssertTrue(
            result.output.contains(#""value":"5""#),
            "got: \(result.output)"
        )
    }

    func testEvalToolSurfacesPythonExceptionsAsErrorField() async throws {
        let pythonPath = try resolveOrSkip()
        let runner = PythonRunner(pythonPath: pythonPath)
        let tool = PythonEvalTool(runner: runner)
        // Division by zero — `eval` should raise ZeroDivisionError.
        let result = try await tool.invoke(arguments: #"{"expression":"1/0"}"#)
        XCTAssertNil(result.error, "tool itself succeeded; Python's exception is in the JSON output")
        XCTAssertTrue(
            result.output.contains("ZeroDivisionError"),
            "got: \(result.output)"
        )
    }

    func testRunToolEmitsExpectedJSONShape() async throws {
        let pythonPath = try resolveOrSkip()
        let runner = PythonRunner(pythonPath: pythonPath)
        let tool = PythonRunTool(runner: runner)
        let result = try await tool.invoke(arguments: #"{"code":"print('x')"}"#)
        XCTAssertNil(result.error)
        // Decode to confirm it's valid JSON with the right keys, not
        // just a string-contains check.
        struct Out: Decodable {
            let stdout: String
            let stderr: String
            let exit_code: Int
            let timed_out: Bool
        }
        let decoded = try JSONDecoder().decode(Out.self, from: Data(result.output.utf8))
        XCTAssertEqual(decoded.stdout, "x\n")
        XCTAssertEqual(decoded.exit_code, 0)
        XCTAssertFalse(decoded.timed_out)
    }
}
