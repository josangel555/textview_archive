#!/usr/bin/env bash
# check-dylib-identifiers.sh — TSK-157 guard.
#
# The --deep signing pass in build-app.sh must NOT stamp the main bundle
# identifier onto the nested grammar dylibs: passing `--identifier` to a
# `--deep` codesign re-signs every nested item with the SAME id, which
# breaks per-file signature identity and is a footgun for the future
# ship-public / Developer ID transition (Gatekeeper treats identifier
# collisions across distinct code as suspicious). Omitting it lets
# codesign derive each dylib's identifier from its filename.
#
# Usage: check-dylib-identifiers.sh [path/to/App.app]
# Exits 1 if any Contents/Frameworks dylib carries the main bundle id,
# or if no dylibs are found (the lazy-grammar split guarantees 11 — an
# empty Frameworks dir means this check is no longer checking anything).

set -euo pipefail

APP_DIR="${1:-dist/TextView.app}"
BUNDLE_ID="com.markdownviewer.MarkdownViewer"
FRAMEWORKS="$APP_DIR/Contents/Frameworks"

if [[ ! -d "$FRAMEWORKS" ]]; then
  echo "ERROR: $FRAMEWORKS missing — nothing to check (lazy-grammar split gone?)" >&2
  exit 1
fi

count=0
while IFS= read -r -d '' dylib; do
  count=$((count + 1))
  ident="$(codesign -d -v "$dylib" 2>&1 | sed -n 's/^Identifier=//p')"
  if [[ "$ident" == "$BUNDLE_ID" ]]; then
    echo "ERROR: $(basename "$dylib") is signed with the MAIN BUNDLE identifier" >&2
    echo "       ($BUNDLE_ID) — '--identifier' leaked into the --deep signing" >&2
    echo "       pass in build-app.sh (TSK-157)." >&2
    exit 1
  fi
done < <(find "$FRAMEWORKS" -name '*.dylib' -print0)

if [[ "$count" -eq 0 ]]; then
  echo "ERROR: no dylibs under $FRAMEWORKS — identifier check is vacuous" >&2
  exit 1
fi

echo "==> dylib identifiers OK ($count nested dylibs, none claim $BUNDLE_ID)"
