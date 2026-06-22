#!/usr/bin/env bash
# TSK-1131 — non-gating code-coverage report.
#
# Nothing measured coverage before this (TSK-788 G1 audit gap). This runs the
# host test suite with LLVM coverage instrumentation and prints an `llvm-cov`
# summary over Sources/ (excluding Tests/ and .build/). It is INFORMATIONAL —
# always exits 0 — so it never gates a merge; wire it into a nightly/manual run.
#
# Usage:  FILTER=ViewerCoreTests bash scripts/coverage.sh   # scope a target (RECOMMENDED)
#         bash scripts/coverage.sh                          # full suite — resource-heavy
#
# NOTE: prefer scoping with FILTER. The unscoped `--parallel` run over the whole
# suite spawns thousands of per-test `.profraw` and, under load / a flaky perf-bench
# failure, SwiftPM skips the profdata merge and leaves corrupt partials (the report
# then can't be produced). A scoped run completes cleanly and reports reliably.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 0

echo "==> swift test --enable-code-coverage ${FILTER:+(filter: $FILTER)} — runs the suite…"
# NB: expand no array under `set -u` — macOS bash 3.2 errors on "${empty[@]}".
if [ -n "${FILTER:-}" ]; then
    swift test --parallel --enable-code-coverage --filter "$FILTER" >/tmp/mdv-coverage-test.log 2>&1
else
    swift test --parallel --enable-code-coverage >/tmp/mdv-coverage-test.log 2>&1
fi
test_status=$?
tail -3 /tmp/mdv-coverage-test.log
[ "$test_status" -ne 0 ] && echo "   (swift test exited $test_status — often the benign coverage+--parallel non-zero exit, NOT a real test failure (TSK-1233); the headless gate is the failure authority. Coverage still computed below via the manual-merge fallback.)"

bin="$(swift build --show-bin-path 2>/dev/null)"
prof="$bin/codecov/default.profdata"
xctest="$(/usr/bin/find "$bin" -maxdepth 1 -name '*.xctest' 2>/dev/null | head -1)"
exec_bin=""
[ -n "$xctest" ] && exec_bin="$xctest/Contents/MacOS/$(basename "$xctest" .xctest)"

# Manual profdata merge fallback (TSK-1233). SwiftPM auto-merges the per-test
# .profraw into codecov/default.profdata ONLY when the run exits 0; the full
# --parallel coverage run exits non-zero (a ViewerUITests-specific trigger under
# coverage+parallel — NO test actually fails; the headless gate is green), so it
# skips the merge and no report can generate. The .profraw files survive, so when
# the auto-merged profdata is missing we merge them ourselves.
if [ ! -f "$prof" ] && [ -n "$bin" ]; then
  raws_list="$(mktemp -t mdv-profraws.XXXXXX)"
  /usr/bin/find "$bin" -name '*.profraw' 2>/dev/null > "$raws_list"
  n="$(grep -c . "$raws_list" 2>/dev/null || echo 0)"
  if [ "$n" -gt 0 ]; then
    echo "==> SwiftPM skipped its auto-merge; merging $n surviving .profraw manually (TSK-1233)…"
    mkdir -p "$(dirname "$prof")"
    # Two non-obvious requirements (both verified the hard way, TSK-1233):
    #  - `-f <listfile>`, NOT argv: a full run leaves 6000-9000 .profraw and the
    #    argv form blows past ARG_MAX (merges nothing, exits 0 — silent).
    #  - `--failure-mode=warn`: the non-zero-exit run leaves CORRUPT partial
    #    .profraw ("file header is corrupt"); the default mode aborts the whole
    #    merge ("no profile can be merged") on the first bad input. warn skips the
    #    bad ones and merges the good ones.
    xcrun llvm-profdata merge -sparse --failure-mode=warn -f "$raws_list" -o "$prof" 2>/dev/null || true
    if [ -f "$prof" ]; then
      echo "    merged → $prof"
    else
      echo "    llvm-profdata merge produced no profdata (all inputs unreadable?)"
    fi
  fi
  rm -f "$raws_list"
fi

if [ -f "$prof" ] && [ -n "$exec_bin" ] && [ -f "$exec_bin" ]; then
  echo "==> coverage summary (Sources/ only):"
  xcrun llvm-cov report "$exec_bin" -instr-profile "$prof" \
    -ignore-filename-regex='(/Tests/|/\.build/|/checkouts/)' 2>/dev/null \
    | tail -45
else
  echo "coverage data not found — prof=$prof exec=$exec_bin"
  echo "(SwiftPM writes default.profdata under \`swift build --show-bin-path\`/codecov after --enable-code-coverage)"
fi
exit 0
