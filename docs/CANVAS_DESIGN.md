# Canvas — unified design (TSK-1342, reconciles CANVAS-0001)

> **Status: DESIGN — awaiting owner review. Nothing implemented.**
> Owner ask (2026-07-01): a WYSIWYG editor for **agents** (and humans) to build UIs,
> infographics, explainers, and presentations. Underlying tech is HTML/CSS/JS, but with
> **abstraction layers to reduce friction** so an agent *inserts/edits structured elements*
> instead of writing top-down HTML files. It is the **foundation layer** for later features
> (UI Design à la Claude Design, Presentations, Explainers-in-Walkthroughs, and more).
> **Read §0 first** — it reconciles the two independent design passes and carries the single
> merged decision list (Q1–Q10). §1–§11 below remain the problem-space/foundations spike.

---

## 0. RECONCILIATION (2026-07-01) — adopted unified design

Two independent design passes were produced the same day: **this doc** (TSK-1342 — problem
space, prior-art/lowering principles, wide use-case sweep, boundaries) and
**`docs/CANVAS_DESIGN_CANVAS-0001.md`** (a second claude-mdv session; markdown-filed as
CANVAS-0001 while the board was down — deep codebase-integrated engineering design). They
**converge on every fundamental** *independently* — a strong signal the architecture is right:
scene graph as the only source of truth (never HTML) · stable IDs on every node with a
`data-cv-id` DOM back-reference · small declarative ops (insert/update/move/delete/batch) with
the op log = undo = history · auto-layout containers lowered to flex/grid · design tokens with
app-theme inheritance · components with props/slots · declarative behaviors (no authored JS) ·
sandboxed raw-HTML `embed` escape hatch · standalone-HTML/PDF/PNG export · no CRDT v1 ·
zero new deps / vendored hand-rolled runtime.

**Verdict: adopt CANVAS-0001 as the engineering base** — it is materially stronger where it
counts for build-out (verified against the code 2026-07-01: the cited reuse seams
`CodeMirrorBridge`, trusted-HTML `HTMLDocumentPolicy` (†in `ViewerCore/`, not `ViewerUI/`),
`MermaidBundle` vendoring, Walkthrough engine/store, `MCPToolCatalog`/`AutomationHost`,
`ScriptVerbCatalog`, warm WebView caches, `ViewMode` all exist as claimed):

- **L0–L4 stack bound to real app seams** (CM6-style bridge/vendoring, warm caches, MCP tools) —
  de-risks the build and honors house lessons (TSK-1046 park/re-attach, compositor occlusion).
- **F1–F8 friction table** — each layer justified by the friction it kills.
- **The feedback loop** (query → lint → snapshot tiers; lint inline with every apply; snapshot
  via the runtime = headless, **no Screen-Recording TCC** — sidesteps the T5-grant class).
- **Co-editing protocol** (rev/baseRev conflicts, events feed, shared undo with author labels,
  locks) — my design only gestured at this.
- **Security model** (op fence, path jail, first content-write-MCP precedent, resource caps,
  embed = HTML/CSS-only sandboxed iframe) and a **testing strategy** mapped to the house tiers
  (host gate / WebView lane / T5+T6 with negative-control teeth).
- **P0-first phasing** that kills the riskiest unknowns (bridge perf, patch fidelity) before any
  schema freeze.

**This doc contributes to the unified design (CANVAS-0001 adopts these):**
- **§10 hard boundaries** — the distortion table (no pixel editing / NLE / CAD / 3D / app
  backend / prepress / game runtime; the 10³⁺-node DOM-scale fork). CANVAS-0001 has thin
  non-goals; foundation epics die by scope creep — this is the fence.
- **§9 wide use-case sweep** (~60 across 11 families) + the *preset formula* (a mode = spatial
  model + palette + enabled layers + export targets) — pressure-tests that one core carries all;
  CANVAS-0001's UC-1..14 are the near-term subset.
- **§3 lowering principles** (engraving research): three-layer model (intent ▸ structure ▸
  presentation, presentation always computed), bidirectional intent↔pixel linkage, primitives
  carrying composition metadata — the design rationale under D1.
- **Two decisions CANVAS-0001 misses** — added as Q9/Q10 below.

**Conflicts resolved:**

