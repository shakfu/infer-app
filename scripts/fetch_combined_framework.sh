#!/usr/bin/env bash
# Downloads and installs the combined ggml-stack xcframework set
# (Ggml + LlamaCpp + Whisper + StableDiffusion) into thirdparty/.
#
# Replaces the prior per-library fetch (fetch_llama_framework.sh,
# fetch_whisper_framework.sh) — those upstream releases each shipped
# their own libggml.dylib and collided when both were loaded into one
# process. This release bundles a single shared Ggml.framework that the
# other three frameworks dynamically link to via `use Ggml` in their
# module maps.
#
# Idempotent: any of the four xcframeworks already present will be
# replaced from the freshly downloaded copy.
#
# Override the version with arg-1 or VERSION env var:
#   ./scripts/fetch_combined_framework.sh           # uses default
#   ./scripts/fetch_combined_framework.sh 0.2.15
#   VERSION=0.2.15 ./scripts/fetch_combined_framework.sh
set -euo pipefail

DEFAULT_VERSION="0.2.14"

if [ $# -gt 1 ]; then
    echo "Usage: $0 [version]" >&2
    echo "Example: $0 $DEFAULT_VERSION (default)" >&2
    exit 1
fi

VERSION="${1:-${VERSION:-$DEFAULT_VERSION}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
THIRDPARTY_DIR="$PROJECT_ROOT/thirdparty"

ARCHIVE_NAME="ggml-cpp-stack-xcframework-arm64-${VERSION}.zip"
URL="https://github.com/shakfu/cyllama/releases/download/${VERSION}/${ARCHIVE_NAME}"

# Frameworks expected inside the archive. Update this list if the
# upstream release adds more (e.g. a future Bark/MeloTTS framework).
FRAMEWORKS=(
    "Ggml.xcframework"
    "LlamaCpp.xcframework"
    "Whisper.xcframework"
    "StableDiffusion.xcframework"
)

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ZIP_PATH="$TMP_DIR/$ARCHIVE_NAME"

echo "Downloading $URL"
curl -fL --progress-bar -o "$ZIP_PATH" "$URL"

echo "Extracting $ZIP_PATH"
unzip -q "$ZIP_PATH" -d "$TMP_DIR"

mkdir -p "$THIRDPARTY_DIR"

# Each framework gets located by name (the archive's top-level folder
# layout isn't load-bearing — `find` makes the script tolerant of
# wrappers like `ggml-cpp-stack-xcframework-arm64-X.Y.Z/` if upstream
# adds one).
for FW in "${FRAMEWORKS[@]}"; do
    SRC="$(find "$TMP_DIR" -type d -name "$FW" -print -quit)"
    if [ -z "$SRC" ]; then
        echo "Error: $FW not found in archive" >&2
        exit 1
    fi
    DEST="$THIRDPARTY_DIR/$FW"
    if [ -e "$DEST" ]; then
        echo "Replacing existing $DEST"
        rm -rf "$DEST"
    fi
    echo "Copying $SRC -> $DEST"
    cp -R "$SRC" "$DEST"
done

echo
echo "Done. ggml-stack ${VERSION} installed at $THIRDPARTY_DIR/{Ggml,LlamaCpp,Whisper,StableDiffusion}.xcframework"
