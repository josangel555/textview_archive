#!/usr/bin/env bash
# TSK-1131 — non-gating code-coverage report.
#
# Nothing measured coverage before this (TSK-788 G1 audit gap). This runs the
# host test suite with LLVM coverage instrumentation and prints an `llvm-cov`
# summary over Sources/ (excluding Tests/ and .build/). It is INFORMATIONAL —
# always exits 0 — so it never gates a merge; wire it into a nightly/manual run.
#
# Usage:  bash scripts/coverage.sh            # full suite (slow)
#         FILTER=ViewerCoreTests bash scripts/coverage.sh   # scope a target
set -uo pipefail
cd "$(dirname "$0")/.." || exit 0

filter_args=()
[ -n "${FILTER:-}" ] && filter_args=(--filter "$FILTER")

echo "==> swift test --enable-code-coverage ${FILTER:+(filter: $FILTER)} — runs the suite…"
swift test --parallel --enable-code-coverage "${filter_args[@]}" >/tmp/mdv-coverage-test.log 2>&1
test_status=$?
tail -3 /tmp/mdv-coverage-test.log
[ "$test_status" -ne 0 ] && echo "   (tests reported failures — coverage below is still computed from what ran)"

bin="$(swift build --show-bin-path 2>/dev/null)"
prof="$bin/codecov/default.profdata"
xctest="$(/usr/bin/find "$bin" -maxdepth 1 -name '*.xctest' 2>/dev/null | head -1)"
exec_bin=""
[ -n "$xctest" ] && exec_bin="$xctest/Contents/MacOS/$(basename "$xctest" .xctest)"

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
