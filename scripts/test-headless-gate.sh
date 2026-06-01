#!/usr/bin/env bash
# Headless-first merge/PR gate.
#
# Runs the HEADLESS test tiers — the whole bare `swift test` sweep, which now
# completes on a host with no `dist/TextView.app` and no WindowServer GUI
# session:
#   - ViewerKitTests          (T1 value/type tests)
#   - ViewerCoreTests         (T1/T1m pure-logic + model tests)
#   - ViewerUITests           the HeadlessUITestCase-based (T1/T1m/T2') suites
#
# The heavy tiers self-skip in this environment and therefore do NOT run their
# bodies here:
#   - LiveAppTestCase  (T4) — XCTSkips because dist/TextView.app isn't built
#   - PixelTestCase    (T5) — XCTSkips (no app + no Screen-Recording grant)
# They run for real in the SEPARATE VM / nightly lane (scripts/test-in-vm.sh),
# gated by a built bundle + MDV_RUN_WEBVIEW_TESTS for the WKWebView suites.
#
# TIER ENFORCEMENT (so "headless" can't silently regress):
#   We arm `MDV_HEADLESS_GATE=1`. The in-process `TierGateObserver`
#   (Tests/ViewerUITests/Harness/TierGateObserver.swift) then watches every
#   test and, for any LiveAppTestCase/PixelTestCase *subclass* that RUNS its
#   body instead of skipping, appends the test name to the sentinel file. After
#   the sweep we fail the gate if the sentinel is non-empty. Tier is the type,
#   the type is checked at runtime — a new heavy test that forgets its skip
#   guard, or is mis-filed under the wrong base, turns this gate red.
#
# Usage:
#   bash scripts/test-headless-gate.sh            # build-tests + gate sweep
#   SKIP_BUILD=1 bash scripts/test-headless-gate.sh   # assume already built
#
# Exit non-zero on: any test failure OR any heavy-tier gate violation.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
cd "$ROOT_DIR"

SENTINEL="${MDV_HEADLESS_GATE_SENTINEL:-${TMPDIR:-/tmp}/mdv-headless-gate-violations.txt}"
export MDV_HEADLESS_GATE_SENTINEL="$SENTINEL"
export MDV_HEADLESS_GATE=1

log() { printf "==> %s\n" "$*"; }

# Start clean: a stale sentinel from a previous run must not fail this one.
rm -f "$SENTINEL"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  log "swift build --build-tests (compile the gate sweep)"
  swift build --build-tests
fi

log "MDV_HEADLESS_GATE=1 swift test --parallel  (headless tiers)"
# Don't let a test failure abort the script before we report the tier verdict.
set +e
swift test --parallel
TEST_RC=$?
set -e

# Tier verdict: the observer wrote the sentinel iff a heavy-tier test ran its
# body. (No file / empty file == clean.)
GATE_RC=0
if [[ -s "$SENTINEL" ]]; then
  echo ""
  echo "============================================================"
  echo "HEADLESS GATE FAILED — heavy-tier test(s) ran in the gate:"
  sed 's/^/  - /' "$SENTINEL"
  echo ""
  echo "LiveAppTestCase (T4) / PixelTestCase (T5) descendants must skip"
  echo "in the headless gate (no app bundle, no WindowServer) and run in"
  echo "the VM / nightly lane instead. Fix the test's skip guard, or move"
  echo "it under the correct tier base class. See"
  echo "Tests/ViewerUITests/Harness/TierBaseCases.swift."
  echo "============================================================"
  GATE_RC=1
else
  log "tier enforcement: OK — no heavy-tier test ran in the gate"
fi

if [[ $TEST_RC -ne 0 ]]; then
  log "FAILED: swift test exited $TEST_RC"
  exit "$TEST_RC"
fi
if [[ $GATE_RC -ne 0 ]]; then
  exit "$GATE_RC"
fi

log "headless gate PASSED"
