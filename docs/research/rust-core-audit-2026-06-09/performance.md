# performance — rust-core audit 2026-06-09

## Adversarially confirmed findings

### [S3] cm_apply ships the FULL document across FFI in BOTH directions per edit batch (~10x doc-size memory traffic per 200ms debounce tick)
- **Where:** `/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/core/src/cm_edit.rs:46`
- **Why it matters:** This is the highest-frequency FFI path the Swift app has (typing). O(doc) work per O(1) edit means latency and allocator pressure scale with file size, not edit size; on multi-MB docs the 200 ms debounce window can be eaten by copying alone, and GC/allocator churn on both sides hits the editor's responsiveness.
- **Fix sketch:** For the production core: make the editor doc STATEFUL Rust-side (a handle owning a rope/gap-buffer keyed in UTF-16 code units, or piece-table over the original + add buffer), so the wire carries only `{from,to,insert}` per batch and an occasional full-resync. Interim cheap wins in the current stateless shape: `#[serde(borrow)] base: Cow<'a, str>` to skip the decode copy; skip the full Vec<u16> materialization by walking UTF-8 with a UTF-16 offset cursor (convert only the edited spans); pre-size `out` with `base_units.len() + Σ insert.len()`.
- **Verifier:** Rust-side evidence verified exactly: cm_edit.rs ApplyRequest carries the full doc (lines 100-104), apply_wire decodes it to an owned String (131-140), apply materializes the full Vec<u16> base (51) plus a second full Vec<u16> out (73) and a validating from_utf16 (93), and the full result text rides back in the response frame; Swift CoreClient.swift:298-330 adds the full-doc request encode plus two more response copies (Array + unframe). The stateless contract is genuinely O(doc) memory traffic per O(1) edit in both directions, and the module is explicitly the designated production migration path for editor edits (slice #2) — the fix direction (stateful Rust-side doc handle, wire carries only deltas) is correct, so the finding is real. HOWEVER the severity rests on a hot-path claim that is false: CodeMirrorEditorView.swift:572 calls the Swift CMEditApplier directly and never routes through RustCMEditAdapter — the adapter's only caller outside its definition is the A/B test (Tests/RustCoreTests/CMEditApplyABTests.swift:56), and the .cmEdit gate is default-OFF (RustCoreGates.swift). So there is no per-keystroke FFI traffic in the shipped app today; the 10 MB-per-tick cost is contingent on future wiring plus an opt-in gate flip, and even then ~10 MB of copies costs low-single-digit milliseconds, not the debounce window. Real architectural debt for the production core, but a forward-looking design correction rather than a present serious performance defect: S2 → S3.

### [S3] TUI redraws run O(file)/O(table) work EVERY frame: full text-metrics scans, full filter re-match, full cell-find re-scan per keypress
- **Where:** `/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/tui/src/main.rs:2520`
- **Why it matters:** On a 10 MB text file or 100k-row CSV, every keystroke (including pure scroll keys) burns tens of milliseconds rescanning unchanged data — visible input lag that scales with file size while the rendered viewport is constant-size.
- **Fix sketch:** Cache per-Preview invariants once at load: TextMetrics/encoding/line-ending labels are immutable per `raw` (compute in Preview::new, store the formatted badge String). Cache `filtered_table_indices` keyed by needle (recompute only when `table_needle()` changes — same CachedView pattern session.rs:36-45 already implements core-side); cache `find_in_table` hits keyed by (query, filter-needle). Fold text_metrics' three passes into one loop while at it.
- **Verifier:** VERIFIED MECHANICS — every citation checks out:
(1) Event loop: `terminal.draw(|frame| self.draw(frame))` runs once per `event::read()` key event (/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/tui/src/main.rs:1981-1989), so every keypress (including pure scroll keys) triggers a full redraw.
(2) Text-mode badge: main.rs:2520-2529 recomputes `String::from_utf8_lossy(&p.raw)` (full validation pass, full copy on any invalid byte) + `meta::text_metrics` (meta.rs:113-122 — three separate full passes: `chars().count()`, `split_whitespace().count()`, `bytes().filter()`) + `meta::line_ending` (meta.rs:48-74, full byte walk) on EVERY frame, despite `p.raw` being immutable per Preview. ~5 full scans per keystroke confirmed.
(3) Table mode: main.rs:2319 `p.filtered_table_indices(header, rows)` → `filter::matching_indices_in` (filter.rs:69+) re-scans every row per frame; main.rs:195-198 `content_len()` runs the SAME full filter scan again during key handling (e.g. main.rs:1970); even with an EMPTY filter it allocates a full `Vec<u32>` of 0..rows.len() per call (filter.rs:70-74). main.rs:2367 `find::find_in_table` rescans all shown rows per frame when a find query is active.
(4) The contrast is real and damning: `ListRow` (main.rs:127-136) exists precisely because "rebuilding the label Strings per frame would scale per-frame work with directory size", and `hl_cache` (main.rs:160-166) exists because "per-frame re-parse would be far too slow" — the codebase's own stated standard, unapplied to the badge/filter/find paths. Fix sketch is sound.

SEVERITY MISCALIBRATED — the finding's impact scenario is wrong: ALL file loads go through `read_capped(path, PREVIEW_CAP)` with `PREVIEW_CAP = 1 MiB` (main.rs:58, 750, 1054, 1109; truncation enforced at main.rs:2973-2974). A "10 MB text file" is truncated to 1 MiB before any of this code sees it, and a "100k-row CSV" can only exist within the 1 MiB cap. So the worst case is ~5 MiB scanned + an O(rows) Vec alloc (×2) per keystroke — realistically low single-digit milliseconds, not "tens of milliseconds ... scales with file size". Input lag does NOT grow unboundedly; it plateaus at the cap. Additionally, redraws are event-driven (blocking `event::read`), not continuous, and the TUI crate is outside default-members and the merge gate — it is a secondary front-end, not the production FFI core path. Real, worth fixing exactly as sketched (compute badge in Preview construction; cache filtered indices keyed on needle), but a bounded-cost efficiency wart in a non-gated front-end is S3 (moderate), not S2.

### [S3] highlight() recompiles the tree-sitter HighlightConfiguration (query parse + compile) on every call; web tier pays it per HTTP request
- **Where:** `/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/highlight/src/lib.rs:268`
- **Why it matters:** Query compilation for big grammars (typescript, c_sharp, swift) is milliseconds-scale and 100% redundant after the first call per language; on the web tier it's the dominant per-request cost for source files, repeated for trivially cacheable navigation clicks.
- **Fix sketch:** Cache `HighlightConfiguration` per `Lang` in a `thread_local!` (or `OnceLock<Mutex<HashMap<Lang, ...>>>` if Send allows) inside the highlight crate so all front-ends benefit; `configure(HIGHLIGHT_NAMES)` once at build. Also return `&'static str` (Cow) from `grammar()` for the non-concat languages instead of `to_string()`.
- **Verifier:** Every element of the finding checks out against the code.

1. Per-call recompilation: `/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/highlight/src/lib.rs:268-274` — `highlight()` calls `lang.grammar()` then `HighlightConfiguration::new(language, lang.name(), &query, "", "")` plus `config.configure(HIGHLIGHT_NAMES)` on every invocation, with no OnceLock/thread_local/static cache anywhere in the 522-line crate. `grammar()` (lib.rs:112-177) returns an owned `String` per call; TypeScript/TSX/C++ build it via `format!` concatenation of two multi-KB embedded queries (lib.rs:128-132, 137-140, 154-158).

2. TUI caches the result: `/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/tui/src/main.rs:166` (`hl_cache: RefCell<Option<Vec<Vec<Segment>>>>`) with lazy fill at lines 182-188 — so the TUI pays the compile once per opened file, as claimed.

3. Web tier pays per request: `/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/web/src/main.rs:1063-1066` calls `mdvcore_highlight::highlight_lines(&lines.join("\n"), lang)` inside `content_html` (defined at main.rs:913), which is invoked from `render_view_filtered` (main.rs:687) on every `/view` request — page load, every `?find=`/`&fmatch=` step, every goto click. There is no result cache in the web crate, and `lines.join("\n")` reallocates the full document each time, exactly as claimed.

4. The crate's own doc comment (lib.rs:110-111: "the front-ends cache the highlight result, so `grammar()` runs once per file") encodes an invariant the web front-end violates — strong evidence this is an unintended inefficiency, not a deliberate trade-off.

Mitigating scope I checked: the FFI crate (the key SwiftUI path) does not depend on or call the highlight crate at all (grep of crates/ffi/src + Cargo.toml: zero hits), and the web tier is out of default-members / not gate-covered. So the blast radius is the web front-end's per-request latency (ms-scale redundant query compilation for the larger grammars plus a full-document join allocation) — a real, trivially fixable architectural perf debt against the stated "hyper efficient" goal, but not serious/critical. S3 (moderate) is correctly calibrated; the fix sketch (per-Lang cached HighlightConfiguration in the highlight crate, Cow/&'static str for non-concat queries) is sound.

