#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns from scripts/render-icon.swift.
# Run this only when the icon design changes — the .icns is committed
# so daily builds don't re-render.
#
# Usage: bash scripts/build-icon.sh
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

ICONSET="$SCRIPT_DIR/AppIcon.iconset"
OUT="$ROOT_DIR/Resources/AppIcon.icns"

echo "==> Rendering PNGs"
mkdir -p "$ICONSET"
swift "$SCRIPT_DIR/render-icon.swift" "$ICONSET"

echo "==> iconutil → $OUT"
mkdir -p "$ROOT_DIR/Resources"
iconutil -c icns -o "$OUT" "$ICONSET"

ls -lh "$OUT"
echo
echo "Rebuild the .app to embed the new icon:"
echo "  bash scripts/build-app.sh"
echo "  bash scripts/install-app.sh"
echo
echo "Then clear the icon services cache so Finder/Dock pick up the change:"
echo "  killall Finder Dock"
