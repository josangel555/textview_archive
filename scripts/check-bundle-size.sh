#!/usr/bin/env bash
# Bundle size guardrail. Fails the build when dist/TextView.app
# crosses a budget (default 25 MB). Sourced from scripts/build-app.sh
# at the tail so a release build that bloats past budget refuses to
# install rather than silently shipping a megabyte avalanche.
#
# Usage:
#   bash scripts/check-bundle-size.sh                    # 25 MB default
#   bash scripts/check-bundle-size.sh 30                 # 30 MB budget
#   BUDGET_MB=15 bash scripts/check-bundle-size.sh       # via env
#
# Exit: 0 = within budget, 2 = over budget.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
APP_DIR="$ROOT_DIR/dist/TextView.app"

BUDGET_MB="${BUDGET_MB:-${1:-25}}"
BUDGET_BYTES=$(( BUDGET_MB * 1024 * 1024 ))

if [[ ! -d "$APP_DIR" ]]; then
  echo "Error: $APP_DIR not built. Run scripts/build-app.sh first." >&2
  exit 1
fi

# `du -sk` reports KB on macOS. Convert to bytes.
SIZE_KB=$(/usr/bin/du -sk "$APP_DIR" | awk '{print $1}')
SIZE_BYTES=$(( SIZE_KB * 1024 ))
SIZE_MB=$(( SIZE_KB / 1024 ))

if (( SIZE_BYTES > BUDGET_BYTES )); then
  echo
  echo "✗ Bundle size $SIZE_MB MB exceeds budget of $BUDGET_MB MB."
  echo
  echo "  $APP_DIR"
  echo "  $SIZE_KB KB / $SIZE_BYTES bytes"
  echo
  echo "Find the bloat:"
  echo "  du -sh \"$APP_DIR\"/Contents/MacOS/*"
  echo "  du -sh \"$APP_DIR\"/Contents/Resources/* | sort -hr"
  echo
  echo "Common fixes:"
  echo "  • Build release: scripts/build-app.sh release"
  echo "  • Rebuild icon:  scripts/build-icon.sh"
  echo "  • Strip got skipped? Check the build log for 'strip -S'."
  exit 2
fi

echo "✓ Bundle size $SIZE_MB MB within budget of $BUDGET_MB MB."