### [S3] Table storage is Vec<Vec<String>> — 2 allocations + 48B header overhead per row plus one heap String per cell; ~2M+ allocations for a 1M-cell CSV
- **Where:** `/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/core/src/wire.rs:28`
- **Why it matters:** Owner's brief is a HYPER-EFFICIENT production core; the table is the core's central data structure and is rescanned per filter keystroke. Allocation count dominates open time and the scattered layout dominates filter-scan time on large files.
- **Fix sketch:** Arena layout: one contiguous `String` (or Vec<u8>) holding all cell bytes + a flat `Vec<u32>` of offsets (cells addressed as `offsets[row*cols+i]..offsets[...+1]`), with `cell(row, col) -> &str` accessors. Filter scans become a linear walk over one buffer (memchr-friendly); serialization can emit straight from spans. Keep `Table` as the wire DTO; introduce the compact type as the session's internal store and project to wire shapes on demand.
- **Verifier:** Verified against code: wire.rs:28-30 defines Table with header: Vec<String> and rows: Vec<Vec<String>> exactly as cited. session.rs:28 shows CsvSession owns this Table as its internal store (not just a wire DTO), and set_filter (session.rs:104-119) re-runs filter::matching_indices (session.rs:208) which iterates every row and cell (filter.rs:100-108), pointer-chasing each individually heap-allocated String. The 1M-cell scenario is well within the default caps (csv.rs:47, max_total_cells = 32,000,000). Allocation math holds: ~1 heap block per non-empty cell plus 1 per row Vec buffer ≈ 1.1M allocations for a 100k-row × 10-col table; per-cell overhead (24 B String struct + malloc-rounded block) plausibly yields the claimed 40-60 MB overhead for ~10 MB of data. Mitigations checked and found insufficient to refute: empty cells don't allocate, the ASCII fast path avoids scan-time to_lowercase() allocations, and the session uses the no-clone matching_indices path — but none address the scattered layout or open-time allocation count. Minor accounting imprecision in the headline ("2 allocations + 48B per row" — actually 1 alloc per row, the Vec header lives inline in the outer buffer) doesn't change the substance. Severity S3 is calibrated: pure efficiency (no correctness/safety issue, so not S2), but it's the central data structure on the per-keystroke hot path under an explicit hyper-efficiency mandate, so not a nit. Fix sketch (contiguous byte arena + flat u32 offsets, Table retained as wire DTO) is sound.

