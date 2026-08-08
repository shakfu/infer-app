import Foundation
import PluginAPI

/// `python.run` and `python.eval` over an embedded Python.framework
/// built by `scripts/buildpy.py`. Both tools spawn the framework's
/// `python3` binary as a subprocess (no in-process libpython linkage)
/// so a Python crash terminates the child, not Infer.
///
/// Discovery order, applied at `register` time:
///   1. `config.python_path` if set in `plugins.json`
///   2. `<app-bundle>/Contents/Frameworks/Python.framework/...`
///   3. `<repo-root>/thirdparty/Python.framework/...`
/// where `...` is `Versions/Current/bin/python3`, falling back to the
/// newest `Versions/<X.Y>/bin/python3` present. The version is
/// discovered rather than pinned — see `interpreterCandidates`.
/// (no fallback to system `python3` — that would defeat the point of
/// shipping a curated Python with the app's required packages baked in.)
///
/// A missing framework throws `PythonToolsError.frameworkNotFound`,
/// which `PluginLoader` catches and surfaces as a failure record. The
/// rest of the host launches normally and `python.*` tools are absent
/// from the registry.
public enum PythonToolsPlugin: Plugin {
    public static let id = "python_tools"

    public static func register(
        config: PluginConfig,
        invoker _: ToolInvoker,
        host _: any HostServices
    ) async throws -> PluginContributions {
        let cfg: Config = (try? config.decode(Config.self)) ?? Config()
        let pythonPath = try resolvePythonPath(override: cfg.pythonPath)
        let runner = PythonRunner(pythonPath: pythonPath)
        return PluginContributions(tools: [
            PythonRunTool(runner: runner),
            PythonEvalTool(runner: runner),
        ])
    }

