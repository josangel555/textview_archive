# rust-core performance research (2026-06-05)

Source: background research agent — read every module in `crates/core` + `crates/ffi`,
reasoned about hot paths, ran throwaway A/B benchmarks (`/tmp`, deleted) on
`rustc 1.92` / arm64 (M-series, 12 cores). Numbers are real measurements unless tagged *(guess)*.

> **Status:** findings only. Code/profile changes are DEFERRED until the W1 port workflow
> lands (it's concurrently editing `rust-core`); then apply as a dedicated perf wave on a
> clean `main`. Quick wins are filed on the `tasked` board; the one dep ask is in
> DECISIONS NEEDED.

## 1. Executive summary — highest-leverage wins

1. **The shipped profile optimizes for the wrong thing.** `dist` inherits `release` =
   `opt-level = "z"` (size). Owner priority is runtime speed first. Switching `dist` to
   `opt-level = 3` makes the core **1.6–4× faster across every hot path** (CSV 1.6×,
   wire-encode 3.4×, diff-parse 2.9×, hex-render **4.0×**) — and the binary-size cost,
   measured after dead-strip + strip, is **effectively zero** (§4). Single biggest,
   lowest-risk win. No code change, no dep.
2. **`filter::apply` allocates a fresh lowercased `String` per cell on every keystroke**
   (`cell.to_lowercase()`), `Scope::All` scans every cell. A no-alloc ASCII-aware
   case-insensitive scan is **3.4× faster** (598 µs vs 2012 µs on 10k×8) with a Unicode
   fallback. Filtering runs per keypress — most latency-sensitive interaction.
3. **The session's filter path clones the entire table body then throws it away.**
   `session::ensure_cached` → `filter::apply` returns `(indices, rows)`; the session keeps
   `indices`, discards `_rows`. That discarded clone measured **3319 µs on 10k×8 — larger
   than the whole filter scan.** Pure waste on every filter change.
4. **`snapshot()` (owned) clones visible rows; the FFI never needs it.** `snapshot_frame()`
   (borrow-based) exists and is documented as the alloc-light FFI path — but the FFI shim
   `mdvcore_session_snapshot` calls the owned `snapshot()`. Measured: owned 4353 µs vs
   frame 2603 µs unfiltered; the gap is the discarded row clone.
5. **CSV parse is dominated by ~1 heap `String` per cell** (600k allocs for 50k×12 → 34 ms
   at opt-3). Structural; realistic lever is opt-level (#1) + optional capacity reserve. A
   string arena changes the wire type — bigger bet (§3).

## 2. Quick wins (no new dep, low risk)

- **QW-1 — wire the FFI snapshot to the borrow encoder.** `crates/ffi/src/lib.rs::mdvcore_session_snapshot`
  calls `session.snapshot()` + `encode_frame`; replace with `session.snapshot_frame()`
  (already framed, parity-tested). Eliminates one full clone of visible rows per pull
  (~1.7 ms on 10k unfiltered, scales with result size). Trivial / low risk.
- **QW-2 — stop discarding a full-table clone in the filter path.** Add
  `filter::matching_indices(table, query) -> Vec<u32>` (same match loop, no `row.clone()`);
  have `session::ensure_cached` call it. Removes the discarded matched-row clones on every
  filter change. Low / low.
- **QW-3 — no-alloc case-insensitive filter match.** `filter::apply` does
  `cell.to_lowercase()` per cell. Precompute the lowercased needle once; for ASCII cells
  scan with `eq_ignore_ascii_case` byte windows (no alloc); fall back to
  `to_lowercase().contains()` only when `!cell.is_ascii()`. **3.4× faster** (598 vs 2012 µs).
  Add a Unicode-parity unit test (`İstanbul`, `ß`). Stacks with QW-2. Low–med / low.
- **QW-4 — single-allocation frame encode.** `wire::encode_frame` allocates `body` then a
  second `Vec` and copies the body in. Serialize into one pre-reserved buffer (4-byte
  placeholder → `Serializer::new(&mut buf).with_struct_map()` → backfill the length via a
  checked slice write). ~7% on a 641 KB frame + removes a 640 KB transient. Low / low.
- **QW-5 — CSV capacity pre-reservation** (`csv::parse_with`): estimate row count
  (`\n` count) to pre-size `rows`; reserve each `row` to header column count. *(guess)*
  low single-digit % — parse is alloc-bound on the cell `String`s, not vec spines. Minor.
- **QW-6 — diff: avoid `format!` in the quoted-path splitter** (`diff::parse_diff_git_paths`
  line ~203). Avoidable throwaway `String` on the rare quoted-path branch. Trivial / low.

## 3. Bigger bets / dep-gated

| Option | Crate (size/health) | Impact | Tradeoff |
|---|---|---|---|
| **SIMD substring search** (filter + hex search) | `memchr` 2.7 (tiny, BurntSushi, ubiquitous) | hex search + filter scan → SIMD (NEON on arm64); likely several× on large buffers (hex on 2 MB ~4.7 ms naive) | one dep; `memchr::memmem::Finder`; unsafe is internal+audited so core stays `#![forbid(unsafe_code)]`. **Recommend approving** — serves two hot paths. |
| Stack-allocate small rows | `smallvec` 1 (small, mature) | removes heap alloc for short CSV rows; CSV is alloc-bound so could be real | new dep; `Vec<String>`→`SmallVec` ripples into wire types. Only if CSV parse is measured pain. |
| Faster wire codec | `postcard` | decode ~1.5× faster, ~70% size | Swift side already speaks MessagePack (`MsgPackReader`); switching means rewriting the Swift decoder. **Do not pursue now.** |
| Parallelize filter/parse | `rayon` (medium) | filter embarrassingly parallel, ~5–8× on 12 cores | per-keystroke filter is ~0.6 ms after QW-2/3 (sub-frame); not justified <100k rows. Defer. |
| String arena for CSV cells | none (invasive) | could ~halve CSV parse | changes `Table.rows` structure → wire-type + every consumer. Big refactor; defer. |

**`memchr` is the one to push for approval** — narrow, serves filter + hex search, trivially maintained.

## 4. Build-profile & binary-size (the `dist` profile)

`dist` currently ships `opt-level = "z"`. Measured opt-z → opt-3 (fat LTO, cgu=1, on real hot paths):

| Operation | opt-z (shipped) | opt-3 | speedup |
|---|---|---|---|
| `csv::parse` 50k×12 | 53.8 ms | 33.5 ms | **1.60×** |
| `wire::encode_frame` 10k | 2402 µs | 710 µs | **3.38×** |
| `wire::decode_frame` 10k | 4981 µs | 2550 µs | **1.95×** |
| `diff::parse` 50f×10h×30l | 2310 µs | 794 µs | **2.91×** |
| `diff::hunk_marks` | 1236 µs | 517 µs | **2.39×** |
| `hex::render_all` 2 MB | 20.5 ms | 5.2 ms | **3.96×** |
| `hex::hex_search` 2 MB | 6414 µs | 4746 µs | 1.35× |
| `set_filter+snapshot_frame` 10k | 8584 µs | 5809 µs | 1.48× |

**Size cost — measured, ~nil.** Linked a minimal C harness referencing all 13 exported
symbols against each `.a` with `-dead_strip` + `strip`:
- core=z → **322,152 bytes**
- core=opt-3 → **318,536 bytes** (opt-3 is *smaller* after dead-strip)

So opt-3 costs **~0 bytes** against the 16 MB exec budget while delivering 1.6–4×. The size objection is unfounded here.

**Recommended `dist`:**
```diff
  [profile.dist]
  inherits = "release"
+ opt-level = 3        # speed; measured ~0 net exec-size cost after dead-strip
  panic = "unwind"     # unchanged — GUI-host-correct (catch_unwind keeps app alive)
```
Either set `opt-level = 3` on `dist`, or split so `release` stays `z` (the documented
size-reference build) and only `dist` overrides. Keep `codegen-units = 1` + `lto = "fat"`
for `dist`. `target-cpu=apple-m1`: **no meaningful gain** (workloads are alloc/branch-bound,
not auto-vectorizable) + pins the CPU baseline — skip. PGO: not measured, heavy operational
cost, revisit only if opt-3 + quick wins leave a hot path slow. `panic = "abort"` on `dist`
is **forbidden** (the build script rejects it — `catch_unwind` must keep the host alive).

## 5. Methods
Standalone cargo project depending on `mdvcore-core` by path, build dirs under `/private/tmp`;
wall-clock over N iters with warmup + `black_box`; custom `relz`/`rel3`/`rels`/`rel3thin`
profiles mirroring the real ladder. Microbenchmarks (not criterion), but ratios are large
enough to be unambiguous. Size method as in §4.

## 6. Investigate next
- `memchr::memmem` real-world gain (only the naive byte loop was benched — already 3.4× over `to_lowercase`).
- **Decode dominance is Swift-side:** the 2438 µs Rust→Swift decode happens in Swift's `MsgPackReader`, not this crate — profile the Swift decoder separately; it may be the real per-action latency.
- `SessionHandle::with` `try_lock` per FFI call — cheap uncontended; not isolated. Probably leave (soundness guard).
- `view::build` uses `String::from_utf8_lossy` (allocates even when input is valid UTF-8) — a `Cow` borrow is free when valid. Low priority (view-model is front-end-only, not the FFI hot path).
- CSV arena ceiling — prototype `(start,len)` offsets into one buffer to quantify 1.5× vs 2× before committing to the wire-type ripple.

**Bottom line:** ship `opt-level = 3` on `dist` (free 1.6–4×), then land QW-1/2/3 (borrow-based
snapshot, kill the discarded clone, no-alloc filter) for the per-interaction latency users
feel. All of §2 is no-dep and keeps `#![forbid(unsafe_code)]` + the no-panic policy intact.
