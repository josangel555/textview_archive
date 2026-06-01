#!/usr/bin/env bash
# heap-dump.sh — show EXACTLY what lives in the app's heap for a scenario, so
# per-file / per-tab memory is attributed to concrete object types + malloc
# blocks, not guessed. Native tools only (heap / vmmap / footprint; optional
# malloc_history with stack logging). No external deps.
#
# Usage:
#   bash scripts/heap-dump.sh                       # 1 source file (per-tab cost)
#   bash scripts/heap-dump.sh -- doc.md             # a rendered-markdown tab
#   STACKS=1 bash scripts/heap-dump.sh -- a.swift   # also capture alloc stacks
#                                                     for the biggest malloc bucket
#   MDV_APP=dist/TextView.app bash scripts/heap-dump.sh
#
# Output: footprint, the heap class histogram (top by total bytes), the vmmap
# region summary, and (STACKS=1) malloc_history for the largest allocations.
set -uo pipefail
ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
APP="${MDV_APP:-/Applications/TextView.app}"; [[ "$APP" != /* ]] && APP="$ROOT_DIR/$APP"
EXEC="$APP/Contents/MacOS/MarkdownViewer"
SETTLE="${SETTLE:-7}"
[[ -x "$EXEC" ]] || { echo "FATAL: no exec at $EXEC" >&2; exit 1; }

# args after `--` are files to open; default = one ~10 KB source file
FILES=(); seen=0
for a in "$@"; do [[ "$a" == "--" ]] && { seen=1; continue; }; [[ $seen == 1 ]] && FILES+=("$a"); done
FIX="$(mktemp -d "${TMPDIR:-/tmp}/mdv-heap.XXXXXX")"; trap 'rm -rf "$FIX"' EXIT
if [[ ${#FILES[@]} -eq 0 ]]; then
  python3 - "$FIX" <<'PY'
import sys,os
open(os.path.join(sys.argv[1],"a.swift"),"w").write(
  "import Foundation\n"+"\n".join(f"func f{i}(_ x:Int)->Int{{x*{i}+{i*i}}}" for i in range(220))+"\n")
PY
  FILES=("$FIX/a.swift")
fi
echo "fixture(s): ${FILES[*]}  ($(wc -c < "${FILES[0]}" 2>/dev/null || echo '?') bytes first file)"

ENVV=(MDV_BACKGROUND=1 MDV_SKIP_WORKSPACE_RESTORE=1)
[[ "${STACKS:-0}" == "1" ]] && ENVV+=(MallocStackLogging=1)
env "${ENVV[@]}" "$EXEC" "${FILES[@]}" >/dev/null 2>&1 &
PID=$!
sleep "$SETTLE"
kill -0 "$PID" 2>/dev/null || { echo "process exited early"; exit 1; }

echo; echo "=== footprint ==="
footprint "$PID" 2>/dev/null | grep -iE 'phys_footprint|footprint \(peak\)' | head -3

echo; echo "=== heap: live objects, top buckets by total size ==="
HEAP="$FIX/heap.txt"; heap "$PID" >"$HEAP" 2>/dev/null || echo "(heap failed — task access?)"
# summary line + the largest class/bucket rows (heap already sorts by size)
sed -n '1,8p' "$HEAP"
echo "  --- top object/bucket rows ---"
grep -E '^\s*[0-9]' "$HEAP" | head -40

echo; echo "=== vmmap --summary: top dirty regions ==="
vmmap --summary "$PID" 2>/dev/null | sed -n '/REGION TYPE/,/^$/p' | sort -t= -k1 | head -30

if [[ "${STACKS:-0}" == "1" ]]; then
  echo; echo "=== malloc_history: allocation stacks for the largest MALLOC region ==="
  echo "(run manually for a specific address from vmmap: malloc_history $PID <addr>)"
  malloc_history "$PID" -allBySize 2>/dev/null | sed -n '1,40p' || echo "(needs MallocStackLogging=1; relaunch with STACKS=1)"
fi

kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
echo; echo "Done. Read 'heap' rows as: <count> <total-bytes> <class/bucket>. Big anonymous"
echo "MALLOC_* buckets = our raw allocations (attributed strings / parse trees / caches)."
