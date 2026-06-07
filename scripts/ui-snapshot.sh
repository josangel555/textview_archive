#!/usr/bin/env bash
# ui-snapshot.sh — deterministic UI screenshot + pixel eval (TSK-492).
#
# WHY: headless frame-walks prove LAYOUT, not VISIBILITY — they passed green
# three times while the terminal tab chips were invisible (a ScrollView
# rendered its content empty). This harness drives the app into an EXACT
# state via MDV_UI_SCENE, captures its window by id through the COMPOSITOR
# (real pixels — unlike the app's cacheDisplay --auto-snapshot, which is
# blind to SwiftUI CA layers and gives false greens), runs a pixel eval, and
# reaps the instance. No defaults/AX roulette.
#
# Usage:  bash scripts/ui-snapshot.sh <scene> [outdir]
#   scene   terminal-left | terminal-top | terminal-right | terminal-3 | ...
#   outdir  where to write <scene>.png + .log (default /tmp/mdv-ui)
#
# Env:  MDV_APP=/path/to/TextView.app   MDV_FILE=/path/to/file
#
# Exit 0 = captured + eval PASS; non-zero = FAIL (PNG kept for triage).
#
# HOST today (owner lent the Mac for UI testing). UTM port (TSK-492 Layer 3):
# macOS 15 redacts windows of launchctl-asuser apps, so the VM needs the app
# installed as a GUI-session-native LaunchAgent before this capture works
# there — that's the remaining unblock.
set -uo pipefail

SCENE="${1:-terminal-left}"
OUTDIR="${2:-/tmp/mdv-ui}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${MDV_APP:-$ROOT/dist/TextView.app}/Contents/MacOS/MarkdownViewer"
FILE="${MDV_FILE:-$ROOT/DESIGN.md}"
mkdir -p "$OUTDIR"
PNG="$OUTDIR/$SCENE.png"
LOG="$OUTDIR/$SCENE.log"
WID_FILE="$(getconf DARWIN_USER_TEMP_DIR)com.markdownviewer.MarkdownViewer.windowid"

[ -x "$APP" ] || { echo "FAIL: app not built at $APP"; exit 2; }
rm -f "$WID_FILE" "$PNG"

# Keep the display awake — a slept/locked display can't be screen-captured
# ("could not create image from window"), which is the norm for autonomous
# overnight runs. -u asserts user activity (wakes it); -t covers the run.
caffeinate -u -t 30 &
CAFF=$!
MDV_TEST_INSTANCE=1 MDV_SKIP_WORKSPACE_RESTORE=1 MDV_UI_SCENE="$SCENE" \
  "$APP" "$FILE" >"$LOG" 2>&1 &
PID=$!
trap 'kill "$PID" "$CAFF" 2>/dev/null; sleep 0.3; kill -9 "$PID" 2>/dev/null' EXIT

for _ in $(seq 1 50); do [ -s "$WID_FILE" ] && break; sleep 0.3; done
WID="$(tr -d '[:space:]' < "$WID_FILE" 2>/dev/null || true)"
[ -n "$WID" ] || { echo "FAIL: no window id (app didn't launch?); see $LOG"; exit 3; }

# Scene-apply delay (0.6s) + layout + first paint.
sleep 2.5
osascript -e 'tell application id "com.markdownviewer.MarkdownViewer" to activate' 2>/dev/null || true
sleep 0.5
screencapture -l"$WID" -o -x "$PNG"
[ -s "$PNG" ] || { echo "FAIL: capture produced no PNG (Screen Recording denied?)"; exit 4; }

# Pixel eval. For terminal scenes the accent-selected chip is a VIVID
# (saturated) swatch; the rail/chrome/shell are ~unsaturated. A saturated
# pixel in the terminal band (bottom of the window) ⇒ the chip painted.
python3 - "$PNG" "$SCENE" <<'PY'
import sys
from PIL import Image
png, scene = sys.argv[1], sys.argv[2]
im = Image.open(png).convert("RGB"); W, H = im.size
px = im.load()
def sat(x, y):
    r, g, b = px[x, y]; return (max(r, g, b) - min(r, g, b)) > 90
# The accent-selected chip is a SOLID saturated swatch (~90x56px retina).
# Require a saturated pixel whose 33x33 neighborhood is ≥60% saturated — a
# dense block. This rejects the scattered saturated chrome pixels (git/icon
# glyphs in the sidebar/status bar) that a "any saturated pixel" check
# false-passed on. Scan the bottom ~48% (covers the open terminal pane; the
# vertical rail's chips sit near the pane's TOP, so a bottom-only band misses
# them), excluding the ~status bar.
y0 = int(H * 0.52); y1 = max(y0 + 1, H - 50)
def dense(cx, cy):
    tot = s = 0
    for dy in range(-16, 17, 4):
        for dx in range(-16, 17, 4):
            x, y = cx + dx, cy + dy
            if 0 <= x < W and 0 <= y < H:
                tot += 1
                if sat(x, y): s += 1
    return tot > 0 and s / tot >= 0.6
found = None
for y in range(y0, y1, 4):
    for x in range(0, W, 4):
        if sat(x, y) and dense(x, y):
            found = (x, y); break
    if found: break
print(f"eval scene={scene} size={W}x{H} dense_chip_block={found is not None} loc={found}")
sys.exit(0 if found else 5)
PY
RC=$?
[ $RC -eq 0 ] && echo "PASS: $SCENE -> $PNG" || echo "FAIL($RC): $SCENE -> $PNG (kept for triage)"
exit $RC
