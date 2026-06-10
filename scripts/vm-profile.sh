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
# Usage: bash scripts/vm-profile.sh [file-to-open] [seconds] [mode] [config] [scope]
#        modes:  open   — launch with the file as argv (default)
#                resize — launch with a --script that opens the file, then
#                         runs `resize-sweep 700 1400 120` (~4s oscillation)
#                         while the trace records (TSK-592)
#        config: release (default) | debug — debug keeps symbols, use it
#                when you need SYMBOLICATED Time Profiler stacks (the
#                release bundle is stripped; its timings are honest but
#                its samples are addresses).
#        scope:  app (default) — xctrace --launch targets the app only;
#                  includes the os_signpost instrument.
#                system — xctrace --all-processes records SYSTEM-WIDE while
#                  the app is launched separately in the GUI session. Use
#                  when the cost lives in an XPC peer the app-scoped trace
#                  is blind to — e.g. the WKWebView WebContent process
#                  repainting during a resize sweep (TSK-592). No signpost
#                  instrument in this scope; anchor windows by the
#                  MarkdownViewer process's own sample density.
#        (defaults: LESSONS.md, 20s, open, release, app)
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
MODE="${3:-open}"
CONFIG="${4:-release}"
SCOPE="${5:-app}"
if [[ ! -f "$FILE_ARG_HOST" ]]; then
  echo "Error: file not found on host: $FILE_ARG_HOST" >&2
  exit 1
fi
if [[ ! "$SECONDS_ARG" =~ ^[0-9]+$ ]]; then
  echo "Error: seconds must be an integer: $SECONDS_ARG" >&2
  exit 1
fi
case "$MODE" in open|resize) ;; *)
  echo "Error: mode must be open|resize: $MODE" >&2; exit 1 ;; esac
case "$CONFIG" in release|debug) ;; *)
  echo "Error: config must be release|debug: $CONFIG" >&2; exit 1 ;; esac
case "$SCOPE" in app|system) ;; *)
  echo "Error: scope must be app|system: $SCOPE" >&2; exit 1 ;; esac

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

echo "==> Build dist/TextView.app ($CONFIG) on VM"
ssh macOS15 "cd markdown_viewer && bash scripts/build-app.sh $CONFIG 2>&1 | tail -2"

echo "==> Record xctrace signpost profile in the GUI session (${SECONDS_ARG}s)"
# Quoted heredoc: nothing from the host expands into the remote body.
# PASSWORD/GUI_UID/path/seconds ride as positional args (vm-smoke.sh
# pattern) so an untrusted filename can't break out of the sudo'd sh -c.
ssh macOS15 'bash -s' -- "$PASSWORD" "$GUI_UID" "$FILE_ARG_VM" "$SECONDS_ARG" "$MODE" "$SCOPE" <<'REMOTE'
  set -e
  PASSWORD="$1"; GUI_UID="$2"; FILE_ARG_VM="$3"; SECS="$4"; MODE="$5"; SCOPE="$6"
  pkill MarkdownViewer 2>/dev/null || true
  # sudo'd: a prior run's trace may be root-owned (xctrace runs under
  # the sudo'd asuser bridge) — a plain rm can't delete it.
  echo "$PASSWORD" | sudo -S rm -rf /tmp/mdv-vm-profile.trace
  if [ "$MODE" = "resize" ]; then
    # Driver script: open the doc, settle, then oscillate the window
    # width inside ONE verb (resize-sweep) while the trace records.
    # 120 steps @ ~30Hz ≈ 4s of continuous relayout (TSK-592). The
    # runner exits 0 after the last step, ending the recording cleanly.
    cat > /tmp/mdv-resize-driver.txt <<SCRIPT
open $FILE_ARG_VM
delay 4
resize-sweep 700 1400 120
delay 6
SCRIPT
    LAUNCH_ARGS="--script /tmp/mdv-resize-driver.txt"
  else
    LAUNCH_ARGS="$FILE_ARG_VM"
  fi
  if [ "$SCOPE" = "system" ]; then
    # System-wide: the recorder cannot --launch, so start it first
    # (background), give it a beat to spin up, then launch the app in
    # the GUI session WITHOUT xctrace. The recorder's --time-limit ends
    # the trace; the app exits itself via the driver script.
    echo "$PASSWORD" | sudo -S sh -c "
      xcrun xctrace record --template 'Time Profiler' --all-processes \
        --time-limit ${SECS}s --output /tmp/mdv-vm-profile.trace \
        2>&1 | tail -3
    " &
    RECORDER_PID=$!
    sleep 3
    echo "$PASSWORD" | sudo -S launchctl asuser "$GUI_UID" /bin/sh -c '
      cd /Users/vm-tester/markdown_viewer &&
      MDV_SIGNPOSTS=1 MDV_SKIP_WORKSPACE_RESTORE=1 \
        dist/TextView.app/Contents/MacOS/MarkdownViewer $1
    ' _ "$LAUNCH_ARGS"
    wait "$RECORDER_PID"
  else
    # asuser drops env passed via /usr/bin/env but propagates env set
    # inside the spawned shell; launch args stay positional.
    echo "$PASSWORD" | sudo -S launchctl asuser "$GUI_UID" /bin/sh -c '
      cd /Users/vm-tester/markdown_viewer &&
      xcrun xctrace record --template "Time Profiler" --instrument "os_signpost" \
        --env MDV_SIGNPOSTS=1 --env MDV_SKIP_WORKSPACE_RESTORE=1 \
        --time-limit "$2"s --output /tmp/mdv-vm-profile.trace \
        --launch -- dist/TextView.app/Contents/MacOS/MarkdownViewer $1 \
        2>&1 | tail -3
    ' _ "$LAUNCH_ARGS" "$SECS"
  fi
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
