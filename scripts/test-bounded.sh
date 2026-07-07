#!/bin/bash
# TSK-1194 — resource-bounded command execution: kill the runaway, not the host.
#
# Runs a command (default: swift test) under a MEMORY ceiling and a WALL-CLOCK
# deadline, watching the whole process TREE. macOS has no cgroups and ulimit -v
# is unreliable for real allocations, so this is a watchdog: poll the tree's
# aggregate RSS every 1s; over-budget or over-deadline → TERM, then KILL.
# NOTE the ceiling is a KILL trigger, not a hard cap: an extreme allocator
# (GBs/sec) can overshoot between polls before dying — fine for the target
# failure mode (tests that grow to tens of GB over minutes).
# Reports the peak observed footprint either way. Motivating incident: an
# O(n*m) LineDiff test reached ~77 GB phys_footprint + 25 GB swap.
#
# Usage:
#   bash scripts/test-bounded.sh [--mem-mb N] [--timeout-s N] [-- cmd args...]
#   bash scripts/test-bounded.sh --self-test
# Defaults: 12288 MB, 1800 s, `swift test`.
set -u

MEM_MB=12288
TIMEOUT_S=1800
SELF_TEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mem-mb)    MEM_MB="$2"; shift 2 ;;
    --timeout-s) TIMEOUT_S="$2"; shift 2 ;;
    --self-test) SELF_TEST=1; shift ;;
    --)          shift; break ;;
    *)           break ;;
  esac
done

if [ "$SELF_TEST" = "1" ]; then
  # A deliberate hog: grow a python list until killed. The wrapper must kill
  # it at ~256 MB and exit non-zero with a MEM-KILL report.
  exec bash "$0" --mem-mb 256 --timeout-s 60 -- \
    python3 -c 'b = []
while True:
    b.append(bytearray(8 * 1024 * 1024))'
fi

CMD=("$@")
[ ${#CMD[@]} -eq 0 ] && CMD=(swift test)

"${CMD[@]}" &
ROOT_PID=$!
START=$(date +%s)
PEAK_KB=0
VERDICT="OK"

# Aggregate RSS (KB) of ROOT_PID and every descendant.
tree_rss_kb() {
  local pids="$ROOT_PID" frontier="$ROOT_PID" children
  while true; do
    children=$(pgrep -P "${frontier// /,}" 2>/dev/null | tr '\n' ' ')
    [ -z "${children// /}" ] && break
    pids="$pids $children"
    frontier="${children}"
  done
  # shellcheck disable=SC2086
  ps -o rss= -p ${pids// /,} 2>/dev/null | awk '{s+=$1} END {print s+0}'
}

while kill -0 "$ROOT_PID" 2>/dev/null; do
  RSS_KB=$(tree_rss_kb)
  [ "$RSS_KB" -gt "$PEAK_KB" ] && PEAK_KB=$RSS_KB
  NOW=$(date +%s)
  if [ "$RSS_KB" -gt $((MEM_MB * 1024)) ]; then
    VERDICT="MEM-KILL (${MEM_MB}MB ceiling)"
  elif [ $((NOW - START)) -gt "$TIMEOUT_S" ]; then
    VERDICT="TIMEOUT-KILL (${TIMEOUT_S}s deadline)"
  fi
  if [ "$VERDICT" != "OK" ]; then
    # TERM the whole tree (leader first), escalate to KILL.
    pkill -TERM -P "$ROOT_PID" 2>/dev/null
    kill -TERM "$ROOT_PID" 2>/dev/null
    sleep 3
    pkill -KILL -P "$ROOT_PID" 2>/dev/null
    kill -KILL "$ROOT_PID" 2>/dev/null
    break
  fi
  sleep 1
done

wait "$ROOT_PID" 2>/dev/null
RC=$?
ELAPSED=$(( $(date +%s) - START ))
echo "== bounded-run report =="
echo "   verdict:  $VERDICT"
echo "   peak rss: $((PEAK_KB / 1024)) MB (tree aggregate; ceiling ${MEM_MB} MB)"
echo "   elapsed:  ${ELAPSED}s (deadline ${TIMEOUT_S}s)"
echo "   exit:     $RC"
if [ "$VERDICT" != "OK" ]; then
  exit 137
fi
exit "$RC"
