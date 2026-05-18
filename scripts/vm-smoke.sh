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
# Known limitation (macOS 15+ Sequoia TCC):
#   The screencap output captures the wallpaper + menu bar but does
#   NOT include the TextView window's content. CGWindowList confirms
#   the window exists and is on-screen, but the WindowServer redacts
#   its pixels in the captured image. Cause: macOS 15's "Screen
#   Capture Privacy" hides windows of processes launched via
#   `sudo launchctl asuser` — TCC can't reconcile the bridged
#   ownership. Two ways to lift this (out of scope for v1):
#     1. Install TextView as a LaunchAgent or login item on the VM so
#        the process is owned by the GUI session natively.
#     2. Eyeball through the UTM display window directly — manual
#        smoke covers what the automated capture can't.
#   For now this script verifies the build / launch / screencap
#   PIPELINE works end-to-end; the captured PNG is a sanity check
#   that the VM session is alive, not a substitute for visual
#   regression. The XCTest-driven visual smoke (run via
#   `ssh macOS15 'cd markdown_viewer && swift test'`) is the
#   authoritative path.
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

echo "==> Reset window position + workspace state on VM"
ssh macOS15 "
  pkill MarkdownViewer 2>/dev/null || true
  # Workspace JSON (tab list, sidebar root, etc.)
  rm -rf '/Users/vm-tester/Library/Application Support/MarkdownViewer/Workspaces' 2>/dev/null || true
  # AppKit autosaved window frame — keyed in CFPrefs by autosave name.
  # Without clearing, a prior off-screen frame would override center().
  defaults delete com.markdownviewer.MarkdownViewer 'NSWindow Frame MainWindow' 2>/dev/null || true
  sleep 1
"

echo "==> Launch + screencap (via launchctl asuser; sh -c is the env-propagation trick)"
ssh macOS15 "
  set -e
  # launchctl asuser drops env vars passed via /usr/bin/env, but
  # propagates env set INSIDE the shell it spawns. So we ask asuser
  # to run sh -c '...env=val cmd...'. The 'sh' is the user shell;
  # the env stays in scope through the exec.
  echo '$PASSWORD' | sudo -S launchctl asuser $GUI_UID /bin/sh -c '
    MDV_SKIP_WORKSPACE_RESTORE=1 \
    /Users/vm-tester/markdown_viewer/dist/TextView.app/Contents/MacOS/MarkdownViewer \
    /Users/vm-tester/$FILE_ARG_VM &
  '
  # AppKit needs a few hundred ms to lay out + paint the window.
  # Bumped from 3s → 6s; some VM swaps push it.
  sleep 6
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
