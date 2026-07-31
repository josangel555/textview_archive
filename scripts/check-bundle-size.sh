#!/usr/bin/env bash
# Bundle size guardrail. Fails the build when dist/TextView.app
# crosses a budget. Two checks:
#   - total .app size (default 80 MB)
#   - main executable size (default 70 MB)
#
# Caps bumped 40->48 / 20->26 (2026-06-03) for the UX-overhaul features
# (embedded terminal + ANSI parser, command registry/keybindings,
# content-toolbar + breadcrumb, find/replace rebuild, footer git) — ~2.4 MB of
# legitimate Swift growth (exec 19->21.4 MB), no TreeSitter grammar static-linked
# (all new code is pure Swift; grammars remain dylibs in Contents/Frameworks/).
# Earlier: caps bumped 37->40 / 18->20 (2026-05-31) for the Rust-core CSV integration.
# Two facts justified the bump, MEASURED this run:
#   1. The `main` release exec (NO Rust), stripped exactly like build-app.sh
#      (`strip -S`), was ALREADY 18.60 MB — the old 18 MB exec cap was stale
#      and `main` itself breached it (pre-existing drift, not this change).
#   2. Static-linking libmdvcore_ffi.a adds only ~0.36 MB to the exec
#      (18.60 -> ~18.96 MB) and ~0.3 MB to the bundle (measured 39 MB total).
# (At that 2026-05-31 bump the 20 MB exec / 40 MB total caps covered the real
# baseline + the Rust core + modest headroom; the live caps are now 70 / 80 (exec / total) —
# see the header above.) The exec sub-cap still catches a TreeSitter grammar
# silently regressing to static linkage. NOTE: the Rust core is purely ADDITIVE at this
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

# 48 -> 64 (2026-06-12, OWNER-APPROVED "bump caps as needed for now; will
# revisit hard caps"): the TSK-660 rust tree-sitter grammars' C objects now
# enter libmdvcore_ffi.a and (once Swift references the export) the exec —
# measured release 63 MB bundle / 43 MB exec while the Swift grammars are
# still double-carried. Stage 4 (Swift grammar deletion) reclaims part;
# the owner revisits hard caps then.
# 64 -> 72 (2026-06-12, same owner blanket): TSK-660 stage 3 adds the 10
# parity grammars (python/bash/yaml/html/css/go/ruby/md/xml/sql) — release
# measured 70 MB bundle / 50 MB exec with the Swift grammars still
# double-carried. Stage 4 deletion reclaims; owner revisits hard caps then.
# 72 -> 80 (2026-06-14, owner ask "up the headroom a bit for upcoming tasks"):
# release measured 71.9 MB / 51.8 MB exec — only ~50 KB / ~160 KB under the
# 72/52 caps, i.e. one feature from red. +8 MB headroom for upcoming work; the
# real reclaim is still Stage 4 (delete the double-carried Swift grammars).
BUDGET_MB="${BUDGET_MB:-${1:-80}}"
# Per-exec check defaults to 26 MB. The eager keeplist (JSON, Swift,
# Markdown) + everything-else-Swift-and-resources fits in ~11 MB
# release. The CodeMirror 6 editor (Swift wrapper + JS bridge code)
# bumped the executable by ~200 KB; CM6 itself is a JS resource
# (~570 KB) under Resources/codemirror/, not in the executable. The
# Headroom over the current baseline catches a TreeSitter grammar
# silently regressing to static linkage (look for an unintended
# `import TreeSitter<X>` in ViewerCore). History: bumped 16 -> 18
# (2026-05-30) for the shoulder-rails + large-file read-only +
# picker-fix work (~140 KB Swift, 15.91 -> 16.05 MB); 18 -> 20
# (2026-05-31) for the Rust-core CSV integration (static-linking
# libmdvcore_ffi.a adds ~0.36 MB, 18.60 -> ~18.96 MB, and `main`
# itself was already 18.60 MB, breaching the stale 18 MB cap); 20 -> 26
# (2026-06-03) for the UX-overhaul features (embedded terminal + ANSI
# parser, command registry/keybindings, content-toolbar + breadcrumb,
# find/replace rebuild, footer git — ~2.4 MB of legitimate Swift,
# exec 19 -> 21.4 MB). Grammars remain dylibs in Contents/Frameworks/,
# so each bump is real code growth, not a static-link regression.
# Override via env to opt out:
#   EXEC_BUDGET_MB=0 bash scripts/check-bundle-size.sh
# 26 -> 44 (2026-06-12): same owner-approved TSK-660 bump — the rust
# grammar objects are exec-resident (static link), unlike the Swift lazy
# grammar dylibs they will replace.
# 44 -> 52 (2026-06-12): stage-3 grammar objects (same blanket as above).
# 52 -> 60 (2026-06-14, owner ask "up the headroom a bit"): release exec
# measured 51.8 MB (~160 KB under the 52 cap). +8 MB headroom for upcoming
# work. Most of the exec is tree-sitter grammar parse tables (~29 MB of the
# rust archive) double-carried with the Swift dylibs — Stage 4 is the reclaim.
# 60 -> 65 (2026-06-22, owner ask "update to 65"): release exec measured
# 60.4 MB, just over the 60 cap — organic growth, NOT a static-link regression
# (grammars still ship as Frameworks/ dylibs). +~5 MB headroom; the real fix is
# the reclaim (TSK-1214/1098: lazy-load / dedup the double-carried parse tables).
# 65→70 (2026-07-31, owner-approved): release exec reached 67.9 MB organically
# (pulldown-latex math tables + 5 weeks of features; lazy grammar dylibs
# verified still in Contents/Frameworks/ — no static-link regression).
EXEC_BUDGET_MB="${EXEC_BUDGET_MB:-70}"
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
