#!/usr/bin/env bash
# Bundle size guardrail. Fails the build when dist/TextView.app
# crosses a budget. Two checks:
#   - total .app size (default 35 MB)
#   - main executable size (default 15 MB)
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

BUDGET_MB="${BUDGET_MB:-${1:-35}}"
# Per-exec check defaults to 15 MB now that the TreeSitter lazy-
# grammar migration has landed. The eager keeplist (JSON, Swift,
# Markdown) + everything-else-Swift-and-resources fits in ~11 MB
# release; 15 MB gives 4 MB headroom for incidental growth. If the
# executable creeps above 15 MB it almost certainly means a grammar
# regressed to static linkage (look for an unintended `import
# TreeSitter<X>` in ViewerCore). Override via env to opt out:
#   EXEC_BUDGET_MB=0 bash scripts/check-bundle-size.sh
EXEC_BUDGET_MB="${EXEC_BUDGET_MB:-15}"
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
