import Foundation
import CPythonBridge

/// Proof-of-concept embedding of CPython 3.14 via the bundled
/// Python.xcframework. Initializes the interpreter, prints the version
/// to stderr (so it shows up in Console / xcode run log), and finalizes
/// on shutdown. No script-execution surface yet — that comes after we
/// confirm bundling, codesigning, and stdlib resolution actually work.
actor PythonRunner {
    static let shared = PythonRunner()

    private var initialized = false

    func initialize() {
        guard !initialized else { return }

        // PYTHONHOME tells CPython where to find its stdlib (lib/python3.14).
        // The xcframework lays out the prefix as
        // Python.framework/Versions/3.14/{lib,include,Python}, so we point
        // at that directory. Set before Py_Initialize — CPython reads it
        // during startup and ignores later changes.
        if let frameworksPath = Bundle.main.privateFrameworksPath {
            let home = "\(frameworksPath)/Python.framework/Versions/3.14"
            setenv("PYTHONHOME", home, 1)
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
}
