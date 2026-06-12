#!/usr/bin/env bash
# Supply-chain audit lane for rust-core (TSK-554).
#
# Two tools, deliberately split:
#   cargo-deny  → licenses / bans (duplicate versions) / sources,
#                 config: rust-core/deny.toml (graph pinned to the targets
#                 we actually build; cbindgen MPL-2.0 exception documented
#                 there).
#   cargo-audit → RustSec ADVISORIES. cargo-deny 0.18.x cannot parse the
#                 advisory DB's CVSS-4.0 entries (hard error), so the
#                 advisories duty lives here until cargo-deny catches up.
#
# Policy: vulnerabilities AND warn-class advisories (unmaintained/unsound)
# fail the lane (`--deny warnings`); known-triaged warnings are ignored by
# RUSTSEC id BELOW with their triage note — re-justify each on bumps.
#
# Usage:  bash scripts/rust-supply-chain-audit.sh
# Exit:   0 = clean · nonzero = violation (read the tool output above it)

set -euo pipefail
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR/../rust-core"

for tool in cargo-deny cargo-audit; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool not installed. brew install $tool  (or: cargo install --locked $tool)" >&2
    exit 2
  fi
done

echo "==> cargo deny check licenses bans sources"
cargo deny check licenses bans sources

echo "==> cargo audit (advisories; warn-class denied, triaged ids ignored)"
# Triaged ignores — BOTH are ratatui→(tui front-end) only, NOT in the
# shipping staticlib graph (verified `cargo tree --workspace -i`, 2026-06-12):
#   RUSTSEC-2024-0436  paste 1.0.15 unmaintained (proc-macro, build-time)
#   RUSTSEC-2026-0002  lru 0.12.5 IterMut unsound (we never use IterMut)
# Drop these when ratatui bumps past them.
cargo audit --deny warnings \
  --ignore RUSTSEC-2024-0436 \
  --ignore RUSTSEC-2026-0002

echo "==> supply-chain audit PASSED"
