# Canvas · 02 — `canvas-core` (the engine; the bulk of the work)

> A **pure, sans-IO rust-core crate**. No WebView, no SwiftUI, no filesystem, no clock inside.
> Deterministic: same document + same ops ⇒ same records, same lowering, same patch plan.
> Everything here is host-testable (cargo gate + proptest/fuzz); nothing here needs the VM.
> Placement rationale: `README.md` + `05-ROADMAP.md` Q11 (reusable-core-is-Rust, no new
> Swift-engine port debt, wasm32/remote-core standing goals, compact-binary FFI preference).

## 1. Responsibilities (and explicit non-responsibilities)

**Owns:** record store · schema + validation + migrations · operation reducer + fence + inverse
ops · selectors/queries · DTCG token resolution · component expansion · data binding resolution ·
timeline model · static lint · lowering (records → HTML/CSS) · **DOM-patch plans** (op → minimal
mutation script) · export assembly (standalone HTML/deck player input) · revision + event log.

**Does NOT own:** geometry (the browser computes flex/grid — we never implement layout math; no
Taffy, no solver), measured lint (overflow/contrast-in-context — JS shell reports results back
as data), pixels/snapshots, file I/O, persistence, undo *UI* (core provides inverse ops; the
Swift shell owns the stack), the WKWebView bridge.

## 2. Document model — flat record store

```text
Document = {
  format:   "textview.canvas/v1",            // discriminator
  schema:   { sequences: { "core": 3, "node.chart": 1, … } },   // migration versions
  records:  Map<Id, Record>,                  // THE store — flat
  meta:     { title, kind: page|deck|board, generator, … }
}

Record (common envelope)
  id:     branded, prefixed, opaque        // "nd:7f3a", "pg:1", "cmp:kpi", "tok:root", "dat:rev"
  type:   discriminator                    // per-type prop schema (§3)
  place:  { parent: Id, index: FracIndex } // ONE atomic field (Figma rule); FracIndex jittered
  name?:  human/agent label (addressing convenience; never identity)
  meta?:  open map (agent scratch, tags/groupIds-style cross-cutting refs)
```

- **IDs**: assigned at creation, never reused, never positional (the CAD topological-naming
  lesson). Callers MAY supply IDs (`insert` with id = idempotent upsert → safe agent retries).
- **Sibling order** = jittered fractional index, engine-internal; the op API speaks
  `at: index|before|after` intent and the engine mints keys (`getIndexBetween`), rebalancing
  when strings grow.
- **Record kinds**: nodes (visual tree), pages, component defs, token sets, data blocks,
  timelines, behaviors. One store, one diff/merge/event model for all of them.
- **The tree is derived**: `childrenOf(parent)` = index-ordered scan (cached). Physical layout
  of the store is an engine freedom (arena/columnar — §2c), not schema.

### 2c. Physical representation — hyper-optimized internals (owner directive 2026-07-01)

Owner bar: *extremely minimal storage overhead; minimal transformations and intermediary
objects; minimal mem/CPU footprint; hyper-performant.* The design commitments (validated by
criterion benches in M0/M1, budgets below):

- **Interning everywhere.** Type ids and prop keys → `u16` symbols (registry-assigned, stable
  per schema version); string *values* → doc-local intern pool (`u32` handles, dedup). A prop
  is `(u16 key, CompactValue)`; a `CompactValue` is a tagged union (inline f64/i32/bool/symbol/
  token-ref/handle) — no boxed JSON values anywhere in memory.
- **Arena + SoA hot columns.** Records live in a generational arena (indices, not pointers);
  the hot fields (`type`, `parent`, `index`, flags) are struct-of-arrays for cache-friendly
  tree walks; cold props are compact sorted small-vecs per record. Target: **< ~200 bytes/node
  + interned strings**; a 10k-node document ≈ low tens of MB ceiling.