### [S3] find_matches allocates a fresh String for EVERY line — and the Case::Sensitive path copies each line despite the doc claiming "no allocation"
- **Where:** `/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/core/src/find.rs:190`
- **Why it matters:** The grep overlay walks every file in a folder; per-line allocation makes the dominant cost malloc, not matching. The misleading doc comment also invites callers to treat Sensitive as free.
- **Fix sketch:** Return `Cow<'_, str>` from fold (Borrowed for Sensitive) — zero-alloc sensitive path immediately. For Insensitive, drop fold entirely and scan with a no-alloc ASCII-case-folded window search (the crate already has exactly this: `filter::ascii_contains_ignore_case`, filter.rs:123-130 — generalize it to report offsets).
- **Verifier:** Verified against the code. (1) find.rs:190-195: fold() does `Case::Sensitive => s.to_string()` — a full String copy — while the doc comment at find.rs:187-188 claims "(no allocation when `Sensitive`)"; direct contradiction. (2) find.rs:61: find_matches calls fold(line, case) inside the per-line loop, so one fresh String allocation per line per call in BOTH case modes. (3) All cited callers check out: tui/main.rs:1903 (find_matches), tui/main.rs:1372 (grep_lines per file in the folder-grep walk), web/main.rs:1009 (find_matches per request), find.rs:142 (grep_lines→find_matches). (4) The fix-sketch helper filter.rs:123-131 ascii_contains_ignore_case exists and is the claimed no-alloc windows().eq_ignore_ascii_case scan. Minor nuance: the cited callers all use Case::Insensitive, so a Cow Borrowed Sensitive path alone wouldn't speed them — but the per-line allocation churn they incur is real, and the doc/code contradiction stands independently. Severity S3 is calibrated: pure perf inefficiency + misleading doc, no correctness or security impact, but multiplied across every file in folder grep in a core with an explicit efficiency mandate.

