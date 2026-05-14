#!/usr/bin/env bash
# Diagnostic: rebuild from source, reset persisted window-frame state, then
# launch MarkdownViewer on the file you pass in. Use this when the live app
# disagrees with what the test suite says it should look like.
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
BUNDLE_ID="com.markdownviewer.MarkdownViewer"

FILE_ARG="${1:-}"

echo "==> Killing any running MarkdownViewer instances"
killall MarkdownViewer 2>/dev/null || true

echo "==> Resetting persisted window-frame state (other prefs preserved)"
defaults delete "$BUNDLE_ID" "NSWindow Frame MainWindow" 2>/dev/null || true

echo "==> Rebuilding .app bundle"
bash "$SCRIPT_DIR/build-app.sh" debug

echo "==> Launching"
if [[ -n "$FILE_ARG" ]]; then
  open -a MarkdownViewer "$FILE_ARG"
else
  open -a MarkdownViewer
fi

echo
echo "If the window is still wrong, capture diagnostics with:"
echo "  swift test --filter LiveAppLaunchTests"
echo "(requires Accessibility permission for xctest / osascript)"
