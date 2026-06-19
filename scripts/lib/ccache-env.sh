# shellcheck shell=bash
# scripts/lib/ccache-env.sh
#
# TSK-851: opt-in compiler-cache wiring for the TreeSitter grammar C compiles.
#
# Why: the regenerated grammar `parser.c` files are ~165 MB of C across 11
# grammars (swift 55 MB / c-sharp 30 MB / cpp+ts ~18 MB each) and recompile from
# scratch on every CLEAN build. SwiftPM honors the `CC` environment variable for
# its C target compiles (verified: a `CC` wrapper is invoked for each `parser.c`
# .c → .o, while Swift modules go straight through `swiftc` and are untouched).
# So routing `CC` through ccache/sccache caches those `.o` outputs keyed on the
# preprocessed source + flags — the 2nd clean build's C phase is a cache hit.
#
# Design constraints (owner directive):
#   * OPT-IN / AUTO-DETECTED. A host WITHOUT ccache/sccache degrades to a normal
#     build — NO hard dependency at build time (contributors needn't install it).
#   * The wrapper only ever touches C compiles (it IS the `CC`); Swift module
#     builds never invoke `CC`, so they are not cached/affected.
#
# This is a SOURCEABLE helper so the build script and a hermetic host test share
# one implementation (mirrors lib/restage-header.sh). It exports two things into
# the caller's environment when a cache tool is available, and is a pure no-op
# (no exports, return 0) when none is:
#   * MDV_CC_CACHE     — the resolved cache binary (ccache | sccache), for logs.
#   * CC               — the wrapper script that runs `<cache> <clang> "$@"`.
#
# Selection precedence (override → ccache → sccache):
#   * MDV_CC_CACHE_BIN=<path|name> forces a specific cache binary (or "none" /
#     "off" to disable entirely — the explicit escape hatch).
#   * else the first of `ccache`, `sccache` found on PATH.
#
# The prior "sccache net-negative" finding was Swift-specific (sccache wrapping
# swiftc); here the cache only ever sees C compiles, so it does not apply.

# mdv_resolve_cc_cache
#
# Echo the resolved cache binary path (absolute if resolvable, else the bare
# name) on stdout, or nothing if caching is disabled / unavailable. Never fails.
mdv_resolve_cc_cache() {
  local forced="${MDV_CC_CACHE_BIN:-}"
  case "$forced" in
    none|off|disabled|0)
      return 0 ;;            # explicit opt-out
    "")
      ;;                     # auto-detect below
    *)
      # Forced to a specific tool: accept a bare name found on PATH or an
      # absolute/relative path that is executable. If it is not usable we fall
      # back to NO cache (degrade gracefully) rather than break the build.
      if command -v "$forced" >/dev/null 2>&1; then
        command -v "$forced"
        return 0
      elif [ -x "$forced" ]; then
        printf '%s\n' "$forced"
        return 0
      else
        return 0
      fi ;;
  esac
  local tool
  for tool in ccache sccache; do
    if command -v "$tool" >/dev/null 2>&1; then
      command -v "$tool"
      return 0
    fi
  done
  return 0
}

# mdv_setup_cc_cache [WRAPPER_DIR]
#
# Detect a usable compiler cache and, if found, export CC=<wrapper> +
# MDV_CC_CACHE=<tool> into the calling shell. No-op (exports nothing, returns 0)
# when no cache tool is available or caching is disabled.
#
# WRAPPER_DIR (optional) is where the per-invocation wrapper script lives;
# defaults to this file's sibling directory (scripts/) so the committed
# cc-grammar-wrapper.sh is used. A test can point it elsewhere.
#
# The wrapper itself (cc-grammar-wrapper.sh) reads MDV_CC_CACHE + MDV_CC_REAL at
# RUN time, so it stays a no-op passthrough whenever MDV_CC_CACHE is empty — that
# is what makes "missing ccache ⇒ normal build" hold even if CC is left set.
mdv_setup_cc_cache() {
  local wrapper_dir="${1:-}"
  if [ -z "$wrapper_dir" ]; then
    # Resolve relative to THIS sourced file (scripts/lib/), one level up.
    local self_dir
    self_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
    wrapper_dir="$( cd "$self_dir/.." >/dev/null 2>&1 && pwd )"
  fi
  local cache
  cache="$(mdv_resolve_cc_cache)"
  if [ -z "$cache" ]; then
    # No cache tool — degrade to a normal build. Do NOT touch CC.
    return 0
  fi
  local wrapper="$wrapper_dir/cc-grammar-wrapper.sh"
  if [ ! -x "$wrapper" ]; then
    # Wrapper missing/unexecutable — be safe, build normally.
    return 0
  fi
  # The real compiler the wrapper forwards to. Honor a pre-set CC (a contributor
  # may already point at a non-default clang) before falling back to `cc`.
  local real="${MDV_CC_REAL:-}"
  if [ -z "$real" ]; then
    if [ -n "${CC:-}" ] && [ "${CC:-}" != "$wrapper" ]; then
      real="$CC"
    else
      real="$(command -v cc || echo /usr/bin/cc)"
    fi
  fi
  export MDV_CC_CACHE="$cache"
  export MDV_CC_REAL="$real"
  export CC="$wrapper"
}
