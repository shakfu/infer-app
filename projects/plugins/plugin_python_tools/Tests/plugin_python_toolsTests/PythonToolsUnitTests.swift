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
        struct NoopHost: HostServices {
            struct EmptySandbox: SandboxResolver {
                func roots(for _: SandboxRootCategory) -> [URL] { [] }
            }
            let sandbox: any SandboxResolver = EmptySandbox()
        }
        do {
            _ = try await PythonToolsPlugin.register(config: cfg, invoker: noopInvoker, host: NoopHost())
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

/// Coverage for `defaultRepoThirdpartyDir` — the walk-up that locates
/// `<repo-root>/thirdparty` in a dev tree. Previously untested: every
/// `resolvePythonPath` test above injects both candidate directories,
/// so the walk itself never ran under test. That gap hid a marker bug
/// where a missing `Python.framework` made the walk return `nil`,
/// dropping the repo candidate from the `frameworkNotFound` message.
///
/// These build synthetic trees under the temp dir and drive the real
/// `FileManager` marker check, so the logic under test is the shipping
/// one; only the starting points are injected.
final class PythonRepoRootWalkUpTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appending(path: "plugin_python_tools-walkup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
        tmp = nil
    }

    @discardableResult
    private func mkdir(_ path: String) throws -> URL {
        let url = tmp.appending(path: path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touchMakefile(in dir: URL) throws {
        try Data().write(to: dir.appending(path: "Makefile"))
    }

    /// The regression test. The tree has a repo root but no
    /// `thirdparty/` and no `Python.framework` anywhere — exactly the
    /// pre-`make fetch-python` state. The walk must still resolve, so
    /// the path the user is told to create can be named in the error.
    func testWalkUpFindsThirdpartyEvenWhenFrameworkIsAbsent() throws {
        let root = try mkdir("repo")
        let deep = try mkdir("repo/projects/plugins/plugin_python_tools")
        try touchMakefile(in: root)

        let found = PythonToolsPlugin.defaultRepoThirdpartyDir(starts: [deep])
        XCTAssertEqual(
            found?.standardizedFileURL,
            root.appending(path: "thirdparty").standardizedFileURL
        )
        let path = try XCTUnwrap(found).path
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: path),
            "returned unconditionally — existence is resolvePythonPath's call, not the walk's"
        )
    }

    func testWalkUpStopsAtNearestMakefile() throws {
        let outer = try mkdir("outer")
        let inner = try mkdir("outer/inner")
        let deep = try mkdir("outer/inner/a/b")
        try touchMakefile(in: outer)
        try touchMakefile(in: inner)

        XCTAssertEqual(
            PythonToolsPlugin.defaultRepoThirdpartyDir(starts: [deep])?.standardizedFileURL,
            inner.appending(path: "thirdparty").standardizedFileURL,
            "nested checkouts must bind to the closest root, not the outermost"
        )
    }

    func testWalkUpReturnsNilWhenNoMakefileWithinDepth() throws {
        let deep = try mkdir("no-marker/a/b/c")
        // Depth 4 covers exactly c, b, a, no-marker — bounded so the
        // walk cannot escape into a real checkout above the temp dir.
        XCTAssertNil(PythonToolsPlugin.defaultRepoThirdpartyDir(starts: [deep], maxDepth: 4))
    }

    func testWalkUpRespectsMaxDepth() throws {
        let root = try mkdir("depth")
        let deep = try mkdir("depth/a/b/c/d")
        try touchMakefile(in: root)

        XCTAssertNil(
            PythonToolsPlugin.defaultRepoThirdpartyDir(starts: [deep], maxDepth: 4),
            "marker sits 5 levels up; a 4-step walk must not reach it"
        )
        XCTAssertEqual(
            PythonToolsPlugin.defaultRepoThirdpartyDir(starts: [deep], maxDepth: 5)?.standardizedFileURL,
            root.appending(path: "thirdparty").standardizedFileURL
        )
    }

    /// The binary-path start exists precisely because the CWD start
    /// misses under some runners; a dead first start must not poison
    /// the result.
    func testWalkUpFallsBackToSecondStartingPoint() throws {
        let root = try mkdir("second")
        let marked = try mkdir("second/pkg")
        try touchMakefile(in: root)
        let unmarked = try mkdir("unmarked/x/y")

        XCTAssertEqual(
            PythonToolsPlugin.defaultRepoThirdpartyDir(
                starts: [unmarked, marked],
                maxDepth: 3
            )?.standardizedFileURL,
            root.appending(path: "thirdparty").standardizedFileURL
        )
    }

    /// The payoff: with the framework absent, the thrown error names
    /// the directory `make fetch-python` populates. Before the marker
    /// fix `searched` held only the bundle path, which under `swift
    /// test` is the xctest runner's directory inside Xcode.
    func testFrameworkNotFoundErrorNamesRepoThirdpartyPath() throws {
        let root = try mkdir("errmsg")
        let deep = try mkdir("errmsg/projects/plugins/plugin_python_tools")
        try touchMakefile(in: root)

        XCTAssertThrowsError(
            try PythonToolsPlugin.resolvePythonPath(
                override: nil,
                bundleFrameworksDir: URL(fileURLWithPath: "/nonexistent/bundle/Contents/Frameworks"),
                repoThirdpartyDir: PythonToolsPlugin.defaultRepoThirdpartyDir(starts: [deep]),
                fileExists: { _ in false }
            )
        ) { error in
            guard case PythonToolsError.frameworkNotFound(let searched) = error else {
                return XCTFail("wrong error: \(error)")
            }
            // One candidate per root: nothing is on disk, so no
            // versioned directories are discovered and each root
            // contributes only its `Versions/Current` path.
            XCTAssertEqual(searched.count, 2, "repo candidate must survive into the message")
            XCTAssertTrue(
                searched.contains {
                    $0.hasPrefix(root.path)
                        && $0.hasSuffix("thirdparty/Python.framework/Versions/Current/bin/python3")
                },
                "message must name the path make fetch-python populates; got \(searched)"
            )
            XCTAssertTrue("\(error)".contains("make fetch-python"))
        }
    }

    /// Exercises the real default starting points rather than injected
    /// ones. Skips instead of failing on runners whose CWD and binary
    /// both sit outside a checkout, since that is an environment fact,
    /// not a defect.
    func testDefaultStartsLocateRealRepoThirdpartyInDevTree() throws {
        guard let dir = PythonToolsPlugin.defaultRepoThirdpartyDir() else {
            throw XCTSkip("no Makefile ancestor of CWD or binary — not a dev-tree checkout")
        }
        XCTAssertEqual(dir.lastPathComponent, "thirdparty")
        let makefile = dir.deletingLastPathComponent().appending(path: "Makefile")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: makefile.path),
            "walk-up must anchor on a real Makefile: \(makefile.path)"
        )
    }
}

