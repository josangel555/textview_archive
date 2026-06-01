#!/usr/bin/env bash
# flamegraph.sh — capture a CPU flame graph of app launch + an operation, using
# only native tools (`sample`), rendered to a self-contained browser-viewable SVG
# (via scripts/lib/sample_flamegraph.py — dep-free) plus a .folded file.
#
# Usage:
#   bash scripts/flamegraph.sh                       # launch + open a source file, 4s
#   bash scripts/flamegraph.sh -- doc.md             # profile opening a markdown
#   DUR=6 bash scripts/flamegraph.sh                 # longer sample window
#   OUT=/tmp/fg.svg bash scripts/flamegraph.sh
#
# For the RICHEST interactive view (true launch profiling, per-thread, GPU), use
# Instruments instead — no custom code:
#   xctrace record --template 'Time Profiler' --launch -- \
#     /Applications/TextView.app/Contents/MacOS/MarkdownViewer <files>
#   open <result>.trace      # Xcode 16 Instruments has a native flame-graph view
set -uo pipefail
ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
APP="${MDV_APP:-/Applications/TextView.app}"; [[ "$APP" != /* ]] && APP="$ROOT_DIR/$APP"
EXEC="$APP/Contents/MacOS/MarkdownViewer"
DUR="${DUR:-4}"; OUT="${OUT:-/tmp/mdv-flamegraph.svg}"
[[ -x "$EXEC" ]] || { echo "FATAL: no exec at $EXEC" >&2; exit 1; }

FILES=(); seen=0
for a in "$@"; do [[ "$a" == "--" ]] && { seen=1; continue; }; [[ $seen == 1 ]] && FILES+=("$a"); done
FIX="$(mktemp -d "${TMPDIR:-/tmp}/mdv-fg.XXXXXX")"; trap 'rm -rf "$FIX"' EXIT
if [[ ${#FILES[@]} -eq 0 ]]; then
  python3 - "$FIX" <<'PY'
import sys,os
open(os.path.join(sys.argv[1],"a.swift"),"w").write(
  "import Foundation\n"+"\n".join(f"func f{i}(_ x:Int)->Int{{x*{i}+{i*i}}}" for i in range(400))+"\n")
PY
  FILES=("$FIX/a.swift")
fi

RAW="$FIX/sample.txt"
echo "launching + sampling ${DUR}s (launch + open: ${FILES[*]##*/})…"
MDV_BACKGROUND=1 MDV_SKIP_WORKSPACE_RESTORE=1 "$EXEC" "${FILES[@]}" >/dev/null 2>&1 &
PID=$!
# start sampling immediately so we catch launch + the open/highlight work
sample "$PID" "$DUR" -file "$RAW" >/dev/null 2>&1 || { echo "sample failed (task access?)"; kill "$PID" 2>/dev/null; exit 1; }
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null

python3 "$ROOT_DIR/scripts/lib/sample_flamegraph.py" "$RAW" "$OUT" "MarkdownViewer launch+open"
echo "flame graph: $OUT   (open in a browser)"
echo "folded stacks: $OUT.folded   (top self-time:)"
sort -k2 -nr -t' ' "$OUT.folded" 2>/dev/null | head -12 | sed 's/^/  /' || true
