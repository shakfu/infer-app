import Foundation
import CPythonBridge

/// Proof-of-concept in-process embedding of the custom CPython distro
/// that `make fetch-python` builds via `scripts/buildpy.py` and stages
/// at `thirdparty/Python.framework`, which `make bundle` copies into
/// `Contents/Frameworks`. Initializes the interpreter, prints the
/// version to stderr (so it shows up in Console / xcode run log), and
/// finalizes on shutdown. No script-execution surface yet — that comes
/// after we confirm bundling, codesigning, and stdlib resolution
/// actually work.
actor PythonRunner {
    static let shared = PythonRunner()

    private var initialized = false

    func initialize() {
        guard !initialized else { return }

        // PYTHONHOME tells CPython where to find its stdlib. The distro
        // lays out the prefix as Python.framework/Versions/<X.Y>/{lib,
        // include,Python}, so we point at that directory and let CPython
        // derive lib/python<X.Y> from it. Set before Py_Initialize —
        // CPython reads it during startup and ignores later changes.
        if let frameworksPath = Bundle.main.privateFrameworksPath,
           let home = Self.pythonHome(
               in: URL(fileURLWithPath: frameworksPath, isDirectory: true)
           ) {
            setenv("PYTHONHOME", home.path, 1)
        }

        Py_Initialize()
        initialized = true

        // Smoke test: prove the interpreter is alive and the stdlib loaded.
        // Routed through stderr so it survives whatever stdout redirection
        // AppKit may have done.
        PyRun_SimpleString("""
            import sys
            sys.stderr.write('[PythonRunner] CPython ' + sys.version + '\\n')
            sys.stderr.flush()
            """)
    }

    func shutdown() {
        guard initialized else { return }
        Py_FinalizeEx()
        initialized = false
    }

    /// The bundled distro's `Versions/<X.Y>` directory, for `PYTHONHOME`.
    ///
    /// The version is discovered, never pinned. `scripts/buildpy.py`
    /// chooses it (`DEFAULT_PY_VERSION`), and a stale literal here fails
    /// silently in a way that is hard to trace: `setenv` does not
    /// validate the path, so a wrong `PYTHONHOME` surfaces much later as
    /// a stdlib import failure inside `Py_Initialize` rather than as a
    /// missing directory at this call site.
    ///
    /// `Versions/Current` is the symlink CPython's `--enable-framework`
    /// build maintains and `make bundle`'s `cp -R` preserves, so it is
    /// tried first; enumerating `Versions/` newest-first covers a distro
    /// whose `Current` link is absent or stale. A candidate counts only
    /// if it actually holds `lib/`, since that is what `PYTHONHOME` is
    /// for — an empty version directory would set a prefix that resolves
    /// to no stdlib at all.
    ///
    /// Returns nil rather than guessing, leaving `PYTHONHOME` unset so
    /// CPython falls back to its own discovery — the same degradation
    /// this function's caller already applies when the app has no
    /// private Frameworks directory.
    static func pythonHome(in frameworksDir: URL) -> URL? {
        let manager = FileManager.default
        let versions = frameworksDir
            .appendingPathComponent("Python.framework", isDirectory: true)
            .appendingPathComponent("Versions", isDirectory: true)

        func holdsStdlib(_ directory: URL) -> Bool {
            manager.fileExists(atPath: directory.appendingPathComponent("lib", isDirectory: true).path)
        }

        let current = versions.appendingPathComponent("Current", isDirectory: true)
        if holdsStdlib(current) { return current }

        let discovered = ((try? manager.contentsOfDirectory(atPath: versions.path)) ?? [])
            .filter { name in !name.isEmpty && name.allSatisfy { $0.isNumber || $0 == "." } }
            .sorted(by: versionIsDescending)
        return discovered
            .map { versions.appendingPathComponent($0, isDirectory: true) }
            .first(where: holdsStdlib)
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
}
