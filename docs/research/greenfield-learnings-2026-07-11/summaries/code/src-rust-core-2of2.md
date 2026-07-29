# Rust-Core Crates/Core — Slice 2 of 2 (Lines 30-57 of Sorted .rs Files)

## File Inventory

**rust-core/crates/core/src/git.rs** (~312 LOC) — pure git porcelain-v1 status parser → `RepoStatus` enum
- notable: security-hardening flags (SANDBOX_ARGS) as constants pinned to prevent drift; proptest for no-panic robustness on arbitrary input; `saturating_add` throughout against counter overflows
- carry: KEEP — security-hardened parsing + property tests set a standard for untrusted input handling

**rust-core/crates/core/src/hex.rs** (~577 LOC) — hex dump rendering (port of Swift HexLayout) + hex search (memchr memmem)
- notable: audit TSK-540 for overflow guarding (width clamping); TSK-399 leverages memchr for SIMD substring search; wire aux channel for frame-cap-exempt large payloads (TSK-580); careful width=0 divide-by-zero handling
- carry: KEEP — the aux bulk side-channel pattern is reusable for other large-buffer operations; memchr integration beats hand-rolled scanning

**rust-core/crates/core/src/history.rs** (~92 LOC) — MRU list logic, pure + reusable
- notable: minimal, stateless; property test pinning the dedup-front-capped invariant
- carry: KEEP — small, focused module; reusable pattern for any client-side MRU needs

**rust-core/crates/core/src/html_patch.rs** (~456 LOC) — top-level DOM block diffing for persistent WebView (TSK-838)
- notable: proptest for partition invariant (split→concat == input); handles void/self-close/comment blocks correctly; robust HTML scanner avoiding full parser dependency; minimal-middle LCS noted as future refinement
- carry: KEEP — the partition invariant + proptest pattern is load-bearing for any framing mechanism

**rust-core/crates/core/src/image.rs** (~250+ LOC) — raster image header parser (PNG/GIF/JPEG/BMP/WEBP)
- notable: no dependencies, bounds-checked byte access via `.get()`, panic-free; handles JPEG marker walking + WEBP codec variants (VP8/VP8L/VP8X) correctly
- carry: KEEP — dependency-free, panic-free header identification is a good model for media-type sniffing

**rust-core/crates/core/src/indent.rs** (~250+ LOC) — indentation style detection (port of Swift IndentDetector)
- notable: BTreeMap histogram for width scoring; CRLF-aware blank-line skipping (guards against Windows CRLF pollution); largest-divisor-wins heuristic for ambiguous widths; wire_aux for frame-cap-exempt text
- carry: KEEP — CRLF handling + histogram heuristic are solid. The wire aux pattern recurs.

**rust-core/crates/core/src/json.rs** (~300+ LOC) — hand-rolled JSON subset parser (TSK-632, owner decision: no serde_json)
- notable: recursive-descent parser, zero `[]` indexing, zero unwrap; supports `\uXXXX` surrogate pairs with lone-surrogate rejection (Foundation parity); depth cap guards stack overflow; last-wins duplicate-key semantics (mirrors Swift dict behavior)
- carry: KEEP — the no-dependency, no-panic parser discipline is strong. Surrogate-pair handling is correct and uncommon.

**rust-core/crates/core/src/lib.rs** (~64 LOC) — crate root + module declarations
- notable: `#![forbid(unsafe_code)]` at crate level, `#![deny(missing_docs)]` enforced
- carry: KEEP — strong safety discipline at the module level

**rust-core/crates/core/src/markdown.rs** (~250+ LOC) — markdown→HTML renderer (port of Swift HTMLRenderer, pulldown-cmark-based)
- notable: chunk contract: core emits STRUCTURE + sentinels, host enriches islands (raw_html, code, mermaid, diagram); frontmatter MetadataBlock suppression; tight-item `<p>` synthesis; slug deduplication via HashMap (O(1) vs O(N²) linear scan in old code)
- carry: KEEP — the chunk/sentinel pattern is elegant and scales to more enrichment islands later

**rust-core/crates/core/src/mermaid.rs** (~250+ LOC) — mermaid host-div generation + hand-rolled SHA-256
- notable: directive parsing (`%% @id`, `%% @step N`); compact JSON steps manifest with sorted keys (byte-parity with Swift); hand-rolled SHA-256 (FIPS 180-4, ~100 lines, no crypto dep under 1000-line rule); 4-byte display hash for theme-flip cache key
- carry: KEEP — hand-rolled SHA-256 is correct and small; the directive parsing + steps JSON is reusable for other annotated-fence workflows

