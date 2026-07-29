# Rust-Core Learnings (Slice 1/2) — Crates/Core Modules

**Batch coverage:** 29 files, ~21K LOC  
**Focus:** Pure engines, wire codecs, document/session management, canvas M1  
**Date:** 2026-07-11

---

## File-by-File Summary

### Pure Engine Modules (Dependency-Free, Fully Host-Testable)

**rust-core/crates/core/src/bench.rs** (409 LOC) — Perf-floor ratchet logic (audit TSK-588)
- role: Baseline data model, text serialization, regression detection. Deterministic (no clock), fully testable on host.
- notable: Ratchet pattern (compare against previous, generous tolerance) is superior to absolute thresholds. Rejects `criterion`. Planted regression tests prove TEETH. BTreeMap for stable, diffable output. No `serde_json` dependency.
- carry: **KEEP** — excellent design for reproducible perf gates; defends against transient load noise better than absolute assertions

**rust-core/crates/core/src/cm_edit.rs** (902 LOC) — CodeMirror UTF-16 incremental-edit reducer
- role: Rust port of Swift `CMEditApplier`; applies edit batches to a UTF-16 mirror, returns minimal changed region.
- notable: UTF-16 semantics are **load-bearing** (CodeMirror's native indexing); lone surrogate pairs are rejected, not silently corrupted. Stateless `apply()` and stateful `CmDoc` share a single `splice_units` kernel for byte-identical equivalence. Allow-clippy attributes justify casts (TSK-575: proven bounds before splice). Borrowed `Cow<'a, str>` for base doc (TSK-561) eliminates copy overhead on keystroke path (~10× traffic reduction).
- carry: **KEEP** — meticulous UTF-16 handling, no silent corruption. The borrowed-input pattern is essential for low-latency editor codecs.

**rust-core/crates/core/src/csv.rs** (1,238 LOC) — Hand-rolled CSV parser, no deps
- role: Delimiter auto-detection (quote-aware), RFC-4180 quoting, line-ending tolerance, resource capping (cells/rows/bytes), arena-direct parsing.
- notable: Single `tokenize()` grammar shared by two sinks (Vec and Arena), so cap behavior is byte-identical. Heap-accounting (CELL_HEAP_OVERHEAD + ROW_HEAP_OVERHEAD + running estimate) defends against memory bombs (audit TSK-557). Malformed lines degrade gracefully (truncate-with-marker, not crash). Arena path kills throwaway allocations on session-open hot path.
- carry: **KEEP** — excellent resource-capping discipline; the two-sink pattern is a reusable template for grammar + specialization.

**rust-core/crates/core/src/diff.rs** (1,029 LOC) — Unified-diff parser (Rust port of Swift)
- role: Tolerant multi-file diff parsing; handles git metadata, renames/copies, binary markers, hunk clamping.
- carry: **KEEP** — faithful port, byte-for-byte A/B parity with Swift.

**rust-core/crates/core/src/find.rs** (686 LOC) — In-file substring find (literal, no regex)
- role: Shared across TUI/web/future tiers; returns byte ranges (line + offset within line). ASCII-only case folding (preserves byte offsets).
- notable: Zero regex, zero deps. Allocation-light (borrows input). Matching is non-overlapping (resume past each hit). Line splitting strips trailing CR (CRLF files report ranges into visible line). Cross-file grep, minimap bucketing, and table find all reuse the same `find_matches` kernel.
- carry: **KEEP** — elegant allocation strategy; the `Cow<str>` fold avoids copies when case-sensitive.

**rust-core/crates/core/src/find_engine.rs** (opening lines only) — Find with literal + regex modes
- role: Host consumer (CodeMirror integration); returns UTF-16 ranges + 1-based line/column. Regex via `regex-lite` (PikeVM, no ReDoS).
- carry: **KEEP** — the ReDoS-free design (PikeVM) is critical for hostile untrusted input.

**rust-core/crates/core/src/filter.rs** (opening lines only) — CSV row filtering
- role: Global or per-column case-insensitive substring match. Pure value logic.
- carry: **KEEP** — mirrors Swift; awaits per-column operators (deferred).

**rust-core/crates/core/src/fuzzy.rs** (opening lines only) — Fuzzy matcher (Rust port of Swift)
- role: Rank query chars in target, scoring on boundaries/runs/prefix. Char-level (not grapheme), indices are scalar offsets.
- notable: A/B parity on ASCII corpus. Index unit divergence (scalar vs grapheme) documented and tolerated in corpus. Zero regex, zero grapheme crate dependency.
- carry: **KEEP** — tight scoring rules kept in exact sync with Swift during the migration window.

**rust-core/crates/core/src/hex.rs** (576 LOC) — HEX dump rendering
- role: Pure row math + layout. Given bytes + scalars, produces rendered dump string (offset · hex bytes · ASCII glyphs, per-row constant width).
- carry: **KEEP** — port of Swift `HexLayout` + `HexDumpBuilder.renderRows`.

**rust-core/crates/core/src/json.rs** (667 LOC) — Hand-rolled JSON parser (no `serde_json`)
- role: Recursive-descent parser for transcript JSONL. Tolerant (skips malformed lines), strict (rejects trailing bytes, lone surrogates), depth-capped (no stack overflow).
- notable: Objects preserve pair order; duplicated keys use last value (Foundation semantics). No-panic discipline (cursors, `.get()`, no `[]` indexing). Hard depth cap 128. Handles all JSON escapes incl. `\uXXXX` surrogate pairs.
- carry: **KEEP** — excellent no-panic discipline; the tolerant-line framing is essential for live-append JSONL (torn tails).

**rust-core/crates/core/src/markdown.rs** (1,077 LOC) — Markdown → HTML + chunks (Rust port)
- role: Structural rendering (headings w/ GitHub slugs, lists, tables, strikethrough, code, mermaid diagrams). Host-coupled islands (raw HTML, code fences, diagrams) returned as `Chunk`s with sentinels for host enrichment.
- notable: Division of labor: core renders structure only; sanitization, highlighting, diagram rendering stay Swift. Frontmatter (YAML/TOML) suppression. Sentinel-based splice (segment-based, never iterative replace — survives payloads containing sentinel text). Tight-list-item `<p>` synthesis (pulldown emits bare, Swift AST wraps in para, so we match). Used-slug HashMap de-dupes headings O(1) (TSK-984: old Vec was O(N²)).
- carry: **KEEP** — excellent separation of concerns; the chunk/sentinel boundary is clean and extensible.

**rust-core/crates/core/src/nav.rs** (1,044 LOC) — File-navigation sorting (dirs-first, multi-key)
- role: Pure sort logic shared across TUI/web; deterministic, stable, time-free (mtime supplied by caller).
- carry: **KEEP** — guarantees parity by construction.

**rust-core/crates/core/src/formula.rs** (3,068 LOC) — Formula evaluator (Rust port, slice 1 = arithmetic)
- role: Arithmetic core (literals, `+ - * / ^ % ()`), precedence/associativity matching Swift. Slice 1 only; cell refs, ranges, functions in later slices.
- carry: **KEEP** — complex domain but well-isolated in slices; validated against Swift corpus.

**rust-core/crates/core/src/transcript.rs** (1,085 LOC) — Claude transcript (JSONL) projection
- role: Tolerant JSONL parser (skips blank/oversized/malformed lines). Record projection (uuid/id fallback, message block-array handling). Redaction barrier (signature/headers, oversized image source).
- notable: Built on hand-rolled `json` (no `serde_json`). Tolerant framing: torn tail lines during live append must not fail. Deterministic id fallback (`line-<n>`, not random UUID, keeps core sans-RNG). Preserves key order in nested objects (JSON spec allows order-nondeterminism; core stays deterministic).
- carry: **KEEP** — excellent tolerance for live-append streams; the redaction barrier is load-bearing for privacy.

**rust-core/crates/core/src/view.rs** (869 LOC) — Render-agnostic view-model
- role: Shapes file content (text/hex/table/diff/image/formatted) the same way for all tiers. Pure + sans-IO; front-end does the IO, core does the composition.
- carry: **KEEP** — guarantees parity by construction.

**rust-core/crates/core/src/format.rs** (766 LOC) — JSON/XML pretty-printer
- role: Format unstructured text into indented output. Rebuilds the view via `view::from_content` after formatting.
- carry: **KEEP** — scope is clear and bounded.

**rust-core/crates/core/src/runtime.rs** (575 LOC) — Eviction-policy core (TSK-589)
- role: Pure eviction decision: given resident docs + budget, returns DocIds to evict. Never evicts pinned (active/unsaved) docs. LRU + TTL idle-reaper. No registry, no FFI, no clock — fully unit-testable on host.
- notable: Host-pin set composes with dirty detection: `effective_pin = host_pin || is_dirty()`, recomputed after every state change. Dirty docs are never victims (explicit owner policy 2026-07-04). Budget = 1.5 GB resident text + 200 docs, whichever binds first.
- carry: **KEEP** — pure-policy design is a template for deterministic eviction testing. Host-pinning + dirtiness composition is clean.

### Wire / FFI Boundary

**rust-core/crates/core/src/wire.rs** (611 LOC) — Wire codec + framing
- role: MessagePack boundary (`rmp-serde`); length-prefixed frames; encode/decode with end-of-stream checks; raw-bytes methods for huge outputs.
- notable: **ALWAYS `to_vec_named`** (maps, not arrays — rmp default silent-mismatch trap). Borrowed decode (TSK-561) for stateless request seams carrying whole documents (diff, cm_apply, find, markdown, transcript, highlight). Frame body max 16 MiB; `TooLarge` distinct from `Framing` (decode-hostile vs "your data is real but too big").
- carry: **KEEP** — the `to_vec_named` rule is critical and should be in a **rebuild PLAYBOOK**; the borrowed-decode pattern is essential for zero-copy on document-sized payloads.

**rust-core/crates/core/src/dispatch.rs** (opening lines only) — Method dispatch (thin-waist, TSK-580)
- role: One safe-Rust entry routes `u16` method id + frame to core functions, returns response. Stable ABI: method ids assigned once, never renumbered/reused.
- notable: Aux side-channel for bulk payloads (sidesteps 16 MiB frame cap). Two raw-output methods (IndentDetect, HexRender) return raw bytes, not frames. Dispatch is the **single source of truth** for method id space, reusable by FFI/TUI/web/WASM.
- carry: **KEEP** — excellent thin-waist design; method ids as ABI is sound.

### Stateful Document & Session Management

**rust-core/crates/core/src/editor_session.rs** (opening lines only) — Stateful editor document (TSK-1516, S1)
- role: Rust-owned EditorSession: UTF-16 mirror (`CmDoc`) + saved baseline + op-log (durability/local-history) + document meta (url, language, mtime).
- notable: Content-based dirty detection (fingerprint: 64-bit hash + length) so reverted edits read clean again (better than sticky flags). Op-log compaction to prevent unbounded growth on long typing. Three laws pinned by tests: REPLAY (log replays reproduce current text), DIRTY (content-based, reverts read clean), ATOMICITY (rejected batch changes nothing).
- carry: **KEEP** — the design is sound; fingerprinting + compaction are well-motivated.

**rust-core/crates/core/src/doc_registry.rs** (opening lines only) — Editor-doc registry (TSK-1517, S2)
- role: Process-global `CoreRuntime<EditorSession>` keyed by never-reused `DocId`. Document crosses boundary once at `doc.open`; every mutation is a delta against the id.
- notable: Eviction budget: 1.5 GB resident text + 200 docs, whichever binds first; dirty docs never evicted (`effective_pin = host_pin || is_dirty()`). Missing/evicted id is data (found: false), never a fault — host rehydrates by re-opening. Rejected batch is found: true, changed: null (atomic no-op server-side).
- carry: **KEEP** — host-pinning + dirtiness composition ensures unsaved buffers survive eviction pressure.

### Canvas Engine (M1 — the real engine, post-M0 demo)

**rust-core/crates/core/src/canvas/mod.rs** — Canvas subsystem overview
- role: M1 engine (full docs at docs/canvas/02-CORE-ENGINE.md). Modules: store (flat records, fractional order) · props/registry (interned keys, validation fence) · ops (atomic revisioned batches + undo) · tokens (DTCG theme) · lower (records→HTML, `var(--cv-*)` refs) · patch (op→minimal DOM mutations) · wire (msgpack + fuzz seam) · doc (FFI façade).
- Notable: M0 demo (hardcoded 201-node doc, SetText/SetStyle mirror ops) was retired; E2E suite now builds via real op engine (TSK-1343 verdict + numbers).

**rust-core/crates/core/src/canvas/store.rs** (canvas/store) — Flat record store (M1.S1)
- role: Load-bearing storage: records in flat map keyed by id; hierarchy via `Place { parent, index }` field on child; sibling order via fractional index (lexicographic byte order, base-62 alphabet).
- notable: Ids are branded, prefixed, opaque, never reused. Single-writer v1 (deterministic midpoints, no jitter). Fractional sibling insert is O(1), no renumbering. Parent link + position move atomically.
- carry: **KEEP** — the fractional-index pattern scales infinitely without renumbering; the flat map + pointer pattern is correct by design.

**rust-core/crates/core/src/canvas/props.rs** (canvas/props) — Interned keys + values (M1.S2)
- role: Keys are `u16` symbols (closed registry table, ABI-like). Values distinguish token refs from literals at TYPE level (structural, not string-sniffing). Prop bags are typed.
- carry: **KEEP** — interning eliminates string keys and JSON boxed values; structural token distinction is clean.

**rust-core/crates/core/src/canvas/registry.rs** (canvas/registry) — Type registry + validation fence (M1.S2)
- role: TypeSpec per record kind (legal props, value shapes, text-bearing, children). Fence validates ops before mutation (never panics — typed errors). Single source of truth for DSL vocabulary artifacts.
- carry: **KEEP** — the fence pattern prevents silent corruption; validation before mutation is sound.

**rust-core/crates/core/src/canvas/ops.rs** (canvas/ops) — Ops, inverses, revisions (M1.S3)
- role: Atomic batch application + revision bumping. Fence-validates each op; any failure rolls back via collected inverses. Idempotent replays (Insert with existing id + same kind/parent/props is Ok no-op).
- carry: **KEEP** — atomic apply-or-reject mirrors strong ACID semantics; agent retry tolerance is well-designed.

**rust-core/crates/core/src/canvas/patch.rs** (canvas/patch) — DOM-patch plans (M1.S5b)
- role: Applied ops map to MINIMAL DOM mutations computed from post-apply store. Shares `css_decl` table with full lowering (two render paths cannot drift by construction). Noop effects yield zero patches.
- carry: **KEEP** — minimal-patch design scales to large documents; construction-time equivalence proof is strong.

**rust-core/crates/core/src/canvas/wire.rs** (canvas/wire) — Wire codec (M1.S5c)
- role: MessagePack request `{baseRev, ops:[…]}` / response `{rev, patches:[…]}` or error. String-keyed, self-describing (JS applier consumes as JSON-equivalents). Internal types serde-free; this is the only boundary and the fuzz target (TSK-584).
- carry: **KEEP** — fuzz boundary is well-defined and narrow.

**rust-core/crates/core/src/canvas/doc.rs** (canvas/doc) — Canvas document façade (M1.S5c)
- role: FFI-facing: op-engine state + token store + root page. Undo history (64 batches, bounded). Entry points: open / lower / apply-frame.
- carry: **KEEP** — thin façade; complexity lives in submodules.

**rust-core/crates/core/src/canvas/*.rs** — Other modules (chart, deck, dsl, io, lint, lower, tokens, vocab)
- role: Specialized services (charting, deck layout, DSL, I/O, linting, HTML lowering, token storage, vocabulary).
- Summary: M1 is well-modularized; each slice handles one task without tangling.

---

## Module Summary — What This Slice Does and How It Hangs Together

**rust-core/crates/core is the pure, deterministic engine suite:**

1. **Format-parsing engines** (CSV, diff, JSON, markdown, transcript, hex): Hand-rolled, zero-to-minimal deps, fully testable on host. Each is tolerant of malformed input (degrades gracefully, never crashes), yet deterministic (no randomness). Shared by TUI/web/future tiers *by construction*.

2. **Search/match engines** (find, fuzzy, find_engine, formula): Pure value logic, no side effects. Byte-accurate offset reporting ensures all consumers highlight the same matches. Formula evaluation is sliced (arithmetic first, then refs/ranges/functions in later slices).

3. **Wire boundary** (wire, dispatch): MessagePack with `to_vec_named` rule (critical interop detail). Length-prefixed frames, end-of-stream checks, raw-output methods for large payloads. Thin-waist dispatch routes stable method IDs — reusable across FFI/TUI/web/WASM.

4. **Stateful document management** (editor_session, doc_registry): Rust-owned UTF-16 mirror (CmDoc) + op-log for durability. Content-based dirty detection so reverted edits read clean. Eviction policy (host-pinning + dirtiness ensures unsaved buffers survive pressure).

5. **Canvas M1 engine** (canvas/* modules): Flat-store + fractional sibling order + interned keys + type registry + atomic ops + minimal DOM patches. Post-M0 demo; fully functional for real documents.

**Invariants held across the suite:**
- **No clock**: All timestamp-dependent logic receives `now_ms` from caller, keeping core deterministic.
- **No randomness**: Deterministic midpoints for fractional indices, `line-<n>` fallback IDs for JSON.
- **No panics**: Cursors + `.get()` instead of `[]` indexing. Errors are typed, never silent.
- **Parity by construction**: TUI/web share the same sort/find/parse engines, so feature divergence is structural (rendering only).
- **Resource capping**: Heap budgets, cell caps, depth limits, frame size caps. Input bombs fail as data, not OOM.

---

## Patterns Worth Porting — Concrete, with File Pointers

### 1. **Two-Sink Tokenization (CSV Pattern, TSK-844)**
**File:** `csv.rs` (lines 218–227)
```
trait CsvSink { 
  fn cur_row_cells(&self) -> usize; 
  fn commit_field(&mut self, field: &mut String); 
  fn end_row(&mut self); 
}
```
**Why port:** Single tokenizer + two implementations (Vec output, Arena output) = byte-identical cap behavior by construction. Avoids grammar duplication and guarantees consistency. Reusable for other grammars (JSON, diff, etc.).

### 2. **Borrowed-Decode for Document-Sized Payloads (TSK-561)**
**File:** `wire.rs` (lines 163–179), `cm_edit.rs` (lines 250–297)
```
pub fn decode_borrowed<'a, T: Deserialize<'a>>(bytes: &'a [u8]) -> Result<T, WireFault>
// ApplyRequest<'a> with #[serde(borrow)] Cow<'a, str>
```
**Why port:** Edit requests, diff frames, find buffers, markdown input, transcript lines, highlight input all carry whole documents. Borrowed decode = zero-copy; critical for keystroke latency. Pattern: request seams get `Cow<'a, str>` fields, response seams get owned `String`.

### 3. **Ratchet-Based Perf Gating (TSK-588)**
**File:** `bench.rs` (lines 198–243)
```
pub fn compare(baseline: &Baseline, measurements: &[Measurement], tolerance: f64) -> Vec<Report>
```
**Why port:** Absolute thresholds are hostage to machine load. Ratchet (compare against previous + generous tolerance) catches real O(N²) regressions while tolerating transient jitter. BTreeMap serialization = stable, diffable baseline files.

### 4. **Fractional Sibling Order (Canvas M1, TSK-1356)**
**File:** `canvas/store.rs` (base-62 alphabet, fractional index)
**Why port:** Insert-between O(1), no renumbering ever. Scales to millions of edits without re-indexing siblings. Figma's model, proven battle-tested.

### 5. **Type Registry + Fence Before Mutation (Canvas M1, TSK-1357)**
**File:** `canvas/registry.rs`, `canvas/ops.rs` (lines ~50–100)
**Why port:** Validate every op before applying. If any fails, roll back via inverse. Never half-applied state. Atomic ACID semantics.

### 6. **Chunk/Sentinel Boundary for Host Coupling (Markdown, TSK-631)**
**File:** `markdown.rs` (lines 99–103, splice logic)
```
pub fn sentinel(n: usize) -> String { format!("<!--mdv-chunk-{n}-->") }
```
**Why port:** Core renders structure; host enriches islands (sanitize, highlight, diagram). Sentinel-based splice = segment-based (survives payloads containing sentinel text), never iterative replace. Clean separation of concerns.

### 7. **Content-Based Dirty Detection (EditorSession, TSK-1516)**
**File:** `editor_session.rs` (Fingerprint struct)
```
struct Fingerprint { hash: u64, len: usize }
```
**Why port:** Reverted edits read clean (better UX than sticky dirty flag). 64-bit hash + length is acceptable collision-resistance for UX; save path writes actual text (never trusts fingerprint).

### 8. **Host-Pinning + Dirtiness Composition (DocRegistry, TSK-1517)**
**File:** `doc_registry.rs`
```
effective_pin = host_pin || is_dirty()
```
**Why port:** Unsaved buffers never evicted even under budget pressure. Composed decision (host visibility + content state) is cleaner than one-off pins.

### 9. **Tolerant JSONL Framing (Transcript, TSK-632)**
**File:** `transcript.rs` (lines ~50–100)
**Why port:** Live-append JSONL (torn tails) must not crash. Skip malformed lines, never fatal. Critical for streaming transcripts.

### 10. **Hand-Rolled JSON Parser (TSK-632)**
**File:** `json.rs` (no `serde_json`)
**Why port:** Tolerant line framing + depth cap + no-panic discipline. Hand-rolled is <1000 LOC and avoids a heavyweight dependency. Recursive-descent is clear and auditable.

---

## Anti-Patterns / Regrets — What a Rebuild Should NOT Repeat

### 1. **Do NOT Use `serde_json` for Transcript**
**Why:** `serde_json` is heavyweight, does not handle tolerant line framing (torn tails), and requires external dependency for core. The hand-rolled parser is <1000 LOC, deterministic, and core already avoids randomness. **Lesson:** Core-only logic should minimize external deps.

### 2. **Do NOT Bake Absolute Performance Thresholds**
**Why:** `criterion` + fixed thresholds are flaky under machine load. Ratchet-against-previous + generous tolerance (50%) is reproducible across noisy runners. **Lesson:** Compare CHANGE, not absolute wall-clock (unless you control the machine).

### 3. **Do NOT Silently Replace U+FFFD on Lone Surrogates**
**Affected:** `cm_edit.rs`, `json.rs`, `markdown.rs`
**Why:** Silent substitution corrupts the buffer permanently, diverging editor and disk. Reject + return None, letting caller handle resync. **Lesson:** Lossy transformations at FFI boundaries are catastrophic; be strict.

### 4. **Do NOT Serialize Structs as `rmp::to_vec` (default array form)**
**Affected:** wire.rs comment (line 6–7)
**Why:** `to_vec` emits arrays; Swift/JS expect named-field maps. Silent mismatch → corrupt decode. **Lesson:** Make the `to_vec_named` rule **mandatory + documented in a playbook**, not optional.

### 5. **Do NOT Read the Clock in Core**
**Why:** Non-determinism makes unit tests flaky and eviction logic non-testable on host. **Lesson:** Caller supplies timestamps (now_ms). Pure policy functions are fully unit-testable.

### 6. **Do NOT Iterate Lines with `.split('\n')` then `.split(' ')`**
**Why:** Pattern does not preserve empty subsequences properly. **Lesson:** Swift `split(omittingEmptySubsequences: false)` ≠ Rust implicit true; document the difference in A/B tests.

### 7. **Do NOT Assume Graphemes Are Characters**
**Affected:** fuzzy.rs docstring
**Why:** The Swift original walks `Character` (grapheme clusters); Rust chars are Unicode scalars. A/B corpus stays ASCII-only; divergence on emoji is documented and tolerated. **Lesson:** Index units must be defined and tested.

### 8. **Do NOT Re-Implement Sort/Find/Parse Logic Per Tier**
**Why:** EVERY divergence in TUI vs web is a feature parity bug. Rust core enforces parity by construction (one engine, shared). **Lesson:** Shared engines are not optional; they are the primary defense against divergence.

### 9. **Do NOT Allow Unbounded Op-Log Growth**
**Affected:** editor_session.rs
**Why:** Long typing sessions can exhaust memory. Compaction is necessary. **Lesson:** Append-only logs need LRU or compaction; do not defer.

### 10. **Do NOT Evict Dirty (Unsaved) Documents**
**Affected:** doc_registry.rs (owner policy 2026-07-04)
**Why:** Users lose work. Dirtiness + host-pinning composition is the solution. **Lesson:** Eviction policy is product logic, not just memory optimization.

---

## Gotchas & Surprises

1. **MessagePack `to_vec_named` is NOT the default** (wire.rs). The default `rmp::to_vec` emits positional arrays; Swift/JS decoders expect named-field maps. This was a silent interop trap caught by A/B tests.

2. **Borrowed-decode requires `#[serde(borrow)]` on the struct field** (wire.rs lines 163–179). Without it, strings are copied. Critical for zero-copy on document-sized payloads.

3. **Fractional indices can have arbitrarily long prefixes** (canvas/store.rs). Insert-between computes midpoints; if you insert between `a` and `b` many times, indices grow (e.g., `a`, `a.` or `aM`, `aM1`, `aM10`, ...). No renumbering is needed, but index length is unbounded. Clients must NOT assume fixed length.

4. **Content-based dirty detection uses `Hash` of the UTF-16 decoded form** (editor_session.rs). If a mirror is ever ill-formed (lone surrogate), the hash reads as length-only. This is acceptable (ill-formed mirrors are always dirty anyway), but document it.

5. **Canvas ops are idempotent on retry** (canvas/ops.rs). `Insert` with an existing id + same kind/parent/props is Ok no-op. This is intentional (agent retry tolerance) but must be documented as a wire contract.

6. **The `HEX_WIDTH` constant is shared between core + TUI + web** (view.rs). A change in one must reflect in all; the constant lives in core to enforce this. **Lesson:** Source of truth placement matters.

7. **The fuzzy matcher scores are LOCKED to Swift parity during migration** (fuzzy.rs docstring). Every constant (+1 base, +6 boundary, +4 consecutive, etc.) is part of the A/B contract. Do not tweak without updating the corpus.

8. **Limit on hunk coordinates: `MAX_COORD = 1,000,000,000`** (diff.rs line 81). Absurd line numbers saturate instead of overflowing. A defensive choice for degenerate diffs.

9. **The two-sink CSV pattern requires careful trait design** (csv.rs). The sink must capture `cur_row_cells()` so the tokenizer can check the per-row cap. Traits with state are error-prone; keep them minimal.

10. **The formula evaluator is sliced by domain** (formula.rs). Slice 1 = arithmetic only. Slices 2+ add refs, ranges, functions. Slices are committed separately and validated against the Swift corpus slice-by-slice. Do not cut slices at arbitrary LOC boundaries; respect functional coherence.

---

## Rebuild Notes — If Building This Capability Fresh: Approach, Boundaries, What to Design Up Front

### Architecture & Layering

1. **Core = Pure Engines + Wire Boundary; Host = Everything Else**
   - Core: format parsing, search, sorting, validation, eviction policy. No clock, no RNG, no IO, no regex (ReDoS). Fully testable on host.
   - Host: filesystem IO, GUI rendering, subprocess calls (git diff), real-time event loops, user decisions (pin/unpin).
   - **Boundary:** Thin-waist dispatch (method IDs, MessagePack frames, `Cow<'a, str>` borrowed inputs). Document the contract upfront.

2. **Stateful Document Management**
   - **Early design question:** Does the core hold the document, or only parse/transform?
   - **Decision here:** Core holds UTF-16 mirror (CmDoc) + op-log + metadata. Host holds filesystem bytes and UI state.
   - **Rationale:** Keystroke path ~10× traffic reduction (deltas, not whole buffer). Durability (op-log for undo/local-history). Content-based dirty detection (reverted edits read clean).
   - **If you rebuild:** Decide this upfront. It drives the entire session/registry design.

3. **Multi-Tier Architecture (Core + TUI + Web)**
   - Core exports the same engine instances to TUI, web, and future tiers.
   - Sort/find/parse engines are shared; divergence is only rendering.
   - **Critical:** Design the wire boundary so a WASM shim or a remote transport can consume it. The dispatch method IDs should be stable ABI.

4. **Canvas Engine (M1)**
   - Separate from document editing. Canvas is structured documents (design, templates, dashboards). Editing is text.
   - M1 = flat-store + fractional-order + interned keys + type registry + atomic ops + undo.
   - Do NOT bolt canvas onto the editor core; they are distinct domains with different invariants (editing is keystroke-fast, single-threaded; canvas is batch-ops, schema-validated).

### Key Design Decisions Upfront

| Decision | Here | Rebuild Guidance |
|----------|------|------------------|
| **Document ownership** | Core holds mirror + op-log | Decide if core is stateful or stateless; it drives session design |
| **Wire codec** | MessagePack named-field maps (rmp-serde) | Choose JSON or MessagePack. If MessagePack, make `to_vec_named` **mandatory** in docs |
| **UTF-16 vs UTF-8** | Core uses UTF-16 (CodeMirror's indexing) | If host is UTF-16-based (macOS NSString), mirror at core. If UTF-8-based, convert at boundary |
| **Dirty detection** | Content-based fingerprint | Sticky dirty flags lose work on reverts. Fingerprint is better; plan for it early |
| **Eviction policy** | Host-pin + dirtiness + LRU + TTL | Multi-factor eviction is complex. Design once, test deterministically (pure function) |
| **Fractional sibling order** | Base-62, no renumbering | If document can have millions of edits, fractional is essential. Commit upfront |
| **Tolerance vs strictness** | Tolerant parsing, strict wire | Parsing (user files) should degrade gracefully. Wire (internal protocol) should be strict |
| **Shared vs per-tier engines** | Shared (one CSV parser, all tiers use it) | Parity by construction. Do NOT re-implement per tier |

### Testing Strategy Upfront

1. **Pure-logic unit tests on the host** (no VM, no FFI)
   - `bench::compare` planted-regression tests (prove TEETH)
   - `cm_edit::apply` A/B parity against Swift (differential testing)
   - `csv::parse` resource-cap firing (planted DoS)
   - `json::parse` tolerant-line framing (torn tails)
   - `runtime::eviction_plan` deterministic policy (time-free, host-testable)

2. **A/B parity tests on a shared corpus**
   - Every ported engine (cm_edit, csv, diff, find, fuzzy, hex, json, markdown, transcript, formula) runs against the Swift twin on the same inputs.
   - Corpus includes: edge cases (empty, single-char, giant), malformed/hostile, real data (actual CSVs, diffs, transcripts).
   - **Lesson:** Corpus discipline early prevents silent divergence.

3. **Wire/FFI tests (native platform)**
   - `encode_frame` / `decode_frame` round-trip tests
   - Raw-output methods (HexRender, IndentDetect) tested with large payloads
   - Borrowed-decode correctness (lifetimes, no-copy)

4. **VM/integration tests (after core lands)**
   - Live editor keystroke path (stateful CmDoc)
   - Canvas op apply + undo + replay
   - Multi-tier (TUI + web consume same engines)

### Dependency Hygiene (Critical)

- **CSV, diff, find, fuzzy, hex, json, markdown, transcript:** Zero deps (or owner-approved minimal set, e.g., `pulldown-cmark`, `regex-lite`).
- **Formula, canvas:** Minimal deps. No proc-macros unless absolutely justified.
- **All deps:** `default-features = false` + explicit feature list + pinned exact version.
- **dev-deps:** `proptest`, `cargo-fuzz` for property testing and fuzzing. Not included in release binary.
- **Audit:** `cargo tree` for transitive bloat. A single dep brings entire supply chains (build.rs, proc-macros all compile locally).

### Deployment & Remote Transport

Design the wire boundary to support:
1. **In-process (this rebuild):** Core + TUI + web all in one binary. Dispatch is a function call.
2. **Remote (future):** Core is a separate service; dispatch is RPC over HTTP/gRPC/WebSocket. Method IDs + frame format stay the same.

To support remote without a rewrite:
- Method IDs are **stable ABI** (never renumber, never reuse).
- Frame format is **self-contained** (MessagePack named-field maps, no external schema).
- Requests use **borrowed inputs** (`Cow<'a, str>`) for zero-copy on the local side; remote converts to owned.
- Responses are **tiny** or **raw-output** (don't double-encode).

---

## Summary: What This Slice Demonstrates

**rust-core/crates/core (slice 1/2) is the production-grade, pure engine suite that powers all tiers by construction.**

- **Pure + deterministic:** No clock, no RNG, no panics. Fully testable on host.
- **Parity by construction:** TUI/web/future all use the same engines. Feature divergence is rendering only.
- **Resource-bounded:** Caps on cells, rows, heap, depth, frame size. Input bombs fail as data.
- **Wire boundary is thin:** MessagePack with `to_vec_named` rule, borrowed-decode for documents, method IDs as ABI.
- **Stateful document management:** UTF-16 mirror + op-log + content-based dirty. Keystroke traffic ~10× lower.
- **Canvas M1 is functional:** Flat-store + fractional order + typed ops + undo. Post-demo and ready for real documents.

**For the rebuild: Design the pure-logic core early, commit to a thin wire boundary, and enforce parity by construction across all tiers. Testing discipline (A/B corpus, planted regressions, tolerant-input tests) is essential.**

---

*Report generated 2026-07-11 | Slice 2 covers canvas subsystem + runtime + remaining modules*
