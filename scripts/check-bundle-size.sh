#!/usr/bin/env bash
# Bundle size guardrail. Fails the build when dist/TextView.app
# crosses a budget. Two checks:
#   - total .app size (default 40 MB)
#   - main executable size (default 20 MB)
#
# Caps bumped 37->40 / 18->20 (2026-05-31) for the Rust-core CSV integration.
# Two facts justified the bump, MEASURED this run:
#   1. The `main` release exec (NO Rust), stripped exactly like build-app.sh
#      (`strip -S`), was ALREADY 18.60 MB — the old 18 MB exec cap was stale
#      and `main` itself breached it (pre-existing drift, not this change).
#   2. Static-linking libmdvcore_ffi.a adds only ~0.36 MB to the exec
#      (18.60 -> ~18.96 MB) and ~0.3 MB to the bundle (measured 39 MB total).
# The 20 MB exec / 40 MB total caps cover the real baseline + the Rust core +
# modest headroom. The exec sub-cap still catches a TreeSitter grammar silently
# regressing to static linkage. NOTE: the Rust core is purely ADDITIVE at this
# beachhead (both Swift CSVParser AND the Rust core ship); the size recovers
# when Swift duplicates are deleted in a later migration phase.
# These two defaults are the single source of truth for the cap; the
# BUDGET_MB / EXEC_BUDGET_MB defaults below MUST match the numbers in
# this header and the comment in build-app.sh's tail block.
# The split matters because the lazy-grammar refactor moves grammar
# parsers from the executable into Contents/Frameworks/, so a healthy
# bundle has a small executable + larger Frameworks. A single total
# cap can't distinguish "grew because we added Frameworks" from "grew
# because we silently regressed to static-linking everything".
#
# Sourced from scripts/build-app.sh at the tail.
#
# Usage:
#   bash scripts/check-bundle-size.sh                       # defaults
#   bash scripts/check-bundle-size.sh 40                    # 40 MB total
#   BUDGET_MB=30 EXEC_BUDGET_MB=12 bash scripts/check-bundle-size.sh
#
# Exit: 0 = within budget, 2 = over budget.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
APP_DIR="$ROOT_DIR/dist/TextView.app"

BUDGET_MB="${BUDGET_MB:-${1:-40}}"
# Per-exec check defaults to 16 MB. The eager keeplist (JSON, Swift,
# Markdown) + everything-else-Swift-and-resources fits in ~11 MB
# release. The CodeMirror 6 editor (Swift wrapper + JS bridge code)
# bumped the executable by ~200 KB; CM6 itself is a JS resource
# (~570 KB) under Resources/codemirror/, not in the executable. The
# Headroom over the post-CM6 baseline catches a TreeSitter grammar
# silently regressing to static linkage (look for an unintended
# `import TreeSitter<X>` in ViewerCore). Bumped 16 -> 18 (2026-05-30):
# the shoulder-rails + large-file read-only + picker-fix work added
# ~140 KB of legitimate Swift to the exec (15.91 -> 16.05 MB),
# tipping the old 16 MB line; grammars remain dylibs in
# Contents/Frameworks/, so this is real code growth, not a
# static-link regression. Override via env to opt out:
#   EXEC_BUDGET_MB=0 bash scripts/check-bundle-size.sh
EXEC_BUDGET_MB="${EXEC_BUDGET_MB:-20}"
BUDGET_BYTES=$(( BUDGET_MB * 1024 * 1024 ))
EXEC_BUDGET_BYTES=$(( EXEC_BUDGET_MB * 1024 * 1024 ))

if [[ ! -d "$APP_DIR" ]]; then
  echo "Error: $APP_DIR not built. Run scripts/build-app.sh first." >&2
  exit 1
fi

# `du -sk` reports KB on macOS. Convert to bytes.
SIZE_KB=$(/usr/bin/du -sk "$APP_DIR" | awk '{print $1}')
SIZE_BYTES=$(( SIZE_KB * 1024 ))
SIZE_MB=$(( SIZE_KB / 1024 ))

# Main executable — typically Contents/MacOS/TextView (or whatever
# the bundle's CFBundleExecutable says). Grab the largest file under
# Contents/MacOS/ which is functionally the executable. If empty,
# skip the per-exec check (early-build state).
EXEC_PATH=$(/usr/bin/find "$APP_DIR/Contents/MacOS" -type f -depth 1 2>/dev/null | head -1 || true)
EXEC_BYTES=0
EXEC_MB=0
if [[ -n "$EXEC_PATH" ]]; then
  EXEC_BYTES=$(/usr/bin/stat -f%z "$EXEC_PATH" 2>/dev/null || echo 0)
  EXEC_MB=$(( EXEC_BYTES / 1024 / 1024 ))
fi

FAIL=0

if (( SIZE_BYTES > BUDGET_BYTES )); then
  echo
  echo "✗ Bundle size $SIZE_MB MB exceeds total budget of $BUDGET_MB MB."
  echo
  echo "  $APP_DIR"
  echo "  $SIZE_KB KB / $SIZE_BYTES bytes"
  echo
  echo "Find the bloat:"
  echo "  du -sh \"$APP_DIR\"/Contents/MacOS/*"
  echo "  du -sh \"$APP_DIR\"/Contents/Frameworks/* 2>/dev/null | sort -hr"
  echo "  du -sh \"$APP_DIR\"/Contents/Resources/* | sort -hr"
  echo
  echo "Common fixes:"
  echo "  • Build release: scripts/build-app.sh release"
  echo "  • Rebuild icon:  scripts/build-icon.sh"
  echo "  • Strip got skipped? Check the build log for 'strip -S'."
  FAIL=1
fi

if (( EXEC_BUDGET_MB > 0 )) && (( EXEC_BYTES > 0 )) && (( EXEC_BYTES > EXEC_BUDGET_BYTES )); then
  echo
  echo "✗ Main executable $EXEC_MB MB exceeds exec budget of $EXEC_BUDGET_MB MB."
  echo
  echo "  $EXEC_PATH"
  echo "  $EXEC_BYTES bytes"
  echo
  echo "If this just spiked, a TreeSitter grammar (or another large"
  echo "dependency) was silently static-linked. Verify the lazy-grammar"
  echo "loader still routes the new language through Contents/Frameworks/"
  echo "rather than baking it into the executable."
  FAIL=1
fi

if (( FAIL == 1 )); then
  exit 2
fi

if (( EXEC_BUDGET_MB > 0 )) && (( EXEC_BYTES > 0 )); then
  echo "✓ Bundle $SIZE_MB MB / exec $EXEC_MB MB within budgets ($BUDGET_MB MB total / $EXEC_BUDGET_MB MB exec)."
elif (( EXEC_BYTES > 0 )); then
  echo "✓ Bundle $SIZE_MB MB (exec $EXEC_MB MB) within budget of $BUDGET_MB MB."
else
  echo "✓ Bundle size $SIZE_MB MB within budget of $BUDGET_MB MB."
fi
