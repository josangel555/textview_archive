#!/bin/bash
# Standing background CI loop (owner directive 2026-08-01: "skip the full CI
# for every commit … leave it in the background as a permanent loop").
#
# Re-runs the central headless gate on each NEW committed HEAD of main, inside
# the dedicated CI worktree (../markdown_viewer-ci, detached HEAD — a DELIBERATE
# permanent worktree, exempt from the reap-after-merge hygiene rule) so
# in-flight edits in the main checkout can never tear a run. Per-commit
# validation in the working checkout is targeted `swift test --filter` only.
#
# Emits ONE line per completed run — the session Monitor turns each into a
# notification: "CI <sha> GATE rc=<n> (<dur>s)". Bench-only failures under
# host load are the known flaky class: re-run quiet before chasing (LESSONS).
#
# The untracked host-built rust artifacts (rust-core/link/) are copied in
# before each run; only the .a and .h are needed — mdv-serve is rebuilt by the
# build itself (and copying it would race the main checkout's writes).
set -u

REPO="${MDV_CI_REPO:-/Users/me/Documents/workspaces/claude/markdown_viewer}"
CI="${MDV_CI_WORKTREE:-/Users/me/Documents/workspaces/claude/markdown_viewer-ci}"
STATE="$CI/.ci-last-tested"
POLL="${MDV_CI_POLL_SECONDS:-60}"

while true; do
  head="$(git -C "$REPO" rev-parse main 2>/dev/null)"
  last="$(cat "$STATE" 2>/dev/null || true)"
  if [ -n "$head" ] && [ "$head" != "$last" ]; then
    if ! git -C "$CI" checkout --detach -q "$head" 2>/dev/null; then
      echo "CI ${head:0:9} CHECKOUT FAILED — worktree torn? ($CI)"
      sleep "$POLL"; continue
    fi
    mkdir -p "$CI/rust-core/link"
    for f in libmdvcore_ffi.a mdvcore.h; do
      # Retry once: the main checkout's builds rewrite the header in place.
      cp "$REPO/rust-core/link/$f" "$CI/rust-core/link/$f" 2>/dev/null \
        || { sleep 2; cp "$REPO/rust-core/link/$f" "$CI/rust-core/link/$f" \
             || echo "CI ${head:0:9} WARN: could not stage $f"; }
    done
    start="$(date +%s)"
    ( cd "$CI" && bash scripts/test-headless-gate.sh > "$CI/.ci-gate.log" 2>&1 )
    rc=$?
    dur=$(( $(date +%s) - start ))
    extra=""
    [ "$rc" -ne 0 ] && extra=" — log: $CI/.ci-gate.log"
    echo "CI ${head:0:9} GATE rc=$rc (${dur}s)$extra"
    printf '%s' "$head" > "$STATE"
  fi
  sleep "$POLL"
done
