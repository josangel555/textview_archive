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

echo "==> swift test --parallel (headless; heavy tiers self-skip) — capturing per-case timings…" >&2
# Mirror the merge gate so heavy tiers skip; tee to a file we then aggregate.
# `|| true` so a red test still yields a timing report (we want timings either way).
MDV_HEADLESS_GATE=1 swift test --parallel >"$OUT" 2>&1 || true

python3 "$SCRIPT_DIR/test-timings.py" "$OUT" "$TOP_N"