    /// Decoded `config` blob. All keys optional.
    struct Config: Decodable {
        var pythonPath: String?
        enum CodingKeys: String, CodingKey {
            case pythonPath = "python_path"
        }
        init() {}
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.pythonPath = try c.decodeIfPresent(String.self, forKey: .pythonPath)
        }
    }

    /// Visible-for-testing: resolution algorithm, factored out of
    /// `register` so unit tests can drive it without spawning a
    /// process. Returns the first existing path in the precedence
    /// order; throws if none exist.
    static func resolvePythonPath(
        override: String?,
        bundleFrameworksDir: URL? = Self.defaultBundleFrameworksDir(),
        repoThirdpartyDir: URL? = Self.defaultRepoThirdpartyDir(),
        fileExists: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) throws -> URL {
        if let override, !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard fileExists(url) else {
                throw PythonToolsError.configuredPythonMissing(url.path)
            }
            return url
        }
        let candidates: [URL] = [bundleFrameworksDir, repoThirdpartyDir]
            .compactMap { $0 }
            .flatMap { Self.interpreterCandidates(in: $0) }
        for url in candidates where fileExists(url) {
            return url
        }
        throw PythonToolsError.frameworkNotFound(searched: candidates.map(\.path))
    }

    /// Interpreter candidates under one root, most-preferred first.
    ///
    /// The framework version is *discovered*, never hardcoded. Pinning
    /// `3.13` here meant a `scripts/buildpy.py` version bump
    /// (`DEFAULT_PY_VERSION`) silently stopped resolving — and because
    /// the external tests `XCTSkip` rather than fail on a missing
    /// interpreter, both `make test` and `make test-integration` would
    /// still have exited 0.
    ///
    /// `Versions/Current` is a symlink maintained by CPython's
    /// `--enable-framework` build and preserved by `make bundle`'s
    /// `cp -R`, so it resolves whatever version is installed; it is
    /// tried first and is the only candidate needed in practice.
    /// Enumerating `Versions/` is the fallback for a framework whose
    /// `Current` link is absent or stale, newest version first.
    ///
    /// `Current` is emitted even when nothing exists on disk, so a
    /// missing framework still yields an actionable `searched` path
    /// rather than an empty list.
    static func interpreterCandidates(
        in root: URL,
        versionsIn: (URL) -> [String] = { url in
            (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        }
    ) -> [URL] {
        let discovered = versionsIn(root.appending(path: "Python.framework/Versions"))
            .filter { name in
                name != "Current"
                    && !name.isEmpty
                    && name.allSatisfy { $0.isNumber || $0 == "." }
            }
            .sorted(by: versionIsDescending)
        return (["Current"] + discovered).map { version in
            root.appending(path: "Python.framework/Versions/\(version)/bin/python3")
        }
    }

    /// Component-wise numeric ordering, newest first, so `3.14` sorts
    /// ahead of `3.9` (a lexicographic sort gets this backwards).
    static func versionIsDescending(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    static func defaultBundleFrameworksDir() -> URL? {
        // `Bundle.main` in the app process points at `Infer.app`. In
        // unit tests it points at the test runner's host bundle, which
        // doesn't ship Python — that's fine; resolution falls through
        // to the repo-thirdparty candidate.
        Bundle.main.bundleURL.appending(path: "Contents/Frameworks")
    }

    /// Walk-up starting points, in precedence order. Split out from
    /// `defaultRepoThirdpartyDir` so tests can drive the walk against a
    /// synthetic tree.
    ///
    ///   - CWD under `swift test` is the package directory (inside the
    ///     repo), so the walk-up reaches the root.
    ///   - `CommandLine.arguments[0]` points at the running binary,
    ///     which under `swift test` lives in DerivedData and is *not*
    ///     under the repo — it only helps for a binary run in-tree.
    static func defaultWalkUpStarts() -> [URL] {
        [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            URL(fileURLWithPath: CommandLine.arguments.first ?? "/")
                .deletingLastPathComponent(),
        ]
    }

    /// Development-only fallback: locate `<repo-root>/thirdparty`. In
    /// the bundled app the bundle-frameworks candidate hits first.
    ///
    /// The repo root is identified by its `Makefile` — the sole build
    /// entry point, and the only Makefile in the tree. Two markers were
    /// rejected:
    ///   - `thirdparty/Python.framework` (the original) made the marker
    ///     the very artifact being searched for, so a missing framework
    ///     returned `nil` here, dropped this candidate from `searched`,
    ///     and left `frameworkNotFound` reporting only the bundle path
    ///     — which under `swift test` is the xctest runner's directory
    ///     inside Xcode, never naming the directory `make fetch-python`
    ///     actually populates.
    ///   - bare `thirdparty/` is no better: nothing under it is tracked
    ///     (`.gitignore` has `thirdparty/*`), so it is absent on a fresh
    ///     clone until the first fetch.
    ///
    /// Returns the path whether or not it exists; existence of the
    /// interpreter is `resolvePythonPath`'s call, and returning it
    /// unconditionally is what keeps the error message actionable.
    static func defaultRepoThirdpartyDir(
        starts: [URL] = Self.defaultWalkUpStarts(),
        maxDepth: Int = 10
    ) -> URL? {
        for start in starts {
            var dir = start.standardizedFileURL
            for _ in 0..<maxDepth {
                let marker = dir.appending(path: "Makefile")
                if FileManager.default.fileExists(atPath: marker.path) {
                    return dir.appending(path: "thirdparty")
                }
                let parent = dir.deletingLastPathComponent()
                if parent == dir { break }
                dir = parent
            }
        }
        return nil
    }
}

public enum PythonToolsError: Error, Equatable, Sendable {
    /// `config.python_path` was set but the file doesn't exist or
    /// isn't executable. Most likely a typo or stale config.
    case configuredPythonMissing(String)
    /// Neither the bundled framework nor the dev-tree framework was
    /// found. Fix: `make fetch-python` (one-time, ~5 min) then rebuild.
    case frameworkNotFound(searched: [String])
}

extension PythonToolsError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .configuredPythonMissing(let path):
            return "plugin_python_tools: configured python_path does not exist or is not executable: \(path)"
        case .frameworkNotFound(let searched):
            return "plugin_python_tools: Python.framework not found. Run `make fetch-python` (builds thirdparty/Python.framework, ~5 min). Searched: \(searched.joined(separator: ", "))"
        }
    }
}