- **JSON exists only at the boundary.** Parse streams straight into the arena (serde streaming,
  no `serde_json::Value` intermediate); serialization streams back out. In-memory is never
  JSON-shaped.
- **Zero-intermediary pipeline.** DSL/ops parse → validate against the store in place (no
  retained AST) → apply → patch plan emitted into a reusable byte buffer → FFI returns a
  borrowed slice (zero-copy out). The patch plan is computed from op semantics + the type
  registry — there is **no shadow DOM in core** and no tree-diff on the edit path; full
  re-lower is the recovery path only.
- **Undo is the inverse-op log** (no snapshots, no persistent structures needed with a
  single-writer store); content-hash subtree fingerprints (u64) are the deferred incremental
  cache key for lowering.
- **Budgets (criterion-benched, gate-enforced once set in M1):** apply single op < 100µs and
  patch-plan emit < 1ms @ 10k nodes · load 10k-node doc < 50ms · full lower 10k nodes < 100ms ·
  steady-state memory < ~30MB @ 10k nodes. Budgets are ratchets: the bench suite fails the
  cargo gate on regression, same discipline as the app's perf benches.

## 3. Node types & prop schemas (the ShapeUtil pattern)

Each `type` registers: **prop schema** (validators), **defaults**, **lowering** (emit HTML/CSS
fragment), **static-lint hooks**, **migration sequence**. Adding a type touches one module.

v1 node types: `frame` (layout container: stack/row/grid/wrap/absolute) · `text` (RichText IR
inline runs; block role → token) · `image` · `shape` (rect/ellipse/line/arrow/poly; connectors
anchor to node IDs) · `table` · `chart` (Vega-Lite-shaped: `{mark, dataRef, encoding{channel→
field|value}}`) · `code` (existing highlight pipeline) · `diagram` (DiagramRegistry) ·
`component` (instance: `{ref, props}`) · `embed` (sandboxed raw HTML/CSS escape hatch — ships
in P1, not later) · `hole` (typed placeholder — a document mid-build is never invalid; lint
reports holes, render shows a stub).

**Style** = a closed prop set with CSS/Figma-familiar names (`fill`, `stroke`, `radius`,
`shadow`, `font`, `color`, `opacity`, `gap`, `padding`, `align`, `justify` …) — meet the
training distribution in *vocabulary*, constrain in *structure*. Every style value is a literal
or a `{token: "color.accent"}` reference. Layout children carry intent only (`grow`, `shrink`,
`span`, `minW/maxW/minH/maxH` clamps).

**Per-property ownership is declared in the schema** (the MusicXML lesson): model-owned
(everything above) vs **renderer-owned** (resolved geometry, measured boxes) — renderer-owned
values are *reported* into queries, never stored as document truth.

### 3b. The CSS escape-hatch ladder (Q13 — owner concern: CSS can't be fully encapsulated)

CSS is the canonical leaky abstraction; a Claude-Design-class target (complex real web design)
will exceed any closed prop set, and the research *measured* the cost of over-constraining
(DesignAsCode: banning `backdrop-filter`/`mix-blend-mode`-class properties visibly lowers
output quality). So the closed style set is a **default, not a ceiling** — a graded ladder,
with lint steering every author to the lowest sufficient rung:

| Rung | Mechanism | Properties | Trade |
|---|---|---|---|
| **L0** | Closed style props + tokens (§3) | lintable · themeable · portable · morphable | the 80% path |
| **L1** | **Raw-CSS passthrough per node** — `style.css: {"backdrop-filter": "blur(6px)", …}` | still in the model, diffable, preserved verbatim; sanitized (no `@import`, no external `url()` — CSP fences network anyway) | not themeable/lintable; lint flags it |
| **L2** | **Shared style rules** — named style records nodes reference (the Webflow shared-class lesson); may carry raw declarations *plus structured pseudo-class (`:hover`) and breakpoint variants*, scoped to referencing subtrees | reusable, one edit restyles all users; the home of responsive/media rules for the UI-Design track | selector power stays bounded (no global cascade) |
| **L3** | `embed` node — sandboxed HTML/CSS island (§3) | anything, opaque | invisible to lint/morph/export-semantics |
| **L4** | **Code components** (plugin-registered real code, Plasmic's survival move) | Claude-Design's last mile | full power, full responsibility |

The load-bearing invariant: **structure, identity, and layout stay model-owned even when
styling escapes** — the tree and IDs remain addressable/diffable/morphable at every rung, so
the agent-editability contract survives arbitrary styling complexity. Only *visual detail*
escapes; the document never stops being a document.

## 4. Operations — the only write path

```jsonc
{ "op": "insert",  "id?": "nd:k1", "type": "component", "into": "nd:grid", "at": 0,
  "props": { "ref": "cmp:kpi", "label": "Revenue" } }          // partial; defaults filled
{ "op": "update",  "id": "nd:t1", "set": { "props.text": "Q3" }, "unset": ["style.shadow"] }
{ "op": "move",    "id": "nd:k1", "into": "nd:row2", "at": "after:nd:k0" }
{ "op": "remove",  "id": "nd:k1" }
{ "op": "batch",   "label": "Insert KPI row", "ops": [ … ] }   // one undo step, atomic
```

- **Fence** (runs on every apply, any author): schema-validate, ID existence, cycle check,
  token-reference resolution, `place` atomicity, size/depth caps. Malformed ⇒ **typed error,
  nothing applied** (batches are transactions). Fuzzed (untrusted input).
- **Partials + defaults**: update = dotted-path merge with explicit `unset`; insert fills
  type defaults — authors never construct complete records (tldraw footgun killed).
- **Every op has a computed inverse** → `apply` returns `{rev, inverse, staticLint[]}`. The op
  log is the undo stack, the history, and the event feed — one mechanism.
- **Revisions**: ops carry `baseRev`; stale ⇒ structured conflict naming intervening ops
  (re-query → retry). Single writer at a time; per-property LWW + version/nonce (Excalidraw
  shape) reserved for later multi-writer — the flat store keeps the CRDT door open (no CRDT v1).
- **Agent contract** (enforced in tool descriptions + schemas): plan free-form first, then emit
  ops (schema-constrained emission only at the final step); JSON-Schema published per op for
  constrained decoding.

### 4b. The interface language (Q2b — spike DONE, `07-DSL-SPIKE.md`; owner approved the DSL direction 2026-07-01)

The owner's split is right: JSON is the *serialization*, not necessarily the *authoring
language*. The canvas is built **incrementally over many agent turns**, each patching a
portion — and the evidence says JSON ops are the wrong surface for that: AutoPresent (DSL code
= 80%+ executability vs 2–11% raw API), Framer (invented a terse patch language for its
agents — "every token spent is directly used"), LayoutGPT (representations the model has seen
at scale win), Let-Me-Speak-Freely (JSON-forcing during generation degrades output).

**Proposal — three surfaces, ONE op layer underneath (everything compiles to canonical ops):**

1. **Canvas DSL (write path).** Terse, line-oriented, CSS/Figma-familiar vocabulary; one line
   = one op; a fenced block = one atomic batch (one undo step). Sketch:
   ```
   insert kpi-card #k4 in #grid at 2 { label:"Errors"; value:"12"; delta:"-3%" }
   set #title { text:"Q3 Review"; font:$font.display }
   move #k1 after #k2
   animate #chart.opacity 0 -> 1 over 400ms after beat:reveal
   ```
   Parsed and validated in canvas-core (a parser is exactly what rust-core is good at; it gets
   the fuzz lane like every parser). Errors are line-anchored. `$token` / `#id|name` /
   `beat:` are first-class tokens — addressing is *in the grammar*, not bolted on.
2. **Projection editing (read-modify-write path — the "patch a portion" workflow).**
   `canvas_edit(selector)` renders the selected subtree as canonical DSL text; the agent edits
   that text exactly as it edits a code-file region today (the workflow models are heavily
   trained on); core **structurally diffs** old→new back into ops — existing IDs preserved,
   new nodes minted, removals explicit. This is Unison's `edit` pattern (text as a transient
   projection of structure) applied to the canvas; the diff is semantic, not textual.
