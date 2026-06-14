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

# TSK-846: the gate builds with --disable-index-store (index store OFF) while
# interactive `swift build`/`swift test` default to --auto-index-store (ON).
# The index-store flag is part of SwiftPM's build-plan hash, so sharing one
# `.build` between the two incompatible plans forced a full ~63s test-target
# rebuild on EVERY gate<->interactive switch (both directions) — the 63s thrash
# dwarfed the ~14s cold saving TSK-832 bought. Giving the gate its OWN scratch
# dir keeps the index-off speed AND leaves the owner's warm interactive `.build`
# untouched. Costs ~2GB disk for `.build-gate` (gitignored) + one cold seed.
GATE_SCRATCH="${MDV_GATE_SCRATCH:-$ROOT_DIR/.build-gate}"

log() { printf "==> %s\n" "$*"; }

# Start clean: a stale sentinel from a previous run must not fail this one.
rm -f "$SENTINEL"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  # The RustCore target static-links libmdvcore_ffi.a; it must exist before
  # any `swift build` (incl. --build-tests) or the link fails. build-app.sh
  # does this too; the gate needs it independently for a fresh checkout / CI.
  log "build Rust core (mdvcore staticlib) — required for the RustCore static link"
  bash "$SCRIPT_DIR/build-rust-core.sh"
  # TSK-855: RemoteTransportLoopbackTests spawns the REAL mdv-serve binary to
  # prove the engine surface is byte-equal local-FFI vs remote. build-rust-core.sh
  # builds ONLY the dist FFI staticlib — NOT the serve bin — so without this the
  # suite ran against a possibly days-stale mdv-serve (false RED on a wire change
  # that rebuilt the FFI but not serve; worse, a false PASS for a wire change that
  # didn't break decode, silently defeating the loopback's whole point). Build it
  # fresh into the exact debug path the test's fallback resolves. Guarded on cargo
  # so no-toolchain hosts (the VM) keep self-skipping the loopback as before.
  if command -v cargo >/dev/null 2>&1; then
    log "cargo build -p mdvcore-serve — fresh loopback server (TSK-855)"
    CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/private/tmp/mdv-rust-target}" \
      cargo build --locked --manifest-path "$ROOT_DIR/rust-core/Cargo.toml" -p mdvcore-serve
  fi
  log "swift build --build-tests --scratch-path .build-gate --disable-index-store (compile the gate sweep)"
  swift build --build-tests --scratch-path "$GATE_SCRATCH" --disable-index-store
fi

log "MDV_HEADLESS_GATE=1 swift test --parallel --scratch-path .build-gate --disable-index-store  (headless tiers)"
# --disable-index-store (TSK-832): the CLI gate never reads the SourceKit index
# store, so skip emitting it — trims the build phase + ~244 MB of disk. The
# interactive `swift build` keeps the default --auto-index-store for the IDE.
# Pinned on BOTH the build (above) and test invocations + the shared
# --scratch-path (TSK-846): identical flags + a dedicated scratch dir mean the
# build phase's output is reused by `swift test` (no within-gate re-plan), and
# the gate never invalidates the interactive `.build`.
# Don't let a test failure abort the script before we report the tier verdict.
set +e
swift test --parallel --scratch-path "$GATE_SCRATCH" --disable-index-store
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