## UNVERIFIED (verifier died on session limit — re-run on resume)

- [S2] Level-triggered snapshot serializes ALL surviving rows per pull; full-table frame per filter change, and the 16 MiB MAX_FRAME_LEN hard-fails large tables
- [S3] CSV parser is char-at-a-time with per-char cap checks and per-char String::push — several× slower than bulk byte-span scanning
- [S3] Wire request decoding copies whole payloads into owned Strings — zero-copy borrowed deserialization is available and unused
- [S3] hex_search_find is a naive O(n·m) scan with a bounds-checked subslice compare at every position
- [S3] Named-map MessagePack encodes repeat field-name keys per ELEMENT in hot collections — ~41 bytes/line of pure key text in diff frames
- [S3] Swift boundary does a DOUBLE full copy of every response frame: MdvBuf→Array, then unframe's Array(frame[4...])

## S4 nits (unverified by design)

- trace facade: field values are eagerly allocated and an RwLock is taken per emit even when NO sink is installed; spans cost two lock round-trips (`/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/core/src/trace.rs`)
- nav sort comparator allocates two lowercase Strings per comparison — O(n log n) alloc churn per directory sort (`/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/core/src/nav.rs`)
- Web table view clones every surviving row per request via filter::apply_rows where index projection (already used by the TUI) suffices (`/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/web/src/main.rs`)
- No incremental filter narrowing: each query keystroke rescans ALL rows even when the new needle extends the old one (`/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/core/src/session.rs`)
- highlight Segment owns a String per token-run per line — O(file) small-String churn where (Range, TokenKind) borrows would do (`/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/highlight/src/lib.rs`)
- Web tier re-reads, re-shapes, re-parses and re-highlights the ENTIRE file on every request — no (path, mtime) memoization (`/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/web/src/main.rs`)

---

## Full reviewer report

# rust-core performance + efficiency audit (2026-06-09)

Scope: `/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/` (crates: `core`, `ffi`, `highlight`, `tui`, `web`), with FFI hot-path weighting derived from the actual Swift call sites in `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/RustCore/CoreClient.swift` and the `ViewerCore` adapters.

## Hot-path map (how Swift actually drives the FFI)

