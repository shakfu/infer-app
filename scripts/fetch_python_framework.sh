#!/usr/bin/env bash
# Builds (via scripts/buildpy.py) and stages a minimized Python.framework at
# thirdparty/Python.framework so the Makefile's `bundle` rule will copy it
# into Infer.app/Contents/Frameworks/.
#
# Idempotent: if thirdparty/Python.framework already exists, this is a no-op.
# Force a rebuild with `rm -rf thirdparty/Python.framework` first, or pass
# FORCE=1.
#
# Python is an optional plugin for Infer. The app builds, runs, and tests
# without it — features that depend on the embedded interpreter just stay
# disabled. Run this script (once) to opt in.
#
# Pass extra packages via PY_PKGS, e.g.:
#   PY_PKGS="httpx requests" ./scripts/fetch_python_framework.sh
#
# Override the Python version with PY_VERSION (default: 3.13.13).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/thirdparty/Python.framework"
BUILD_DIR="$REPO_ROOT/build/python-framework"
BUILDPY="$REPO_ROOT/scripts/buildpy.py"

PY_VERSION="${PY_VERSION:-3.13.13}"
PY_PKGS="${PY_PKGS:-}"
FORCE="${FORCE:-0}"

if [[ -d "$TARGET" && "$FORCE" != "1" ]]; then
    echo "Python.framework already present at $TARGET — skipping."
    echo "Set FORCE=1 (or 'rm -rf $TARGET') to rebuild."
    exit 0
fi

if [[ ! -x "$BUILDPY" ]]; then
    chmod +x "$BUILDPY"
fi

echo "Building Python $PY_VERSION framework with packages: $PY_PKGS"
echo "Build scratch:  $BUILD_DIR"
echo "Output target:  $TARGET"
echo "(this takes a while — buildpy downloads + compiles CPython from source)"

mkdir -p "$BUILD_DIR"
pushd "$BUILD_DIR" >/dev/null

# buildpy writes to <CWD>/build/install when --install-dir is omitted with
# `-t framework-ext`. Pass --install-dir explicitly so we land in a known
# spot regardless of buildpy's internal defaults.
PKG_ARGS=()
if [[ -n "$PY_PKGS" ]]; then
    # Word-split intentionally — PY_PKGS is a space-separated list.
    # shellcheck disable=SC2206
    PKG_ARGS=(-i $PY_PKGS)
fi

"$BUILDPY" \
    -c framework_max \
    -v "$PY_VERSION" \
    ${PKG_ARGS[@]+"${PKG_ARGS[@]}"} \
    --install-dir "$BUILD_DIR/staged"

popd >/dev/null

STAGED="$BUILD_DIR/staged/Python.framework"
if [[ ! -d "$STAGED" ]]; then
    echo "error: buildpy did not produce $STAGED" >&2
    echo "Inspect $BUILD_DIR for the actual layout and adjust this script." >&2
    exit 1
fi

rm -rf "$TARGET"
mkdir -p "$(dirname "$TARGET")"
mv "$STAGED" "$TARGET"
echo "Installed Python.framework at $TARGET"
