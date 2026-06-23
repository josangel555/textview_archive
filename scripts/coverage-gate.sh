#!/usr/bin/env bash
# coverage-gate.sh — measure line coverage of the headless test sweep and
# (optionally) enforce per-target / overall thresholds.
#
# TSK-795: the project had no coverage measurement and no way to enforce it in
# the build. This script is the orchestration half (the threshold/attribution
# logic — the part that can silently rot — lives in scripts/coverage_gate.py,
# pinned by ViewerCoreTests.CoverageGateTests on the host).
#
# It runs the SAME headless tiers as scripts/test-headless-gate.sh, but with
# `--enable-code-coverage`, then uses the toolchain's `llvm-cov export` to emit
# the JSON the Python gate reads. Heavy T4/T5 tiers self-skip (no bundle / no
# GUI), so this measures the host-coverable surface — exactly the surface the
# merge gate protects.
#
# Coverage is OFF in the merge gate by default (it adds instrumentation
# overhead). This is a SEPARATE, opt-in / nightly artifact step. Default mode is
# REPORT-ONLY (min thresholds 0): it measures + prints + writes an artifact and
# always exits 0, so it can be wired in immediately without turning a merge red.
# Ratchet thresholds up via the env knobs once a baseline is known — see
# docs/TEST_COVERAGE_2026-06-19.md.
#
# Usage:
#   bash scripts/coverage-gate.sh                 # measure + report-only
#   MIN_TOTAL=70 bash scripts/coverage-gate.sh    # fail if overall < 70%
#   MIN_TARGET=60 INCLUDE_TARGETS="ViewerCore ViewerKit" \
#       bash scripts/coverage-gate.sh             # per-target gate, scoped
#   SKIP_BUILD=1 bash scripts/coverage-gate.sh    # reuse an existing build
#
# Env knobs:
#   MIN_TOTAL=PCT          overall line-coverage minimum (default 0)
#   MIN_TARGET=PCT         per-target minimum (default 0)
#   TARGET_OVERRIDES="A=80 B=60"   per-target overrides (space-separated)
#   INCLUDE_TARGETS="A B"  scope the per-target gate to these targets
#   COV_SCRATCH=PATH       SwiftPM scratch dir (default .build-cov)
#   COV_OUT=PATH           JSON artifact path (default .build-cov/coverage.json)
#
# Exit: 0 thresholds met / report-only; 2 a threshold missed; 3 no coverage data.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
cd "$ROOT_DIR"

COV_SCRATCH="${COV_SCRATCH:-$ROOT_DIR/.build-cov}"
COV_OUT="${COV_OUT:-$COV_SCRATCH/coverage.json}"
MIN_TOTAL="${MIN_TOTAL:-0}"
MIN_TARGET="${MIN_TARGET:-0}"

log() { printf "==> %s\n" "$*"; }

# Coverage instrumentation must NOT leak into the heavy tiers — keep the same
# headless posture as test-headless-gate.sh so no window ever opens.
export MDV_HEADLESS_GATE=1

# TSK-1246: the instrumented run emits one .profraw per test (~8900 → ~23GB) into
# COV_SCRATCH; on a near-full disk it ENOSPCs mid-run (hard enough to kill captured
# output). Fail fast with a clear message if free disk is below the threshold — a
# gate that can't MEASURE must SIGNAL (exit non-zero), not ENOSPC mid-run or
# silently pass. Reap the .profraw on exit so they don't pile up ~23GB across runs.
MIN_FREE_MB="${COV_MIN_FREE_MB:-35000}"
FREE_MB="$(df -m "$ROOT_DIR" 2>/dev/null | awk 'NR==2{print $4}')"
if [[ -n "$FREE_MB" && "$FREE_MB" -lt "$MIN_FREE_MB" ]]; then
  echo "coverage-gate: only ${FREE_MB}MB free (<${MIN_FREE_MB}MB needed for the ~23GB of instrumented .profraw) — refusing to run to avoid ENOSPC. Free disk or lower COV_MIN_FREE_MB." >&2
  exit 2
fi
trap 'find "$COV_SCRATCH" -name "*.profraw" -delete 2>/dev/null || true' EXIT

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  log "build Rust core (mdvcore staticlib) — required for the RustCore static link"
  bash "$SCRIPT_DIR/build-rust-core.sh"
fi

log "swift test --enable-code-coverage --parallel --scratch-path $COV_SCRATCH (headless tiers, instrumented)"
set +e
swift test --enable-code-coverage --parallel --scratch-path "$COV_SCRATCH"
TEST_RC=$?
set -e
if [[ $TEST_RC -ne 0 ]]; then
  # TSK-1238: do NOT gate on this exit. `swift test --enable-code-coverage
  # --parallel` exits non-zero on a benign coverage+parallel trigger even when
  # no test failed; the HEADLESS GATE (scripts/test-headless-gate.sh) is the
  # pass/fail authority. coverage-gate's job is to MEASURE coverage and gate on
  # the COVERAGE THRESHOLD (coverage_gate.py below) — so note the exit and
  # continue to measurement instead of failing here (matches the script's own
  # "non-gating by default" contract; gating on TEST_RC made it exit 3 on
  # essentially every run, same root cause as the coverage.sh defect TSK-1233).
  log "note: instrumented swift test exited $TEST_RC (benign coverage+parallel trigger; pass/fail is the headless gate's authority) — measuring coverage anyway"