| FFI entry | Swift driver | Frequency | Payload |
|---|---|---|---|
| `mdvcore_cm_apply` | `CodeMirrorEditorView` → `CMEditApplier.apply` (`Sources/ViewerUI/CodeMirrorEditorView.swift:15,572`), 200 ms JS debounce | **per typing burst** | full doc both ways |
| `mdvcore_session_set_filter` + `mdvcore_session_snapshot` | CSV session filter | per filter keystroke | full visible row set out |
| `mdvcore_diff_parse` + `mdvcore_diff_hunk_marks` | `RustDiffAdapter` (`Sources/ViewerCore/RustDiffAdapter.swift`) | per git-diff refresh of viewed file — **same diff text crosses TWICE** (parse + marks) | full diff text in, full structured diff out |
| `mdvcore_hex_search` | `RustHexSearchAdapter` | per hex search | full buffer scanned |
| `mdvcore_hex_render` | hex view open | per open | ~4.5× input size out (18 MB for 4 MB) |
| `mdvcore_session_open` / `_table` | CSV open | per open | full table out |

All adapters are `RustCoreFallback`-gated (default-OFF), so today's production traffic is low — but this audit weights by the intended end-state where the gates flip on.

The TUI redraws on **every key event** (`crates/tui/src/main.rs:1982-1984`); the web tier rebuilds **every page per request**. Those are the front-end "frames".

## S2 — serious

### 1. `cm_apply`: full-document round trip per edit batch
`crates/core/src/cm_edit.rs:100-104` (`ApplyRequest { base: String, … }`), `:46-93` (`apply`), `crates/ffi/src/lib.rs:119`.
The stateless contract means each 200 ms debounce tick while typing moves ≈10× the document size through allocate/copy stages: Swift msgpack encode of `base` → frame; Rust decode to owned `String`; `encode_utf16().collect::<Vec<u16>>()` (2× bytes, `:51`); spliced second `Vec<u16>` (`:73`); validating `String::from_utf16` (`:93`); full response frame; Swift `Array` copy; Swift unframe copy; Swift String decode. **1 MB doc ⇒ ~10 MB traffic per tick to apply a few bytes of edit.**
**Fix:** stateful doc handle Rust-side (rope/piece-table indexed in UTF-16 units), edits-only wire. Interim: `#[serde(borrow)] Cow<str>` base; splice UTF-8 spans directly without materializing the full UTF-16 mirror; pre-size the output.

### 2. Snapshot pulls serialize all surviving rows; 16 MiB frame cap breaks big tables
`crates/core/src/session.rs:162-184`, `crates/core/src/wire.rs:73,163`, `crates/ffi/src/lib.rs:560`.
`snapshot_frame` is admirably clone-free Rust-side (borrow-based `SnapshotView`), but the *frame* still carries every visible row — data Swift already received via `mdvcore_session_table` at open. 100k×10 cells ≈ 9 MB encode + full Swift decode per filter change. And `MAX_FRAME_LEN = 16 MiB` hard-fails tables whose body exceeds it, while `csv::Limits` admits up to 32M cells (`csv.rs:48`) — the Rust path simply errors (`WireError`) on exactly the large inputs it should excel at.
**Fix:** indices-only snapshot (4 B/row) + Swift-side projection from the retained Table; or windowed `snapshot(offset, limit)` viewport pulls; chunked transfer for the >16 MiB open-time table pull.

### 3. TUI per-frame O(file)/O(table) recomputation
`crates/tui/src/main.rs:2520-2529` — every Text-mode frame: `String::from_utf8_lossy(&p.raw)` (full pass; full **copy** if the file has any invalid UTF-8) + `meta::text_metrics` (`crates/core/src/meta.rs:113-122`, 3 separate full passes) + `meta::line_ending` (full pass) ⇒ ~5 file scans per keypress, for a static badge.
Table mode: `filtered_table_indices` re-runs the full filter match per frame (`:2319`) and *again* in `content_len()` during scroll handling (`:198`); `find_in_table` rescans all shown rows per frame (`:2367`). The codebase already knows better — `ListRow` (`:127-136`) and `hl_cache` (`:166`) exist precisely to avoid per-frame rebuilds; these paths missed the pattern.
**Fix:** compute badge/metrics once per `Preview`; cache filter indices keyed by needle (the `CachedView` pattern from `session.rs:36-45`); cache table find hits keyed by (query, needle); single-pass `text_metrics`.