3. **Canonical JSON ops** remain: the substrate every surface compiles to, the programmatic/
   MCP alternative, the `events` feed format, and the persistence layer (Q2a — decided).

**Spike (TSK-1350, blocks M2; parser home lands with M1):** grammar (incl. quoting/escaping
rules that survive LLM emission), projection canonical form (stable ordering so diffs are
minimal), the structural-diff algorithm + its property tests (`parse(render(doc)) == doc`;
`diff(A, edit(render(A)))` applies cleanly), error-recovery ergonomics (bad line ⇒ precise
message + the rest of the batch rejected atomically).

## 5. Tokens (DTCG-shaped, pinned)

Token records mirror the DTCG 2025.10 shape (`$value`, `$type`, brace aliases, composites,
`$deprecated`) — pinned snapshot, own validator (C1 resolution). Three tiers; **the fence steers
agents to tier-2 semantic references**; raw literals legal but lint-flagged; renames =
deprecate-and-alias. The default set derives from the active app theme and lowers to `--cv-*`
custom properties; a document restyles by swapping tier-1 values.

## 6. Components, control flow, data

- **Component def** = named subtree + declared prop/slot schema; **instance** = `{ref, props}`.
  Def-update re-expands instances as **one invertible op**. No variants matrix at v1
  (Plasmic-scale machinery; deferred with the tier-3-token rule: build when 3+ kits need it).
- **Focused component work + system-owned sync (owner directive 2026-07-01):** the def is its
  own projection-editing scope (`canvas_edit(component:…)` — agent context holds only the
  component); instances are **closed** v1 (param overrides only; `detach` forks to plain
  nodes; slot overrides = designed v2). Cross-document reuse via **kits** (kind:`kit` docs of
  defs+tokens): imports are **vendored + pinned** `{kit, version, hash}` so files stay
  self-contained; the app detects hash drift and offers per-document sync (diff preview → one
  invertible op). Replication/versioning/drift is engine+app machinery the agent never
  manages. Full workflow: `07-DSL-SPIKE.md` §4.
- **Structural control flow** (the UIDL/SwiftUI convergence): `conditional` (visibleWhen over
  state/data) and `repeat` (template × data collection) are node types, never code.
- **Data blocks**: named tabular/JSON records (`dat:`); `bind` = declarative property references
  (`props.value ← data.revenue.rows[i].usd`) — QML-style bindings, resolved in core at lowering
  time; live re-bind on data-block update ops (the FileWatcher feeds those ops in the shell).
  Rive's ViewModel split is the blueprint: typed data schema separate from motion/behavior.

## 7. Timeline & behavior model

- **Every animatable property** is a `{a, k}` container: `a:0` constant / `a:1` keyframes
  (`t`, value, hold, cubic-bezier easing handles, value-axis unclamped for overshoot). One
  interpolation code path (`alpha × rate_func` — the universal primitive).
- **Timeline records**: a `par`/`seq`/`excl` container tree; entries reference node+property
  tracks or **steps** (deck fragments: reveal-index model). **Relational timing**
  (`after: "tl:intro.end+0.3s"`) and **named beats** (`beat:reveal`) — agents sequence against
  beats; humans nudge beat times in the editor without touching structure (Motion Canvas
  time-events seam).
- **Behaviors v1** = closed verb set (`gotoPage`, `setState`, `showTooltip`, `playTo(beat)`,
  `openUrl`(policy-gated), `postMessage`(vetted)) hung on events. **Escalation path** (when a
  mode needs real state): Rive/XState-shaped **state machine records** — named states, typed
  inputs (bool/number/trigger), guarded transitions with mix durations. Documents stay data,
  never programs (PostScript anti-decision).
