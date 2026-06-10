# correctness — rust-core audit 2026-06-09

## UNVERIFIED (verifier died on session limit — re-run on resume)

- [S3] hunk_marks loses the Deleted gutter mark when a deletion starts at the top of the file (mark lands on line 0)
- [S3] The no-panic lint wall has two enforcement holes: str-range slicing (clippy::string_slice) and arithmetic overflow are not denied
- [S3] MAX_FRAME_LEN (16 MiB) is below the app's legitimate CSV payloads (64 MB loader cap) and is enforced only after fully serializing the frame

## S4 nits (unverified by design)

- hex::rendered_row_length(0) panics (debug: subtract-with-overflow) / returns garbage (release wrap) — confirmed (`rust-core/crates/core/src/hex.rs`)
- FFI poisoned-lock recovery silently serves post-panic session state, contradicting the documented drop-and-recreate contract (`rust-core/crates/ffi/src/handle.rs`)
- MdvBuf.data is documented "null when len == 0" but from_vec yields a dangling non-null pointer for empty payloads (`rust-core/crates/ffi/src/buf.rs`)
- CSV delimiter detection and the parser disagree on the quote state machine (detection re-enters quotes mid-field), mis-picking the delimiter on degenerate headers — exact Swift parity, so inherited (`rust-core/crates/core/src/csv.rs`)

---

## Full reviewer report

# rust-core audit — CORRECTNESS + ROBUSTNESS ("rock solid")

**Date:** 2026-06-09 · **Scope:** `rust-core/` workspace only (crates: core, ffi, highlight, tui, web) · **Dimension:** parser edge cases, integer overflow/truncation, the *reality* of the no-panic discipline, error-model holes, state-machine bugs, core↔Swift parity contracts.

**Method:** full read of all 21 `crates/core/src` modules, the entire `crates/ffi` crate (lib/guard/handle/buf/status), `crates/highlight`, workspace manifests + `clippy.toml` + `scripts/rust-core-gate.sh`; spot-scan of the out-of-gate `tui`/`web` monoliths; **empirical verification** of every suspicious site by (a) running the gate's `cargo clippy --all-targets` and (b) compiling a probe binary against the built `libmdvcore_core.rlib`; **parity verification** by line-by-line comparison against the live Swift sources (`CSVParser.swift`, `DiffHunkParser.swift`, `RustDiffAdapter.swift`).

**Bottom line:** this is an unusually disciplined codebase — no S1/S2 found. Every finding below was empirically confirmed or verified against both implementations. The headline risks are (1) a parity-locked gutter-mark bug shared with Swift, (2) two structural holes in the no-panic lint wall, and (3) a 16 MiB frame cap that contradicts the app's 64 MB CSV reality.

---

## Findings

### F1 (S3) — `hunk_marks` drops the Deleted gutter mark for top-of-file deletions
`rust-core/crates/core/src/diff.rs:517` (and `:474`)