/// Coverage for `interpreterCandidates` — the version discovery that
/// replaced a hardcoded `Versions/3.13`. The pin was invisible to CI:
/// a `scripts/buildpy.py` `DEFAULT_PY_VERSION` bump would stop
/// resolution dead, but `PythonExternalTests` skip rather than fail on
/// a missing interpreter, so both test targets kept exiting 0.
final class PythonInterpreterCandidateTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/opt/example")

    private func candidates(_ versions: [String]) -> [String] {
        PythonToolsPlugin.interpreterCandidates(in: root, versionsIn: { _ in versions })
            .map(\.path)
    }

    func testCurrentSymlinkIsPreferredOverVersionedDirectories() {
        XCTAssertEqual(
            candidates(["3.13"]).first,
            "/opt/example/Python.framework/Versions/Current/bin/python3",
            "Current tracks whatever the framework build installed; it should win"
        )
    }

    func testVersionsAreEnumeratedNewestFirst() {
        XCTAssertEqual(
            candidates(["3.9", "3.14", "3.13"]),
            [
                "/opt/example/Python.framework/Versions/Current/bin/python3",
                "/opt/example/Python.framework/Versions/3.14/bin/python3",
                "/opt/example/Python.framework/Versions/3.13/bin/python3",
                "/opt/example/Python.framework/Versions/3.9/bin/python3",
            ]
        )
    }

    func testNonVersionDirectoryEntriesAreIgnored() {
        XCTAssertEqual(
            candidates(["Current", "_CodeSignature", ".DS_Store", "junk", "", "3.13"]),
            [
                "/opt/example/Python.framework/Versions/Current/bin/python3",
                "/opt/example/Python.framework/Versions/3.13/bin/python3",
            ],
            "Current must not be duplicated, and non-numeric entries must not become candidates"
        )
    }

    /// The interaction with the `frameworkNotFound` message: an absent
    /// framework enumerates to nothing, but must still yield a path so
    /// the error names something the user can act on.
    func testAbsentFrameworkStillYieldsCurrentCandidate() {
        XCTAssertEqual(
            candidates([]),
            ["/opt/example/Python.framework/Versions/Current/bin/python3"]
        )
    }

    func testVersionOrderingIsNumericNotLexicographic() {
        XCTAssertTrue(PythonToolsPlugin.versionIsDescending("3.14", "3.9"), "3.14 is newer than 3.9")
        XCTAssertFalse(PythonToolsPlugin.versionIsDescending("3.9", "3.14"))
        XCTAssertTrue(PythonToolsPlugin.versionIsDescending("3.13.1", "3.13"))
        XCTAssertFalse(PythonToolsPlugin.versionIsDescending("3.13", "3.13"), "equal is not descending")
        XCTAssertTrue(PythonToolsPlugin.versionIsDescending("4.0", "3.99"))
    }

    /// End-to-end against a real directory tree with a version that is
    /// deliberately *not* the one the code used to hardcode, and no
    /// `Current` symlink — the case a buildpy version bump produces.
    func testResolvePicksNewestVersionWhenCurrentIsMissing() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "plugin_python_tools-versions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        for version in ["3.13", "3.14"] {
            let bin = tmp.appending(path: "Python.framework/Versions/\(version)/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try Data().write(to: bin.appending(path: "python3"))
        }

        let resolved = try PythonToolsPlugin.resolvePythonPath(
            override: nil,
            bundleFrameworksDir: nil,
            repoThirdpartyDir: tmp,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
        XCTAssertEqual(
            resolved.standardizedFileURL,
            tmp.appending(path: "Python.framework/Versions/3.14/bin/python3").standardizedFileURL,
            "must resolve the newest installed version without any code change"
        )
    }
}
