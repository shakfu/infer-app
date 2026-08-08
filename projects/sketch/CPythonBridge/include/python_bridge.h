// Narrow C surface for embedding CPython in-process. Re-including
// <Python/Python.h> from C gives Swift a module to import, so
// `PythonRunner` can reach Py_Initialize / PyRun_SimpleString /
// Py_FinalizeEx without Swift resolving CPython's headers itself.
//
// The runtime artifact is the custom distro `scripts/buildpy.py` builds
// (`make fetch-python`), staged at `thirdparty/Python.framework` and
// copied into `Contents/Frameworks` by `make bundle`. The version is
// whatever buildpy's DEFAULT_PY_VERSION produced — `PythonRunner`
// discovers it at runtime rather than assuming one.
//
// STATUS: not built. No Package.swift declares this target (nothing
// includes `projects/sketch/` at all), so the framework header search
// path this file needs is unconfigured and the spike does not compile
// in-tree. Wiring it up is not a matter of adding a `.binaryTarget`
// like Ggml / LlamaCpp / Whisper / StableDiffusion: those are
// `.xcframework`s, whereas `fetch-python` stages a plain `.framework`,
// which SwiftPM's binaryTarget does not accept. The shipping path for
// embedded Python is `plugin_python_tools`, which sidesteps all of this
// by spawning the distro's `python3` as a subprocess instead of linking
// libpython into the host process.
#ifndef CPYTHON_BRIDGE_H
#define CPYTHON_BRIDGE_H

#include <Python/Python.h>

#endif
