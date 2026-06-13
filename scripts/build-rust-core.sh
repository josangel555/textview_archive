#!/usr/bin/env bash
# Build the Rust core staticlib + cbindgen header and stage them where the
# SwiftPM build links them.
#
#   rust-core/                      the cargo workspace (mdvcore-core + mdvcore-ffi)
#   rust-core/link/libmdvcore_ffi.a the staticlib SwiftPM links (-L rust-core/link)
#   Sources/CMdvCore/mdvcore.h      the cbindgen header the systemLibrary imports
#
# Both staged files are gitignored build artifacts — they regenerate from the
# Rust source and must never be hand-edited or committed (the header would
# silently drift from the extern "C" surface otherwise).
#
# This MUST run before `swift build`/`swift test`/`scripts/build-app.sh` so the
# `.a` and header exist at link/compile time. `scripts/build-app.sh` invokes it
# automatically.
#
# Profile: `dist` (size-opt + panic=unwind). This is the GUI-host-correct
# profile — under panic=abort (`release`) a core panic would SIGABRT the app
# before catch_unwind could convert it to an error. Do NOT link `release`.
#
# Build dir lives OUTSIDE the worktree (worktree hygiene) via CARGO_TARGET_DIR.
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
RUST_DIR="$ROOT_DIR/rust-core"
LINK_DIR="$RUST_DIR/link"
CMOD_DIR="$ROOT_DIR/Sources/CMdvCore"

# The SwiftPM header-staleness guard (TSK-626) lives in a sourceable function so
# build + a hermetic host test share one implementation.
# shellcheck source=lib/restage-header.sh
source "$SCRIPT_DIR/lib/restage-header.sh"

PROFILE="${MDV_RUST_PROFILE:-dist}"

# Guard the app-link path against a panic=abort profile (Architecture invariant
# #4). The staged .a is linked into the GUI host, so it MUST be built with
# `panic = "unwind"` — otherwise the FFI `catch_unwind` shims are no-ops and a
# core panic SIGABRTs the whole app instead of becoming MdvStatus::Panic.
#   * `dist`  — release size ladder + panic=unwind (the shipping GUI profile).
#   * `dev` / `test` — no `panic` override → cargo's default `unwind`.
#   * `release` — panic=abort (size-figure only); linking it ships a bundle
#     whose panic path silently aborts. REJECT it (and any other custom profile,
#     which inherits release/panic=abort unless it explicitly opts back in).
case "$PROFILE" in
  dist|dev|test) ;;
  *)
    echo "Error: MDV_RUST_PROFILE='$PROFILE' is not allowed for the app-link path." >&2
    echo "       Only 'dist', 'dev', or 'test' build with panic=unwind, which the" >&2
    echo "       FFI catch_unwind shims require to convert a core panic into an" >&2
    echo "       error instead of aborting the GUI host (Architecture invariant #4)." >&2
    echo "       The 'release' profile uses panic=abort and MUST NOT be linked." >&2
    exit 1
    ;;
esac

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/private/tmp/claude-$(id -u)/mdv-rust-csv-target}"

if ! command -v cargo >/dev/null 2>&1; then
  # No Rust toolchain on this host. The UTM test VM is exactly this case: it has
  # no cargo and links the HOST-built staticlib + header that ride along in the
  # rsync (rust-core/link/ and Sources/CMdvCore/ aren't excluded). `swift build`/
  # `swift test` already link these; the only thing that broke was build-app.sh
  # calling here and hard-failing. So if the staged artifacts are present, use
  # them and skip the cargo build — that's what lets build-app.sh assemble a
  # fresh dist/ on the VM for the live-tier (T4/T5) lane.
  if [[ -f "$LINK_DIR/libmdvcore_ffi.a" && -f "$CMOD_DIR/mdvcore.h" ]]; then
    echo "==> cargo not found; using pre-staged Rust core artifacts (no rebuild):"
    echo "    $LINK_DIR/libmdvcore_ffi.a   ($(/usr/bin/du -h "$LINK_DIR/libmdvcore_ffi.a" | awk '{print $1}'))"
    echo "    $CMOD_DIR/mdvcore.h"
    echo "==> Rust core ready (pre-staged; cargo absent)."
    exit 0
  fi
  echo "Error: cargo not found on PATH AND no pre-staged staticlib at" >&2
  echo "       $LINK_DIR/libmdvcore_ffi.a (+ $CMOD_DIR/mdvcore.h)." >&2
  echo "       Install the Rust toolchain (rustup) on a build host, or rsync the" >&2
  echo "       host-built staticlib + header here first (the VM model)." >&2
  exit 1