**rust-core/crates/core/src/meta.rs** (~238 LOC) — file-metadata detection (line-ending + encoding badge)
- notable: CRLF pair counting (not double-counted as CR+LF); BOM sniff (UTF-8/UTF-16 LE/BE only, not a full charset guesser); text-metrics (lines/words/chars) with Unicode-aware scaling
- carry: KEEP — the CRLF pair-counting and BOM sniff are lean and correct

**rust-core/crates/core/src/nav.rs** (~250+ LOC) — file-navigation ordering + filtering (shared by TUI/web pane)
- notable: stable sort keys (Name/Modified/Size with tie-break); subsequence matcher with prefix/contiguity/earliness scoring (higher is better); breadcrumb trail generation; allocation-light (one Vec of matches)
- carry: KEEP — the scoring heuristic is well-tuned; the logic is allocation-minimal

**rust-core/crates/core/src/outline.rs** (~250+ LOC) — markdown outline scanner (ATX + setext headings, fence tracking)
- notable: deliberately NOT a full CommonMark parser; high-value subset avoiding block-quote/HTML/list-item contexts; proptest for fenced-code-block suppression; setext underline edge cases (mixed `-`/`=`, preceding blank line)
- carry: KEEP — the trade-off (high-value subset vs parsing complexity) is documented and justified

**rust-core/crates/core/src/runtime.rs** (~250+ LOC) — eviction-policy core + multi-document registry (TSK-589)
- notable: pure `eviction_plan` function (no clock read, deterministic, unit-testable); TTL idle-reaper + byte-budget + count-cap LRU; pinned docs (active/visible) never evicted; CoreRuntime generic over payload type; lock-poisoning recovery (panic-safe)
- carry: KEEP — the eviction model is sound; the generic payload design is reusable for other resource-managed collections