- **Morph transitions** (the signature): between two pages/steps the engine computes the
  **identity set-diff** — matched IDs interpolate (FLIP over WAAPI), enter/leave partitions
  fade — deterministic because IDs are real, with `morphKey` to force cross-node
  correspondences (PowerPoint `!!` lesson) and pluggable matchers reserved for text granularity.
  Core emits the *transition plan*; the JS player executes it.

## 8. Lint — two stages, honest split

- **Static (core, every apply, free):** schema violations, dangling refs (fail loud + repair
  suggestion), token misuse (raw literal in themeable slot), unreachable `conditional`, missing
  clamps on hug/fill text, absolute-island audit (flags "geometry unproven — measured pass
  needed"), holes outstanding, caps. Flow content is **provably** overlap-free — stated as a
  guarantee, not checked pixels.
- **Measured (JS shell, on demand):** resolved geometry, overflow, contrast-in-context,
  tap-target size. Reported back as data; `canvas_lint` merges both with provenance
  (`static|measured`) so the agent knows what's proven vs observed.

## 9. Lowering & patch plans

`records → resolve tokens → expand components → resolve bindings → per-type HTML/CSS emit
(each node stamped data-cv-id) → assemble page/deck (+ inject player runtime only for used
behavior layers)`. Deterministic; content-hash subtree fingerprints reserved as the incremental
cache key (Unison lesson; deferred lever).

**Patch plans:** for each applied op batch, core emits a minimal DOM mutation script
(`setText`, `setAttr/Style`, `insertBefore`, `remove`, `moveBefore`) keyed by `data-cv-id` —
the JS shell is a dumb applier. Full re-lower = the recovery path, never the edit path (F2).

**Export:** standalone HTML (records + player + assets inlined; the player interprets the same
document — runtime-interpreted, not codegen, per the Lona lesson) · PDF/PNG via the shell.
Framework code export = later tier (Q10), one-way and disposable, never re-imported.

## 10. Events & queries

- `events(sinceRev)` → op log entries with author labels (human gesture ops and agent ops are
  the same shape — Theatre.js peer-editing model; the human-awareness feed).
- `query(selector, fields, depth)` → projected records: ids/types/names/props/text +
  renderer-reported geometry when available. Selectors: id, type, name-path, tag, page/step
  scope. **Compact wire form** (omit defaults, short canonical names — Framer token economics).
- `timelineState(at: step|beat|t)` → what's visible/where — the MoVer-style declarative
  verification surface for TIME (agents/tests assert before any snapshot).

## 11. FFI & portability

- Boundary = **compact binary envelope** (house style, no JSON over FFI): ops in, results/
  patch-plans/events out; rides the TSK-634 codegen lineage. Swift keeps thin Codable mirrors
  only where SwiftUI needs value types.
- **sans-IO, wasm32-buildable** (CI-guarded like the rest of rust-core): keeps the remote-core
  door open (a remote agent authoring canvases through the same contract) and the option of the
  exported player one day sharing the engine. Neither is a v1 deliverable; the *constraint* is.

## 12. Testing (all host-side, cargo gate)

- **proptest invariants:** `apply(op); apply(inverse)` = identity · idempotent re-apply with
  supplied IDs · fence never partially applies a batch · fractional-index order stable under
  arbitrary insert/move storms · lowering deterministic (same doc ⇒ byte-identical HTML) ·
  migration round-trips (old fixtures → current → validate).
- **Fuzz targets** (TSK-584 rule — the fence decodes untrusted input): op batches, document
  files, token sets. Seed corpus from example docs.
- **Golden lowering fixtures:** doc → HTML snapshots, reviewed as text diffs.
- The JS applier + measured lint are the *shell's* tests (webview lane); the engine's contract
  tests pin the patch-plan format so the two sides can't drift.
