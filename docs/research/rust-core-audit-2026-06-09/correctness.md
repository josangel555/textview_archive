# correctness — rust-core audit 2026-06-09 (final, post-resume)

## Adversarially confirmed findings

### [S4] hunk_marks loses the Deleted gutter mark when a deletion starts at the top of the file (mark lands on line 0)
- **Where:** `rust-core/crates/core/src/diff.rs:517`
- **Why:** User-visible correctness: the gutter's whole job is to signal "lines were removed here"; a deletion at the very top of a file (a common edit — removing a header, an import block, a license banner) silently shows nothing in both the Rust and Swift engines. The byte-for-byte parity contract masks it forever.
- **Fix:** Clamp the successor key to the first real line: `marks.entry((line_in_new + 1).max(1)).or_insert(DiffMark::Deleted);` in diff.rs:517, plus the mirrored `max(1)` in DiffHunkParser.swift:80 so the A/B contract stays byte-identical. Add a pinned test for `@@ -1,N +0,0 @@` asserting the mark lands on line 1 (and that a later `+` at line 1 still upgrades to Modified).
- **Verifier:** MECHANISM VERIFIED, IMPACT OVERSTATED — real bug, but the headline scenario doesn't occur through the app's actual pipeline; downgrade S3 → S4.

What holds up:
- /Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/core/src/diff.rs:474 sets `line_in_new = n - 1`; for a `+0,0` hunk header that is -1, and each `-` line at diff.rs:517 does `marks.entry(line_in_new + 1).or_insert(DiffMark::Deleted)` → key 0. The doc contract (diff.rs:442-443) says keys are 1-based new-side line numbers, so key 0 never renders. The Swift original (/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/Git/DiffHunkParser.swift:80-81, with lineInNew = -1 from line 38) has the identical behavior, so the A/B parity contract is indeed structurally blind to it. The fix sketch (`.max(1)` clamp mirrored in both engines + pinned test) is correct and cheap.

What does NOT hold up — the claimed user-visible impact:
- The only production feed is the gutter path: DocumentModel.swift:1118/1159 → GitClient.diff(forPath:) → `git diff --no-color HEAD -- <path>` (GitClient.swift:212) — DEFAULT context, not -U0. I reproduced the exact scenario the finding cites (deleting the first two lines of a file, e.g. an import block/header): git emits `@@ -1,5 +1,3 @@` — new-side start 1 → line_in_new = 0 → the `-` lines mark entry(1) → the Deleted tick correctly lands on line 1. So "deleting a header/import block/license banner at the top silently shows nothing" is FALSE for the shipping pipeline; that common edit renders correctly today.
- A `+0,0` header reaches the parser only in two narrow cases (both reproduced with git): (1) the file is FULLY emptied (`@@ -1,N +0,0 @@`) — but then the on-disk file has no content lines at all; a clamped mark would put a tick on the empty line-1 CM6 still renders, which is a nicety, not a missing signal for real surviving content; (2) the user's global git config sets `diff.context=0` (the app passes no -U flag, so user config applies) — a rare config, and under -U0 the parser's successor-line placement has other off-by-one issues anyway (`+4,0` positioning). No other consumer exists: `hunk_marks` is unused by the TUI/web crates (grep empty), so no front-end feeds arbitrary zero-context diffs.

Net: a genuine edge-case parser defect worth the one-line clamp + pinned test in both engines, but not the "common edit silently loses its gutter signal" S3 claimed — the common case works. S4 (edge-case correctness nit).

