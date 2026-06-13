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

# restage_core_header NEW_HEADER CMOD_HEADER ROOT_DIR
#
# Detect whether NEW_HEADER differs from the currently-staged CMOD_HEADER (the
# copy SwiftPM imports), overwrite CMOD_HEADER with NEW_HEADER, then run the
# staleness touches:
#   * ALWAYS touch Sources/RustCore/*.swift — the prebuilt `.a` is not a tracked
#     build input either, so the bridge sources must relink every restage
#     (caught 2026-06-10: an A/B test compared stale Rust against new Swift).
#   * WHEN the header CHANGED, widen the touch to the TEST targets
#     (Tests/RustCoreTests) plus every Swift file naming the header's exported
#     surface (MDV_CAP_/MDV_WIRE_VERSION/import CMdvCore) across Sources + Tests.
#     Conditional so routine restages (header unchanged) stay cheap.
#
# Pure filesystem ops — no cargo — so it is host-testable with fixture dirs.
# Echoes a "header CHANGED" marker line when (and only when) a change is detected.
restage_core_header() {
  local new_header="$1" cmod_header="$2" root_dir="$3"
  local changed=1
  if cmp -s "$new_header" "$cmod_header" 2>/dev/null; then
    changed=0
  fi
  cp "$new_header" "$cmod_header"

  find "$root_dir/Sources/RustCore" -name '*.swift' -exec touch {} + 2>/dev/null || true

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
