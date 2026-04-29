import Foundation
import PythonKit

/// Bootstraps the embedded Python.framework that the Makefile copies into
/// `Contents/Frameworks/Python.framework`. PythonKit dlopens libpython at
/// first use, so we have to point it at the bundled library *before* any
/// `Python.import(...)` call — otherwise it falls back to a system-discovery
/// path that won't resolve under a sandboxed/distributed app.
///
/// `PYTHONHOME` tells the embedded interpreter where stdlib + site-packages
/// live; without it, third-party imports raise `ModuleNotFoundError` because
/// site-packages is unreachable.
enum PythonBridge {
    enum InitError: Error {
        case frameworkMissing(URL)
        case libraryMissing(URL)
    }

    private static let initLock = NSLock()
    nonisolated(unsafe) private static var didInit = false

    /// Idempotent. Safe to call from `applicationDidFinishLaunching`.
    static func initializeIfNeeded() throws {
        initLock.lock()
        defer { initLock.unlock() }
        if didInit { return }

        let frameworksURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let pyFramework = frameworksURL.appendingPathComponent("Python.framework", isDirectory: true)
        let versionDir = pyFramework.appendingPathComponent("Versions/3.13", isDirectory: true)
        let dylib = versionDir.appendingPathComponent("Python")

        guard FileManager.default.fileExists(atPath: pyFramework.path) else {
            throw InitError.frameworkMissing(pyFramework)
        }
        guard FileManager.default.fileExists(atPath: dylib.path) else {
            throw InitError.libraryMissing(dylib)
        }

        let libDir = versionDir.appendingPathComponent("lib/python3.13", isDirectory: true)
        let sitePackages = libDir.appendingPathComponent("site-packages", isDirectory: true)
        let zipPath = versionDir.appendingPathComponent("lib/python313.zip")

        // PYTHONHOME drives the prefix/exec_prefix computation; PYTHONPATH
        // covers explicit additions for the zipped stdlib + site-packages.
        // Set both before PythonLibrary loads so the interpreter sees them
        // during its bootstrap (Py_Initialize reads env vars exactly once).
        setenv("PYTHONHOME", versionDir.path, 1)
        setenv("PYTHONPATH",
               "\(libDir.path):\(sitePackages.path):\(zipPath.path)",
               1)
        // Skip the user site-packages (~/Library/Python) so we never pull
        // in a host-installed module that shadows the bundled one.
        setenv("PYTHONNOUSERSITE", "1", 1)

        PythonLibrary.useLibrary(at: dylib.path)
        didInit = true
    }

    /// Imports `sys`, `anthropic`, `openai` and returns a one-line summary.
    /// Throws PythonError if any import fails — useful as a startup smoke test.
    static func smokeTest() throws -> String {
        try initializeIfNeeded()
        let sys = Python.import("sys")
        let anthropic = Python.import("anthropic")
        let openai = Python.import("openai")
        let pyVersion = String(sys.version.description.split(separator: "\n").first ?? "")
        let aVer = String(describing: anthropic.__version__)
        let oVer = String(describing: openai.__version__)
        return "python=\(pyVersion) anthropic=\(aVer) openai=\(oVer)"
    }
}
