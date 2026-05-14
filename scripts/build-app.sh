#!/usr/bin/env bash
# Assemble dist/MarkdownViewer.app from the swift-built executable + Info.plist.
# Usage: bash scripts/build-app.sh [debug|release]   (default: debug)
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

CONFIG="${1:-debug}"
case "$CONFIG" in
  debug|release) ;;
  *) echo "Error: config must be 'debug' or 'release', got '$CONFIG'" >&2; exit 2 ;;
esac

APP_NAME="MarkdownViewer"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

echo "==> swift build -c $CONFIG"
( cd "$ROOT_DIR" && swift build -c "$CONFIG" )

BIN_DIR="$( cd "$ROOT_DIR" && swift build -c "$CONFIG" --show-bin-path )"
BIN_PATH="$BIN_DIR/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "Error: built executable not found at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN_PATH" "$CONTENTS/MacOS/$APP_NAME"
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS/Info.plist"

# Copy SPM-generated resource bundles (one per target with resources, e.g.
# MarkdownViewer_ViewerUI.bundle containing markdown.css).
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$CONTENTS/Resources/"
done
shopt -u nullglob

plutil -lint "$CONTENTS/Info.plist"

# Ad-hoc sign with an **explicit, stable identifier** so TCC (privacy
# prompts for Documents / Desktop / Downloads / etc.) and Launch Services
# treat consecutive builds as the same app. Without `--identifier`, the
# default identifier is derived from the bundle and is technically stable
# — but `--preserve-metadata=identifier` is the belt-and-suspenders flag
# that prevents codesign from rewriting it across rebuilds.
#
# Note: the CDHash will still change every build (the binary changes), so
# TCC may still re-prompt on a fresh rebuild. The fix for that is a real
# Developer ID certificate (Phase 9, distribution). During dev, granting
# Full Disk Access to /usr/bin/open (the launcher) or running the binary
# directly out of dist/MarkdownViewer.app/Contents/MacOS/MarkdownViewer
# is the workaround.
codesign --force \
  --sign - \
  --identifier "com.markdownviewer.MarkdownViewer" \
  --timestamp=none \
  "$APP_DIR" >/dev/null 2>&1 || true

# Register with Launch Services so `open -a MarkdownViewer` works by name.
# Without this, only an absolute-path `open -a /path/to/App.app` works.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "==> Built $APP_DIR"
echo
echo "Open a file with it (any of these work):"
echo "  open -a MarkdownViewer DESIGN.md            # name lookup (after lsregister)"
echo "  open -a \"$APP_DIR\" DESIGN.md"
echo "  open DESIGN.md -a \"$APP_DIR\""
echo
echo "Right-click a .md file in Finder → Open With → MarkdownViewer"
