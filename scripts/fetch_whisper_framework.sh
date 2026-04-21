#!/usr/bin/env bash
set -euo pipefail

DEFAULT_TAG="v1.8.4"

if [ $# -gt 1 ]; then
    echo "Usage: $0 [tag]" >&2
    echo "Example: $0 v1.8.4 (default: $DEFAULT_TAG)" >&2
    exit 1
fi

TAG="${1:-$DEFAULT_TAG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
THIRDPARTY_DIR="$PROJECT_ROOT/thirdparty"

URL="https://github.com/ggml-org/whisper.cpp/releases/download/${TAG}/whisper-${TAG}-xcframework.zip"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ZIP_PATH="$TMP_DIR/whisper-${TAG}-xcframework.zip"

echo "Downloading $URL"
curl -fL --progress-bar -o "$ZIP_PATH" "$URL"

echo "Extracting $ZIP_PATH"
unzip -q "$ZIP_PATH" -d "$TMP_DIR"

XCFRAMEWORK_PATH="$(find "$TMP_DIR" -type d -name 'whisper.xcframework' -print -quit)"
if [ -z "$XCFRAMEWORK_PATH" ]; then
    echo "Error: whisper.xcframework not found in archive" >&2
    exit 1
fi

mkdir -p "$THIRDPARTY_DIR"
DEST="$THIRDPARTY_DIR/whisper.xcframework"
if [ -e "$DEST" ]; then
    echo "Removing existing $DEST"
    rm -rf "$DEST"
fi

echo "Copying $XCFRAMEWORK_PATH -> $DEST"
cp -R "$XCFRAMEWORK_PATH" "$DEST"

echo "Done. whisper.xcframework (tag $TAG) installed at $DEST"