| Topic | This doc said | CANVAS-0001 says | Resolution |
|---|---|---|---|
| Layout default | free-form default (slides/infographics), auto-layout for UI | auto-layout default, `absolute` opt-in per-frame (D2) | **Adopt D2.** The agent-first argument wins: agents without pixel feedback produce overlapping absolute layouts (the #1 LLM-layout failure). Free-form stays one op away for the genuinely freeform. §5's hybrid note is superseded accordingly. |
| Layer numbering | L0–L7 stack | L0–L4 stack | Same layers, different granularity (my L3 layout + L4 comp/tokens + L5 behavior live *inside* its L2 model + L1 runtime; my L6 export + L7 modes ≈ its L4 domain layers). **Adopt CANVAS-0001's L0–L4 naming** going forward. |
| Op surface | generic `scene.*` verbs | concrete `canvas_*` MCP tools + script verbs + `{baseRev, ops[]}` envelope | **Adopt CANVAS-0001's** (concrete, house-patterned, adds the missing read/lint/snapshot/events tools). |
| DOM back-ref attr | `data-cvs-id` | `data-cv-id` | `data-cv-id`. |
| First mode | Slides *or* Explainer (asked owner) | Presentation first (Q1: epic 688 + OwnerWishlist P6 signal) | **Converged: Presentation first** — CANVAS-0001 brings the evidence. |
| Ticket of record | TSK-1342 | CANVAS-0001 (board was down) | Board is back: **TSK-1342 is the epic of record**; CANVAS-0001 ≡ TSK-1342. Decompose per its §15 (one ticket per P0–P5 slice, `area:canvas`) on green-light. |

**Review findings on CANVAS-0001 (gaps the unified design fixes — none architectural):**
1. **No FLOW/pagination stance** → its UC-9 "rich reports (PDF export)" hits text pagination
   immediately (the thing Figma/Canva/Miro all punt). → **Q9**.
2. **No DOM-scale ceiling** for `kind:"board"`/diagram ambitions (10³–10⁴ nodes collapse DOM
   rendering) → note the virtualization/canvas-backend fork trigger on D3. → folded into Q3.
3. **Insert idempotency:** `baseRev` handles conflicts but not *retries* — a re-sent
   `insert` duplicates. Fix: ops may carry caller-supplied IDs (insert-with-id = idempotent
   upsert). Spec note for P1.
4. **`update` path semantics** (`"set": {"style.font": …}`) needs precise merge rules —
   dotted-path sets, an `unset`, array semantics. Spec note for P1.
5. **Component-definition update undo** (re-projects all instances) must be a single invertible
   op. Spec note for P1/P4.
6. Path nit: `HTMLDocumentPolicy.swift` is in `Sources/ViewerCore/`.

### The single merged decision list (owner review — supersedes §12 below and CANVAS-0001 §16)

| # | Decision | Recommendation |
|---|---|---|
| Q1 | First domain track after the core — Presentation (UC-2/3) or UI Design (UC-1)? | **Presentation** (epic 688 + wishlist P6; both designs converge). |
| Q2 | File extension — `.canvas` (Obsidian collision) or `.tvcanvas`? | `.canvas` + our `textview.canvas/v1` schema discriminator. |
| Q3 | Page/artboard-first; infinite `board` later (D3)? | Yes — with the added rider: `board`/large-diagram ambitions carry a **DOM-scale fork trigger** (virtualize or canvas-backend at ~10³ nodes); decide only if/when that use-case is prioritized. |
| Q4 | Zero new deps v1 — hand-rolled vendored runtime + hand-rolled SVG chart marks (D4)? | Yes; per-layer dep proposals (chart micro-lib, graph auto-layout à la elk/dagre) come back as parked approval asks only when scope demands. |
| Q5 | `embed` ceiling: HTML/CSS-only v1 (no script)? | Yes; script-in-iframe deferred until a use case demands it. |
| Q6 | Assets: single-file base64 (capped) vs sidecar dir? | Single-file to ~2 MB, sidecar beyond. |
| Q7 | Content-write MCP precedent: op fence + tab indicator + events audit, or per-document human grant? | Op fence + indicator + audit (grants add friction to the core loop). |
| Q8 | User-facing name "Canvas" (*File ▸ New Canvas*)? | Yes. |
| Q9 | **FLOW / text pagination stance** (reports/résumés/email — every canvas tool punts) | **Defer full FLOW**; v1 "reports" = multi-page pages with manual breaks; revisit as its own mechanic when a reports/docs track is prioritized. The schema keeps it additive (`kind:"flow"` later). |
| Q10 | **Code-export target for the UI-Design track** (UC-1's hard mile) | Standalone semantic HTML/CSS first; the framework target (React vs SwiftUI vs plain) decided when the UC-1 track starts — tiered: wireframe → clickable prototype → code. |
| Q11 | **Engine placement** — `canvas-core` as a rust-core crate (§0.6) vs a Swift ViewerCore model layer? | **rust-core** (per the owner's core-first directive + the settled reusable-core decision; §0.6 argues practicality). Confirm — it shapes P1 entirely. |

**On green-light:** implement per CANVAS-0001 §15 phasing (P0 spike → P1 document core → P2 agent
surface → P3 WYSIWYG → P4 design system → P5 presentation), decomposed on the board under TSK-1342,
with the §0.5 deltas and the §0.6 core-first split applied.

---

## 0.5 Research round 2 — salvaged fan-out results, mined 2026-07-01 (deltas ADOPTED)

The killed research fleet's canvas-related outputs were salvaged and mined (20 substantive
reports; per-dimension detail + citations: **`docs/research/canvas-2026-07-01/`**, README = index).
Two kinds of value: hard **evidence** for bets already made, and concrete **design deltas**.

### The empirical backbone (evidence the abstraction bet is right)
- **The abstraction level of the authoring API is the dominant lever on agent reliability:**
  AutoPresent measured LLM slide-generation executability at **2–11% against a raw low-level API
  vs 80%+ against a purpose-built high-level DSL** (170-line raw programs → 13-line library calls).
- **Raw coordinates are the documented model weakness:** LLM-layout literature finds "spatial
  hallucination… struggle with fine-grained spatial constraints and precise coordinate
  positioning"; raw SVG degrades with complexity. Flow/flex intent is the model's *strength*.
- **Generation is open-loop and blind** (DesignAsCode): render-and-inspect feedback is mandatory,
  not optional — independently validates the query→lint→snapshot loop (and the house T6 rule).
- **The production LLM-UI pattern is "select + parameterize from a registered vocabulary," not
  "write markup"** (Vercel AI-SDK generative UI, Thesys C1, Airbnb/Lyft server-driven UI) — the
  component-kit layer is the industry-convergent shape, arrived at from both the SDUI and LLM sides.
- **Framer's agent postmortem** (the one team that shipped "agent authors a design tree it can't
  see"): stream **patch deltas against stable ids**, compress the IR (short prop names, omit
  defaults) — "every token spent is directly used."

### Design deltas (adopted; supersede conflicting details in the docs below)

| # | Delta | Source / why |
|---|---|---|
| **R1** | **Flat record store, not a nested tree.** Document = map `id → node` + `parentId` + **fractional sibling index** (jittered, tldraw-style); `parentId+index` updated **atomically as one property** (Figma's orphan warning). File = `{formatVersion, schema, records}` (à la `.tldr`), canonical-sorted → still git-diff-friendly (one record per entry). The *render* tree is derived. Supersedes the nested `children:[…]` sketches in §5 below and CANVAS-0001 §5. | `document-models-scene-graphs.md`: "flat map vs nested children[] is the load-bearing decision" — O(1) reparent/reorder, surgical agent patches, CRDT-ready. |
| **R2** | **Schema migrations from day one.** Versioned per-sequence up/down migrations run on load (tldraw `StoreSchema`); unknown node types/props round-trip opaquely; Rive's type-tagged forward-compat is the north star if a binary form ever ships. | `tldraw-programmatic-authoring.md`, `scene-identity-timeline-transitions.md`. Additive-Codable alone under-invests; agent-written docs outlive schema versions. |
| **R3** | **Tokens = W3C DTCG 2025.10 format** (`$value`/`$type`, brace aliases) instead of an ad-hoc token tree. Three tiers (primitive → semantic → component); **the op fence constrains agents to tier-2 semantic references** (raw literals allowed but lint-flagged); renames via deprecate-and-alias. Compiles to `--cv-*` CSS custom properties (unchanged). | `design-tokens-theming.md`. A real standard with tooling; validates + hardens CANVAS-0001 §6.2. |
| **R4** | **Layout D2 hardened:** flow/flex/grid make overlap *impossible by construction* and are **statically checkable in the core without rendering** → the static half of lint moves into the engine (§0.6). Add min/max clamps on hug/fill (bounds intrinsic-sizing blowouts). **Never add a constraint solver** — under-constrained systems fail *silently* (Apple's own docs: no warning, no breakpoint) — the worst failure shape for a blind agent. | `layout-abstractions-blind-agents.md` (+ LLM-layout papers). |
| **R5** | **Op ergonomics:** ops accept **partials, engine fills type defaults** (kills tldraw's two-write-tier footgun); `insert` accepts **caller-supplied IDs** → idempotent retries; a `hole` placeholder node type (Hazel) so mid-build documents are never invalid; document `unset` + dotted-path merge semantics precisely. Tool guidance: **plan free-form, then emit schema-constrained ops** — format-restricting the *reasoning* measurably degrades it ("Let Me Speak Freely"). | `tldraw…`, `projectional-editing…`, `ui-description-languages…`. |
| **R6** | **TIME/INTERACT layer shapes:** every animatable property uses Lottie's **`{a,k}` container** (constant *or* keyframed, one interpolation path for everything); timeline composition = SMIL's **`par`/`seq`/`excl` container tree** with **relational timing** (`after: intro.end`), serializable + seekable; INTERACT altitude = Rive-style **state machine** (named states + typed inputs + transitions) rather than loose event→action pairs when state grows. | `animation-motion-representations.md`, `scene-identity-timeline-transitions.md`. |
| **R7** | **Identity-based morph transitions — signature feature.** Keynote Magic-Move / PowerPoint Morph / reveal auto-animate all *heuristically match* elements between slides (and mis-match). **Our stable IDs make the match exact**: same id on adjacent pages/steps ⇒ deterministic FLIP morph. Falls out of the model nearly free; no other HTML deck tool has exact matching. | `scene-identity-timeline-transitions.md`. |
| **R8** | **Verify loop for motion/steps** (MoVer pattern, 58.8%→93.6% via check-and-iterate): the runtime exposes **declarative timeline state queries** ("what is visible/where at step N") so agents and tests verify TIME behavior as data before any snapshot. | `animation-motion-representations.md`. |
| **R9** | **Meet the training distribution:** node/style/layout vocabulary mirrors CSS/Figma names the model has seen at scale (`gap`, `padding`, `align`, `justify`, `fill`, `stroke`…) — no exotic synonyms. Chart IR follows the Vega-Lite encoding shape (`mark` + channel→field). | `explorables-llm-ui-generation.md` (LayoutGPT), `declarative-grammars…`. |
| **R10** | **Ceiling placed consciously; escape hatch is an early feature.** A too-tight IR measurably *lowers* visual quality (DesignAsCode); the no-code 80/20 ceiling is real. `embed` ships early (P1/P2, not "later"); Plasmic-style **code components** are the reserved plugin shape for the last mile. One-way codegen stays absolute — exported HTML is disposable, never hand-edited (round-trip = "two one-way pipes in a trench coat"). | `ui-description-languages…`. |
| **R11** | **Content-hash subtree caching** (Unison): hash each record subtree → skip re-lowering/re-rendering unchanged subtrees; also the natural fingerprint for the events feed. Perf lever, not a v1 requirement. | `projectional-editing…`. |
| **R12** | **The projectional-editing graveyard, read correctly:** structured editing failed where *humans hand-drove the structure* (Intentional, Darklang's editor); it works when the human sees a **projection** (our WYSIWYG) and the machine authors the model. The inherited obligation: diff/merge/review/search must stay possible → the canonical **text** JSON format + the app's own diff viewer are load-bearing, not cosmetic. Keeps Q-format decisions honest (no binary-only format). | `projectional-editing…`. |

### Review verdict on the salvage
Nothing contradicts the adopted architecture — the strongest reports *independently converge* on
it (typed nodes + stable IDs + ops + tokens + components + declarative behaviors + one-way
lowering). The material *changes* storage shape (R1), the token standard (R3), where lint lives
(R4→§0.6), op ergonomics (R5), and the TIME layer's internal shape (R6–R8) — and contributes one
signature feature (R7).

---

## 0.6 Core-first architecture (owner directive 2026-07-01) — where the bulk of the work lives

> Owner: Canvas must stay agent-driven and user-facing, but be **a fundamental, extendable,
> broadly reusable core feature — the bulk of the work is in core.** This section makes that
> concrete and grounded.

### The split: a pure, UI-agnostic **canvas engine** + thin shells

Everything that defines Canvas semantics is a **pure, sans-IO engine** — no WebView, no
SwiftUI, no file I/O inside it:

```
                    ┌──────────────────────────────────────────────────────┐
   ENGINE (core)    │  canvas-core: schema + records + migrations (R1/R2)  │
   pure, sans-IO    │  op reducer + validation fence + undo/invert         │
                    │  selectors · token resolution (DTCG) · component     │
                    │  expansion · STATIC lint (flow safety, token refs,   │
                    │  schema, caps — R4) · lowering → HTML/CSS + patch    │
                    │  plan · export assembly · events/rev log             │
                    └───────────────┬──────────────────────────────────────┘
                    FFI (compact binary ops/patches — house style, no JSON over the boundary)
        ┌───────────────────────────┼───────────────────────────────┐
   Swift shell                      │                        JS shell (WKWebView)
   file I/O · persistence/sessions  │                        DOM patch APPLIER (engine emits the
   MCP/script-verb hosting · undo   │                        patch plan) · direct manipulation →
   stack UI · SwiftUI chrome        │                        ops · MEASURED lint (geometry,
   (inspector/layers/palette)       │                        contrast-in-context, overflow) ·
                                    │                        behavior/timeline player · snapshot
```

- **In core** (the bulk): document model, ops, fence, selectors, tokens, components, static lint,
  the IR→HTML/CSS lowering and DOM-**patch plan** computation, export assembly, migrations, the
  rev/event log. All deterministic, all host-testable, all reusable.
- **Deliberately NOT in core:** the layout *math* — flexbox/grid geometry is computed by the
  browser engine (that is *the* reason HTML/CSS is the substrate; we never write or vendor a
  layout engine — no Taffy, keeps core dep-free). Consequence: geometry/measured-lint live in the
  JS shell and are reported back as data.
- **Swift/JS become shells:** Swift = I/O + persistence + agent-surface hosting + native chrome;
  JS = a dumb patch applier + interaction capture + measurement + player.

### Placement: the engine is a **rust-core crate** (`canvas-core`)

Grounded in standing house decisions, not novelty:
1. **"Reusable-core is Rust"** is the settled architecture (2026-05-30 decision; engine ports
   TSK-630..634). Building a NEW engine in Swift would mint the next port-debt item on day one —
   the migration policy exists precisely because we keep paying that cost.
2. **Remote-core + wasm32 are standing goals** the engine slots into: `canvas-core` sans-IO ⇒
   wasm-buildable (CI-guarded like the rest of the core), which keeps two doors open cheaply —
   a remote agent authoring canvases through the transport-agnostic contract, and (later) the
   exported standalone player sharing the exact engine.
3. **Compact binary over the boundary** is the owner's stated FFI preference; Lyft's SDUI
   (protobuf primitives, 40–60% smaller payloads) is the production precedent for binary UI-doc
   ops. Ops/patches ride the existing envelope work (TSK-634 codegen lineage).
4. **The test story lands in the strongest lane:** op-reducer invariants are proptest-shaped
   (`apply∘invert = identity`, idempotent re-apply, fence never partially applies, lowering
   determinism) — the house property-test lane (TSK-585). The op fence decodes untrusted input ⇒
   a fuzz target + corpus per the TSK-584 rule. Both are cargo-gate, VM-free.
5. **Known frictions, priced in:** FFI surface grows (mitigated by the codegen path); the VM has
   no Rust toolchain (existing flow: host-built `libmdvcore_ffi.a` rsync'd — unchanged); Swift
   keeps thin Codable mirrors only where SwiftUI needs value types.

### What this changes in the phasing (CANVAS-0001 §15, amended)
- **P0 spike** gains one goal: prove the **core↔WebView patch loop** (Rust computes patch plan →
  FFI → JS applies → geometry query returns) alongside bridge perf.
- **P1 document core = the `canvas-core` crate** (records/ops/fence/tokens/lowering/static-lint +
  proptest/fuzz), NOT a Swift model layer. Swift gets the Codable mirror + store glue only.
- Later phases unchanged in order; each render slice still carries its VM tail.

---

## 1. Problem statement

Agents are good at producing **structured intent** ("a title, three feature cards, a CTA
button") and **data→graph** mappings. They are bad at producing **pixel-precise HTML/CSS**:
raw markup is a huge, unforgiving surface — flexbox/grid/positioning bugs, no stable way to
re-target an element later, no spatial feedback loop, and every edit is a file rewrite. Today
the agent writes a whole `.html` file top-down and hopes it lays out; it can't *see* the
result, can't nudge one element, and can't reliably say "change THAT card."

**Canvas** replaces "emit an HTML file" with "**operate on a structured scene**": the agent
inserts, moves, styles, and binds *elements* addressed by stable IDs, against a semantic
document model that the system **lowers** (compiles) to HTML/CSS/JS and renders live in a
WebView. The human sees WYSIWYG; the agent sees an inspectable, addressable model. The same
core powers many products (§9) — UI design, slides, infographics, explainers, diagrams, …

### Goals
- **Agent-first authoring.** A small, composable, *addressable*, *idempotent*, *undoable*
  operation API — the agent's primary interface. WYSIWYG for the human is the second consumer.
- **Friction reduction via the right abstractions** (§4): semantic elements + components,
  layout that an agent can get right *without seeing pixels*, design tokens, op-based edits.
- **One foundation, many modes.** Slides / infographics / UI / explainers are *presets*
  over one scene core, not separate apps.
- **HTML/CSS/JS is the render substrate + an export target**, never the authoring model.
- **Fits the existing app**: a new tab/`ViewMode` rendered in a `WKWebView` (reuse the
  MarkdownRenderedView / CM6 WebView infra), persisted per-tab/session like other documents,
  driven by the existing agent surfaces (verb bus / MCP / stable-element addressing).

### Non-goals (v1) — and the hard boundaries (§10 details them)
- Not a pixel/photo editor, not a video NLE, not a CAD constraint-solver, not a 3D tool, not
  an app backend. Canvas authors/lays-out; it does not become those specialized *runtimes*.
- Not real-time multiplayer in v1 (the model should not *preclude* it — see §5 CRDT note).
- Not a general HTML *importer* in v1 (lowering is one-way IR→HTML; see §6).

---

## 2. Prior art — what to steal, what to avoid (not-invented-here survey)

*(Synthesized from the research subagents + domain knowledge. The prior-art web survey is
still running; its citations will be appended to `docs/research/canvas-2026-07-01/` when it
lands. The abstraction subagent failed on a model outage; that dimension is covered here from
knowledge + the "lowering pipeline" findings below.)*

| System | The transferable idea | The caution |
|---|---|---|
| **Figma** | *Auto-layout* (flex-like stacks with padding/gap/alignment) is the single most agent-friendly layout primitive — declarative intent, engine computes pixels. Components + variants + tokens. | Its model is proprietary/absolute-first; auto-layout is a *layer on top*, exactly as we should do it. |
| **tldraw** | Clean **shape schema + `ShapeUtil`** (each shape type owns its schema, render, bounds, resize) + a reactive **store** + a **migrations** system + a documented editor/command API. The closest architectural blueprint for an agent-addressable scene. | React/DOM-canvas hybrid; we render via lowering-to-HTML, not its canvas.
| **Excalidraw** | Dead-simple flat **element array** schema (type + geometry + style + a stable `id` + `version`), trivially serializable + diffable. | Flat array (no true containers) limits nesting/auto-layout; we want a tree. |
| **ProseMirror / Lexical / Slate** | **Document = schema + transactions of steps**; every edit is a typed, invertible step → undo/redo + collaboration fall out. This is the model for our **op API** (§7). | Text-flow-centric; we generalize "steps" to spatial ops. |
| **Yjs / CRDTs** | If multiplayer/merge ever matters, a CRDT-shaped document makes concurrent edits + offline merge tractable. | Overkill for v1; just keep the model *CRDT-able* (stable IDs, commutative-ish ops). |
| **reveal.js / impress.js / Slidev** | Presentations = HTML sections + a **step/fragment timeline** + transitions + presenter mode. Our `TIME` layer + a "slide" preset ≈ this, for free. | They're authoring-by-HTML; we author-by-scene and *lower* to this shape. |
| **Webflow / Framer / Plasmic / Builder.io** | Visual→**production code export** (the hard, high-value mile for "UI Design"). Plasmic's "designs are data, codegen is a consumer" is the right stance. | Code-export fidelity is genuinely hard; ship *tiers* (§9 UI). |
| **Music engraving: LilyPond / MEI / MusicXML / SMuFL / Verovio** (the serendipitous orphan) | The deepest lesson for a *lowering* system — see §3. A 25-year-proven "author intent, compute the visual" architecture. | Their last-mile aesthetic still needs human override; keep an escape hatch. |
| **D3 / Vega-Lite** | Data→visual as a **declarative grammar** (encodings: x/y/color/size). The right shape for the `DATA` layer + charts. | Vega's full grammar is large; expose a curated subset via chart *components*. |

---

## 3. The core insight — Canvas is a **lowering compiler**, not an HTML editor

The single most important framing (reinforced independently by the music-engraving research):
**hard-split "what it IS" from "how it looks," and COMPUTE the visual from the intent.**

Music engravers (LilyPond, MEI+Verovio) never store coordinates in the source; they store
*semantic intent* and run a **phased pipeline** (parse → events → contexts → engravers →
graphical objects → backend) that computes publication-quality layout from rules. Five
patterns transfer directly:

1. **Semantic/visual split, visual computed not stored.** The scene model holds *intent*
   (a "card" with a title + body, in a "row", themed "primary"), not `<div style="left:…">`.
   The renderer computes the HTML/CSS. → our **Scene IR → lowering → HTML** (§5, §6).
2. **Lowering as a phased pipeline**; the semantic side never holds pixels. → §6.
3. **Layout by constraint/optimization, not imperative placement** (LilyPond's springs-and-rods
   + "ugliness score"). → auto-layout containers + snapping/alignment engine (§5 layout).
4. **A three-layer model beats two: intent ▸ logical structure ▸ presentation** (MEI). For us:
   *semantic role/binding* ▸ *element tree + props* ▸ *computed CSS/positions*. Presentation is
   derived + overridable, never the source of truth.
5. **Primitives carry their own composition metadata** (SMuFL glyph anchors) + **bidirectional
   intent↔pixel linkage** (Verovio stamps the source `id` into the SVG). → every element gets a
   stable `id`; the rendered DOM node carries `data-cvs-id` back to the scene element, so
   selection/drag on the WebView maps to a scene op, and the agent's ops map to DOM nodes.

**Corollary — keep a manual-override escape hatch.** Every mature lowering system does. Ours:
per-element style overrides + a "raw HTML/embed" element for the 10% the abstraction can't express.

---

## 4. The abstraction stack (the spike's core answer: *what layers make sense*)

Bottom = substrate; each layer up reduces friction for the agent. Layers marked **core** are
always present; the rest are **opt-in per mode/preset**.

```
 ┌───────────────────────────────────────────────────────────────────────┐
 │ L7  MODES / PRESETS   slide · infographic · ui-design · explainer · …   │  (§9 — apps over the core)
 ├───────────────────────────────────────────────────────────────────────┤
 │ L6  EXPORT            self-contained HTML/JS · PDF · PNG/SVG · code · embed │
 ├───────────────────────────────────────────────────────────────────────┤
 │ L5  BEHAVIOR (opt-in) DATA (bind/repeat) · INTERACT (events/state) · TIME (steps/anim) │
 ├───────────────────────────────────────────────────────────────────────┤
 │ L4  COMPONENTS + TOKENS   card/button/chart/icon/… · theme (color/space/type scales)   │
 ├───────────────────────────────────────────────────────────────────────┤
 │ L3  LAYOUT            free-form (x/y/w/h) + auto-layout containers (stack/grid) + snap   │
 ├───────────────────────────────────────────────────────────────────────┤
 │ L2  OP API  ★core★    insert/move/resize/style/group/bind/… — addressable, idempotent, undoable │
 ├───────────────────────────────────────────────────────────────────────┤
 │ L1  SCENE IR ★core★   serializable tree of typed elements + stable IDs + props (§5)     │
 ├───────────────────────────────────────────────────────────────────────┤
 │ L0  RENDER SUBSTRATE  WKWebView; deterministic Scene→HTML/CSS/JS lowering (§6)          │
 └───────────────────────────────────────────────────────────────────────┘
```

**Why each layer earns its place (the friction it removes):**
- **L1 Scene IR** — stable, structured, inspectable model. Removes: fragile selectors, "parse
  the HTML to know what's there," whole-file rewrites.
- **L2 Op API** — the agent *mutates* by ID with small ops. Removes: emit-and-pray; enables
  incremental edits, undo, and "change THAT element."
- **L3 Layout** — **the biggest friction.** Auto-layout containers (stack/row/grid with
  gap/padding/align) let the agent express *intent* ("a row of 3 cards, evenly spaced") without
  computing pixels — the thing agents get wrong. Free-form x/y stays for design freedom;
  snapping/alignment guides + distribute ops assist. **Recommendation: hybrid** (see §5).
- **L4 Components + tokens** — insert "a bar chart / a button / a callout," not raw divs+SVG;
  style by token ("primary", "space-md"), not hex/px. Removes: reinventing UI primitives;
  inconsistent, un-themeable output. This is *infrastructure disguised as a feature* — invest early.
- **L5 Behavior** — opt-in per mode: `DATA` (bind element props to a data model + repeaters),
  `INTERACT` (events → state → conditional visibility/navigation), `TIME` (ordered steps +
  keyframes + transitions). Slides/explainers need `TIME`; dashboards need `DATA`; prototypes
  need `INTERACT`.
- **L6 Export** — the model is the source of truth; export *targets* are consumers:
  self-contained HTML/JS (share/embed), PDF/PNG (infographics/slides/print), production code
  (UI design). **`EXPORT:embed` is a force-multiplier** — one "self-contained bundle + resize
  protocol" makes *every* artifact distributable (research shortlist's #1 leverage item).
- **L7 Modes/presets** — a mode = *spatial model + element palette + enabled behavior layers +
  export targets + starter templates*. Same core underneath.

---

## 5. The Scene IR (L1) — recommended shape

> ⚠️ **Storage shape superseded by §0.5-R1:** the document is stored as a **flat record map**
> (`id → node` + `parentId` + fractional sibling index); the tree below is the *derived/logical*
> view. Field content (type/style/props/bind/on/steps) still applies.

A **tree** of elements (not a flat array — we need containers/auto-layout/grouping), each:

```jsonc
{
  "id": "el_7f3a",              // stable, opaque, survives edits — the agent's handle + data-cvs-id in the DOM
  "type": "text|image|shape|container|component|chart|embed|slide|…",
  "name": "Hero title",        // human/agent-facing label (addressing by name is a convenience over id)
  "layout": {                  // see the hybrid model below
    "mode": "free|stack|row|grid",
    "frame": { "x": 40, "y": 24, "w": 320, "h": 120 },   // free-form: absolute within parent
    "flow":  { "gap": "space-md", "padding": "space-lg", "align": "start|center|end|stretch",
               "justify": "start|center|between|…", "wrap": false }  // auto-layout containers
  },
  "style": { /* token-referencing props: fill:"color.primary", radius:"radius.md", … + raw overrides */ },
  "props": { /* type-specific: text→{content, inlineRuns}; chart→{kind, dataRef, encoding}; image→{src, fit} */ },
  "bind":  { /* optional DATA: prop → data path / expression / repeater over a collection */ },
  "on":    { /* optional INTERACT: event → action (navigate/setState/toggle/…) */ },
  "steps": { /* optional TIME: appear/emphasize/transition keyed to a step index */ },
  "children": [ /* nested elements */ ]
}
```

Document = `{ schemaVersion, theme (token overrides), mode/preset, data?, pages/frames:[…], … }`.

**Design decisions baked in:**
- **Stable opaque IDs** (`el_<rand>`), assigned on insert, never reused; the addressing
  foundation (ties into the existing element-ref / AX-id work). The renderer stamps `data-cvs-id`
  on the DOM node → bidirectional linkage (click a node → know the element; edit an element → find the node).
- **Tokens over raw values** — `style` references theme tokens (`color.primary`, `space.md`,
  `type.h1`, `radius.md`, `shadow.1`); the theme resolves them to CSS. Raw values allowed as an
  escape hatch. → consistency + one-line re-theming + agent doesn't guess hex/px.
- **Type-specific `props` validated by a per-type schema** (à la tldraw `ShapeUtil`): each element
  type declares its prop schema, default, bounds, and lowering. Adding a type = adding one util.
- **Additive-optional everywhere** (the app's persistence convention): new fields default-safe so
  older documents load + downgrade cleanly.
- **CRDT-ready but not CRDT (v1):** stable IDs + tree + typed ops make a later Yjs/CRDT swap
  feasible without a rewrite; v1 is single-writer with an undo stack.

### Layout model — the deepest fork (⚠️ superseded by §0: **auto-layout default, `absolute` opt-in** — CANVAS-0001 D2)
The research names the spatial model as *the* early architectural fork. Three modes over one IR:
- **free-form** (absolute x/y/w/h within parent) — design freedom; the default for slides/
  infographics/whiteboard. Agent-assisted by **snapping + alignment guides + align/distribute ops**
  so the agent says "align these left / distribute evenly" instead of computing pixels.
- **auto-layout containers** (`stack`/`row`/`grid` with gap/padding/align/justify — flexbox/grid
  lowered) — for UIs and any responsive/structured content. **This is the key agent-friendliness
  win**: declarative intent, engine computes pixels.
- **reflow-flow** (paginated text flow) — **the beast most canvas tools punt on** (Figma/Canva/
  Miro can't paginate → they're weak at reports/résumés/email). *Decision for the owner (§12):*
  treat `FLOW` as a first-class mode from the start, or defer it (fine if docs/reports aren't priority).

---

## 6. Lowering: Scene IR → HTML/CSS/JS (L0), + the round-trip stance

A **deterministic, phased renderer** (the engraving pipeline):
`Scene IR → resolve theme/tokens → resolve layout (auto-layout→flex/grid, free→absolute) →
per-type lowering (each ShapeUtil emits its HTML fragment + scoped CSS) → assemble document
(+ inject data/interact/time runtime only for enabled behavior layers) → HTML/CSS/JS`.

- **Rendered live in a `WKWebView`** (reuse the existing WebView infra + the warm-cache/DOM-patch
  perf levers — TSK-838/1183 — so edits patch the DOM, not full-reload).
- **WYSIWYG editing** = the human's drag/resize/select on the WebView emits a **scene op** (via
  the `data-cvs-id` back-reference), which mutates the IR, which re-lowers/patches. The IR stays
  the single source of truth (no direct DOM editing).
- **Round-trip (import raw HTML → IR): OUT OF SCOPE v1.** Lowering is one-way (IR→HTML). Full
  HTML→IR lifting is the "two-way derivation is sometimes impossible" problem MEI explicitly
  concedes. A **"raw HTML/embed" element** covers the escape-hatch cases (paste a snippet as an
  opaque node). Optional later: a *lossy* importer that maps common structures to components.

---

## 7. The agent Operation API (L2) — the primary interface

The agent authors by **ops**, not by emitting HTML. Ops are **addressable** (by stable id/name),
**idempotent** where sensible, **composable**, and **undoable** (each op is an invertible
transaction, ProseMirror-style — undo/redo + a later CRDT fall out). Illustrative verbs:

```
scene.insert(type|component, { into: <id|"root">, at: <index|frame>, props, style, layout })  → new id
scene.update(id, { props?, style?, layout?, bind?, on?, steps? })     // partial, merge semantics
scene.move(id, { into?, index?, frame? })       scene.remove(id)      scene.duplicate(id)
scene.group([ids], as: stack|row|grid)           scene.reorder(id, index)
scene.align([ids], left|center|…)   scene.distribute([ids], horizontal|vertical)
scene.setText(id, content|inlineRuns)   scene.setTheme(tokenOverrides)   scene.bind(id, prop, dataPath)
scene.addStep(...)  scene.setInteraction(id, event, action)            // behavior layers
scene.query(selector|role|text) → [ids]          scene.get(id) → element        // read-back / inspection
```

**Integration with existing agent surfaces:** these map onto the app's **verb bus / MCP tools /
stable-element addressing** (the same infrastructure behind AX ids, Copy-Reference, script verbs).
`scene.query`/`scene.get` give the agent a *structured read* of the canvas (no HTML parsing) —
the feedback loop that raw-HTML authoring lacks. This is also the natural **AX/UAT** surface:
ops are host-testable (op → IR change) and the IR→lowering is host-testable; the on-screen render
is validated via the WebView lane (DOM query on `data-cvs-id`) — mostly *not* T5-gated.

---

## 8. Fit with the existing app
- **A new document/tab type** (`.canvas` doc + a `ViewMode`/preview lens), rendered in a WebView,
  persisted in the session/tab like other documents (the Scene IR is Codable → the session snapshot,
  reusing the persistence conventions). Opens from New ▸ Canvas / the walkthrough authoring path.
- **Reuses:** WebView infra (MarkdownRenderedView/CM6), the DOM-patch perf lever, the verb/MCP/
  element-ref agent surfaces, design already present (RichText IR for text elements, the
  Walkthrough system for the Explainer mode, chart/table building blocks).
- **Testability ladder:** op-layer + IR + lowering are **host-testable** (pure); the rendered DOM
  is **webview-lane** validatable (query `data-cvs-id`, assert structure) — agent-runnable, not
  T5. Pixel-exact/occlusion cases (rare) are the only T5 tier.

---

## 9. Use-cases on the foundation (the "explore widely" ask)

A **mode/preset = spatial model + element palette + enabled behavior layers + export targets +
starters.** From the use-case research (~60 across 11 families); ranked shortlist by
value × feasibility-on-the-shared-core:

| Rank | Use-case | Preset (mode + layers) | Notes |
|---|---|---|---|
| 1 | **Slide decks** ★ | free/fixed-page + `TIME` + export HTML/PDF | Near-perfect fit; presenter view + speaker notes + per-slide build steps. |
| 2 | **Explainers / walkthroughs** ★ | fixed-page + `TIME` + `INTERACT` | *Strategic dogfood* — reuses the deck engine + the existing Walkthrough system (canvas + narration + step-scoped spotlight). |
| 3 | **Infographics** ★ | free-form + `DATA` + export IMG/PDF | Data→one-shot layout is exactly what agents are good at; annotation callouts. |
| 4 | **Diagrams** (flow/org/mind/timeline/ER) | free/auto + `DATA` + auto-layout | **Agents emit graphs natively** → engine supplies geometry (sidesteps "nudged a box 3px"). One layer serves ~6 diagram types. Beyond Mermaid/Dot (TSK-713). |
| 5 | **Social / marketing assets** | fixed-page + `COMP` + export IMG | Size presets + brand-kit apply; low risk, broad appeal. |
| 6 | **Scrollytelling** | fixed-page + `TIME`(scroll-triggered) | ~free once `TIME` steps exist (rebind trigger to scroll). |
| 7 | **Explorables / calculators / widgets** | + `DATA` + `INTERACT` + `TIME` | The layer that forces the reactive core to be *real* → de-risks dashboards/configurators/courseware. Agent-authored interactives are genuinely novel. |
| 8 | **UI design / prototyping** ★ | auto-layout + `COMP` + `INTERACT` + **export CODE** | Ship in **tiers**: wireframe → clickable prototype → **code export** (the hard mile). "Claude-Design-like: insert elements, export." |
| 9 | **Dashboards / reports** | auto/flow + `DATA`(live) + (`FLOW` for reports) | Reports need real pagination (`FLOW`). |
| 10 | **Forms / surveys / micro-apps** | auto + `INTERACT` + `DATA` + submission sink | Validation + conditional logic. |

**Long tail (same core, different preset):** wireframes · design systems/component libraries ·
landing pages · **email templates** (table-layout export) · storyboards · comics · in-app product
tours (anchor to host DOM) · interactive fiction · chart composer · maps/geo annotation · Kanban/
retro boards · journey maps · seating/floor plans · posters/flyers · brochures/page-layout ·
résumés · certificates (mail-merge + QR) · invoices · menus/labels · courseware (SCORM-ish) ·
quizzes · annotated figures · moodboards · whiteboards · mockups · calculators · digital signage ·
QR microsites · screenshot annotation · ML data-labeling · game/level/board layout · timelines/
roadmaps/Gantt · mind maps · org charts.

**Highest-leverage, non-obvious picks (build early):**
- **`EXPORT:embed`** — one self-contained-bundle + resize protocol makes *every* artifact
  distributable. Highest leverage-per-effort.
- **`DATA` + auto-layout diagrams** — plays to model strengths (emit a graph, engine lays it out).
- **The component + token layer (`COMP`)** — infrastructure that compounds across every design use-case.
- **Explorables** — the one use-case that exercises `DATA`+`INTERACT`+`TIME` together → forces a real reactive core.

---

## 10. Hard boundaries — use-cases that would DISTORT the foundation (hold this line)
Each shares a signature: pinned to an extreme that needs a *different substrate / precision model /
temporal model* than DOM/CSS/vector-screen. **Support the *authoring/layout*, never the specialized *runtime*.**

| Distorter | The warp | Safe posture |
|---|---|---|
| CAD / floor plans / technical drawing | constraint-solver + real-world units + dimension lines | diagram-grade precision only; no solver |
| Video / motion-graphics *editor*, DAW | multi-track NLE + media decode/scrubbing/audio | motion *templates* (CSS-animation-grade), not an editor |
| Photo compositing / raster editing | pixel buffers + masks + pixel-level blend (canvas/WebGL) | image *placement* + CSS filters; no pixel editing |
| 3D / spatial / AR | 3D scene graph + camera + lighting | out of scope |
| Full micro-apps w/ backend | routing/auth/DB/server = a platform | emit the *front end*; stop at the data-sink boundary |
| Commercial print / prepress | CMYK/bleed/imposition/spot color | "office-grade" RGB PDF only |
| Games needing a loop/physics | 60fps loop + collision + input = a runtime | level/board *layout* export, not the engine |
| Very-large diagrams (10³–10⁴ nodes) | DOM rendering collapses | a real **rendering-backend fork** to plan for (DOM → canvas/WebGL) — not a distortion but a scaling decision |

---

## 11. Phasing (proposal — sliced so each phase ships something usable + host/webview-validatable)
- **Phase 0 — spike/design (this doc).** Owner review of the architecture + the §12 decisions.
- **Phase 1 — Scene core + lowering + op API (host-provable).** Scene IR + per-type ShapeUtils +
  deterministic IR→HTML lowering + the op API + `data-cvs-id` linkage + persistence. Host tests
  for ops + lowering. *No editor UI yet* — but an agent can already build a static artifact + export HTML.
- **Phase 2 — WebView canvas + WYSIWYG.** Render in the WebView; select/drag/resize → ops;
  free-form layout + snapping/align; tokens/theme. First human-facing editor. Webview-lane validation.
- **Phase 3 — Components + auto-layout + first mode.** Component/token library + stack/row/grid.
  Ship **one** end-to-end mode — recommend **Slides** (cleanest fit) or **Explainer** (dogfood into Walkthroughs).
- **Phase 4 — Behavior layers.** `DATA` (bind/repeat) + `INTERACT` (events/state) + `TIME` (steps/anim)
  → unlocks infographics, dashboards, explorables, scrollytelling.
- **Phase 5 — Export fan-out.** `embed` (force-multiplier) → PDF/PNG → **code export** (UI Design tier).
- Diagrams (`DATA`+auto-layout) can slot in around Phase 3–4 as a high-value early win.

---

## 12. Decisions needed from the owner (⚠️ superseded — the merged Q1–Q10 list in §0 is authoritative)
1. **Scope of v1 / which mode first.** Recommend Phase-1 core + **Slides** *or* **Explainer** as the
   first end-to-end mode. Which? (Explainer dogfoods into the existing Walkthrough system.)
2. **Layout model.** Confirm the **hybrid** (free-form default + auto-layout containers). And: is
   **reflow-flow / pagination** (`FLOW`) a first-class mode from the start (needed for docs/reports/
   résumés/email — the thing every canvas tool punts on), or deferred?
3. **Code export (UI Design).** Target(s)? — self-contained HTML first (easy), then which framework
   (React? plain HTML/CSS? SwiftUI?) for the "export to production code" mile. Tiered delivery OK?
4. **Dependencies.** The core (Scene IR + lowering + op API) is **vanilla Swift + WebView, zero new
   deps**. But some layers *could* pull libraries — charts (a JS charting lib vs. hand-rolled SVG),
   diagram auto-layout (e.g. an elk/dagre-style layout — JS dep), animation. **Per your rule, every
   such dep needs explicit approval.** Recommend: build the core dep-free; bring dep proposals per-layer
   with alternatives when we reach them. Approve that approach?
5. **Rendering backend.** DOM/CSS for v1 (fits everything except very-large diagrams). Accept the
   later canvas/WebGL fork *only if/when* a 10³⁺-node use-case is prioritized?
6. **Multiplayer.** Confirm single-writer + undo for v1 (keep the model CRDT-able, don't build it yet)?

---

## Appendix — research provenance
- **Use-case catalog** (`ab7523cf…` subagent): 11 families / ~60 use-cases + tension axes + the
  distortion analysis (§10) + the one-foundation verdict (§7 layering). Folded into §9/§10.
- **Semantic→visual lowering pipelines** (`abdaeb8ba…`, the serendipitous music-engraving agent):
  LilyPond / MEI / MusicXML / SMuFL / Verovio → the 7 lowering patterns in §3. Directly on-point.
- **Prior-art architectures** (`adcd9860…` subagent): *still running* — its per-system notes +
  citations will be appended to `docs/research/canvas-2026-07-01/` and this table (§2) updated.
- **Abstraction-techniques agent** (`a7301a43…`): failed on a Claude-Fable-5 model outage; the
  dimension is covered here from knowledge + the lowering findings. Re-runnable if the owner wants the raw survey.
