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
# Translate the host path to the corresponding VM-ABSOLUTE path. Anything
# under the project root rsyncs to ~/markdown_viewer/<relpath>; anything
# else gets copied via scp. Both branches yield an absolute VM path so the
# launch site can use it verbatim (no prefix prepend).
if [[ "$FILE_ARG_HOST" == "$ROOT_DIR"* ]]; then
  RELPATH="${FILE_ARG_HOST#$ROOT_DIR/}"
  FILE_ARG_VM="/Users/vm-tester/markdown_viewer/$RELPATH"
else
  FILE_ARG_VM="/tmp/vm-smoke-input"
  # MDV_SMOKE_DRY_RUN: path-logic test mode (VMSmokePathGuardTests) — no
  # remote contact of any kind.
  [[ -z "${MDV_SMOKE_DRY_RUN:-}" ]] && scp -q "$FILE_ARG_HOST" "macOS15:$FILE_ARG_VM"
fi

# Defense-in-depth: the VM path is handed to a privileged remote shell
# (`sudo -S launchctl`), so reject anything outside a strict allowlist
# before it ever leaves the host. The path is passed to the remote as a
# positional arg (not interpolated into the command body), but we still
# refuse shell metacharacters / quotes / whitespace so a hostile filename
# can never reach the sudo'd context even if the transport changes.
if [[ ! "$FILE_ARG_VM" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  echo "Error: refusing VM path with unsafe characters: $FILE_ARG_VM" >&2
  echo "       (allowed: A-Z a-z 0-9 . _ / -)" >&2
  exit 1
fi

# Dry-run exit AFTER the allowlist so tests exercise the real rejection
# path; everything below this line touches the VM.
if [[ -n "${MDV_SMOKE_DRY_RUN:-}" ]]; then
  echo "DRY-RUN VM path: $FILE_ARG_VM"
  exit 0
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
  # Persisted session state (tab list, sidebar root, etc.). This is the
  # dir SessionStore.defaultDirectory() actually writes (the old
  # MarkdownViewer/Workspaces shape was retired). The launch also sets
  # MDV_SKIP_WORKSPACE_RESTORE=1, so this reset is belt-and-suspenders.
  rm -rf '/Users/vm-tester/Library/Application Support/MarkdownViewer/Sessions' 2>/dev/null || true
  # AppKit autosaved window frame — keyed in CFPrefs by autosave name.
  # Without clearing, a prior off-screen frame would override center().
  defaults delete com.markdownviewer.MarkdownViewer 'NSWindow Frame MainWindow' 2>/dev/null || true
  sleep 1
"

echo "==> Launch + screencap (via launchctl asuser; sh -c is the env-propagation trick)"
# The remote body is a QUOTED heredoc — nothing from the host is expanded
# into it. PASSWORD, GUI_UID and the (already-allowlisted) VM path are sent
# as positional args ($1/$2/$3) so an untrusted filename can never break out
# of the remote sudo'd `sh -c` context.
ssh macOS15 'bash -s' -- "$PASSWORD" "$GUI_UID" "$FILE_ARG_VM" <<'REMOTE'
  set -e
  PASSWORD="$1"
  GUI_UID="$2"
  FILE_ARG_VM="$3"
  # launchctl asuser drops env vars passed via /usr/bin/env, but
  # propagates env set INSIDE the shell it spawns. So we ask asuser
  # to run sh -c '...env=val cmd...'. The 'sh' is the user shell;
  # the env stays in scope through the exec. The path is passed to that
  # inner sh as ITS positional $0-shifted arg ("$1"), keeping it out of
  # the command string entirely.
  echo "$PASSWORD" | sudo -S launchctl asuser "$GUI_UID" /bin/sh -c '
    MDV_SKIP_WORKSPACE_RESTORE=1 \
    /Users/vm-tester/markdown_viewer/dist/TextView.app/Contents/MacOS/MarkdownViewer \
    "$1" &
  ' _ "$FILE_ARG_VM"
  # AppKit needs a few hundred ms to lay out + paint the window.
  # Bumped from 3s -> 6s; some VM swaps push it.
  sleep 6
  echo "$PASSWORD" | sudo -S launchctl asuser "$GUI_UID" \
    /usr/sbin/screencapture -x /tmp/vm-smoke.png
  ls -lh /tmp/vm-smoke.png
REMOTE

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
