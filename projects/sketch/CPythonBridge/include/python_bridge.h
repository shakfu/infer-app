// Narrow C surface for embedding CPython. Exists for the same reason as
// CWhisperBridge: the vendored Python.xcframework ships its modulemap at
// Versions/3.14/include/python3.14/module.modulemap rather than at the
// framework-standard Modules/ path, so a Swift `import Python` does not
// resolve. Re-including <Python/Python.h> here lets the C compiler reach
// the headers via the framework search path (which the binary target
// configures), and Swift then talks to CPython through this module.
#ifndef CPYTHON_BRIDGE_H
#define CPYTHON_BRIDGE_H

#include <Python/Python.h>

#endif