fi

echo "==> cargo build --profile $PROFILE (CARGO_TARGET_DIR=$CARGO_TARGET_DIR)"
cargo build --manifest-path "$RUST_DIR/Cargo.toml" --profile "$PROFILE"

# We stage the STATICLIB (libmdvcore_ffi.a) and let SwiftPM link it directly
# into the MarkdownViewer executable.
#
# Why static, not a dylib in Contents/Frameworks/ — a measured, deliberate call
# (both were built + tested):
#   * A separate dylib is ~344 KB vs ~2.9 MB of exec growth from the static
#     link, BUT under the hardened runtime (`codesign --options runtime`) +
#     this project's SELF-SIGNED local cert (TeamIdentifier "not set"), dyld
#     REFUSES to load a non-platform dylib that is a *load-time dependency* of
#     the signed executable: "mapping process and mapped file have different
#     Team IDs". (The lazy TreeSitter grammars dodge this only because they are
#     `dlopen`'d at runtime, where dyld is lenient — a load-time dep is not.)
#   * Static-linking the .a sidesteps the team-ID problem entirely: there is no
#     separate Mach-O to load, so the app launches clean and codesign --deep
#     --strict passes. The size cost (~2.9 MB exec) is a legitimate, reviewed
#     cap bump (see scripts/check-bundle-size.sh + docs/RUST_CSV_INTEGRATION.md).
# Revisit the dylib path once a Developer ID / real Team ID is in play (the
# migration doc's xcframework binaryTarget end-state).
STATICLIB="$CARGO_TARGET_DIR/$PROFILE/libmdvcore_ffi.a"
if [[ ! -f "$STATICLIB" ]]; then
  echo "Error: staticlib not found at $STATICLIB" >&2
  exit 1
fi

# The cbindgen build.rs mirrors the header into rust-core/crates/ffi/include/.
HEADER_SRC="$RUST_DIR/crates/ffi/include/mdvcore.h"
if [[ ! -f "$HEADER_SRC" ]]; then
  # Fall back to the per-build OUT_DIR copy.
  HEADER_SRC="$(find "$CARGO_TARGET_DIR/$PROFILE" -name mdvcore.h -path '*mdvcore-ffi*/out/*' 2>/dev/null | head -n1)"
fi
if [[ ! -f "$HEADER_SRC" ]]; then
  echo "Error: generated header mdvcore.h not found (cbindgen did not run?)." >&2
  exit 1
fi

mkdir -p "$LINK_DIR"
# Stage ONLY the .a — if a stale .dylib lingers in the link dir, SwiftPM's
# `-lmdvcore_ffi` would prefer it (and reintroduce the team-ID load failure), so
# remove it.
rm -f "$LINK_DIR/libmdvcore_ffi.dylib"
cp "$STATICLIB" "$LINK_DIR/libmdvcore_ffi.a"
cp "$HEADER_SRC" "$LINK_DIR/mdvcore.h"

# Stage the SwiftPM-imported header + run the staleness touches (TSK-626):
# detect a real header change before overwriting, always relink the RustCore
# bridge sources (the prebuilt .a isn't a tracked input), and on a header change
# widen the touch to the TEST targets + header-surface referents so stale test
# objects against a re-laid-out ABI can't SIGSEGV-as-FFI-bug. See the function's
# header in scripts/lib/restage-header.sh; pinned by RustCoreHeaderRestageTests.
restage_core_header "$HEADER_SRC" "$CMOD_DIR/mdvcore.h" "$ROOT_DIR"

echo "==> staged:"
echo "    $LINK_DIR/libmdvcore_ffi.a   ($(/usr/bin/du -h "$LINK_DIR/libmdvcore_ffi.a" | awk '{print $1}'))"
echo "    $CMOD_DIR/mdvcore.h"
echo "==> Rust core ready ($PROFILE)."
