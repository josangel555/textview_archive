#!/usr/bin/env bash
# Record an xctrace signpost profile of a file open INSIDE the UTM VM's
# GUI session, and pull the .trace back to the host.
#
# The PerfSignpost capture (docs/PERFORMANCE_PROFILING.md) needs a real
# WindowServer session; per the owner directive (2026-06-10) anything
# that opens app UI runs on the UTM VM, never the host. This is the
# profiling sibling of vm-smoke.sh: same rsync → VM build → launchctl
# asuser bridge, but the launch runs under
# `xctrace record --instrument 'os_signpost'` instead of screencapture.
#
# Usage: bash scripts/vm-profile.sh [file-to-open] [seconds]
#        (defaults: LESSONS.md, 20s)
# Output: $TMPDIR/mdv-vm-profile.trace on the HOST. Read intervals with:
#        xcrun xctrace export --input <trace> --toc
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

# Same dev-VM credential vm-smoke.sh uses (see its header comment).
PASSWORD="${MDV_VM_SUDO_PASSWORD:-<vm-sudo-password>}"
# GUI-session uid — launchctl asuser needs it so the spawned app
# inherits WindowServer + TCC context (vm-smoke.sh, TSK-502).
GUI_UID=501

FILE_ARG_HOST="${1:-$ROOT_DIR/LESSONS.md}"
SECONDS_ARG="${2:-20}"
if [[ ! -f "$FILE_ARG_HOST" ]]; then
  echo "Error: file not found on host: $FILE_ARG_HOST" >&2
  exit 1
fi
if [[ ! "$SECONDS_ARG" =~ ^[0-9]+$ ]]; then
  echo "Error: seconds must be an integer: $SECONDS_ARG" >&2
  exit 1
fi

# Host → VM path translation (same rule as vm-smoke.sh).
if [[ "$FILE_ARG_HOST" == "$ROOT_DIR"* ]]; then
  RELPATH="${FILE_ARG_HOST#$ROOT_DIR/}"
  FILE_ARG_VM="/Users/vm-tester/markdown_viewer/$RELPATH"
else
  FILE_ARG_VM="/tmp/vm-profile-input"
  scp -q "$FILE_ARG_HOST" "macOS15:$FILE_ARG_VM"
fi

# Defense-in-depth allowlist before the path reaches a sudo'd remote
# shell — identical contract to vm-smoke.sh.
if [[ ! "$FILE_ARG_VM" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  echo "Error: refusing VM path with unsafe characters: $FILE_ARG_VM" >&2
  exit 1
fi

OUT_TRACE="${TMPDIR:-/tmp}/mdv-vm-profile.trace"

echo "==> rsync source to VM"
rsync -az --delete \
  --exclude='.build/' --exclude='.swiftpm/' \
  --exclude='dist/' --exclude='.git/objects/pack/' \
  "$ROOT_DIR/" macOS15:markdown_viewer/

echo "==> Build dist/TextView.app (release) on VM"
ssh macOS15 'cd markdown_viewer && bash scripts/build-app.sh release 2>&1 | tail -2'

echo "==> Record xctrace signpost profile in the GUI session (${SECONDS_ARG}s)"
# Quoted heredoc: nothing from the host expands into the remote body.
# PASSWORD/GUI_UID/path/seconds ride as positional args (vm-smoke.sh
# pattern) so an untrusted filename can't break out of the sudo'd sh -c.
ssh macOS15 'bash -s' -- "$PASSWORD" "$GUI_UID" "$FILE_ARG_VM" "$SECONDS_ARG" <<'REMOTE'
  set -e
  PASSWORD="$1"; GUI_UID="$2"; FILE_ARG_VM="$3"; SECS="$4"
  pkill MarkdownViewer 2>/dev/null || true
  # sudo'd: a prior run's trace may be root-owned (xctrace runs under
  # the sudo'd asuser bridge) — a plain rm can't delete it.
  echo "$PASSWORD" | sudo -S rm -rf /tmp/mdv-vm-profile.trace
  # asuser drops env passed via /usr/bin/env but propagates env set
  # inside the spawned shell; the file path stays a positional arg.
  echo "$PASSWORD" | sudo -S launchctl asuser "$GUI_UID" /bin/sh -c '
    cd /Users/vm-tester/markdown_viewer &&
    xcrun xctrace record --template "Time Profiler" --instrument "os_signpost" \
      --env MDV_SIGNPOSTS=1 --env MDV_SKIP_WORKSPACE_RESTORE=1 \
      --time-limit "$2"s --output /tmp/mdv-vm-profile.trace \
      --launch -- dist/TextView.app/Contents/MacOS/MarkdownViewer "$1" \
      2>&1 | tail -3
  ' _ "$FILE_ARG_VM" "$SECS"
  pkill MarkdownViewer 2>/dev/null || true
  # The sudo'd xctrace writes the trace as ROOT — chown it back so the
  # vm-tester scp pull can read it (same class as the TSK-502 root-owned
  # .build poisoning; see reference_vm_pixel_lane_tcc).
  echo "$PASSWORD" | sudo -S chown -R vm-tester /tmp/mdv-vm-profile.trace
  ls -ld /tmp/mdv-vm-profile.trace
REMOTE

echo "==> Pull trace back to host"
rm -rf "$OUT_TRACE"
scp -rq macOS15:/tmp/mdv-vm-profile.trace "$OUT_TRACE"

echo
echo "==> Done: $OUT_TRACE"
echo "    Inspect: xcrun xctrace export --input $OUT_TRACE --toc"
