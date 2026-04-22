#!/usr/bin/env bash
# Fetches the offline web assets (KaTeX, highlight.js) used by the print /
# export pipeline into thirdparty/webassets/. These are bundled into
# Infer.app by `make bundle-infer` — no network access at print time.
#
# Pinned versions; bump manually when needed. KaTeX ships as a tarball with
# fonts; highlight.js is two files pulled from cdnjs.
set -euo pipefail

KATEX_VERSION="${KATEX_VERSION:-0.16.22}"
HLJS_VERSION="${HLJS_VERSION:-11.11.1}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="$ROOT/thirdparty/webassets"

mkdir -p "$DEST"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Fetching KaTeX ${KATEX_VERSION}..."
KATEX_URL="https://github.com/KaTeX/KaTeX/releases/download/v${KATEX_VERSION}/katex.tar.gz"
curl -fL --retry 3 -o "$TMP/katex.tar.gz" "$KATEX_URL"
rm -rf "$DEST/katex"
mkdir -p "$DEST/katex"
tar -xzf "$TMP/katex.tar.gz" -C "$TMP"
# Tarball extracts to a top-level 'katex/' dir; move its contents in.
cp -R "$TMP/katex/." "$DEST/katex/"
echo "  -> $DEST/katex/"

echo "Fetching highlight.js ${HLJS_VERSION}..."
HLJS_BASE="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/${HLJS_VERSION}"
rm -rf "$DEST/highlight"
mkdir -p "$DEST/highlight"
curl -fL --retry 3 -o "$DEST/highlight/highlight.min.js" "$HLJS_BASE/highlight.min.js"
curl -fL --retry 3 -o "$DEST/highlight/github.min.css" "$HLJS_BASE/styles/github.min.css"
echo "  -> $DEST/highlight/"

echo "Done. Re-run this script to update (edit KATEX_VERSION / HLJS_VERSION at the top)."
