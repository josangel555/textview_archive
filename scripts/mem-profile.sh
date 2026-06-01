#!/usr/bin/env bash
# mem-profile.sh — reproducible memory accounting for TextView.app.
#
# Launches the built app with a fixed set of fixture files, waits for the
# process to reach steady state, and captures the REAL resident numbers with
# native tools — phys_footprint (Apple's "the number that matters"), the
# vmmap region summary, and the RSS of the WebKit XPC helpers — so every
# scenario's memory is attributable to: our heap vs the WebKit floor vs the OS.
#
# It runs several scenarios so the load-bearing question is answered directly:
#   base          — no files (the empty-app floor; mostly Swift/AppKit runtime)
#   two-source    — 2 plain source files (NSTextView; NO WebKit) → if this is
#                   ~120 MB, that's a REGRESSION in our heap, not WebKit
#   md-plus-src   — 1 rendered-markdown + 1 source (pulls in the WebKit floor +
#                   one WebContent) → ~120 MB here is roughly in-envelope
#   db            — a tiny (~8 KB) SQLite file (the slow-open report)
#
# WHY THIS IS THE REPRODUCIBLE PATH (the SOP):
#   - footprint reads phys_footprint, the same accounting the OS uses for the
#     memory-pressure / jetsam limit — not the misleading Activity-Monitor sum.
#   - Fixtures are generated deterministically here, so the run is hermetic and
#     CI-able (no dependence on whatever the user happened to have open).
#   - MDV_SKIP_WORKSPACE_RESTORE=1 → a clean launch (no prior session restored).
#   - MDV_BACKGROUND=1 → the app does not steal focus (test-env convention).
#
# LIMITATION: footprint/vmmap need task access to the target. A locally-signed
# build WITHOUT the get-task-allow entitlement (hardened runtime) blocks them;
# this script reports that clearly and the SOP's fallback is the in-app
# `--mem-report` probe (task_vm_info from inside the process — always works,
# and is the CI/smoke-grade mechanism).
#
# Usage:
#   bash scripts/mem-profile.sh                 # all scenarios, /Applications build
#   MDV_APP=dist/TextView.app bash scripts/mem-profile.sh
#   SETTLE=10 bash scripts/mem-profile.sh       # longer steady-state wait
#   bash scripts/mem-profile.sh base two-source # only the named scenarios

set -uo pipefail

ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
APP="${MDV_APP:-/Applications/TextView.app}"
[[ "$APP" != /* ]] && APP="$ROOT_DIR/$APP"
EXEC="$APP/Contents/MacOS/MarkdownViewer"
SETTLE="${SETTLE:-7}"

if [[ ! -x "$EXEC" ]]; then
  echo "FATAL: no executable at $EXEC (set MDV_APP, or run scripts/build-app.sh)" >&2
  exit 1
fi

FIX="$(mktemp -d "${TMPDIR:-/tmp}/mdv-mem.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

# --- deterministic fixtures ---------------------------------------------------
python3 - "$FIX" <<'PY'
import sys, os
d = sys.argv[1]
# a real source file (~few KB) so highlight/tree-sitter runs
open(os.path.join(d, "a.swift"), "w").write(
    "import Foundation\n\n" + "\n".join(
        f"func f{i}(_ x: Int) -> Int {{ return x * {i} + {i*i} }}" for i in range(120)) + "\n")
open(os.path.join(d, "b.swift"), "w").write(
    "\n".join(f"// line {i}: the quick brown fox jumps over the lazy dog" for i in range(400)) + "\n")
# a markdown file that renders in the WKWebView
open(os.path.join(d, "doc.md"), "w").write(
    "# Title\n\n" + "\n\n".join(f"## Section {i}\n\nSome **bold** and `code` and a list:\n\n- one\n- two\n- three"
    for i in range(40)) + "\n")
PY
# an ~8 KB SQLite db (matches the slow-open report) — best-effort
if command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$FIX/data.db" "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, val REAL);
    WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<200)
    INSERT INTO t(name,val) SELECT 'row'||i, i*1.5 FROM c;" 2>/dev/null
  echo "  fixture db size: $(stat -f%z "$FIX/data.db" 2>/dev/null || echo '?') bytes"
fi

declare -a SCN_NAMES=(base two-source md-plus-src db)
declare -a SCN_ARGS=("" "$FIX/a.swift $FIX/b.swift" "$FIX/doc.md $FIX/a.swift" "$FIX/data.db")

WANT=("$@"); [[ ${#WANT[@]} -eq 0 ]] && WANT=("${SCN_NAMES[@]}")

phys_of() { # $1=pid -> phys_footprint in MB (via footprint), or "n/a"
  local out; out="$(footprint "$1" 2>/dev/null)"
  echo "$out" | grep -ioE 'phys_footprint[^0-9]*[0-9.]+ ?[KMG]B' | head -1 \
    || echo "$out" | grep -iE 'footprint' | head -1 || echo "n/a"
}
webkit_rss_kb() { ps -axo rss,comm 2>/dev/null | awk '/WebKit\.(WebContent|GPU|Networking)/{s+=$1} END{print s+0}'; }

printf '\n%-14s %-12s %-12s %-14s\n' SCENARIO PHYS_FOOTPRINT VMMAP_TOTAL WEBKIT_HELPERS_KB
printf '%s\n' "------------------------------------------------------------------"
for name in "${WANT[@]}"; do
  idx=-1; for i in "${!SCN_NAMES[@]}"; do [[ "${SCN_NAMES[$i]}" == "$name" ]] && idx=$i; done
  [[ $idx -lt 0 ]] && { echo "  (unknown scenario: $name)"; continue; }
  wk_before="$(webkit_rss_kb)"
  # shellcheck disable=SC2086
  MDV_BACKGROUND=1 MDV_SKIP_WORKSPACE_RESTORE=1 "$EXEC" ${SCN_ARGS[$idx]} >/dev/null 2>&1 &
  PID=$!
  sleep "$SETTLE"
  if ! kill -0 "$PID" 2>/dev/null; then echo "  $name: process exited early"; continue; fi
  PHYS="$(phys_of "$PID")"
  VTOTAL="$(vmmap --summary "$PID" 2>/dev/null | grep -iE 'Physical footprint:' | head -1 | sed 's/.*: *//')"
  [[ -z "$VTOTAL" ]] && VTOTAL="$(vmmap --summary "$PID" 2>/dev/null | grep -iE '^TOTAL' | head -1 | awk '{print $2,$3}')"
  [[ -z "$VTOTAL" ]] && VTOTAL="(task access denied — hardened runtime? use --mem-report probe)"
  wk_after="$(webkit_rss_kb)"
  printf '%-14s %-12s %-12s %-14s\n' "$name" "${PHYS:-n/a}" "${VTOTAL:-n/a}" "$((wk_after - wk_before))"
  # detailed vmmap regions for the heaviest scenario (kept for the report)
  if [[ "$name" == "md-plus-src" || "$name" == "two-source" ]]; then
    echo "    --- vmmap --summary top regions ($name) ---"
    vmmap --summary "$PID" 2>/dev/null | sed -n '1,30p' | sed 's/^/    /'
  fi
  kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
  sleep 1
done
echo
echo "Notes: PHYS_FOOTPRINT is the real per-process number. WEBKIT_HELPERS_KB is"
echo "the RSS delta of WebKit XPC helpers during this scenario (shared, summed by"
echo "Activity Monitor under the app but NOT in our phys_footprint). 'two-source'"
echo "should carry NO WebKit; 'md-plus-src' should show the WebKit floor appear."
