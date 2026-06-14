# shellcheck shell=bash
# scripts/lib/restage-header.sh
#
# The SwiftPM staleness guard for the staged CMdvCore header (TSK-626). Extracted
# from build-rust-core.sh into a sourceable function so it has ONE home that both
# the build script and a hermetic, no-cargo host test exercise (the test drives
# this exact function over fixture dirs — not a parallel reimplementation).
#
# Why it exists: SwiftPM does NOT track the staged header as a build input. A
# header-only change (new const, re-laid-out decl) silently compiles stale
# dependents — and stale TEST objects against a re-laid-out ABI SIGSEGV in ways
# that look like FFI bugs (the documented trap; bit twice, incl. a pure-Swift
# `throw CoreError.panic` that segfaulted on stale test objects). The cure is to
# touch the importing Swift sources so the next build relinks/recompiles.

# restage_core_header NEW_HEADER CMOD_HEADER ROOT_DIR [STATICLIB_CHANGED]
#
# Detect whether NEW_HEADER differs from the currently-staged CMOD_HEADER (the
# copy SwiftPM imports); overwrite CMOD_HEADER only when it changed, then run the
# staleness touches:
#   * Touch Sources/RustCore/*.swift — the bridge sources that link the prebuilt
#     `.a` — when the `.a` OR the header changed, so SwiftPM relinks RustCore +
#     downstream against the fresh `.a` (the `.a` is NOT a tracked build input;
#     caught 2026-06-10: an A/B test compared stale Rust against new Swift). The
#     caller passes STATICLIB_CHANGED (1/0) from a cmp of the freshly built vs
#     staged `.a`. It DEFAULTS TO 1 (always relink) when omitted — the safe,
#     backward-compatible fallback. TSK-848: when nothing changed (no Rust, no
#     header), this touch is SKIPPED, so a no-Rust-change gate run no longer
#     relinks RustCore + every downstream module (~63s saved per run).
#   * WHEN the header CHANGED, widen the touch to the TEST targets
#     (Tests/RustCoreTests) plus every Swift file naming the header's exported
#     surface (MDV_CAP_/MDV_WIRE_VERSION/import CMdvCore) across Sources + Tests.
#     Conditional so routine restages (header unchanged) stay cheap.
#
# Pure filesystem ops — no cargo — so it is host-testable with fixture dirs.
# Echoes a "header CHANGED" marker line when (and only when) a change is detected.
restage_core_header() {
  local new_header="$1" cmod_header="$2" root_dir="$3" staticlib_changed="${4:-1}"
  local changed=1
  if cmp -s "$new_header" "$cmod_header" 2>/dev/null; then
    changed=0
  fi
  # Only overwrite (and re-stamp the mtime of) the SwiftPM-imported header when
  # it actually changed — an unconditional cp recompiled CMdvCore's importers on
  # every no-op build too (TSK-848).
  if [[ "$changed" == "1" ]]; then
    cp "$new_header" "$cmod_header"
  fi

  # Relink the bridge sources only when the `.a` or the header actually changed.
  if [[ "$changed" == "1" || "$staticlib_changed" == "1" ]]; then
    find "$root_dir/Sources/RustCore" -name '*.swift' -exec touch {} + 2>/dev/null || true
  fi

  if [[ "$changed" == "1" ]]; then
    echo "==> header CHANGED — touching header-referencing targets (TSK-626)"
    find "$root_dir/Tests/RustCoreTests" -name '*.swift' -exec touch {} + 2>/dev/null || true
    grep -rl --include='*.swift' -E "MDV_CAP_|MDV_WIRE_VERSION|import CMdvCore" \
        "$root_dir/Sources" "$root_dir/Tests" 2>/dev/null | while read -r f; do
      touch "$f"
    done
  fi
  return 0
}
