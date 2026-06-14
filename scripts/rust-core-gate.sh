#!/usr/bin/env bash
# Rust-core gate — enforce the workspace's no-panic lint policy + run the pure
# cargo tests. This is the Rust analog of scripts/test-headless-gate.sh.
#
# Why this exists: the PR workflow only ran `cargo build` (build-rust-core.sh),
# which compiles the core but runs NEITHER `cargo clippy` NOR `cargo test`. The
# workspace `[workspace.lints]` table DENIES indexing_slicing / panic /
# unwrap_used / expect_used in non-test code (the core is sans-panic by design),
# but with nothing invoking clippy those denies were dead letters — two
# panic-capable slices in cm_edit.rs shipped (0cead3c) before clippy ever ran.
# And the 65+ pure cargo tests never gated a merge.
#
#   * `cargo clippy` exits non-zero on the DENY-level lints (the no-panic
#     policy) but 0 on the pedantic WARN-level nits — exactly the right
#     enforcement boundary, no flag-juggling needed.
#   * `cargo test` runs every workspace crate's tests.
#
# --workspace is load-bearing (audit TSK-550): without it cargo honors
# default-members (core + ffi only) and the tui/web/highlight crates — two
# shipping front-ends and the highlighting engine, ~8,300 lines with real test
# suites — never gate a merge. A core API change that breaks them sails through.
#
# Build dir lives OUTSIDE the worktree (worktree hygiene) via CARGO_TARGET_DIR,
# matching build-rust-core.sh.
#
# --locked is load-bearing (TSK-783, supply-chain): the committed Cargo.lock is
# the authoritative transitive-dependency set, and --locked makes any build that
# WOULD mutate it FAIL instead of silently re-resolving. Direct deps are already
# exact-pinned with default-features=false (workspace manifest), so a drift can
# only come from a transitive sub-dep's range — exactly what this catches. Pairs
# with deny.toml (cargo-deny: multiple-versions=deny, crates.io-only sources) run
# via scripts/rust-supply-chain-audit.sh. A lockfile change must now be an
# explicit, reviewable Cargo.lock diff — the owner-approval chokepoint.
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
RUST_DIR="$ROOT_DIR/rust-core"

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/private/tmp/claude-$(id -u)/mdv-rust-gate-target}"

if ! command -v cargo >/dev/null 2>&1; then
  echo "Error: cargo not found on PATH. Install the Rust toolchain (rustup)." >&2
  exit 1
fi

echo "==> cargo clippy --locked --workspace --all-targets (no-panic deny lints + Cargo.lock drift guard)"
cargo clippy --locked --manifest-path "$RUST_DIR/Cargo.toml" --workspace --all-targets

echo "==> cargo test --locked --workspace (all five crates incl. tui/web/highlight)"
cargo test --locked --manifest-path "$RUST_DIR/Cargo.toml" --workspace

# Header-drift check (audit TSK-539): the clippy/test runs above just re-ran
# the ffi build script, so crates/ffi/include/mdvcore.h is freshly generated.
# If the copy SwiftPM actually compiles against (Sources/CMdvCore/mdvcore.h,
# staged by build-rust-core.sh) differs, Swift is reading the ABI through a
# stale header — the cross-language memory-corruption setup this gate exists
# to catch. (Skip when the staged copy doesn't exist yet: fresh clone, Rust-
# only checkout.)
GEN_HEADER="$RUST_DIR/crates/ffi/include/mdvcore.h"
STAGED_HEADER="$ROOT_DIR/Sources/CMdvCore/mdvcore.h"
if [[ -f "$STAGED_HEADER" && -f "$GEN_HEADER" ]]; then
  if ! cmp -s "$GEN_HEADER" "$STAGED_HEADER"; then
    echo "==> FAILED: ABI header drift — $STAGED_HEADER does not match the" >&2
    echo "    freshly generated $GEN_HEADER. Run scripts/build-rust-core.sh" >&2
    echo "    to restage before relying on any Swift build." >&2
    exit 1
  fi
  echo "==> header-drift check: OK (staged header matches generated)"
fi

echo "==> Rust-core gate green."