fi

# `swift test --enable-code-coverage` writes a merged .profdata under
# <scratch>/<arch>-apple-macosx/debug/codecov/default.profdata. The
# `swift test --show-codecov-path` flag prints the canonical location for the
# toolchain in use — prefer it over hand-building the path so an arch/layout
# change doesn't break us.
log "locate merged profdata + test bundle"
PROFDATA="$(swift test --enable-code-coverage --scratch-path "$COV_SCRATCH" --show-codecov-path 2>/dev/null || true)"
if [[ -z "$PROFDATA" || ! -f "$PROFDATA" ]]; then
  # Fallback: find it ourselves.
  PROFDATA="$(find "$COV_SCRATCH" -name 'default.profdata' -path '*codecov*' 2>/dev/null | head -1)"
fi
if [[ -z "$PROFDATA" || ! -f "$PROFDATA" ]]; then
  # TSK-1238: SwiftPM only auto-merges default.profdata on a 0-exit, but the
  # instrumented --parallel run exits non-zero (benign), so it's usually absent.
  # Merge the raw .profraw ourselves — same fallback coverage.sh uses (TSK-1233):
  #  - `-f <listfile>` (NOT argv): a full run leaves 6000-9000 .profraw and the
  #    expanded argv blows ARG_MAX (silently merged nothing before the -f fix).
  #  - `--failure-mode=warn`: the non-zero-exit run leaves CORRUPT partial
  #    .profraw; warn-mode skips them instead of aborting the whole merge.
  log "default.profdata absent (expected on the non-zero coverage run) — manual llvm-profdata merge"
  RAWS_LIST="$(mktemp -t mdv-gate-profraws.XXXXXX)"
  find "$COV_SCRATCH" -name '*.profraw' 2>/dev/null > "$RAWS_LIST"
  if [[ -s "$RAWS_LIST" ]]; then
    MERGED="$COV_SCRATCH/mdv-coverage-gate.profdata"
    xcrun llvm-profdata merge -sparse --failure-mode=warn -f "$RAWS_LIST" -o "$MERGED" 2>/dev/null || true
    if [[ -f "$MERGED" ]]; then
      PROFDATA="$MERGED"
      log "manual-merged profdata: $PROFDATA ($(grep -c . "$RAWS_LIST") profraw inputs)"
    fi
  fi
  rm -f "$RAWS_LIST"
fi
if [[ -z "$PROFDATA" || ! -f "$PROFDATA" ]]; then
  echo "coverage-gate: could not locate or merge default.profdata under $COV_SCRATCH" >&2
  exit 3
fi
log "profdata: $PROFDATA"

# The instrumented binary llvm-cov reads regions from: the xctest bundle's
# loaded executable. SwiftPM links one PackageTests bundle; point llvm-cov at
# its Mach-O. (There can be multiple test bundles; pass them all as -object.)
BIN_ARGS=()
while IFS= read -r b; do
  BIN_ARGS+=("-object" "$b")
done < <(find "$COV_SCRATCH" -type f -path '*.xctest/Contents/MacOS/*' -not -path '*.dSYM/*' 2>/dev/null)
if [[ ${#BIN_ARGS[@]} -eq 0 ]]; then
  echo "coverage-gate: no .xctest test binary found under $COV_SCRATCH" >&2
  exit 3
fi

# Use the toolchain's llvm-cov (xcrun resolves the active Xcode's copy).
LLVM_COV="$(xcrun --find llvm-cov 2>/dev/null || echo llvm-cov)"

mkdir -p "$(dirname "$COV_OUT")"
log "llvm-cov export → $COV_OUT (line-coverage JSON)"
# -ignore-filename-regex drops out-of-tree dependency checkouts, the .build
# tree, and test sources themselves — we gate the SHIPPING Sources/ surface.
"$LLVM_COV" export \
  -instr-profile="$PROFDATA" \
  -ignore-filename-regex='(/\.build|/Tests/|/checkouts/)' \
  "${BIN_ARGS[@]}" \
  > "$COV_OUT"

# Assemble the Python gate args from the env knobs.
GATE_ARGS=(--min-total "$MIN_TOTAL" --min-target "$MIN_TARGET" --json-out "${COV_OUT%.json}.summary.json")
for ov in ${TARGET_OVERRIDES:-}; do
  GATE_ARGS+=(--target "$ov")
done
for t in ${INCLUDE_TARGETS:-}; do
  GATE_ARGS+=(--include-target "$t")
done

log "coverage_gate.py ${GATE_ARGS[*]}"
set +e
python3 "$SCRIPT_DIR/coverage_gate.py" "$COV_OUT" "${GATE_ARGS[@]}"
GATE_RC=$?
set -e

if [[ $GATE_RC -eq 0 ]]; then
  log "coverage gate PASSED (artifact: $COV_OUT)"
fi
exit "$GATE_RC"