## S3 — moderate

### 4. `highlight()` recompiles the tree-sitter query per call; web pays per request
`crates/highlight/src/lib.rs:268-274` (+ owned query Strings / `format!` concats in `grammar()`, `:112-177`). The web tier calls `highlight_lines(&lines.join("\n"), lang)` per HTTP request (`crates/web/src/main.rs:1066`) — query compile + full reparse + full-document `join` for every navigation click. **Fix:** cache `HighlightConfiguration` per `Lang` (thread_local / OnceLock) inside the crate; all front-ends inherit the win.

### 5. CSV parser: char-at-a-time tokenization
`crates/core/src/csv.rs:174-227` — per Unicode scalar: 2 cap compares + state branches + `field.push(c)`. Bulk span scanning (byte-find the next `delim/\n/\r/"` then `push_str` the run) is typically 5-10× faster; this is the open-time cost of every CSV session. `memchr` would help (dep **PROPOSAL** — owner approval required); a hand-rolled byte loop already gets most of it.

### 6. `Table` = `Vec<Vec<String>>` — allocation-heavy, cache-hostile
`crates/core/src/wire.rs:28-30`. 1M-cell table ≈ 1.1M allocations, ~40-60 MB overhead for ~10 MB of payload; per-keystroke filter scans pointer-chase scattered cells (`filter.rs:100-110`). **Fix:** arena layout (one contiguous byte buffer + flat `Vec<u32>` offsets, `cell(r,c) -> &str`) as the session's internal store; keep `Table` as a wire DTO.

### 7. `find_matches` allocates per line; `Case::Sensitive` copies every line despite a "no allocation" doc claim
`crates/core/src/find.rs:190-195` (`fold` → `s.to_string()`), used per line in `:53-77`; multiplied across files by `grep_lines` (`:138-154`, TUI folder grep `tui/main.rs:1372`). **Fix:** `Cow` for Sensitive; replace the Insensitive fold-then-find with the no-alloc ASCII window scan already present at `filter.rs:123-130`.

### 8. Zero-copy misses in wire request structs
`crates/core/src/diff.rs:410-413` (`ParseRequest { text: String }` — used by *both* `parse_wire` and `hunk_marks_wire`, so one refresh decodes the same diff text twice) and `cm_edit.rs:100-104`. rmp-serde supports `#[serde(borrow)]` `&str`/`Cow` from the frame slice the FFI already holds. A combined `diff_parse_and_marks` call would also halve the crossings.

### 9. `hex_search_find` is O(n·m) position-by-position
`crates/core/src/hex.rs:171-189` — bounds-checked subslice compare at every offset, no first-byte skip. 5-20× available from memchr-style skipping (memchr = dep **PROPOSAL**; an `iter().position(|&b| b == first)` pre-filter is dependency-free and already a big win).

### 10. Named-map MessagePack repeats key strings per element in hot collections
`crates/core/src/diff.rs:28-38` (`Line`: ≈41 B/line of key text + string enums ⇒ ≈4-5 MB of literals in a 100k-line diff frame), `:528-532` (`MarkWire`). The Swift decoder is the hand-rolled `MsgPackReader`, not Codable, so positional tuples for per-element records are feasible while keeping named maps at the envelope level. The owner's "compact binary RPC" goal argues for this.

### 11. Swift boundary double-copies every response frame
`Sources/RustCore/CoreClient.swift:221` (MdvBuf → `Array`) then `:234` (`Array(frame[4...])` — second full copy to drop 4 bytes). Hex render: ~36 MB transient copying for a 4 MB file. Rust's `MdvBuf` is already zero-copy-out; consume it via `Data(bytesNoCopy:deallocator:)`/raw-buffer reads with an offset-aware reader. (Swift-side, but it is the FFI boundary cost model.)

## S4 — nits / opportunities

