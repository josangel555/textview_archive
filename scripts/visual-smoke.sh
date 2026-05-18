#!/usr/bin/env bash
# Visual smoke test — required after any change to TextDisplayView,
# ContentView's view-tree shape, or anything that introduces an
# NSViewRepresentable wrapping NSScrollView/NSTextView in the source
# area. Builds the app, launches it pointing at a real source file,
# captures the window via the macOS WindowServer (NOT in-process), and
# leaves a PNG at a known path for the human to eyeball.
#
# Why this exists: the macOS 14+ SwiftUI compositor pathology that
# blanks sibling HostingViews when NSTextView is nested inside SwiftUI
# only manifests at WindowServer composition time. xctest runs headless
# and `NSView.cacheDisplay(in:to:)` snapshots bypass the WindowServer,
# so neither catches the bug. `screencapture` reads what's actually on
# the screen — that's the only path that reveals it.
#
# Usage:
#   bash scripts/visual-smoke.sh                  # default: a Swift source file
#   bash scripts/visual-smoke.sh path/to/file     # pick the file
#
# Manual verification: open the PNG and confirm:
#   ✓ Tab bar at top is visible (file name, X button)
#   ✓ Mode bar below tab bar is visible (language badge if applicable)
#   ✓ Sidebar on left has file tree (if a folder is open)
#   ✓ Source text is visible with line numbers
#   ✓ Bottom status bar is visible
#
# If ANY of TabBar/ModeBar/Sidebar/StatusBar is blank while the source
# text is visible, the compositor bug has regressed — revert the
# offending change.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

FILE_ARG="${1:-$ROOT_DIR/Sources/ViewerCore/Highlight/TreeSitterEngine.swift}"
if [[ ! -f "$FILE_ARG" ]]; then
  echo "Error: file not found: $FILE_ARG" >&2
  exit 1
fi

OUT_PNG="${TMPDIR:-/tmp}/mdv-visual-smoke.png"

echo "==> Building..."
bash "$SCRIPT_DIR/build-app.sh" debug >/dev/null

APP_PATH="$ROOT_DIR/dist/TextView.app"
BIN_PATH="$APP_PATH/Contents/MacOS/MarkdownViewer"

# Kill prior instance.
/usr/bin/killall MarkdownViewer 2>/dev/null || true
sleep 0.3

echo "==> Launching for: $FILE_ARG"
"$BIN_PATH" "$FILE_ARG" &
APP_PID=$!

# Let the window appear + the source view paint.
sleep 2

# Get the WindowServer window-id for our app's main window. `osascript`
# could find it by name but the AppleScript route is rate-limited and
# requires Accessibility permission. CGWindowListCopyWindowInfo via
# `screencapture -l` needs a numeric ID. `screencapture -o` (no list)
# falls back to the frontmost window of the app being captured if we
# can foreground it first — that's what we do.
osascript -e 'tell application "TextView" to activate' 2>/dev/null || true
sleep 0.4

# -x: no shutter sound. -o: no window shadow/decoration in capture. -w
# would prompt for window pick. Instead we capture the WINDOW by name
# via -W (modern macOS only). Fall back to fullscreen if -W not
# supported.
rm -f "$OUT_PNG"
if ! /usr/sbin/screencapture -x -o -W "$OUT_PNG" 2>/dev/null; then
  # -W support varies. Fallback: capture the entire screen; the user
  # still gets a usable image.
  /usr/sbin/screencapture -x "$OUT_PNG"
fi

# Don't kill the app — let the user keep using it after the capture if
# they want. Print the PNG path.
echo
echo "==> Screenshot: $OUT_PNG"
echo
echo "Open it and verify these are ALL visible:"
echo "  [ ] Tab bar at top (file title, X button)"
echo "  [ ] Mode bar (with language badge for code files)"
echo "  [ ] Sidebar (if a folder is open) — file tree on the left"
echo "  [ ] Source text — with line numbers in the gutter"
echo "  [ ] Status bar at bottom (path, line count, etc.)"
echo
echo "If only the source text is visible and the rest is blank, the"
echo "macOS-14+ SwiftUI compositor pathology has regressed. Revert"
echo "any change that re-introduced NSTextView nesting under SwiftUI."

# Open the PNG for the user.
/usr/bin/open "$OUT_PNG"
