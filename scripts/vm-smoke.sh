#!/usr/bin/env bash
# vm-smoke.sh — run the visual smoke test on the macOS15 UTM VM.
#
# Why: the host runs the user's daily work. Anything that opens a real
# window (live-app tests, visual regression, screencapture) is
# disruptive. The VM is the isolated runtime for those. This wrapper:
#
#   1. rsyncs the working tree to the VM
#   2. builds dist/TextView.app on the VM
#   3. launches the .app inside the VM's GUI session via launchctl asuser
#   4. takes a screencapture from inside the VM's session
#   5. copies the PNG back to the host so the user can eyeball it
#
# Usage:
#   bash scripts/vm-smoke.sh                # default test file (DESIGN.md)
#   bash scripts/vm-smoke.sh path/to/file   # pick the file
#
# Requirements:
#   - SSH host `macOS15` configured (see ~/.ssh/config)
#   - vm-tester@macOS15 has a GUI login session (UTM display window open)
#   - Sudo password cached at MDV_VM_SUDO_PASSWORD env (defaults to "<vm-sudo-password>"
#     per the user's local convention; override for CI / other VMs)
#   - On first run on a fresh VM, grant Terminal these in System
#     Settings → Privacy & Security on the VM:
#       Accessibility       → +Terminal   (lets osascript activate work)
#       Screen Recording    → +Terminal   (lets screencapture see windows)

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

# The PASSWORD is the vm-tester user's sudo password on the VM. It's a
# dev VM credential — see ~/.claude/projects/-Users-me/memory/
# reference_macos15_vm_credentials.md for context.
PASSWORD="${MDV_VM_SUDO_PASSWORD:-<vm-sudo-password>}"

# 501 is the default UID of the first non-system user on a fresh macOS
# install. `launchctl asuser` needs the GUI-session uid so the spawned
# process inherits WindowServer + TCC context.
GUI_UID=501

FILE_ARG_HOST="${1:-$ROOT_DIR/DESIGN.md}"
if [[ ! -f "$FILE_ARG_HOST" ]]; then
  echo "Error: file not found on host: $FILE_ARG_HOST" >&2
  exit 1
fi
# Translate the host path to the corresponding path inside the VM
# checkout. Anything under the project root rsyncs to
# ~/markdown_viewer/<relpath>; anything else gets copied via scp.
if [[ "$FILE_ARG_HOST" == "$ROOT_DIR"* ]]; then
  RELPATH="${FILE_ARG_HOST#$ROOT_DIR/}"
  FILE_ARG_VM="markdown_viewer/$RELPATH"
else
  FILE_ARG_VM="/tmp/vm-smoke-input"
  scp -q "$FILE_ARG_HOST" "macOS15:$FILE_ARG_VM"
fi

OUT_PNG="${TMPDIR:-/tmp}/vm-smoke.png"

echo "==> rsync source to VM"
rsync -az --delete \
  --exclude='.build/' --exclude='.swiftpm/' \
  --exclude='dist/' --exclude='.git/objects/pack/' \
  "$ROOT_DIR/" macOS15:markdown_viewer/

echo "==> Build dist/TextView.app on VM"
ssh macOS15 'cd markdown_viewer && bash scripts/build-app.sh debug 2>&1 | tail -2'

echo "==> Launch + screencap (via launchctl asuser, so it lands in the GUI session)"
ssh macOS15 "
  set -e
  pkill MarkdownViewer 2>/dev/null || true
  sleep 1
  # Blow away the saved workspace so the window restores at default
  # geometry instead of an old off-screen frame.
  rm -rf '/Users/vm-tester/Library/Application Support/MarkdownViewer/Workspaces' 2>/dev/null || true
  # Launch the binary directly with MDV_SKIP_WORKSPACE_RESTORE so the
  # app comes up with a single fresh tab pointed at the input file.
  # launchctl asuser is mandatory — without it the process inherits
  # the SSH session's null WindowServer and the window never paints.
  echo '$PASSWORD' | sudo -S launchctl asuser $GUI_UID \
    /usr/bin/env MDV_SKIP_WORKSPACE_RESTORE=1 \
    /Users/vm-tester/markdown_viewer/dist/TextView.app/Contents/MacOS/MarkdownViewer \
    /Users/vm-tester/$FILE_ARG_VM >/tmp/textview.log 2>&1 &
  sleep 4
  echo '$PASSWORD' | sudo -S launchctl asuser $GUI_UID \
    /usr/bin/osascript -e 'tell application \"TextView\" to activate' 2>&1 || true
  sleep 1
  echo '$PASSWORD' | sudo -S launchctl asuser $GUI_UID \
    /usr/sbin/screencapture -x /tmp/vm-smoke.png
  ls -lh /tmp/vm-smoke.png
"

echo "==> Pull screenshot back to host"
scp -q macOS15:/tmp/vm-smoke.png "$OUT_PNG"

echo
echo "==> Done: $OUT_PNG"
echo
echo "Eyeball checklist (same as scripts/visual-smoke.sh):"
echo "  [ ] Tab bar at top (file title, X button)"
echo "  [ ] Mode bar (with language badge for code files)"
echo "  [ ] Sidebar — file tree on the left"
echo "  [ ] Source text — with line numbers in the gutter"
echo "  [ ] Status bar at bottom (path, line count, etc.)"
echo
echo "Open with: open $OUT_PNG"

/usr/bin/open "$OUT_PNG"
