#!/usr/bin/env bash
# aqua-runner.sh — runs INSIDE the VM's Aqua (GUI) login session, launched by
# the LaunchAgent `com.markdownviewer.uitest` (NOT over SSH). This is the whole
# point: a process bootstrapped into `gui/<uid>` reports
# `launchctl managername == Aqua`, so the WindowServer gives `screencapture
# -l<windowID>` REAL pixels — unlike a process spawned from an SSH
# (`Background` domain) shell or via `launchctl asuser`, whose windows macOS 15
# redacts to blank. This is the documented unblock for the UTM visual lane
# (TSK-492 / vm-smoke.sh "known limitation").
#
# Protocol (file-based, since the agent has no stdout we can read over SSH):
#   IN : $JOB_DIR/scene        — one line, e.g. "terminal-paneright"
#   OUT: $JOB_DIR/<scene>.png  — the captured window
#        $JOB_DIR/<scene>.result — "PASS"/"FAIL(n)" + eval line + diag
#        $JOB_DIR/done          — sentinel written LAST (host polls for it)
#
# The host (scripts/vm-uitest.sh) drops `scene`, removes `done`, kickstarts the
# agent, then polls for `done`. Eval is the SAME dense-saturated-block /
# region-variety logic as scripts/ui-snapshot.sh — programmatic pass/fail, no
# human eyeballing (owner directive 2026-06-07).
set -uo pipefail

JOB_DIR="${MDV_UITEST_JOB_DIR:-$HOME/.mdv-uitest}"
APP="${MDV_APP:-$HOME/markdown_viewer/dist/TextView.app}/Contents/MacOS/MarkdownViewer"
FILE="${MDV_FILE:-$HOME/markdown_viewer/DESIGN.md}"
WID_FILE="$(getconf DARWIN_USER_TEMP_DIR)com.markdownviewer.MarkdownViewer.windowid"

mkdir -p "$JOB_DIR"
RESULT="$JOB_DIR/result.tmp"
: > "$RESULT"
log() { echo "$*" >> "$RESULT"; }

log "aqua-runner: managername=$(launchctl managername 2>/dev/null || echo '?') uid=$(id -u)"

scene="$(tr -d '[:space:]' < "$JOB_DIR/scene" 2>/dev/null || true)"
[ -n "$scene" ] || scene="terminal-paneright"
log "scene=$scene"

PNG="$JOB_DIR/$scene.png"
rm -f "$WID_FILE" "$PNG"

if [ ! -x "$APP" ]; then
  log "FAIL: app not built at $APP"
  mv "$RESULT" "$JOB_DIR/$scene.result"; : > "$JOB_DIR/done"; exit 2
fi

# Keep the display awake (overnight runs lock it → capture fails).
caffeinate -u -t 40 &
CAFF=$!
MDV_TEST_INSTANCE=1 MDV_SKIP_WORKSPACE_RESTORE=1 MDV_UI_SCENE="$scene" \
  "$APP" "$FILE" >"$JOB_DIR/$scene.applog" 2>&1 &
PID=$!
trap 'kill "$PID" "$CAFF" 2>/dev/null; sleep 0.3; kill -9 "$PID" 2>/dev/null' EXIT

for _ in $(seq 1 50); do [ -s "$WID_FILE" ] && break; sleep 0.3; done
WID="$(tr -d '[:space:]' < "$WID_FILE" 2>/dev/null || true)"
if [ -z "$WID" ]; then
  log "FAIL: no window id (app didn't launch in Aqua?)"
  mv "$RESULT" "$JOB_DIR/$scene.result"; : > "$JOB_DIR/done"; exit 3
fi
log "windowid=$WID"

sleep 2.5
osascript -e 'tell application id "com.markdownviewer.MarkdownViewer" to activate' 2>/dev/null || true
sleep 0.5
screencapture -l"$WID" -o -x "$PNG"
if [ ! -s "$PNG" ]; then
  log "FAIL: screencapture produced no PNG (Screen Recording denied for the agent?)"
  mv "$RESULT" "$JOB_DIR/$scene.result"; : > "$JOB_DIR/done"; exit 4
fi

# Programmatic eval: a dense saturated (accent-chip) block proves the terminal
# tab strip composited; mirrors ui-snapshot.sh. Scene-agnostic band (whole
# window minus status bar) so it works for bottom AND side docks.
python3 - "$PNG" "$scene" >> "$RESULT" 2>&1 <<'PY'
import sys
from PIL import Image
png, scene = sys.argv[1], sys.argv[2]
im = Image.open(png).convert("RGB"); W,H = im.size; px = im.load()
def sat(x,y):
    r,g,b = px[x,y]; return (max(r,g,b)-min(r,g,b))>90
def dense(cx,cy):
    tot=s=0
    for dy in range(-16,17,4):
        for dx in range(-16,17,4):
            x,y=cx+dx,cy+dy
            if 0<=x<W and 0<=y<H:
                tot+=1
                if sat(x,y): s+=1
    return tot>0 and s/tot>=0.6
found=None
for y in range(int(H*0.10), H-50, 4):
    for x in range(0, W, 4):
        if sat(x,y) and dense(x,y): found=(x,y); break
    if found: break
print(f"eval scene={scene} size={W}x{H} dense_chip_block={found is not None} loc={found}")
sys.exit(0 if found else 5)
PY
RC=$?
[ $RC -eq 0 ] && log "PASS: $scene" || log "FAIL($RC): $scene"
mv "$RESULT" "$JOB_DIR/$scene.result"
: > "$JOB_DIR/done"
exit $RC
