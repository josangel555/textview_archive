# M4 — Design system + the Claude-Design gauntlet (TSK-1347) — implementation plan

**Goal (05-ROADMAP §M4, 02-CORE-ENGINE §6, 07-DSL-SPIKE §6, 06 §M4):** the
reuse layer — component DEFINITIONS with INSTANCES that expand at lowering
(edit the definition once, every instance updates: the owner's
"focused work on reusable components, system-handled replication/sync"
rider made structural), instance overrides, an editable token/theming
surface with the zero-op retheme, a vendored starter kit — then the
milestone's honesty test: the **Claude-Design gauntlet**, ~10 realistic
design briefs driven through ONLY the agent surface, measuring how often
the abstraction fails into escape hatches. **Pivot criterion (owner):
>~30% escape rate ⇒ stop and revisit the abstraction before M5.**

## Architecture notes (the load-bearing choices)

- **Expansion at lowering, not at insert** (02 §6): an instance is ONE
  record (`component` kind, `ref` → `cmp:*`); `lower.rs` expands it by
  rendering the definition's subtree with the instance's overrides. Editing
  a definition therefore updates every instance BY CONSTRUCTION — no
  replication machinery, no sync protocol, nothing to drift. The patch
  planner treats a definition edit as "re-lower every visible instance"
  (bounded: instances of THAT definition only).
- **Expanded DOM ids are NAMESPACED** (`nd:inst/nd:inner`): stable,
  addressable (the inspector can select inside an expansion), and never
  collide with document ids. Geometry/selection work unchanged.
- **Overrides v1 = two forms only** (creep guard): (a) props set on the
  instance node apply to the expansion ROOT (fill/padding/etc.); (b) TEXT
  overrides keyed by the definition-subtree anchor (`override text
  nd:title "..."` on the instance). Deep structural overrides are OUT until
  the gauntlet demands them.
- **Definitions live in the document** (`cmp:*` roots, like pages). Kits =
  documents full of definitions; import VENDORS (copies + pins a kit hash)
  — no live cross-doc links (07 §6; drift is detected, not silently synced).

## Slices

### S1 (rust) — definitions + instance expansion + fences
- Store: `cmp:*` roots (insert_root already prefix-agnostic; registry gains
  `Definition` kind or reuses Frame-as-cmp-root? DECISION: a `cmp:` root is
  an ordinary Frame subtree — the ID PREFIX is the marker; zero new kinds).
- `lower.rs`: expand `component` nodes (ref → cmp subtree) with namespaced
  ids; depth cap 8; the CYCLE FENCE rejects a definition that transitively
  instantiates itself (apply-time, typed FenceError).
- Patch planner: an op touching a `cmp:*` subtree ALSO emits re-lower
  patches for every visible instance of that definition.
- Tests: expansion renders the subtree w/ namespaced ids; definition edit
  re-paints instances (patch plan includes them); cycle fence; depth cap;
  proptest: expansion never panics on arbitrary valid docs. Teeth.

### S2 (rust) — instance overrides (root props + text-by-anchor)
- Instance node props → merged onto the expansion root (instance wins).
- `overrides` prop (new key, component-only): text-by-anchor table; lowering
  substitutes; the fence validates anchors exist in the definition.
- Tests: root-prop override wins; text override lands; unknown anchor =
  typed fence; overrides survive save/load (io round trip). Teeth.

### S3 (rust) — DSL + vocab growth
- Definitions: `component #card { … }` (lowers to a cmp: root); instances:
  `use #card #hero-card [prop=… ] [override text #title "…"]`.
- `render` projects definitions + uses back (round-trip law holds).
- Vocab: the new forms in the cheat-sheet + JSON (rot-proof extended).
- Tests: parse→apply→render round trip; teaching errors (unknown component,
  bad override anchor); vocab rot-proof covers the new forms. Teeth.

### S4 (rust+swift) — token editing + zero-op retheme
- Wire/DSL statements: `token set <path> <value>`, `token alias <path>
  <target>`, `token rename <old> <new>` (deprecate-and-alias underneath).
- New patch verb `setTheme{css}`: replaces the root theme block — the
  ZERO-OP RETHEME made incremental (no re-lower; the var() indirection from
  M1.S5 pays off). canvas.js applies it; Swift decodes it.
- MCP: `canvas_tokens {doc, statements}` + tokens listed in canvas_vocab
  (already). Tests: rename keeps old refs resolving (M1 law through the
  tool); setTheme patch swaps live values (webview test, local lane). Teeth.

