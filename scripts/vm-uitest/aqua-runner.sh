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

# Monitor launch-mode UAT (TSK-1477): the Claude Session Monitor is a separate
# `--claude-monitor` window, NOT a MDV_UI_SCENE (it has no document-model scene
# applier). For `monitor-*` scenes, build a fixture root + launch in monitor
# mode pointed at it via MDV_MONITOR_ROOT (the view's documented root override,
# ClaudeMonitorModel.defaultRoot). The monitor window writes the SAME windowid
# file (main.swift openClaudeMonitorWindow), so the capture path is unchanged.
MON_ROOT=""
case "$scene" in
  monitor-rootmissing)
    # A root that does NOT exist → the rootMissing actionable empty state (U1).
    MON_ROOT="$JOB_DIR/mon-missing-does-not-exist"
    rm -rf "$MON_ROOT"
    ;;
  monitor-sessions)
    # A populated root: <root>/projects/<p>/<s>.jsonl → the session list (U4).
    MON_ROOT="$JOB_DIR/mon-root"
    rm -rf "$MON_ROOT"
    mkdir -p "$MON_ROOT/projects/demo-project"
    printf '%s\n%s\n' \
      '{"type":"user","timestamp":"2026-07-01T10:00:00Z","message":{"role":"user","content":"Build the outline panel"}}' \
      '{"type":"assistant","timestamp":"2026-07-01T10:00:05Z","message":{"role":"assistant","content":"Done."}}' \
      > "$MON_ROOT/projects/demo-project/session-abc123.jsonl"
    ;;
esac

# Optional per-run env for the LSP status chip scene (TSK-1444): a forced chip
# state ("<state>[:<language>]", e.g. "failed:python"), dropped by the host in
# $JOB_DIR/lsp-fake before kickstart. Absent/empty → the chip shows the REAL
# pool state (the model treats an empty value as "no override").
LSP_FAKE="$(tr -d '[:space:]' < "$JOB_DIR/lsp-fake" 2>/dev/null || true)"

if [ -n "$MON_ROOT" ]; then
  MDV_TEST_INSTANCE=1 MDV_MONITOR_ROOT="$MON_ROOT" \
    "$APP" --claude-monitor >"$JOB_DIR/$scene.applog" 2>&1 &
else
  MDV_TEST_INSTANCE=1 MDV_SKIP_WORKSPACE_RESTORE=1 MDV_UI_SCENE="$scene" \
    MDV_LSP_STATUS_FAKE="$LSP_FAKE" \
    "$APP" "$FILE" >"$JOB_DIR/$scene.applog" 2>&1 &
fi
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

# Capture only — the PIXEL EVAL runs on the HOST (scripts/vm-uitest.sh), which
# has Pillow; the VM's stock python3 does not, and we deliberately avoid
# installing deps on the shared VM. The agent's job is just to produce real
# Aqua-session pixels.
log "CAPTURED: $scene -> $PNG"

# AX tree read (out-of-process, while the app is still alive) — the semantic
# complement to pixels. Best-effort: needs the Accessibility TCC grant for the
# reader binary (System Settings → Privacy & Security → Accessibility). Without
# it ax-reader exits 4 (empty tree) and we just note it; the capture still
# passes. swiftc is on the VM; cache the compiled binary, rebuild if the source
# changed.
RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AX_SRC="$RUNNER_DIR/ax-reader.swift"
AX_BIN="$JOB_DIR/ax-reader"
if [ -f "$AX_SRC" ]; then
  if [ ! -x "$AX_BIN" ] || [ "$AX_SRC" -nt "$AX_BIN" ]; then
    swiftc -O "$AX_SRC" -o "$AX_BIN" 2>>"$RESULT" || log "ax: compile failed"
  fi
  if [ -x "$AX_BIN" ]; then
    if "$AX_BIN" com.markdownviewer.MarkdownViewer > "$JOB_DIR/$scene.ax" 2>>"$RESULT"; then
      log "ax: $(grep -c . "$JOB_DIR/$scene.ax" 2>/dev/null || echo 0) identifiers -> $scene.ax"
    else
      log "ax: read failed (rc=$?) — Accessibility not granted? (grant the reader binary)"
    fi
  fi
fi

mv "$RESULT" "$JOB_DIR/$scene.result"
: > "$JOB_DIR/done"
exit 0
