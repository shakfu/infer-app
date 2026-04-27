#!/usr/bin/env bash
set -euo pipefail

DEFAULT_TAG="0.0.14"

if [ $# -gt 1 ]; then
    echo "Usage: $0 [tag]" >&2
    echo "Example: $0 0.0.14 (default: $DEFAULT_TAG)" >&2
    exit 1
fi

TAG="${1:-$DEFAULT_TAG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
THIRDPARTY_DIR="$PROJECT_ROOT/thirdparty"
PATCH_DIR="$SCRIPT_DIR/patches/sqlitevec"

URL="https://github.com/jkrukowski/SQLiteVec.git"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CLONE_PATH="$TMP_DIR/SQLiteVec"

echo "Cloning $URL @ $TAG"
git clone -q --depth 1 --branch "$TAG" "$URL" "$CLONE_PATH"
rm -rf "$CLONE_PATH/.git"

# Patch 1: move sqlite3ext.h out of the public include dir.
# See docs/patches/sqlitevec.md for rationale.
echo "Applying patch 1: move sqlite3ext.h out of public include/"
mv "$CLONE_PATH/Sources/CSQLiteVec/include/sqlite3ext.h" \
   "$CLONE_PATH/Sources/CSQLiteVec/sqlite3ext.h"

# Patches 2 & 3: unified diffs.
for p in \
    "$PATCH_DIR/02-package-macos-floor.patch" \
    "$PATCH_DIR/03-database-error-and-int64.patch"
do
    echo "Applying $(basename "$p")"
    (cd "$CLONE_PATH" && patch -p0 --quiet < "$p")
done

mkdir -p "$THIRDPARTY_DIR"
DEST="$THIRDPARTY_DIR/SQLiteVec"
if [ -e "$DEST" ]; then
    echo "Removing existing $DEST"
    rm -rf "$DEST"
fi

echo "Copying $CLONE_PATH -> $DEST"
cp -R "$CLONE_PATH" "$DEST"

echo "Done. SQLiteVec (tag $TAG, $(ls "$PATCH_DIR" | wc -l | tr -d ' ') patches applied) installed at $DEST"