- **trace facade**: eager field allocation + RwLock acquisition per emit with no sink; spans = 2 lock ops each (`crates/core/src/trace.rs:108-148`; call sites `session.rs:58-61,113-117`, `csv.rs:129`). AtomicBool fast path + lazy `event_with(|| …)`.
- **nav sort**: `name_cmp` allocates two lowercase Strings per comparison (`crates/core/src/nav.rs:338-341`) — ~260k allocs sorting a 10k-entry dir. Char-iterator compare or `sort_by_cached_key`.
- **web table filter** clones all surviving rows (`crates/web/src/main.rs:1083` via `filter::apply_rows`, `filter.rs:149-153`) where the TUI's borrow projection (`tui/main.rs:2320-2321`) shows the clone-free shape.
- **No incremental filter narrowing** (`crates/core/src/session.rs:196-214`): an extended substring needle can only shrink the survivor set; scan the cached indices instead of the full table on the append-keystroke case.
- **highlight `Segment` owns Strings** (`crates/highlight/src/lib.rs:315-319`) — O(file) small-String cache, plus per-frame `seg.text.clone()` in the TUI (`tui/main.rs:2585`). Ranges/Cow + borrowed ratatui Spans.
- **web tier has zero memoization** (`crates/web/src/main.rs:1746, 997-1077`): per request = re-read + re-shape + re-parse + re-highlight + render *all* lines to HTML. A tiny (path, mtime, len)-keyed LRU + line-windowed rendering removes nearly all of it.

## Things checked and found GOOD (no finding)

- `wire::encode_frame` single-allocation prefix-backfill rewrite (`wire.rs:149-178`) with a byte-identity oracle test — exactly right.
- `snapshot_frame`'s borrow-based `SnapshotView` (`session.rs:224-233`) eliminates the per-pull row clone Rust-side (the remaining cost is the *protocol*, finding #2).
- `filter::matching_indices` ASCII fast path (`filter.rs:86-98,123-130`) is no-alloc with a Unicode-parity test suite.
- `hex::render_all` pre-sizes its buffer exactly (`hex.rs:72`) and the raw-UTF-8 (non-framed) output choice for hex/indent (`ffi/src/lib.rs:246-249`) avoids a pointless re-decode.
- `MdvBuf` transfers the Vec allocation itself (`ffi/src/buf.rs:38-44`) — zero-copy out of Rust.
- `column_widths` samples a bounded row prefix (`view.rs:204`).
- App links the `dist` profile (opt-level 3, panic=unwind), not the size-opt `release` — `scripts/build-rust-core.sh` rejects `release` for the app link path.
- `tui` caches highlights per Preview (`hl_cache`) and file-list rows (`ListRow`).

## Dependency proposals (owner approval required — flagged, not assumed)

1. **memchr** (`memchr` crate): SIMD memmem/byte-find for `hex_search_find`, the CSV span scanner, and `find_matches`. Tiny, no_std-capable, ~0 transitive deps, the most-downloaded crate on crates.io after serde-family; maintained by BurntSushi.
2. **criterion** (dev-dependency only): the workspace has **no benchmarks at all** — none of the perf-sensitive paths (csv parse, filter scan, snapshot encode, cm apply, hex search) is regression-guarded. Alternative without a dep: `#[bench]`-style timed asserts in an ignored-by-default test lane, mirroring the Swift `FoldBench` pattern.

## Suggested priority order

1. Finding #1 (cm_apply statefulness) — the per-keystroke path and the architectural decision that shapes the production core.
2. Finding #2 (indices-only/windowed snapshot + frame-cap strategy) — same protocol family, decide together.
3. Finding #3 (TUI per-frame caching) — cheap, immediately user-visible.
4. Findings #4, #7, #11 — contained, high ratio wins.
5. Findings #5, #6 — the CSV ingestion overhaul (parser + storage), best done as one piece with the arena layout.
6. The rest as paper-cut batch work, plus the bench lane so none of it regresses silently.