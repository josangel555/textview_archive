#!/usr/bin/env bash
# Build the three rust front-end binaries (release) and stage them into the
# project's dist/bin/ so they live with the app's other build outputs and are
# directly runnable without cargo:
#
#   dist/bin/mdv-tui    ratatui file browser/viewer   (interactive; --snapshot for CI)
#   dist/bin/mdv-web    localhost human web UI        (http://127.0.0.1:<port>/)
#   dist/bin/mdv-serve  machine-API socket daemon     (the MDV_REMOTE_SOCKET peer)
#
# The multi-GB cargo TARGET DIR stays outside the iCloud-synced tree
# (rust-core/.cargo/config.toml → ~/Library/Caches/mdv-rust-target, the
# TSK-555 mandate); only the final small binaries are copied in here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/dist/bin"

echo "==> cargo build --release (mdvcore-tui mdvcore-web mdvcore-serve)"
cargo build --release \
  --manifest-path "$ROOT/rust-core/Cargo.toml" \
  -p mdvcore-tui -p mdvcore-web -p mdvcore-serve

# Resolve the effective target dir (config.toml pin or CARGO_TARGET_DIR override).
TARGET_DIR="${CARGO_TARGET_DIR:-$(grep -m1 'target-dir' "$ROOT/rust-core/.cargo/config.toml" | sed 's/.*= *"//;s/".*//')}"

mkdir -p "$BIN_DIR"
for b in mdv-tui mdv-web mdv-serve; do
  cp -f "$TARGET_DIR/release/$b" "$BIN_DIR/$b"
done

echo "==> staged:"
ls -lh "$BIN_DIR" | awk 'NR>1 {print "    " $9 "  (" $5 ")"}'
