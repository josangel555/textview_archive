#!/usr/bin/env bash
# vm-diagnose.sh — run the app's --diagnose view-tree dump INSIDE the UTM
# VM's GUI session for a given MDV_UI_SCENE, and pull the JSON to the host.
#
# WHY (TSK-493): the realized-NSView-tree dump is the cheap arbiter for
# "is this a layout bug or a draw bug" — it carries every NSView's actual
# frame. Scenes apply after a delay, so the dump is sequenced AFTER the
# scene via MDV_DIAGNOSE_DELAY (TSK-493 plumbing in main.swift). Runs
# under the launchctl-asuser bridge (vm-smoke.sh pattern) because the
# window must realize in a real GUI session.
#
# Usage: bash scripts/vm-diagnose.sh [scene] [file-rel-to-vm-repo]
#        (defaults: terminal-left, DESIGN.md)
# Output: /tmp/mdv-diagnose.json on the HOST.
#
# PRE-REQ: dist/TextView.app built on the VM (bash scripts/test-in-vm.sh build).
set -euo pipefail

SCENE="${1:-terminal-left}"
FILE_REL="${2:-DESIGN.md}"
PASSWORD="${MDV_VM_SUDO_PASSWORD:-<vm-sudo-password>}"
GUI_UID=501
OUT="/tmp/mdv-diagnose.json"

# Strict allowlist on the scene token — it is interpolated into the remote
# inner sh environment (same defensive posture as vm-smoke.sh's path arg).
if [[ ! "$SCENE" =~ ^[a-z0-9-]+$ ]]; then
  echo "Error: scene must match ^[a-z0-9-]+\$: $SCENE" >&2
  exit 2
fi

echo "==> Diagnose dump on VM: scene=$SCENE file=$FILE_REL"
# Quoted heredoc: nothing host-side expands inside. Untrusted-ish values
# travel as positional args into the remote shell, then into the inner sh.
ssh macOS15 'bash -s' -- "$PASSWORD" "$GUI_UID" "$SCENE" "$FILE_REL" <<'REMOTE'
  set -e
  PASSWORD="$1"; GUI_UID="$2"; SCENE="$3"; FILE_REL="$4"
  rm -f /tmp/mdv-diagnose.json /tmp/mdv-diagnose.err
  # asuser drops env passed via /usr/bin/env but keeps env set INSIDE the
  # spawned sh. Scene applies at +0.3s; dump fires at +2.0s — strictly after.
  echo "$PASSWORD" | sudo -S launchctl asuser "$GUI_UID" /bin/sh -c '
    cd /Users/vm-tester/markdown_viewer &&
    MDV_SKIP_WORKSPACE_RESTORE=1 \
    MDV_TEST_INSTANCE=1 \
    MDV_UI_SCENE="$1" \
    MDV_UI_SCENE_DELAY=0.3 \
    MDV_DIAGNOSE_DELAY=2.0 \
    dist/TextView.app/Contents/MacOS/MarkdownViewer --diagnose "$2" \
      > /tmp/mdv-diagnose.json 2> /tmp/mdv-diagnose.err
  ' _ "$SCENE" "$FILE_REL" || true
  echo "--- stderr (scene log expected here):"
  cat /tmp/mdv-diagnose.err || true
  ls -l /tmp/mdv-diagnose.json
REMOTE

echo "==> Pull JSON back to host"
scp -q macOS15:/tmp/mdv-diagnose.json "$OUT"
echo "==> Done: $OUT ($(wc -c < "$OUT") bytes)"
