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
#   * `cargo test` runs every workspace crate's tests (core + ffi).
#
# Build dir lives OUTSIDE the worktree (worktree hygiene) via CARGO_TARGET_DIR,
# matching build-rust-core.sh.
set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
RUST_DIR="$ROOT_DIR/rust-core"

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/private/tmp/claude-$(id -u)/mdv-rust-gate-target}"

if ! command -v cargo >/dev/null 2>&1; then
  echo "Error: cargo not found on PATH. Install the Rust toolchain (rustup)." >&2
  exit 1
fi

echo "==> cargo clippy --all-targets (enforces the workspace no-panic deny lints)"
cargo clippy --manifest-path "$RUST_DIR/Cargo.toml" --all-targets

echo "==> cargo test (all workspace crates)"
cargo test --manifest-path "$RUST_DIR/Cargo.toml"

echo "==> Rust-core gate green."
