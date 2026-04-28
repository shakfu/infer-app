import Foundation
import PluginAPI

/// `python.run` and `python.eval` over an embedded Python.framework
/// built by `scripts/buildpy.py`. Both tools spawn the framework's
/// `python3` binary as a subprocess (no in-process libpython linkage)
/// so a Python crash terminates the child, not Infer.
///
/// Discovery order, applied at `register` time:
///   1. `config.python_path` if set in `plugins.json`
///   2. `<app-bundle>/Contents/Frameworks/Python.framework/Versions/3.13/bin/python3`
///   3. `<repo-root>/thirdparty/Python.framework/Versions/3.13/bin/python3`
/// (no fallback to system `python3` — that would defeat the point of
/// shipping a curated Python with the app's required packages baked in.)
///
/// A missing framework throws `PythonToolsError.frameworkNotFound`,
/// which `PluginLoader` catches and surfaces as a failure record. The
/// rest of the host launches normally and `python.*` tools are absent
/// from the registry.
public enum PythonToolsPlugin: Plugin {
    public static let id = "python_tools"

    public static func register(config: PluginConfig) async throws -> PluginContributions {
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
        let candidates: [URL] = [
            bundleFrameworksDir?.appending(path: "Python.framework/Versions/3.13/bin/python3"),
            repoThirdpartyDir?.appending(path: "Python.framework/Versions/3.13/bin/python3"),
        ].compactMap { $0 }
        for url in candidates where fileExists(url) {
            return url
        }
        throw PythonToolsError.frameworkNotFound(searched: candidates.map(\.path))
    }

    static func defaultBundleFrameworksDir() -> URL? {
        // `Bundle.main` in the app process points at `Infer.app`. In
        // unit tests it points at the test runner's host bundle, which
        // doesn't ship Python — that's fine; resolution falls through
        // to the repo-thirdparty candidate.
        Bundle.main.bundleURL.appending(path: "Contents/Frameworks")
    }

    static func defaultRepoThirdpartyDir() -> URL? {
        // Development-only fallback. In the bundled app the
        // bundle-frameworks candidate hits first. We try two starting
        // points and walk up from each, because:
        //   - `CommandLine.arguments[0]` points at the running binary,
        //     which under `swift test` lives in DerivedData and is not
        //     under the repo.
        //   - CWD under `swift test` is the package directory (inside
        //     the repo), so the walk-up reaches the root.
        let starts: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            URL(fileURLWithPath: CommandLine.arguments.first ?? "/")
                .deletingLastPathComponent(),
        ]
        for start in starts {
            var dir = start
            for _ in 0..<10 {
                let marker = dir.appending(path: "thirdparty/Python.framework")
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