**rust-core/crates/core/src/session.rs** (~250+ LOC) — stateful CSV session (table + filter, level-triggered snapshots)
- notable: idempotent `set_filter` (same query is a no-op, version doesn't advance); cached filtered view (indices only, rows projected on demand); snapshot_window_frame for O(window) pulls (TSK-559)
- carry: KEEP — the level-triggered, idempotent pattern is solid; windowed snapshots are a scalability win

**rust-core/crates/core/src/table_arena.rs** (~250+ LOC) — contiguous arena storage for parsed CSV (2 heap blocks instead of ~2M)
- notable: one `String` holding all cell bytes + one flat offset table; immutable after build; normalized to header arity (short rows pad, long rows truncate); wire projection via spans (serde serializes `&str` like `String`)
- carry: KEEP — the arena pattern is memory-efficient and battle-tested

**rust-core/crates/core/src/theme.rs** (~250+ LOC) — semantic color tokens (Rgb/Rgba, palettes for Light/Dark, one-dark-derived)
- notable: 27 semantic roles (Accent, Link, SynKeyword, etc.); mode-specific color literals (distinct per role/mode); panic-free hex parser (returns `Option`); role/mode matrix enables consistency across front-ends
- carry: KEEP — the semantic role system is extensible and maintains parity

**rust-core/crates/core/src/trace.rs** (~250+ LOC) — hand-rolled instrumentation facade (no tracing dep)
- notable: spans + events; pluggable Sink trait (Send + Sync); AtomicBool presence flag gates the RwLock on every emit (production fast-path: one relaxed load, no lock when no sink); Lock-poisoning treated as "no sink" (recovery, not propagation)
- carry: KEEP — the minimal facade is elegant; the presence flag optimization is smart

**rust-core/crates/core/src/transcript.rs** (~250+ LOC) — Claude transcript (JSONL) projection (TSK-632)
- notable: tolerant framing (blank/over-cap/malformed lines skipped, live append safe); record projection with TSK-245 redaction barrier (secrets stripped, oversized image sources collapsed); hand-rolled JSON (no serde_json)
- carry: KEEP — the redaction barrier pattern is reusable; tolerant parsing is crucial for live-append safety

**rust-core/crates/core/src/view.rs** (~250+ LOC) — render-agnostic view-model (shapes content identically for TUI/web)
- notable: ViewMode enum (Text/Hex/Table/Diff/Image/Formatted); FileKind classification (Plain/Tabular/Diff/Image/Structured); DiffLineKind classification (FileHeader/Hunk/Added/Removed/Context); table_col_widths sampled + clamped (TABLE_WIDTH_SAMPLE, min/max bounds)
- carry: KEEP — the classification + enum-based composition keeps front-ends at parity

**rust-core/crates/core/src/whitespace.rs** (~94 LOC) — whitespace revelation (spaces→·, tabs→→)
- notable: idempotent marker replacement; property tests prove char count is stable + no raw space/tab survives
- carry: KEEP — tiny, focused, well-tested module

**rust-core/crates/core/src/wire.rs** (~250+ LOC) — MessagePack framing + wire types (Table, Snapshot, WireError)
- notable: `rmp_serde::to_vec_named` (structs as maps, not arrays); DIY length-prefix (u32 LE); `decode` + `decode_borrowed` with end-of-stream checks; `decode_frame` validates prefix + caps against MAX_FRAME_LEN (16 MiB)
- carry: KEEP — the framing discipline (not relying on rmp's default) and borrowed decoding are correct and scalable

**rust-core/crates/core/src/wasm_shape.rs** (~189 LOC) — WASM-shape invariant guard (TSK-800, test-only)
- notable: recursive source scan for wasm-breaking std IO; `#[cfg(test)]` module stripper (test-only IO allowed); regression guard ensuring core stays sans-IO/pure
- carry: KEEP — the negative-control pattern is valuable for other invariants

**rust-core/crates/core/tests/Audit_rust_core_crates_core_src_diff_rs_split_parity.rs** (~128 LOC) — audit test pinning diff parser parity
- carry: KEEP — demonstrates A/B audit pattern for critical ports

**rust-core/crates/core/tests/Audit_rust_core_crates_core_src_session_rs_snapshot_frame.rs** (~109 LOC) — audit test for session snapshot wire parity
- carry: KEEP — another A/B parity audit (wire byte equivalence)

**rust-core/crates/core/tests/golden_corpus_diff.rs** (~238 LOC) — golden corpus tests for diff parsing
- carry: KEEP — corpus-driven testing for parser robustness

**rust-core/crates/core/tests/golden_corpus_markdown.rs** (~185 LOC) — golden corpus tests for markdown rendering
- carry: KEEP — corpus-driven markdown A/B parity tests

**rust-core/crates/core/tests/test_profile_debuginfo_speed_lever.rs** (~97 LOC) — profiling test for debuginfo compile-time trade-offs
- carry: KEEP — perf-aware test discipline (TSK-??? era perf leverage)

---

## Module Summary

Slice 2 covers **24 domain-specific engines + 5 test suites**, building atop the foundational wire/dispatch layer from slice 1. Every module is:

- **Pure + sans-IO**: no filesystem, network, threads, processes, or ambient clock reads. Deterministic, testable, WASM-portable.
- **No panic**: every boundary access (byte slicing, option extraction, division) uses checked operations or guards.
- **Composition-first**: modules are thin, single-purpose, and composable. The `view` module orchestrates lower-layer engines (csv, hex, indent) for the front-ends.
- **Parity by construction**: shared logic (nav sorting, theme colors, whitespace markers) lives once in the core, guaranteeing TUI/web/remote tiers are identical.
- **Audit-driven**: critical ports (git, hex, indent, markdown, mermaid, session, diff) have A/B corpus tests pinning byte-for-byte output against the Swift originals.

The **chunk/sentinel pattern** (markdown.rs) is the elegance highlight: core renders structure + placeholders, host enriches islands. This scales: any new island type (code highlighting, SVG rendering, diagram cache key injection) fits the existing framework without core rewrites.

---

## Patterns Worth Porting

### 1. **Chunk/Sentinel Framing** (markdown.rs, html_patch.rs)
Split responsibility: core generates structure + anchors, host enriches in situ. Applies to:
- Any AST with host-decided rendering (syntax highlighting, diagram engines, cached computations)
- Incremental UI updates (patch instead of reload)

```rust
// Core emits structure + sentinel
pub struct Chunk {
    kind: ChunkKind,  // raw_html | code | diagram
    lang: String,
    payload: String,
}
pub struct RenderOutput {
    html: String,  // with <!--mdv-chunk-N--> anchors
    chunks: Vec<Chunk>,
}
// Host splices chunks at sentinels → final HTML
```

### 2. **Wire Aux Bulk Side-Channel** (hex.rs, indent.rs)
For operations on large buffers that would exceed frame caps, route the buffer as a separate `aux` parameter:
- Request carries only metadata (query, config) → small frame
- Response carries only the output (or raw UTF-8) → avoids double-encoding
- Pattern: `fn op_wire_aux(req: &[u8], aux: &[u8]) -> Result<Vec<u8>>`

Applies to: any streaming/windowed operation, search-on-large-files, progressive rendering.

### 3. **Level-Triggered + Idempotent State** (session.rs)
CSVSession model: every snapshot is complete current state, never delta. Idempotent mutations (same query = no-op, version unchanged). Reconciliation is self-healing.

Applies to: any server-push or replay-safe state machine (collaborative editing, async UI, test replay).

### 4. **Arena + Projection Pattern** (table_arena.rs)
Two-block storage (contiguous cell bytes + offset table) instead of `Vec<Vec<String>>`. Wire via borrowed spans. Allows:
- Mutation-free snapshots (expensive query = no per-row clone)
- Memory-efficient filtering (one scan over contiguous buffer)
- Streaming serialization (rows projected on demand from spans)

Applies to: any large table/matrix workload with frequent filtering/sorting.

### 5. **Property-Test Contracts** (git.rs, hex.rs, html_patch.rs, nav.rs, outline.rs, whitespace.rs)
Every non-trivial parser/transform gets proptest pinning invariants:
- Partition invariants (split→concat == input for splitters)
- Differential tests (proptest vs. reference naive impl)
- Robustness (arbitrary input never panics)
- Behavioral contracts (sorted result, dedup, bounds)

Applies to: all parsing, filtering, sorting logic. TSK-585 lane (property-test PoC) proved value.

### 6. **Semantic Role System** (theme.rs)
27 roles (Accent, Link, SynKeyword, etc.) per palette, not ad-hoc color literals. Mode-specific (Light/Dark). Enables:
- Theming consistency across front-ends
- A/B testing of new roles (add to enum, provide values)
- Accessibility (high-contrast variant = new Mode)

Applies to: any multi-front-end system where visual coherence matters.

### 7. **Presence Flag Optimization** (trace.rs)
`AtomicBool` presence gate on every `emit()`, only takes RwLock when a sink exists. Production fast-path: one relaxed load, no contention.

Pattern:
```rust
static SINK_PRESENT: AtomicBool = AtomicBool::new(false);
pub fn emit(record: &Record) {
    if !SINK_PRESENT.load(Ordering::Relaxed) {
        return;  // production: ~3 CPU cycles
    }
    // slow path: take the lock
}
```

Applies to: any pluggable sink/callback system with a hot fast-path.

### 8. **Audit Tests (Byte-for-Byte Parity)** (tests/*.rs)
A/B corpus tests pinning output byte-for-byte against the Swift originals. Catches:
- Parser engine divergence (pulldown vs. cmark-gfm)
- Attribute-order changes in HTML
- JSON key-order shifts
- Floating-point rounding

Applies to: all ports from one language to another; regression guardrails.

---

## Anti-Patterns / Regrets

### 1. **Limited LCS in Block Differ** (html_patch.rs)
Current algorithm: common prefix + common suffix, then delete+insert middle. A minimal-middle LCS refinement is noted as future work (TSK-838).

**Lesson**: For small block counts (10s–100s), a full LCS buy-down would eliminate unnecessary deletes/inserts when blocks *move* (e.g., reordering a list). The current "good enough" approach trades optimality for simplicity; if movement is common, revisit.

### 2. **Naive JSON Parser Over serde_json** (json.rs)
Owner decision: no `serde_json` to avoid a new dep. The hand-rolled parser is correct but adds ~300 LOC of maintenance.

**Lesson**: The 1000-line rule for Rust-core forced this call. If `serde_json` had already shipped (e.g., via rmp-serde transitive), it would have been a no-brainer. For a greenfield rebuild, weigh: is one proven dep worth the risk vs. ~300 LOC of unfuzzed code?

### 3. **No Fuzzing for Parsers** (hex.rs, outline.rs, transcript.rs)
Robustness relies on proptest + deterministic LCG fuzz, not cargo-fuzz. Cargo-fuzz requires nightly; it's dev-only, not in-tree.

**Lesson**: For parsers of untrusted input (HTTP, file formats, network), cargo-fuzz is stronger (continuous feedback, seed corpus evolution). The LCG approach works but is a manual approximation of what fuzzing provides.

### 4. **No Persistence Tier** (session.rs, runtime.rs)
The eviction model and session state are in-memory only. A persistent `mdvcore-host` crate (outside the pure core) is planned for file saving, undo/redo, etc.

**Lesson**: The core is correctly scoped as pure logic. But the boundary between "pure engine" and "persistent store" is a design inflection point. If the rebuild adds file I/O to the core, the WASM goal dies.

### 5. **Hardcoded Limits** (view.rs, csv, wire.rs)
MAX_TEXT_LINES, TABLE_WIDTH_SAMPLE, MAX_FRAME_LEN, MAX_HEX_WIDTH are constants. No runtime config.

**Lesson**: Limits are sensible defaults for a single-user app. For a scalable server or embedded use, plumb limits through the config layer (planned in TSK-589 slice).

---

## Gotchas & Surprises

### 1. **CRLF Pollution** (indent.rs, meta.rs, outline.rs)
Windows line endings (`\r\n`) can pollute indentation detection or blank-line logic if trailing `\r` is not stripped. The code carefully handles this, but it's a recurring pattern.

**Gotcha**: A naive indent scanner that doesn't strip `\r` will miscount space-only CRLF lines as 2-space indents on Windows files.

### 2. **Surrogate Pairs in JSON** (json.rs)
UTF-16 surrogates (U+D800–U+DFFF) in `\uXXXX` escapes require pair handling. A lone surrogate is an error (Foundation parity), not a silent U+FFFD.

**Gotcha**: A quick JSON parser might accept lone surrogates; the rebuild must enforce this for transcript redaction fidelity.

### 3. **Scope Enum + Lazy Evaluation** (nav.rs filter_entries)
The scorer walks both `name` and `needle` as byte slices, not Unicode scalars. This is correct for ASCII filenames but could split UTF-8 on non-ASCII paths (rare in practice).

**Gotcha**: If a rebuilt navigator supports non-ASCII filenames, ensure the scorer walks scalars, not bytes.

### 4. **Frame Cap Framing Error vs. TooLarge** (wire.rs)
`WireFault::Framing` = decode-side hostile/corrupt prefix (safety guard). `WireFault::TooLarge` = legitimate data too big for one frame (recoverable, caller can window). Conflating them hides the distinction.

**Gotcha**: The rebuilt wire layer must preserve this dual-mode error to enable graceful fallback (window the request, not error out).

### 5. **Snapshot Projection Staleness** (session.rs)
The cached filtered view is keyed by query version. If the cache fill is slow and the query changes twice rapidly, a stale snapshot might be pulled. The level-triggered model is self-healing, but the cache is an optimization; correctness requires the version check.

**Gotcha**: A broken cache invalidation (e.g., version check omitted during a refactor) silently returns stale data.

### 6. **Lock Poisoning Recovery** (runtime.rs, trace.rs)
Both `read_guard` and `write_guard` recover from poisoning (treat as "no value" rather than propagate panic). This assumes poisoned data is structurally valid.

**Gotcha**: If a panicking thread leaves the registry in a broken state (e.g., a half-inserted doc), recovery could compound the error. Use carefully; prefer panic-free code.

### 7. **Wire Aux Boundary Crossing** (hex.rs, indent.rs)
The aux buffer is borrowed, not copied. If the front-end's backing buffer is freed before the call completes, UB results. The contract assumes the aux buffer outlives the call.

**Gotcha**: The FFI layer MUST enforce this lifetime; no Rust guarantees it.

### 8. **Diff Line Classification is Greedy** (view.rs DiffLineKind)
Lines starting with `+`, `-`, `@`, or space are classified; anything unrecognized is Context. This works for git/unified diffs but might misclassify exotic formats.

**Gotcha**: A future diff variant (e.g., 3-way merge markers) might need a new classification; the enum is extensible, but existing parsers won't auto-adapt.

---

## Rebuild Notes

### For a Greenfield Markdown+Rust-Core App

**Scope the Pure Core Correctly**
- Engines: parsers, filters, transforms, rendering (markdown, CSV, hex, diff, indent, outline, theme, nav, trace)
- OUT: file I/O, network, subprocess, wall-clock reads. Inject those as parameters.
- Boundary: front-ends (macOS, TUI, WebUI) own I/O; core is pure logic.

**Prioritize the Chunk/Sentinel Pattern**
- Do NOT emit final HTML; emit structure + enrichment islands.
- Allows host to swap highlighting engine, diagram renderer, LSP integration without core rewrites.
- Scales to remote core (WebSocket boundary is cleaner if response is pre-rendered chunks).

**Wire Layer Discipline**
- `rmp-serde::to_vec_named` (maps, not arrays). Test round-trip byte parity.
- Separate small-frame requests from aux bulk data. Reserve frame cap for streaming.
- Borrowed decoding for large document ops (markdown, diff, transcript parse).

**Test Pyramid (Lessons from TSK-585, TSK-838)**
- Unit + differential + proptest for every parser. Robustness is a load-bearing contract.
- A/B corpus for ports (byte-for-byte parity against reference).
- No fuzzing infrastructure (requires nightly)? Use LCG fuzz + deterministic assertions.

**Dependency Hygiene**
- Approved: `serde`, `rmp-serde`, `cbindgen`, `proptest`, `memchr`.
- Owner-gated: anything else. Count transitive surface (dev-machine compiles full tree).
- Prefer `default-features=false` + explicit minimal list.
- Pin exact versions; never floating ranges.

**Safety Discipline**
- `#![forbid(unsafe_code)]` at crate root.
- `#![deny(missing_docs)]` enforced; new pub items document or don't compile.
- Every boundary access checked (no `[]`, no unwrap). Prefer `.get()`.
- Panic-free by construction; audit with a test that forces arbitrary input.

**Semantic Roles for UI**
- Don't scatter color literals. Define one enum of roles (Accent, Text, SynKeyword, etc.).
- Palette struct maps role → RGB per mode (Light/Dark).
- Front-end maps `Rgb` to native color type; core owns values.

**Eviction + Pinning Policy**
- Document: what's pinned (active/visible/unsaved), what's ephemeral.
- LRU + TTL + byte-budget. Never force-evict a pinned doc (stay over-budget and signal host).
- Pure policy function (no clock); host injects timestamps.

**Audit Pattern**
- Before shipping a port, write A/B corpus tests: same input through Swift + Rust, assert byte-equal output.
- Catches parser engine divergence, attribute-order changes, JSON key reordering, float rounding.
- Permanently live in test suite; regression guard.

**Tracing as a Pluggable Seam**
- Hand-rolled facade (no tracing dep, 250 LOC). Spans (RAII) + events (point).
- Presence flag gates the lock on every emit; production fast-path is ~one atomic load.
- Intended FFI seam: host installs a Swift `ObservabilitySink` later.

**WASM Invariant Guard**
- Recursive source scan for std::fs, std::net, std::thread, std::process, std::env, std::time.
- Test runs on every `cargo test`; catches IO creep before it's committed.
- `#[cfg(test)]` module stripper allows test-only IO in guard itself.

**Windowed Snapshots (TSK-559)**
- For large tables (1M+ rows), don't serialize the whole visible set. Window it.
- Request `snapshot_window_frame(offset, limit)` → only the viewport rows + scrollbar size hint.
- Same wire shape as full snapshot; consumer doesn't change.

**Idempotent State Machine**
- Mutations that don't change state should NOT increment version (hot-reload friendly).
- Every snapshot is complete; no deltas. Level-triggered reconciliation is self-healing.
- Useful for replay, UI coherence, client crash recovery.

**Avoid Silent Limits**
- MAX_TEXT_LINES, MAX_FRAME_LEN, MAX_HEX_WIDTH are currently constants.
- For a scalable system, plumb them through config (EvictionBudget pattern).
- Make limits visible to the user ("file truncated at 1M rows").

**Lock Poisoning is a Sign**
- Recovering from poisoned locks assumes the data structure is valid despite the panic.
- If true, mark it clearly; if not, let the panic propagate (forces a fix).
- In `trace.rs` + `runtime.rs`, the assumption holds (list/map structures are still coherent).

---

## Summary for Rebuild Architects

This slice is **24 specialized engines + audit tests**, each 50–300 LOC, composable and deterministic. The highlight patterns:

1. **Chunk/Sentinel framing** — host enriches core structure
2. **Wire aux side-channel** — large buffers bypass frame caps
3. **Level-triggered state** — idempotent, self-healing
4. **Arena + projection** — memory-efficient, mutation-free snapshots
5. **Property tests + A/B audits** — robustness + parity guardrails
6. **Semantic roles** — multi-front-end coherence by construction
7. **Presence flag optimization** — pluggable sinks with zero-cost fast-path

All code is **panic-free, deterministic, sans-IO, and WASM-portable**. The quality bar is high (every boundary checked, audit tests pinning behavior), but the LOC footprint is small (24K total slice 2 + tests).

For a greenfield rebuild, **inherit the discipline**: pure logic, shared engines, front-end-owned I/O, audit-driven correctness. The chunk/sentinel + wire aux patterns alone justify the architecture; the eviction + windowed snapshots enable scalability.
