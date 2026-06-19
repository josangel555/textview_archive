#!/usr/bin/env bash
# Perf-floor RATCHET lane for rust-core (audit TSK-588).
#
# Times the hot pure-logic paths the rust-core audit flagged (CSV arena parse,
# per-keystroke filter scan, in-file find, hex render, unified-diff parse) and
# ratchets each measurement against the PREVIOUS committed baseline:
#   rust-core/crates/serve/benches/perf_floor_baseline.txt
# A metric fails the lane only when it regresses past the tolerance (default
# +50%) — the synthesis (§5 #8) explicitly REJECTED criterion + absolute
# wall-clock thresholds; the ratchet is machine-load-proof in a way a fixed
# "< 5 ms" assert is not.
#
# This is NOT the merge gate. Wall-clock asserts are flaky under machine load
# (CLAUDE.md treats FoldBench/CrossFileSearchBench failures as flaky), so it
# runs on a dedicated GH-HOSTED RUNNER — the UTM VM has NO Rust toolchain, and
# the host merge gate (scripts/rust-core-gate.sh) stays clock-free. The RATCHET
# LOGIC, by contrast, IS host-unit-tested with teeth (mdvcore-core::bench), so a
# logic regression fails the ordinary merge gate even though wall-clock timing
# does not run there.
#
# Usage:
#   bash scripts/rust-perf-floor.sh             # compare vs committed baseline
#   bash scripts/rust-perf-floor.sh --update    # regenerate the baseline (commit the diff)
#   bash scripts/rust-perf-floor.sh --tolerance 0.75
#
# IMPORTANT — the committed baseline is machine-specific (absolute nanoseconds).
# The ratchet is meaningful run-over-run on the SAME runner: a fresh runner
# should `--update` once to capture its own floor, commit that, then ratchet
# subsequent runs against it. A first compare on a slower machine than the one
# that produced the committed seed may report a regression — re-run --update
# there. The diff IS the reviewable record of any intentional perf shift.
#
# Exit: 0 = no regression (or --update) · 1 = a metric regressed · 2 = build/IO error

set -euo pipefail
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
RUST_DIR="$ROOT_DIR/rust-core"

# Shared target dir OUTSIDE the worktree (worktree hygiene) — same cache as
# build-rust-core.sh / rust-core-gate.sh so the build is warm.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/private/tmp/mdv-rust-target}"

if ! command -v cargo >/dev/null 2>&1; then
  echo "ERROR: cargo not found on PATH. Install the Rust toolchain (rustup)." >&2
  exit 2
fi

# RELEASE build — the bench measures optimized code (the profile the app ships).
echo "==> cargo build --release -p mdvcore-serve --bin perf_floor"
cargo build --release --locked --manifest-path "$RUST_DIR/Cargo.toml" \
  -p mdvcore-serve --bin perf_floor

echo "==> perf_floor ratchet ($*)"
# The bin's DEFAULT --baseline path is workspace-root-relative, so run from the
# repo root; pass any extra args (--update / --tolerance) straight through.
cd "$ROOT_DIR"
"$CARGO_TARGET_DIR/release/perf_floor" "$@"
