# Canvas — design spike (TSK-1342)

> **Status: DESIGN — awaiting owner review. Nothing implemented.**
> Owner ask (2026-07-01): a WYSIWYG editor for **agents** (and humans) to build UIs,
> infographics, explainers, and presentations. Underlying tech is HTML/CSS/JS, but with
> **abstraction layers to reduce friction** so an agent *inserts/edits structured elements*
> instead of writing top-down HTML files. It is the **foundation layer** for later features
> (UI Design à la Claude Design, Presentations, Explainers-in-Walkthroughs, and more).
> This doc: the problem space, a recommended architecture (the abstraction stack), and a
> broad use-case exploration. **Decisions the owner must make are in §12.**

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

### Layout model — the deepest fork (recommendation: **hybrid, free-form default + auto-layout containers**)
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

## 12. Decisions needed from the owner (blocking)
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