### S5 (swift) — the starter kit + import
- `CanvasKit.starter`: a built-in kit doc (card, button, badge, header,
  two-column section, KPI stat) built via the engine at first use; 
  `canvas_kit_import {doc}` copies its definitions in + records the kit
  hash (vendored+pinned; drift detection = hash mismatch surfaced in lint).
- Inspector/layers: instances render with an "instance of #card" badge row;
  expansion nodes are selectable but read-only in v1 (edit the definition).
- Tests: import lands definitions + hash; re-import detects drift (lint);
  instance badge derivation. Teeth.

### S6 — THE GAUNTLET (the milestone artifact; 06 §M4)
- ~10 realistic briefs (landing hero, pricing table, dashboard KPI row,
  signup form, testimonial grid, nav bar, article layout, feature grid,
  footer, stats banner) driven through ONLY the MCP surface, kit allowed.
- Each brief scores: completed? ops used, lint findings, ESCAPE HATCHES
  touched (embed kind / raw-CSS-string props beyond the ladder's L0-L1).
- The suite prints a CANVAS-M4-GAUNTLET report (per-brief + the aggregate
  escape rate) and FAILS if escape rate > 30% — the pivot criterion as an
  executable assert. This is the milestone's acceptance gate.

### S7 — rich content kinds: chart (VL-subset) / table / code / diagram
- New kinds (registry + fence + vocab + DSL + lowering + inspector rows):
  `table` (rows/cols from a data prop, lowered to a real <table>), `code`
  (pre-formatted, language prop; v1 = escaped <pre>, the app's tree-sitter
  highlight can arrive later), `diagram` (MERMAID SOURCE — the app already
  ships mermaid rendering; the canvas node carries the source and lowers to
  the same mermaid path), `chart` (a HAND-ROLLED Vega-Lite SUBSET: bar,
  line, pie over inline data — zero new deps; the VL-subset JSON lives in a
  `spec` prop; lowering emits SVG server-side in rust for determinism).
- Each kind: fence rules + lint (empty spec, oversized data) + DSL forms +
  the rot-proofed vocab. Likely splits into S7a (table/code) + S7b
  (chart/diagram) at implementation time.

### S8 — bindings + repeat/conditional (the B0-B3 author-time tier)
- 02 §7's ladder made real at B3: DSL `each`/`if` blocks + a `data` prop
  (inline JSON) — EXPANDED AT APPLY (author-time: the doc stores the
  expanded records + the generating source on the container for re-runs;
  no runtime JS). FormulaEngine reuse for expressions where it fits
  (`{{item.price * 1.2}}` — the gated engine from the formula port).
- Fence: expansion caps (the records-per-doc cap already guards); teaching
  errors on bad paths/expressions.

### S9 — measured lint (the JS-side stage)
- The second lint stage (02 §8): geometry-dependent findings the static
  stage cannot see — text overflow (scrollWidth > clientWidth), offscreen
  nodes, contrast-in-context (fg/bg resolved through the cascade) —
  computed in canvas.js on demand (`measureLint` command → findings ride
  back), merged with static lint at the canvas_lint tool layer.
- Local-lane webview tests; the tool merge is host-tested.

## Budgets
- Expansion cost: lowering a 1k-node doc with 100 instances ≤ 1.5× the
  flat-doc cost (measured in the S1 tests, M0-style printout).
- Chart lowering (rust SVG): 1k-point bar/line ≤ 5ms; repeat expansion:
  500 items ≤ 10ms apply-side.
- Definition edit → 50 visible instances re-lowered ≤ 100ms engine-side.
- setTheme retheme: zero document ops, one patch, no re-lower.

## Risks / kill-criteria
- **Override creep:** v1 stays at root-props + text-by-anchor. Any gauntlet
  brief that NEEDS more gets recorded as a gauntlet finding, not silently
  implemented mid-milestone.
- **Gauntlet honesty:** briefs written BEFORE building S1-S5 finishes
  (this plan commits the list above — no tailoring the exam to the
  student). Escape-rate >30% = STOP, write the abstraction-gap report,
  surface to the owner before M5.
- **Namespaced-id leakage:** expanded ids must never enter the op path
  (the fence rejects `/`-containing ids as op targets — instances are
  edited via definition or overrides only).

## Validation ladder
Rust slices: cargo gate + proptests + teeth. Swift: host gate. The S4
setTheme webview test + any render checks: local in-process lane (the
M3-PLAN contingency stands while TSK-1365's two residual modes are open).
The gauntlet is host-only by design (MCP surface, no pixels).
