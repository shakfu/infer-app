import XCTest
@testable import PluginAPI
@testable import plugin_python_tools

/// Fast-path tests: pure logic that doesn't spawn a process. These
/// always run; the subprocess-driving tests live in
/// `PythonExternalTests` and auto-skip when Python.framework is
/// absent.
final class PythonToolsUnitTests: XCTestCase {
    func testTimeoutClampsToMaxAndMin() {
        XCTAssertEqual(PythonTimeoutBounds.clamp(nil), 10, "default applies on nil")
        XCTAssertEqual(PythonTimeoutBounds.clamp(0), 1, "below min clamps to min")
        XCTAssertEqual(PythonTimeoutBounds.clamp(-5), 1)
        XCTAssertEqual(PythonTimeoutBounds.clamp(99_999), 120, "above max clamps to max")
        XCTAssertEqual(PythonTimeoutBounds.clamp(30), 30, "in-range passes through")
    }

    func testResolveOverrideReturnsConfiguredPathWhenItExists() throws {
        let url = URL(fileURLWithPath: "/usr/bin/true") // exists & executable on macOS
        let resolved = try PythonToolsPlugin.resolvePythonPath(
            override: url.path,
            bundleFrameworksDir: nil,
            repoThirdpartyDir: nil
        )
        XCTAssertEqual(resolved, url)
    }

    func testResolveOverrideThrowsWhenConfiguredPathMissing() {
        XCTAssertThrowsError(
            try PythonToolsPlugin.resolvePythonPath(
                override: "/nonexistent/python3",
                bundleFrameworksDir: nil,
                repoThirdpartyDir: nil
            )
        ) { error in
            guard case PythonToolsError.configuredPythonMissing(let path) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(path, "/nonexistent/python3")
        }
    }

    func testResolveFallsThroughToFirstExistingCandidate() throws {
        // Use the temp dir to stand in for both candidate roots; only
        // the second has a (fake) python3 file, so resolution should
        // pick the second.
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "plugin_python_tools-test-\(UUID().uuidString)")
        let bogusBundle = tmp.appending(path: "bundle/Contents/Frameworks")
        let realRepo = tmp.appending(path: "repo/thirdparty")
        let realPython = realRepo.appending(path: "Python.framework/Versions/3.13/bin/python3")
        try FileManager.default.createDirectory(at: bogusBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: realPython.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // We claim the file exists via the injected predicate; we
        // don't have to make it actually executable for the
        // resolution unit-test.
        defer { try? FileManager.default.removeItem(at: tmp) }

        let resolved = try PythonToolsPlugin.resolvePythonPath(
            override: nil,
            bundleFrameworksDir: bogusBundle,
            repoThirdpartyDir: realRepo,
            fileExists: { $0 == realPython }
        )
        XCTAssertEqual(resolved, realPython)
    }

    func testResolveThrowsWhenNoCandidateExists() {
        XCTAssertThrowsError(
            try PythonToolsPlugin.resolvePythonPath(
                override: nil,
                bundleFrameworksDir: URL(fileURLWithPath: "/nonexistent/bundle"),
                repoThirdpartyDir: URL(fileURLWithPath: "/nonexistent/repo"),
                fileExists: { _ in false }
            )
        ) { error in
            guard case PythonToolsError.frameworkNotFound(let searched) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(searched.count, 2)
        }
    }

    func testJsonEscapeHandlesAllCases() {
        XCTAssertEqual(jsonEscape("hi"), "\"hi\"")
        XCTAssertEqual(jsonEscape("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(jsonEscape("a\\b"), "\"a\\\\b\"")
        XCTAssertEqual(jsonEscape("a\nb"), "\"a\\nb\"")
        XCTAssertEqual(jsonEscape("a\tb"), "\"a\\tb\"")
        XCTAssertEqual(jsonEscape("\u{01}"), "\"\\u0001\"")
    }

    func testRegisterFailsCleanlyWhenNoFramework() async {
        // Ship an obviously-missing override so register hits the
        // "configured path missing" branch deterministically without
        // depending on the host environment.
        let cfg = PluginConfig(json: Data(#"{"python_path":"/nonexistent/python3"}"#.utf8))
        let noopInvoker: ToolInvoker = { _, _ in
            ToolResult(output: "", error: "no invoker wired in this test")
        }
        do {
            _ = try await PythonToolsPlugin.register(config: cfg, invoker: noopInvoker)
            XCTFail("expected register to throw")
        } catch let error as PythonToolsError {
            guard case .configuredPythonMissing = error else {
                return XCTFail("wrong PythonToolsError: \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }
}
