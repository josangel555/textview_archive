# Build & Test Pipeline Speedup — research (2026-06-14)

Research-backed analysis of how to speed up the SwiftPM build + headless test gate + Rust-core
gate, and why `.build` is 4.4 GB. **Analysis only — nothing applied, nothing committed.**

## Read order
1. **[SYNTHESIS.md](SYNTHESIS.md)** — executive summary + prioritized rec table (free wins vs
   tradeoffs), with impact/effort/risk/approval per row, and the suggested execution order.
2. Per-area evidence:
   - [disk-build-dir.md](disk-build-dir.md) — why `.build` is 4.4 GB (3 duplications), reclaim math.
   - [swiftpm.md](swiftpm.md) — index-store, bg-indexing, WMO non-lever, module granularity.
   - [rust.md](rust.md) — target-dir fragmentation (~9.7 GB / 3 caches), nextest, lld/sccache anti-recs.
   - [test-execution.md](test-execution.md) — how `swift test --parallel` parallelizes; rebalance levers.
   - [git-deps.md](git-deps.md) — tree-sitter grammar clone size; no SwiftPM shallow flag.

## Top 5 at a glance
| Rec | What | Impact | Approval |
|---|---|---|---|
| F1 | Kill the duplicate SourceKit-LSP `index-build/` tree | −1.7 GB disk + stops a bg `swift build` | No |
| F3 | One shared `CARGO_TARGET_DIR` for build + gate | −6 GB `/private/tmp`; gate warm after build | No |
| F2 | `--disable-index-store` on the gate's test build | −244 MB + ~5–15% off gate build phase | No |
| F4 | Reap stale target dirs + `.build/release` | −601 MB `.build` + recurring `/private/tmp` | No |
| T1 | `cargo-nextest` for the Rust gate | up to ~30–60% off the 640-test phase | **Yes** |

## Headline numbers
- `.build` 4.4 GB → ~1.9 GB with F1+F4+F2 (zero behaviour risk).
- Rust `/private/tmp` ~9.7 GB → ~3 GB with F3 (collapse 3 caches → 1).
- No new tool needed for the entire free-wins tier; nextest + grammar-mirror are the two
  approval-gated upside levers.
