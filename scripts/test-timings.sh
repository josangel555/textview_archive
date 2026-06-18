#!/usr/bin/env bash
# test-timings.sh — report the slowest swift-test CLASSES (TSK-836, capture half).
#
# Runs the host-safe headless sweep (MDV_HEADLESS_GATE=1 → heavy T4/T5 tiers
# self-skip, so NO window ever opens), captures the per-case
# "… passed (N seconds)." lines, and prints a per-class timing table
# (slowest first) via scripts/test-timings.py. Read-only: never edits product
# or test code — it's the measurement that tells you which classes to split
# or de-sleep (TSK-849/850).
#
#   bash scripts/test-timings.sh [top_n]   # classes to show (default 30; 0 = all)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP_N="${1:-30}"
OUT="$(mktemp -t mdv-test-timings.XXXXXX)"
trap 'rm -f "$OUT"' EXIT

# SERIAL (NOT --parallel) is REQUIRED: `swift test --parallel` uses swiftpm's
# progress reporter ("[N/M] Testing Class/method"), which omits per-case timing,
# and `--xunit-output` is broken on the host toolchain (writes no file). Only
# serial XCTest output carries the "Test Case … passed (N seconds)." lines that
# test-timings.py parses. Serial is SLOWER than the gate (no parallelism) — but
# this is an occasional measurement, not a merge gate, and serial per-case times
# are the cleaner "which class is heavy" signal anyway. MDV_HEADLESS_GATE=1 keeps
# heavy T4/T5 tiers self-skipping (no windows). `|| true` so a red test still
# yields a report. Tip: pass a `swift test --filter` subset for a faster run.
echo "==> swift test (SERIAL, headless; heavy tiers skip) — capturing per-case timings (slow)…" >&2
MDV_HEADLESS_GATE=1 swift test >"$OUT" 2>&1 || true

python3 "$SCRIPT_DIR/test-timings.py" "$OUT" "$TOP_N"