For `@@ -1,N +0,0 @@` (pure deletion of the file's first lines), `line_in_new = 0 - 1 = -1`, and each `-` line does `marks.entry(line_in_new + 1)` → **key 0**. Keys are documented as 1-based working-tree lines; line 0 never renders, so the deletion tick vanishes.

**Empirically confirmed** (probe against the built rlib):
```
hunk_marks("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +0,0 @@\n-first\n-second\n ctx\n")
=> {0: Deleted}
```
The Swift original (`Sources/ViewerCore/Git/DiffHunkParser.swift:80-81`) has the identical behavior, so the byte-for-byte A/B parity test can never catch it — and the Swift copy ships in the app **today**.

**Fix:** `marks.entry((line_in_new + 1).max(1)).or_insert(DiffMark::Deleted)` plus the mirrored `max(1)` in Swift, landed together so parity stays green; pin a `@@ -1,N +0,0 @@` test (mark on line 1; later `+` at line 1 still upgrades to Modified).

### F2 (S3) — The no-panic lint wall doesn't cover str slicing or arithmetic overflow
`rust-core/Cargo.toml:61` (deny set), evidence across `diff.rs` / `theme.rs` / `hex.rs`

The workspace denies `indexing_slicing`/`unwrap_used`/`expect_used`/`panic`, and the merge gate is exactly "clippy exits non-zero". But clippy's `indexing_slicing` **does not cover `&str` range slicing** — that's the separate, un-denied `clippy::string_slice`. Verified: the gate clippy run is green while these panic-capable expressions exist:

- `diff.rs:168-171` — `&raw[1..]` on the FFI-reachable hunk-body path (`mdvcore_diff_parse`)
- `diff.rs:200-202, 258-271, 471-473` — `rest[..mid]`, `raw[after_first..second]`, `line[plus+1..]`, …
- `theme.rs:121-123` — `&body[0..2]` etc.

All current sites are safe-by-construction (offsets from `find()` of ASCII patterns), but **nothing enforces that invariant** — the exact erosion mode the gate header itself records ("two panic-capable slices shipped before clippy ever ran"). Likewise `arithmetic_side_effects` is not denied, and a real instance exists (F3). `crates/highlight` additionally opts out of the lint set entirely yet slices `src[cursor..s]` with tree-sitter byte offsets (`highlight/src/lib.rs:350-363`) — front-end-only exposure.

**Fix:** deny `clippy::string_slice` workspace-wide; convert the ~10 sites to `get(..)` (mechanical) or add per-site `#[allow(..., reason)]`. Consider `arithmetic_side_effects = "deny"` for crates/core, or at minimum fix F3.

### F3 (S4) — `hex::rendered_row_length(0)` panics (confirmed)
`rust-core/crates/core/src/hex.rs:27`

`8 + 2 + (width * 3 - 1) + …` underflows for `width == 0`. Probe output: `panicked at crates/core/src/hex.rs:27:13: attempt to subtract with overflow`. With overflow-checks off it returns ~`usize::MAX` instead (poisoning any caller's capacity math). No current caller passes 0 (`render_all`/`row_count` guard separately), but it's a `pub` API of the "never panics" crate, and `mdvcore_hex_render` accepts an arbitrary `u32` width from Swift. **Fix:** make it total (`width.max(1)` or `Option`), pin a test.

### F4 (S3) — `MAX_FRAME_LEN` (16 MiB) vs 64 MB CSV reality; cap enforced after full serialization
`rust-core/crates/core/src/wire.rs:73` and `:152-167`; `session.rs:162-184`

`encode_frame` serializes the **entire** body, then rejects it if > 16 MiB. The Swift loader feeds CSVs up to 64 MB (`CSVParser.swift` Limits sized for it), so `mdvcore_session_table` / `snapshot_frame` on a legitimate 17 MB+ CSV does tens of MB of serialization work and then returns a blanket `WireError`. The diff path degrades gracefully (RustDiffAdapter → Swift fallback) but the Stage-2 CSV session has no Swift twin once state ownership moves to Rust — the keystone feature simply fails on large valid files. **Fix:** keep the 16 MiB guard on *decode* (hostile length prefix), but for encode: caller-supplied cap, a counting-writer that aborts at the limit, and/or a paged snapshot protocol (`offset/limit` — the level-triggered model tolerates partial views). Add a distinct `FrameTooLarge` status.

### F5 (S4) — Poison-recovery contradicts the documented drop-and-recreate contract
`rust-core/crates/ffi/src/handle.rs:104-108`

`with()` recovers a poisoned mutex via `p.into_inner()` and serves the state, while `guard.rs` and `status.rs::Panic` both document "drop & recreate the handle — state may be suspect". The realistic in-lock panic source is a host trace `Sink` (trace.rs only *asks* sinks not to panic). Today's mutation windows happen to be atomic w.r.t. trace calls (Span::enter precedes mutations; the event follows them), so true torn state is hard to reach — but the boundary's two halves disagree about its most safety-critical story. **Fix:** either latch dead-on-poison (matches Swift's `.handleDead` expectation, CoreClient.swift:197) or rewrite the docs and enforce build-then-commit mutations.

### F6 (S4) — `MdvBuf.data` "null when len == 0" is false for empty payloads
`rust-core/crates/ffi/src/buf.rs:15` vs `from_vec` (`:36-43`)

`Vec::as_mut_ptr()` on an empty vec is a **dangling non-null** sentinel. Reachable: `mdvcore_hex_render` of empty input (ffi/lib.rs:285-287). `free_in_place` is safe (gates on `cap != 0`), but the cbindgen-exported contract invites Swift to test `data != NULL` as "has bytes". **Fix:** normalize empty→`MdvBuf::empty()` in `from_vec`, correct the field doc ("length is the only validity signal").

### F7 (S4) — CSV delimiter detection vs parser quote-model asymmetry (parity-locked with Swift)
`rust-core/crates/core/src/csv.rs:84` vs `:201`

Detection re-enters quote mode on any `"` outside quotes; the parser only opens quotes at field start (`field.is_empty()`). Confirmed: `"x"a"y;1;2,z\nq;w;e\n` detects `,` (the `;`s after the re-entered quote are never counted) → header `["xa\"y;1;2", "z"]`, shredding a `;`-shaped table. Verified identical in `CSVParser.swift:94-133` + `:247` — inherited by deliberate parity, both wrong together. **Fix:** align detection to the parser's field-start rule on both sides in one commit; pin the degenerate shape.

---

## Verified-solid (checked, no issue)

- **wire.rs framing**: trailing-byte enforcement after decode (cursor-position check) is correct and tested; decode-side `MAX_FRAME_LEN` + exact-length checks are right; the single-alloc encode is pinned byte-identical to the legacy path; `u32` casts all bounded by the cap.
- **cm_edit.rs**: UTF-16 unit indexing matches CM6; bounds/overlap validation is airtight (sorted, `last_to` sweep); the validating `String::from_utf16` (no U+FFFD substitution) correctly turns split-surrogate edits into a resync signal; equal-position inserts keep stable input order.
- **csv.rs parse**: quote/CRLF/bare-CR state machine, caps (cell/row/total/scalars) and the `…` marker all match Swift exactly (line-by-line comparison); the trailing-flush and terminal-empty-row drop are parity-correct. (The flush can exceed `max_total_cells` by one row — Swift does the same; cosmetic.)
- **diff.rs structured parse**: 4-strategy `diff --git` splitter, `/dev/null` + rename path precedence, coordinate clamping (`MAX_COORD`), comma-led/empty coords — all pinned by tests and Swift-faithful; all str slicing offsets are ASCII-pattern-derived (safe, but see F2).
- **filter.rs**: ASCII fast path is parity-tested against the Unicode reference (İ/ß cases pinned); `windows()`-based matcher is panic-free.
- **find.rs / nav.rs / outline.rs / meta.rs / whitespace.rs / git.rs / image.rs / format.rs**: byte-offset hygiene is consistently `get()`-based; outline's fence tracking (marker char + run length, backtick-info-string rule) is right; format.rs JSON walker is depth-capped (128) with a 100k-deep regression test, and `pretty_xml` emission is iterative (depth counter) so it can't overflow; image header parsers are fully bounds-checked (`checked_add` + `get`) including the JPEG marker walk; `meta::line_ending` never double-counts CRLF.
- **FFI discipline**: every entry point null-checks, pre-writes a safe-to-free `MdvBuf::empty()`, guards with `catch_unwind`, and the Busy-not-block `try_lock` model is sound; `unsafe impl Send/Sync` justification is correct (mutex-mediated); `cbindgen` opaque handle can't be fabricated by Swift.
- **Gate coverage map** (intentional, worth knowing): the merge gate lints/tests **core + ffi only**; `tui`, `web`, `highlight` deliberately skip the no-panic lint set and the gate. The web server's request handling (header-cap via `Take` + newline-termination checks, canonicalize+starts_with confinement) and the TUI (one non-test `expect` with a just-filled invariant) look clean on spot-check.

## Cross-cutting recommendations

1. **Close the lint holes** (F2) before scaling the core — the no-panic guarantee is currently convention-plus-luck for two whole panic classes.
2. **Decide the large-payload story** (F4) before Stage-2 CSV goes live; the cap/work-ordering is a design constraint, not just a bug.
3. **Treat parity-locked bugs as a category**: F1 and F7 show the A/B contract preserves Swift's bugs by construction. Each parity module deserves one "is the *contract itself* right?" pass with fixes landed on both sides simultaneously.
4. When the FFI grows mutating multi-step operations, adopt build-then-commit state updates so the poison-recovery story (F5) becomes provably safe instead of accidentally safe.
