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

# Core Graphics' PNG encoder writes uncompressed images (no zopfli, no
# palette quantization). At 1024×1024 the 6 file sizes total ~1.8 MB
# before optimization. `oxipng -o 4` typically cuts that 40-60% with
# no visual difference. Falls back silently if oxipng isn't installed.
if command -v oxipng >/dev/null 2>&1; then
  echo "==> Optimizing PNGs with oxipng"
  oxipng -q -o 4 --strip safe "$ICONSET"/*.png
fi

echo "==> Packing .icns (preserves optimized PNGs verbatim)"
mkdir -p "$ROOT_DIR/Resources"
# Apple's `iconutil` recompresses each PNG, throwing away oxipng's
# work. `pack-icns.swift` writes the .icns container ourselves so the
# optimized bytes survive into the final file.
swift "$SCRIPT_DIR/pack-icns.swift" "$ICONSET" "$OUT"

ls -lh "$OUT"
echo
echo "Rebuild the .app to embed the new icon:"
echo "  bash scripts/build-app.sh"
echo "  bash scripts/install-app.sh"
echo
echo "Then clear the icon services cache so Finder/Dock pick up the change:"
echo "  killall Finder Dock"
