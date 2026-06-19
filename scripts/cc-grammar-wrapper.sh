#!/usr/bin/env bash
# scripts/cc-grammar-wrapper.sh
#
# TSK-851: the `CC` SwiftPM invokes for C target compiles when the compiler-cache
# wiring is active. SwiftPM passes ONLY compiler flags (no leading compiler), so
# this script supplies the real compiler and, when a cache is configured, runs it
# through ccache/sccache. The grammar `parser.c` objects (~165 MB of C across 11
# grammars) then come from cache on the 2nd clean build.
#
# Behaviour (read from the environment at RUN time, set by lib/ccache-env.sh):
#   * MDV_CC_REAL   — the real compiler to forward to (default: `cc` on PATH).
#   * MDV_CC_CACHE  — the cache binary (ccache|sccache). When EMPTY/unset this is
#                     a pure passthrough no-op: `exec <real> "$@"`. That is the
#                     "missing ccache ⇒ normal build" guarantee — even if CC is
#                     left pointing here, an empty MDV_CC_CACHE means a plain
#                     compile.
#
# Kept deliberately tiny + dependency-free: it is on the hot path of every C
# compile, so it must add ~zero overhead and never fail for its own reasons.
set -euo pipefail

real="${MDV_CC_REAL:-}"
if [ -z "$real" ]; then
  real="$(command -v cc 2>/dev/null || echo /usr/bin/cc)"
fi

cache="${MDV_CC_CACHE:-}"
if [ -z "$cache" ]; then
  # No cache configured → normal compile. This is the no-op degrade path.
  exec "$real" "$@"
fi

# Cache configured → run the real compiler through it. ccache and sccache share
# the `<cache> <compiler> <args...>` invocation form.
exec "$cache" "$real" "$@"