### [S3] The no-panic lint wall has two enforcement holes: str-range slicing (clippy::string_slice) and arithmetic overflow are not denied
- **Where:** `rust-core/Cargo.toml:61`
- **Why:** The crate's central guarantee — "the core cannot panic, so the FFI cannot kill the host app" — is enforced only by these lints (the gate comment itself records that two panic-capable slices shipped before clippy was wired in). diff.rs is directly behind `mdvcore_diff_parse`/`mdvcore_diff_hunk_marks`; one refactor that derives a slice offset from non-ASCII-safe math turns into a host-app panic (caught → MdvStatus::Panic at best, abort under panic=abort builds) with no gate signal.
- **Fix:** Add `string_slice = "deny"` to `[workspace.lints.clippy]` and convert the ~10 sites to `get(..)`+`?`/early-continue (mechanical; all already have Option-friendly contexts) or add per-site `#[allow(clippy::string_slice, reason = "offset from find() of ASCII pattern")]`. Consider `arithmetic_side_effects = "deny"` for crates/core too (noisier; at minimum fix the hex.rs:27 underflow, see separate finding). Also note crates/highlight deliberately skips the lint set yet does raw `src[cursor..s]` slicing with tree-sitter byte offsets (highlight/src/lib.rs:350-363) — front-end-only, but worth the same `get()` treatment.
- **Verifier:** Attempted refutation failed on every load-bearing claim. (1) Lint hole confirmed: `rust-core/Cargo.toml:52-65` denies `unwrap_used`/`expect_used`/`indexing_slicing`/`panic` but NOT `clippy::string_slice` (a restriction-group lint, covered by neither `all = deny` nor `pedantic = warn`) nor `arithmetic_side_effects`; no per-crate or per-site override exists anywhere in the workspace. (2) The cited str-slice sites all exist verbatim: `crates/core/src/diff.rs:168-171` (`&raw[1..]`), `:200-201`/`:209-210`/`:219-220` (`rest[..mid]`/`rest[mid+3..]`), `:258-271`, `:471-473`, and `crates/core/src/theme.rs:121-123` (`&body[0..2]` etc.). (3) Gate blindness empirically reconfirmed: I ran the exact gate command (`cargo clippy --all-targets` on the workspace manifest) — it finishes green with only doc-markdown warnings, zero slicing diagnostics. (4) FFI reachability confirmed: `mdvcore_diff_parse`/`mdvcore_diff_hunk_marks` at `crates/ffi/src/lib.rs:165,210` route attacker-/caller-supplied diff text into diff.rs. (5) The hex underflow is real as stated: `crates/core/src/hex.rs:27` computes `width * 3 - 1`, so `rendered_row_length(0)` debug-panics on usize underflow; it is `pub` with only a doc-comment precondition ("`width` must be > 0", hex.rs:23). Mitigating nuance the finding doesn't overstate: the FFI path (`mdvcore_hex_render` → `render_all`, hex.rs:60-62) guards `width == 0` before calling it, so the underflow is not FFI-reachable today — it requires a core-API caller violating the documented precondition. (6) The finding's own concession that every current slice site is safe-by-construction is accurate (find()-derived ASCII offsets, length-checked hex body), so this is a regression-guard gap, not a live panic. (7) The gate script's header comment indeed records the precedent — two panic-capable slices in cm_edit.rs shipped (0cead3c) before clippy was wired in — which substantiates the "this exact failure mode already happened here" argument. Severity: S3 is correctly calibrated. Not S2 (no currently-triggerable panic on any FFI path), not S4 (the no-panic lint wall is the crate's central, documented safety contract — Cargo.toml:89-101 panic-strategy notes and the gate exist solely to enforce it — and the enforcement hole has demonstrated historical teeth in this repo). Fix sketch is sound and mechanical: add `string_slice = "deny"` to `[workspace.lints.clippy]`, convert ~10 sites to `get()`+`?` or per-site `#[allow(..., reason)]`, and at minimum fix the hex.rs:27 expression (e.g. `width.saturating_mul(3).saturating_sub(1)` or make the fn handle width==0).

### [S3] MAX_FRAME_LEN (16 MiB) is below the app's legitimate CSV payloads (64 MB loader cap) and is enforced only after fully serializing the frame
- **Where:** `rust-core/crates/core/src/wire.rs:73`
- **Why:** For "the real thing" the level-triggered snapshot is the keystone of the Rust-owns-state design; a hard 16 MiB ceiling means the feature simply errors on large-but-valid files the existing Swift pipeline handles today (silent capability regression), and the serialize-then-reject ordering burns CPU/alloc proportional to the oversized payload on every pull.
- **Fix:** Pick one: (a) raise/parametrize the cap for the trusted in-process FFI (the 16 MiB guard's threat model is a hostile length prefix on DEcode — keep that, but let encode take a caller cap); (b) enforce during encode with a counting `io::Write` wrapper that aborts serialization at the limit (kills the wasted-work half regardless); (c) design the snapshot wire for paging (`offset/limit` rows per pull) — the level-triggered model already tolerates partial views. Also map the failure to a distinct status (e.g. `FrameTooLarge`) so Swift can distinguish "too big" from "corrupt".
- **Verifier:** Every factual claim checks out against the code. (1) Cap: `MAX_FRAME_LEN = 16 * 1024 * 1024` at rust-core/crates/core/src/wire.rs:73, and its doc comment confirms the threat model is the DEcoder ("hostile/corrupt length prefix"), yet it is also enforced on encode. (2) Serialize-then-reject ordering: `encode_frame` (wire.rs:149-178) serializes the entire body into `buf` at lines 152-155 and only then checks `body_len > MAX_FRAME_LEN` at lines 163-166 — the full multi-MB serialization is done and discarded on an oversized payload, exactly as claimed. (3) Both session pulls go through this path: `mdvcore_session_table` calls `wire::encode_frame(session.table())` (crates/ffi/src/lib.rs:489) and `mdvcore_session_snapshot` calls `session.snapshot_frame()` (lib.rs:581 → core/src/session.rs:162-183 → `wire::encode_frame(&view)` at session.rs:183); in both, `Err(_) => MdvStatus::WireError` (lib.rs:495, 587) collapses Encode and Framing faults into one blanket status with no size hint. (4) Size mismatch with the Swift pipeline: `sourceViewMaxBytes = 64 * 1024 * 1024` at Sources/ViewerCore/TextFileLoader.swift:106, and CSVParser.Limits (CSVParser.swift:71-74: 32M total cells, 256M input scalars, 64K chars/cell) deliberately clear a 64 MB file — none of these bound the MessagePack-encoded Table/Snapshot below 16 MiB. MessagePack overhead per cell is small (1-5 bytes), so a legitimate ~17-64 MB CSV produces a frame over the cap and the pull hard-fails. One mitigating fact the finding already half-acknowledges: the Swift `CsvSession` wrapper (Sources/RustCore/CoreClient.swift:100) is referenced nowhere in production Sources outside CoreClient.swift itself (only a test file) — so there is no user-visible breakage today; the regression bites when Stage-2 Rust-owns-state lands, which is precisely the audit's stated production-direction mandate. That forward-looking framing plus the real-today wasted-work inefficiency and the indistinct error status justify S3 (moderate, not serious) — severity is correctly calibrated. Fix sketches are sound: the asymmetric cap (keep decode guard, parametrize/raise encode), a counting-writer abort, snapshot paging, and a distinct FrameTooLarge status are all coherent with the existing design.

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
