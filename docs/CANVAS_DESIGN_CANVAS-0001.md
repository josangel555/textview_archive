<!-- Provenance: independent Canvas design pass (second claude-mdv session), filed as
     CANVAS-0001 in markdown because the tasked board was down 2026-07-01. Preserved
     VERBATIM (only this header added; one known path nit: HTMLDocumentPolicy.swift is in
     Sources/ViewerCore/, not ViewerUI/). Reconciled with docs/CANVAS_DESIGN.md (TSK-1342).
     ⛔ SUPERSEDED (2026-07-01) by the v2 doc set at docs/canvas/ — kept for history. -->

# Canvas — agent-first WYSIWYG surface (spike + detailed design)

**Ticket:** CANVAS-0001 *(markdown-filed — the `tasked` board was down on 2026-07-01;
migrate to a `TSK-###` epic + child tickets when the board is back up)*
**Status:** `[BLOCKED: owner-review]` — design complete, **no implementation started** (per owner directive).
**Date:** 2026-07-01
**Author:** claude-mdv (spike + design pass, owner-requested)
**Kin:** epic 688 walkthrough-presentation · OwnerWishlist P6 "Walkthrough as a presentation
[Like slides, Docs, Source code, Terminal]" · `docs/CM6_INTEGRATION_DESIGN_2026-05-23.md` ·
`docs/WALKTHROUGH_DESIGN_v2.md` · `docs/PLUGINS_DESIGN_v2.md`

---

## 0. TL;DR — the recommendation

Canvas is a new **document type** (`.canvas`, JSON scene graph) plus a new **render surface**
(vendored JS runtime in WKWebView, CM6-style) plus a new **agent write API** (ops over MCP).
The source of truth is **never HTML** — it is a typed, stable-ID **scene graph**; HTML/CSS/JS
is only the render target. Agents stop writing top-down HTML files and instead:

1. **address** nodes by stable ID,
2. **mutate** via small declarative ops (`insert/update/move/delete`, batched),
3. **compose** from layout containers (stack/grid/absolute), design tokens, and a component library
   instead of raw CSS,
4. **observe** what they built through a first-class feedback loop (geometry queries, snapshots,
   overflow/contrast lint) — closing the "agent can't see the pixels" gap,
5. share the same document with the **human**, who edits WYSIWYG (drag/resize/inline text);
   both sides emit the same ops, so agent⇄human co-editing falls out of the model.

Domain layers (UI Design, Presentations, Explainers, Infographics, …) are **schemas + component
kits + verbs on top of the same core** — the epic's value is that the foundation is built once.

Five key design decisions (each argued in §12, listed here for the review):
**D1** scene-graph-as-source-of-truth (not HTML) · **D2** auto-layout by default, absolute
positioning opt-in · **D3** page/artboard-based first, infinite canvas later · **D4** hand-rolled
vanilla-JS runtime vendored like CM6 (no framework dep) · **D5** editor chrome (inspector/layers)
native SwiftUI, selection/handles in-webview.

---

## 1. Problem statement

> Next giga epic: **Canvas** — a WYSIWYG editor **for agents** to build user interfaces,
> infographics, explainers, presentations, etc. Underlying tech is HTML/CSS/JS, but we must
> build abstraction layers to reduce friction. It is the foundation for upcoming features:
> **UI Design** (agent inserts elements into a canvas instead of writing top-down HTML files),
> **Presentation** (slides with animations), **Explainers** (as part of walkthroughs), and more.

Two audiences, one document:

- **The agent** is the primary *author*. It has no eyes by default, burns tokens on every byte it
  writes, and is bad at pixel-perfect layout without feedback. It needs: small addressable
  mutations, strong layout defaults, a design system to compose from, and a measurement/feedback
  channel.
- **The human** is the *director and finisher*. They need direct manipulation (WYSIWYG), an
  inspector, undo, and the ability to hand the document back to the agent without losing either
  side's edits.

### 1.1 Why raw top-down HTML fails agents (the frictions the abstractions must kill)

| # | Friction | Consequence today |
|---|----------|-------------------|
| F1 | **No stable addressing.** Editing element 47 of a 900-line HTML file means regenerating the file or brittle string surgery. | Full-file rewrites per iteration; token cost scales with document size, not edit size. |
| F2 | **No incrementality.** A rewrite reloads the page; runtime state (scroll, animation, form input, selection) is lost. | Iteration feels destructive; long feedback cycles. |
| F3 | **Layout micro-management.** Raw CSS demands pixel decisions the agent can't verify; absolute positions rot on content change. | Overlapping/overflowing layouts; endless nudge-and-pray loops. |
| F4 | **No feedback loop.** The agent cannot see what rendered, where boxes landed, or what overflowed. | "Model-green, on-screen broken" — the exact failure class the T6 directive exists for. |
| F5 | **Styling inconsistency.** Hardcoded hex values and ad-hoc fonts per element; no relationship to app themes. | Visually incoherent output; dark-mode breakage. |
| F6 | **Interactivity = hand-written JS.** Every button needs bespoke script; scripts are a security surface. | Either no interactivity or an unauditable JS blob. |
| F7 | **Animation/presentation mechanics are raw CSS/JS.** Keyframes, fragment reveals, transitions all hand-rolled per deck. | Presentations are impractical to author reliably. |
| F8 | **Human edits are unrepresentable.** If the human tweaks the HTML render, the agent's next write clobbers it. | No co-editing; WYSIWYG impossible. |

Each abstraction layer below is justified by the frictions it removes (tagged F1–F8).

### 1.2 Goals / non-goals

**Goals (foundation slice):**
- A durable, versioned, diff-friendly **document format** owned by us.
- An **agent API** where the marginal cost of an edit is proportional to the edit, not the document.
- A **WYSIWYG surface** in the app (new ViewMode) with direct manipulation and undo.
- A **feedback loop** an agent can close autonomously (measure → lint → snapshot).
- **Domain layers** (slides, UI kit, explainer verbs) expressible without core changes.
- Export: standalone HTML (self-contained), PNG/PDF.

**Non-goals (v1):**
- Not a general web IDE; not arbitrary-JS authoring (escape hatch is sandboxed, §13).
- No real-time multi-cursor CRDT collaboration (single writer at a time + op log is enough; §8).
- No network access from canvas documents (same exfil fence as trusted HTML).
- Not a replacement for the markdown renderer or the paint/image editor.

---

## 2. What exists today (foundation inventory)

The scan found six precedents that carry most of the architecture; Canvas is deliberately
"the same shapes, one level up."

| Precedent | Where | What Canvas reuses |
|---|---|---|
| **CM6-in-WKWebView bridge** | `Sources/ViewerCore/CodeMirrorBridge.swift`, `Sources/ViewerUI/CodeMirrorEditorView.swift`, `docs/CM6_INTEGRATION_DESIGN_2026-05-23.md` §13 | The whole hosting pattern: vendored IIFE bundle + `loadFileURL` host page; versioned envelope `{v, type, replyId?}`; single `window.cmDispatch` entry; `WKScriptMessageHandler` inbound; `requestReply`/`replyId` completion bridge for async round-trips. Canvas gets `window.cvDispatch` + `mdvCanvas` handler with the same discipline. |
| **Trusted-HTML security envelope** | `HTMLRenderedView.swift` trusted mode, `HTMLDocumentPolicy.swift` (`envelope(sanitizedBody:trusted:)`) | The CSP posture for a surface that runs our JS but must not exfiltrate: scripts allowed, `connect-src 'none'`, navigation-policy allowlist. |
| **Mermaid vendoring + lazy runtime injection** | `MermaidBundle.swift`, `nextMermaidInjectionState` in `MarkdownRenderedView.swift`, `docs/MERMAID_IMPL.md`, `VENDOR.md` integrity tests | How to ship heavy optional node renderers (mermaid, charts): vendor with integrity tests, inject as `WKUserScript` only when the document needs them, evict otherwise. |
| **Walkthrough v2 engine** | `Sources/ViewerCore/Walkthrough/*` (script = steps → tagged-union action verbs; engine = pure `@MainActor` state machine; store = durable JSON library with path-traversal-safe IDs; loader = validation fence) | The **presentation player** shape (steps, auto-advance, checkpoints, anchors) and the **document store** shape. Canvas presentations generalize this; walkthrough gains canvas verbs (§11 UC-3). |
| **MCP automation surface** | `MCPToolCatalog.swift` (12 tools), `AutomationHost` protocol, `--mcp-stdio` | Where `canvas_*` agent tools land. Note the scan's finding: **no MCP tool writes document content today** — Canvas ops are the first content-write API, so the design must set that precedent carefully (§7, §13). |
| **Warm WebView caches** | `WarmWebViewCache/WarmHTMLWebViewCache/WarmEditorWebViewCache`, `MountedPanesLRU` | Park/re-attach so the canvas surface (and its runtime state) survives tab/session switches — the exact class of bug (TSK-1046) the app just finished fighting; Canvas adopts the cache from day one. |
| Also | `ViewMode` enum (`Sources/ViewerKit/ViewMode.swift`), `SessionSnapshot` additive-Codable house style, `JSONFileStore`, theming CSS custom properties (`markdown.css` `--mdv-*`) + live `setProperty` pushes, `DiagramRegistry` extensibility seam, `ScriptVerbCatalog`, `URLSchemeRouter`, local-history stores | New `canvas` ViewMode + FileCategory; document Codable style; theme propagation; renderer registry; script verbs; `textview://canvas?…`; timeline integration. |

**Green field:** no layout engine exists anywhere (Rust core is parse/edit/highlight reducers —
scan §8), no scene-graph model, no content-write MCP tool, no component/token system. Those are
the net-new pieces.

---

## 3. The abstraction stack (the core of the design)

```
        agents (MCP tools / script verbs)        human (WYSIWYG surface)
                     │                                   │
   L4  DOMAIN LAYERS: UI-Design kit · Presentation model · Explainer verbs ·
       Infographic/chart kit · (plugin-contributed kits later)
                     │
   L3  OPERATIONS API: insert/update/move/delete/batch · selectors ·
       op log = undo/redo = history · change events out
                     │
   L2  DOCUMENT MODEL: Canvas Scene Graph — typed nodes, stable IDs,
       layout containers, design tokens, components; JSON, schema-versioned
                     │
   L1  RUNTIME (vendored JS, CM6-style): scene graph → DOM projection;
       incremental patching; selection/handles/direct-manipulation;
       geometry + hit-test queries; declarative behaviors + animation player
                     │
   L0  HOST: WKWebView + trusted-CSP envelope + versioned bridge +
       warm cache + theming pipe (Swift side owns files, persistence, undo stack)
```

The layer boundaries are the testing boundaries too: L2/L3 are pure Codable/reducer logic
(host-testable, Swift-Testing-friendly), L1 is JS (headless-testable via the in-process WebView
suite pattern), L0 render truth is VM/T5, per house rules (§14).

### L0 — Host (Swift)

- `CanvasSurfaceView: NSViewRepresentable<WKWebView>` mirroring `CodeMirrorEditorView`:
  bundle-hosted `canvas.html` + `canvas.js` via `loadFileURL`; shared `WKProcessPool`;
  `WarmCanvasWebViewCache` from day one (F2: iteration never reloads).
- Security: trusted-mode CSP (our runtime JS runs; `connect-src 'none'`; no external
  subresources — images/fonts resolve through a local asset scheme, §13).
- Bridge: `CanvasBridge.swift` in ViewerCore — versioned envelope (`CVProtocol.currentVersion = 1`),
  Codable inbound/outbound enums, pure and host-testable exactly like `CodeMirrorBridge`.
- Swift owns: file I/O, autosave, the op log/undo stack, local-history/timeline integration,
  session snapshot (`canvasSelection`, `canvasViewport` fields, additive-optional).

### L1 — Runtime (vendored JS)

Built like CM6: `scripts/canvas-build/` (npm at build time only, IIFE output vendored into
`Sources/ViewerUI/Resources/canvas/`, integrity-tested per `VENDOR.md` conventions). Runtime
responsibilities:

- **Projection:** scene graph → DOM. Each node renders to an element carrying `data-cv-id`;
  ops arrive as patches and are applied **incrementally** (F1, F2) — no innerHTML rewrites.
- **Direct manipulation:** selection model, drag/resize handles, inline text editing
  (`contenteditable` scoped to text nodes), snap/guides, marquee select. Emits *ops*, not DOM
  mutations — the DOM is never the truth (F8).
- **Measurement services:** `getGeometry(selector)` (border boxes, overflow flags),
  `hitTest(x,y)`, `lint()` (overflow, collision, contrast-ratio, min-tap-target) — the agent's
  eyes (F4).
- **Behavior player:** declarative behaviors (§6.4) and the animation/fragment timeline (§11 UC-2)
  — agents never write JS for the common 95% (F6, F7).
- **Node renderer registry:** core nodes built in; heavy renderers (mermaid, chart) lazy-injected
  Mermaid-style. Registry keyed by node `type` — the seam plugins can extend later (F5 — kits, and
  `PLUGINS_DESIGN_v2`'s reserved "renderer contribution" shape).

### L2 — Document model (the Canvas Scene Graph)

See §5 for the schema sketch. Properties that matter architecturally:

- **Stable IDs** on every node (short, ULID-ish, generated Swift-side) — addressing (F1).
- **Typed node union** with a `type` discriminator, additive-optional fields, and
  `textview.canvas/v1` schema versioning + `UnsupportedSchemaError` behavior — exactly the
  walkthrough/session house style. Unknown node types round-trip opaquely (forward compat).
- **Layout is a property of containers, not of children** (F3): `frame` nodes carry a `layout`
  (stack/grid/absolute/…); children carry only intent (`grow`, `align`, spans). Rendering maps
  onto flexbox/grid — we get a battle-tested layout engine for free and never write a constraint
  solver (this is *the* reason HTML/CSS is the right substrate).
- **Design tokens + components** are part of the document (with app-theme inheritance), §6.2–6.3 (F5).
- **Canonical JSON** (sorted keys, pretty) → clean git diffs; a `.canvas` file is reviewable in
  the app's own diff viewer.

### L3 — Operations API

The only way *anything* (agent, human gesture, domain layer) mutates a document:

```jsonc
{ "op": "insert",  "parent": "nd_root", "index": 2, "node": { … } }
{ "op": "update",  "id": "nd_a1b2", "set": { "text": "Q3 Revenue", "style.font": "token:font.h1" } }
{ "op": "move",    "id": "nd_a1b2", "parent": "nd_grid1", "index": 0 }
{ "op": "delete",  "id": "nd_a1b2" }
{ "op": "batch",   "ops": [ … ], "label": "Insert KPI row" }   // one undo step
```

- **Selectors** for reads and bulk ops: by id, by type, by name-path (`"slide[3] text.title"`),
  by tag. Reads never require the agent to hold the whole doc in context (F1): `canvas_query`
  returns projected subtrees (ids + types + geometry + text, depth-limited).
- **Op log** is the single history: undo/redo (human ⌘Z and agent `canvas_undo` share it),
  local-history checkpoints, and the change-event stream back to agents (F8).
- Validation fence at the boundary (walkthrough-loader style): schema check, ID existence,
  cycle prevention, token references resolvable, size caps — malformed ops are *rejected as data*,
  never partially applied.

### L4 — Domain layers

Each is "a schema + a component kit + a few verbs" over L2/L3 — detailed in §11. None require
core changes; that's the acceptance test for the foundation (if a use case needs a new core
primitive, the core is wrong, and we find out at design time — several did shape the core:
fragments → node `revealIndex`, charts → `data` blocks, UI kit → components).

---

## 4. How an agent authors (the end-to-end loop)

```
canvas_create {template: "deck-16x9"}                    → doc + root ids
canvas_apply  {ops: [ …insert slide, title, kpi grid… ]} → applied, rev 7
canvas_lint   {}                                         → [{overflow: "nd_kpi3", by: "18px"}]
canvas_apply  {ops: [ {op:"update", id:"nd_kpi3", set:{"style.font":"token:font.stat-sm"}} ]}
canvas_snapshot {scope: "slide:2", maxPx: 800}           → PNG (agent Reads it)
canvas_query  {selector: "slide:2 *", fields: ["geometry"]}  → boxes as JSON
```

Contract properties:
- **Write cost ∝ edit size** (ops), **read cost ∝ question size** (queries) — never "resend the file".
- **Feedback is programmatic first** (geometry/lint = cheap JSON), **visual second**
  (snapshot = expensive, for final confirmation). This gives agents a T6-compatible
  "confirm with your own eyes" primitive *inside* the app.
- Every apply returns the new **revision**; ops carry a `baseRev` for conflict detection (§8).

---

## 5. Document model sketch (`textview.canvas/v1`)

```jsonc
{
  "schema": "textview.canvas/v1",
  "id": "cv_9f3k2",
  "title": "Q3 Review Deck",
  "kind": "deck",                       // "page" | "deck" | "board" (see D3)
  "tokens": { /* §6.2 — design tokens, inherits app theme */ },
  "components": { /* §6.3 — reusable subtrees with slots */ },
  "data": {                              // named data blocks for data-bound nodes (charts, tables)
    "revenue": { "columns": ["q","usd"], "rows": [["Q1", 1.2], ["Q2", 1.9]] }
  },
  "pages": [
    {
      "id": "pg_1", "name": "Title", "size": {"w": 1280, "h": 720},
      "notes": "Speaker notes live here",
      "root": {
        "id": "nd_root", "type": "frame",
        "layout": {"mode": "stack", "dir": "column", "gap": 24, "pad": 48,
                    "align": "center", "justify": "center"},
        "style": {"fill": "token:color.bg"},
        "children": [
          { "id": "nd_t1", "type": "text", "text": "Q3 Review",
            "style": {"font": "token:font.display", "color": "token:color.fg"} },
          { "id": "nd_kpis", "type": "frame",
            "layout": {"mode": "grid", "cols": 3, "gap": 16},
            "children": [
              { "id": "nd_k1", "type": "component", "ref": "kpi-tile",
                "props": {"label": "Revenue", "value": "$4.2M", "delta": "+12%"} }
            ] },
          { "id": "nd_c1", "type": "chart",
            "chart": {"mark": "bar", "dataRef": "revenue", "x": "q", "y": "usd"},
            "reveal": 2 }                // presentation fragment index (§11 UC-2)
        ]
      }
    }
  ],
  "behaviors": [ /* §6.4 — declarative interactivity */ ],
  "meta": {"createdAt": "2026-07-01T10:00:00Z", "generator": "claude-mdv"}
}
```

### 5.1 Core node types (v1)

| Type | Purpose | Notes |
|---|---|---|
| `frame` | Container + layout | `layout.mode`: `stack` (flex), `grid`, `absolute` (opt-in, D2), `wrap`. Fill/stroke/radius/shadow via style. |
| `text` | Rich-ish text | Inline spans (bold/italic/code/link/color); block role (`h1…body/caption`) maps to tokens. |
| `image` | Local/bundled/data-URI image | Fit modes; assets via local asset store (§13). |
| `shape` | rect/ellipse/line/arrow/polygon | SVG-projected; connectors can anchor to node IDs (diagram use case). |
| `table` | Small data tables | Data-bound via `dataRef` or inline rows. |
| `chart` | Data-bound viz | Declarative mark spec (bar/line/area/pie/scatter …); hand-rolled SVG marks first (D4), no chart-lib dep. |
| `code` | Syntax-highlighted block | Reuses the existing highlight pipeline output (server-side spans, like rendered markdown). |
| `diagram` | Mermaid/dot | Reuses `DiagramRegistry` + lazy mermaid runtime. |
| `component` | Instance of a defined component | `ref` + `props` fill slots (§6.3). |
| `embed` | **Escape hatch**: raw HTML/CSS(/JS later) | Sandboxed iframe, tighter CSP; the pressure valve so the typed model never blocks anyone (§13). |

### 5.2 Styling model

`style` is a **closed set of properties** (fill, stroke, radius, shadow, font, color, opacity,
transforms…), each accepting a literal or a `token:` reference. It deliberately is *not*
pass-through CSS: closed props are lintable, theme-mappable, diff-stable, and portable to
export targets. (Escape hatch for the rest: `embed`.)

---

## 6. The friction-killer subsystems

### 6.1 Layout (F3)
`stack/grid/wrap` map to flex/grid with tokens for gap/pad. Children express intent
(`grow`, `shrink`, `align`, `span`), not geometry. `absolute` exists (badges, freeform boards,
annotation pins) but is opt-in per-frame, so an agent must *choose* to leave auto-layout.
Geometry queries return **resolved** boxes, so the agent reasons about outcomes, not inputs.

### 6.2 Design tokens (F5)
Token tree: `color.*`, `font.*`, `space.*`, `radius.*`, `shadow.*`, `chart.palette.*`.
Documents get a default token set **derived from the active app theme** (the existing
`ThemeDefinition` → CSS-custom-property pipe): `--cv-*` custom properties pushed live, exactly
like `--mdv-content-scale`. Dark/light correctness falls out; a deck restyles by swapping tokens.
Agents are steered to tokens by the API (`set: {"style.color": "token:color.accent"}` is the
documented path; literals allowed but flagged by lint).

### 6.3 Components (F1, F5)
A component = named subtree + declared `props` (slot values) — document-local in v1, importable
kits later (plugin contribution, `PLUGINS_DESIGN_v2` reserved shape). `defineComponent` +
`update` of a definition re-projects all instances. This is the substrate for every domain kit
(KPI tile, hero, button, slide layouts) and the main token-economy win: an agent inserts
`{ref: "kpi-tile", props: {…}}`, not 40 lines of markup.

### 6.4 Behaviors (F6)
Declarative triggers → actions, interpreted by the runtime — no authored JS:

```jsonc
{ "on": {"click": "nd_btn_next"}, "do": [{"action": "gotoPage", "page": "pg_2"}] }
{ "on": {"click": "nd_tab_b"},   "do": [{"action": "setState", "key": "tab", "value": "b"}] }
{ "on": {"hover": "nd_bar_q3"},  "do": [{"action": "showTooltip", "text": "$2.1M"}] }
```

v1 verb set: `gotoPage`, `setState` (+ conditional `visibleWhen` on nodes), `showTooltip`,
`playFragment`, `openUrl` (policy-gated), `postMessage` (to Swift — e.g. a walkthrough checkpoint).
Enough for tabs/toggles/prototype navigation/quizzes; arbitrary logic stays in sandboxed `embed`.

### 6.5 Feedback loop (F4)
Three tiers, cheapest first: **query** (geometry/text/tree as JSON) → **lint** (overflow,
collision, contrast, tap-target, orphan-token) → **snapshot** (PNG of surface/page/node via the
runtime, not `screencapture` — works headless, no Screen-Recording TCC). Lint runs on every
apply and returns warnings inline with the apply result, so the agent sees problems *without
asking*.

---

## 7. Agent surface (MCP tools — the L3 projection)

Added to `MCPToolCatalog` behind the existing `AutomationHost` pattern (all host-testable with a
fake host):

| Tool | Does |
|---|---|
| `canvas_create` | New document (blank or from template/kit), opens as a tab; returns doc id + root ids. |
| `canvas_open` / `canvas_list` | Open/list `.canvas` docs (path-jailed like `open_path`). |
| `canvas_apply` | Apply an op batch `{baseRev, ops[]}` → `{rev, lint[]}`. **The** write tool. |
| `canvas_query` | Selector → projected subtree/geometry/text JSON (depth/size-capped). |
| `canvas_lint` | Full-document lint report. |
| `canvas_snapshot` | PNG of page/node/surface (size-capped). |
| `canvas_define_component` / `canvas_set_tokens` | Design-system management (sugar over ops). |
| `canvas_export` | Standalone HTML / PNG / PDF to a path (jailed). |
| `canvas_events` | Poll/subscribe change feed since rev N (human-edit awareness, §8). |

Same catalog exposed as **script verbs** (`ScriptVerbCatalog` group `canvas`) for `--script`
tests/UAT, and `textview://canvas?path=…` for open-by-URL. **Precedent note:** these are the
app's first *content-writing* automation tools (scan §6 confirmed none exist). Policy: writes
only to `.canvas` documents, never arbitrary files; the op fence (§3-L3) is the validation
boundary; a visible "agent editing" indicator in the tab strip (owner directive on transparency).

---

## 8. Human ⇄ agent co-editing (F8)

- One writer applies at a time (MainActor apply path); no CRDT in v1 (non-goal).
- Every apply bumps `rev`; agent ops carry `baseRev`. Stale `baseRev` → structured conflict
  error naming the intervening ops (agent re-queries the touched nodes and retries — the same
  read-modify-write discipline as LSP edits).
- Human WYSIWYG gestures emit ops through the identical path → they appear in `canvas_events`,
  so an agent can *watch* the human ("user moved nd_k1 into nd_grid2") and adapt.
- Shared undo stack: ⌘Z undoes the last batch regardless of author, with author labels in the
  timeline (`"Insert KPI row (agent)"`).
- Locking affordance (v1.5): human can lock a node/subtree (`locked: true`) — agent ops against
  locked nodes are rejected with a reason; the "don't clobber my manual tweak" contract.

---

## 9. App integration

- **FileCategory + ViewMode:** `.canvas` → new `FileCategory`; ViewModes: `canvas` (WYSIWYG,
  default), `source` (JSON in CM6 — free), `preview` (read-only render, reuses the preview-tab
  pattern). `ViewMode` gains one case (`Sources/ViewerKit/ViewMode.swift`) — additive, snapshot-safe.
- **Editor chrome (D5):** native SwiftUI — inspector panel (selected node props/tokens),
  layers/outline sidebar section (reuses `SidebarSectionRegistry`), insert palette, page strip
  for decks. In-webview: selection handles, guides, inline text editing. Rationale in §12-D5.
- **Persistence:** file on disk is the truth (agent-and-git-friendly); autosave + hot-exit spill
  (`EditorBuffer`-equivalent), local-history checkpoints per N ops, session snapshot carries
  viewport/selection (additive fields on `TabSnapshot`).
- **Markdown synergy:** `![arch](diagrams/arch.canvas)` in rendered markdown renders the canvas
  page as an inline figure (read-only projection). Docs get live-editable figures; this is
  cheap once export-to-SVG/PNG exists and is a distinctive win (UC-12).
- **Walkthrough integration:** new walkthrough verbs `openCanvas`, `canvasGoto(page/fragment)`,
  `canvasSpotlight(nodeId)` — an explainer panel driven step-by-step inside a tour (UC-3).

---

## 10. Rendering & runtime architecture notes

- **Projection contract:** deterministic scene-graph→DOM mapping; every op maps to a minimal DOM
  patch (measured: apply→paint under ~16ms for typical ops; perf budget + PerfSignpost from the
  start, per the MEASURE-don't-guess directive).
- **State kept out of the DOM:** selection, hover, drag state live in the runtime store; the DOM
  can always be re-projected from (graph, state) — this is what makes warm-cache park/re-attach
  and crash recovery safe.
- **Fonts/assets:** document-local `assets/` sidecar dir (`Foo.canvas` + `Foo.canvas-assets/`
  or a single-file bundle with base64 for small assets — **open question Q6**).
- **Export:** standalone HTML = scene graph + runtime + assets inlined into one file (the
  runtime doubles as the player — same trick mermaid uses); PDF/PNG via the WebView print/
  snapshot path. Deck export includes the fragment player (space/arrow navigation).

---

## 11. Use-case catalog (breadth exploration — what the foundation must carry)

Owner asked to explore as many as possible. Each entry: what it is, what it needs beyond core,
and which frictions it stresses. **UC-1..4 are the four named in the epic; the rest are
opportunities the same foundation unlocks** (each is a plausible future epic — none require core
schema changes beyond what's already in §5).

| # | Use case | On top of core it needs | Stresses |
|---|---|---|---|
| **UC-1** | **UI Design** (Claude-design-like: agent inserts elements, iterates with the user, mock → real) | UI component kit (buttons/inputs/nav/cards), device-frame page presets, prototype navigation (behaviors), later export-to-code (HTML/React/SwiftUI skeletons from the typed graph — tractable *because* the graph is typed, impossible from raw HTML) | F1 F3 F5 F6 F8 |
| **UC-2** | **Presentations** (slides, builds, animations, presenting) | `kind:"deck"`; `reveal` fragment indices + transition specs (token-limited set: fade/slide/scale); presenter mode (current+next+notes+timer — a second window, AppKit); keyboard/remote nav; PDF/standalone-HTML export. Generalizes the mermaid step-manifest mechanic. | F2 F7 |
| **UC-3** | **Explainers in walkthroughs** | Walkthrough verbs (§9); canvas panel as overlay or split pane beside live code; spotlight/zoom-to-node; checkpoint postMessage back to the tour engine. Directly serves epic 688 / wishlist P6 ("slides, docs, source, terminal" mixed presentation). | F7 |
| **UC-4** | **Infographics** | Chart nodes + `data` blocks (CSV import from the existing CSV engine!); stat tiles/callouts kit; connector shapes; PNG/SVG export. | F3 F4 F5 |
| UC-5 | **Dashboards over live project data** | `dataRef` → *watched* CSV/JSON files (existing FileWatcher): file changes → data re-bind → charts update. Agent builds a build-health/perf dashboard that stays live. | F2 |
| UC-6 | **Freeform diagramming / whiteboard** (beyond mermaid) | `kind:"board"` (infinite canvas, D3 phase 2); sticky-note/connector kit; auto-layout verb for graphs (the one place a layout algorithm may eventually be wanted — defer, mermaid covers structured graphs today). | F3 |
| UC-7 | **Interactive tutorials & quizzes** | Behaviors (`setState` + `visibleWhen`) cover reveal-answer/branching; ties into walkthrough completion log. | F6 |
| UC-8 | **Annotated screenshots / visual bug reports** | `image` + `absolute` arrows/callouts + text. Agent takes a UAT screenshot, annotates the regression, files it — pairs directly with the T6/UAT lanes and `snapshot_window`. | F3 |
| UC-9 | **Rich reports** (code-review summaries, audit reports, release notes) | Report page kit; charts + code + prose; PDF export. Agents currently emit markdown; canvas is the "publishable" tier. | F5 |
| UC-10 | **Micro-tools / forms** ("agent builds a small UI for a workflow") | Form components + `postMessage`-to-Swift behavior (policy-gated actions). **Deliberately last**: it's the security-sensitive end of the spectrum (§13). | F6 F8 |
| UC-11 | **Algorithm/step animations** (educational: sorting, data-flow) | Fragment timeline + per-node transform animation verbs; pairs with code nodes + walkthrough. | F7 |
| UC-12 | **Live figures in markdown docs** | The `![](x.canvas)` inline projection (§9). Architecture diagrams in READMEs that are *editable in place*. | F2 |
| UC-13 | **Kanban/planning visual boards** | Board kit over `kind:"board"`; column stacks + card components; ops make agent grooming natural. (Adjacent: PinBoard epic 689.) | F1 |
| UC-14 | **App-native surfaces built on canvas** (welcome tour, release-notes screen, empty states) | Nothing — we dogfood the runtime for our own chrome-adjacent content, which keeps the surface honest. | all |

**Reading of the table for phasing:** every use case decomposes into the same core + a kit +
at most one new *mechanic* (fragments, data-watch, infinite viewport, presenter window,
export-to-code). The mechanics are the real roadmap items; kits are content.

---

## 12. Key design decisions (argued)

**D1 — Scene graph is the source of truth; HTML is a render artifact.**
*Alternative rejected:* "HTML file + agent edits it with better tools" (annotate with IDs, edit
via CSS-selector ops). Rejected because HTML-as-truth makes every guarantee soft: no closed
style set (unlintable), no typed nodes (no component props, no export-to-code), sanitization on
every load (we own nothing), diffs are markup soup, and human WYSIWYG edits must be reverse-
engineered from DOM mutations. The typed graph is what makes agents *cheap* and domains *layerable*.
*Cost accepted:* we own a schema forever (mitigated by the proven additive-Codable discipline)
and an escape hatch is mandatory (`embed`).

**D2 — Auto-layout default, absolute opt-in.**
Agents without feedback produce overlapping absolute layouts (F3 is the #1 observed failure of
LLM-generated slides/UIs). Stack/grid + intent props make the *default* output resilient to
content change; `absolute` remains for the genuinely freeform. Figma's auto-layout arrived late
and became the way agents/plugins interact with it — we start there.

**D3 — Page/artboard-based first; infinite canvas (`kind:"board"`) phase 2.**
Three of the four named use cases (UI screens, slides, infographics) are page-shaped. Pages are
also the natural snapshot/export/lint unit. The document `kind` field keeps `board` additive
later; the runtime viewport code is written viewport-relative from day one so the delta is
contained.

**D4 — Hand-rolled vanilla-TS runtime, vendored IIFE (no framework, no chart lib).**
House style (mermaid excepted) is hand-roll + vendor with integrity tests; deps need owner
approval and this design doesn't require any: projection/patching over a typed graph is a few
kLOC without a framework's generality, and v1 chart marks (bar/line/area/pie/scatter) are
straightforward SVG. *Trigger to revisit:* if chart scope grows toward scales/facets/interactions
(a vendored micro-lib would then be a parked dep-approval ask, per the TSK-629 rider pattern).
Build pipeline mirrors `scripts/codemirror-build/` exactly (npm at build time, nothing at runtime).

**D5 — Native SwiftUI chrome; in-webview manipulation.**
Inspector/layers/insert-palette as SwiftUI reuse existing patterns (sidebar registry, Palette,
theming) and keep chrome accessible/host-testable; selection handles and inline text editing
*must* live in the webview (hit-testing/IME). The compositor-occlusion trap (LESSONS: opaque
representable over SwiftUI siblings) is a known hazard for overlay chrome — overlays that float
above the surface get `compositingGroup().zIndex(1)` treatment and T5 verification from the
first slice.

**D6 — Ops + op-log (no CRDT).**
Single-writer-at-a-time with revision checks covers agent⇄human co-editing on one machine.
CRDTs buy multi-writer convergence we don't need and cost schema complexity everywhere.
The op log doubles as undo, history, and the event feed — three features for one mechanism.

---

## 13. Security model

Inherits the audited trusted-HTML posture, tightened for a *writable* surface:

1. **Process/network fence:** canvas WKWebView = trusted-mode CSP — our vendored runtime only,
   `connect-src 'none'`, no external subresources, navigation-policy allowlist (link opens go
   through the existing policy). Nothing in a document can phone home.
2. **Documents are data, not code.** The scene graph contains no executable content; behaviors
   are interpreted verbs from a closed set. The **only** code-bearing node is `embed`:
   - v1 `embed` = HTML/CSS only (sanitized, no script), rendered in a sandboxed iframe
     (`sandbox` attr, separate origin, no bridge access).
   - script-bearing embeds are **explicitly deferred** to an owner decision (Q5) — if allowed,
     they run iframe-jailed with no `postMessage` beyond a vetted shim.
3. **Op fence** (loader-style validation, §3-L3) on every apply, regardless of author.
4. **Path jail:** all MCP canvas tools use `validatedExistingURL`-class confinement; exports and
   asset imports are jailed the same way; asset filenames sanitized WalkthroughStore-style.
5. **First content-write MCP precedent** (§7): scoped to `.canvas` docs; tab-strip indicator when
   an agent holds a canvas open; `canvas_events` gives the human a full audit trail (op log with
   author labels).
6. **Resource caps:** node count, asset size, op-batch size, snapshot pixel caps — DoS-shaped
   inputs fail as typed errors (the MsgPack `tooDeep` philosophy).

---

## 14. Testing strategy (per house rules)

- **Host (merge gate):** L2/L3 are pure — Codable round-trips of every node type (Swift Testing,
  parameterized), op reducer semantics (apply/undo/conflict/fence rejections), selector engine,
  token resolution, component expansion, export HTML assembly, MCP tool catalog via fake
  `AutomationHost` (the established MCP*Tests pattern), bridge envelope round-trips
  (`CanvasBridge` mirroring `CodeMirrorBridgeTests`).
- **In-process WebView suite** (`MDV_RUN_WEBVIEW_TESTS=1`, nightly/VM lane): runtime projection
  correctness (apply ops → query DOM state via the completion bridge — the pattern validated by
  `EditorScrollRestoreWebViewTests`), geometry/lint/hit-test answers, behavior verbs, fragment
  stepping.
- **VM T5 pixel + T6 UAT:** the WYSIWYG surface is exactly the render-path class the owner
  directives target — selection handles visible, drag actually moves pixels, deck fragments
  reveal on keypress. Negative-control switch (`MDV_ENABLE_BROKEN_CANVAS_HANDLES`) from the first
  T5 test, per TSK-1134 convention. Script verbs make T6 journeys drivable (`canvas` verb group).
- **Teeth rule:** every render guard demonstrated red-on-broken before trust.

---

## 15. Phasing (roadmap only — NOT started)

Slices sized to land independently, each gate-green with tests; render slices carry their VM tail:

- **P0 — Spike/PoC (1 slice):** `canvas.html` + minimal runtime hosting a hardcoded scene graph;
  bridge round-trip (apply op → DOM patch → geometry query back); warm-cache park/re-attach
  proof. *Kills the riskiest unknowns (bridge perf, patch fidelity) before any schema freeze.*
- **P1 — Document core:** schema v1 (frame/text/image/shape), Codable + store + FileCategory +
  `canvas` ViewMode + source-mode JSON editing; op reducer + undo; autosave/hot-exit/session
  fields.
- **P2 — Agent surface:** MCP tools (`create/apply/query/lint/snapshot`) + script verbs + events
  feed; lint v1 (overflow/collision/contrast); this is the earliest point the epic pays off —
  agents can build static pages end-to-end.
- **P3 — WYSIWYG:** selection/handles/drag/resize/inline-text; native inspector + layers;
  co-editing revision protocol + locks.
- **P4 — Design system:** tokens (+ app-theme inheritance), components + instances, first kits
  (report + KPI/infographic basics); `table`/`chart`/`code`/`diagram` nodes.
- **P5 — Presentation:** deck kind, fragments/transitions, presenter mode, deck export
  (standalone HTML/PDF); walkthrough verbs (UC-3).
- **P6+ — Tracks by owner priority:** UI-Design kit + prototype behaviors (UC-1) · data-watch
  dashboards (UC-5) · markdown inline figures (UC-12) · board kind (UC-6) · export-to-code ·
  plugin-contributed kits/renderers.

Suggested board decomposition when `tasked` is back: one epic + one ticket per P0–P5 slice,
`area:canvas`, this doc as the spike artifact on the epic.

---

## 16. Open questions for the owner (DECISIONS NEEDED)

| # | Question | Recommendation |
|---|---|---|
| Q1 | **First domain track after the core** — presentation (UC-2/3, matches wishlist P6) or UI Design (UC-1)? Shapes P4/P5 kit order. | Presentation first (existing walkthrough kin + owner wishlist signal). |
| Q2 | **File format/extension** — `.canvas` OK? (Obsidian uses `.canvas` with a different JSON schema — acceptable collision or pick `.tvcanvas`/`.cnv`?) | `.canvas` with our schema discriminator; the discriminator disambiguates. |
| Q3 | **D3 confirm:** page-first, infinite-canvas later — OK? | Yes (argued §12). |
| Q4 | **D4 confirm:** hand-rolled runtime + hand-rolled SVG charts, no new deps in v1 — OK? | Yes; revisit charts on scope growth. |
| Q5 | **`embed` node ceiling:** HTML/CSS-only in v1 (no script) — and is script-in-iframe ever acceptable later? | HTML/CSS-only v1; defer script decision until a use case demands it. |
| Q6 | **Asset strategy:** sidecar `X.canvas-assets/` dir vs single-file (base64 inline, size-capped)? | Single-file up to a cap (~2 MB total), sidecar beyond — decks with screenshots will exceed inline quickly. |
| Q7 | **Content-write MCP precedent** (§7, §13-5): comfortable with agents writing `.canvas` docs under the op fence + audit trail, or want a per-document human grant first (like plugin capability grants)? | Op fence + tab indicator + events audit is sufficient; grants add friction to the core loop. |
| Q8 | **Naming:** "Canvas" as the user-facing feature name (menu: *File ▸ New Canvas*)? | Yes. |

---

## 17. References

- Scan basis: module map, WebView/bridge/warm-cache/mermaid/walkthrough/MCP/persistence/theming
  inventory — this doc §2 (fresh 2026-07-01 codebase sweep).
- `docs/CM6_INTEGRATION_DESIGN_2026-05-23.md` — bridge + vendoring pattern (§13 protocol).
- `docs/WALKTHROUGH_DESIGN_v2.md`, `docs/MCP_AND_WALKTHROUGH_PERSISTENCE.md` — script/engine/store patterns.
- `docs/MERMAID_IMPL.md`, `docs/MERMAID.md`, `VENDOR.md` — JS-renderer vendoring + lazy injection.
- `docs/PLUGINS_DESIGN_v2.md` — reserved renderer/view-mode contribution shapes.
- `docs/SESSIONS_DESIGN.md`, `Sources/ViewerCore/Sessions/SessionSnapshot.swift` — additive-Codable persistence style.
- `docs/PREVIEW_TAB_DESIGN.md` — preview projection pattern.
- `BACKLOG.md` epic 688 · `OwnerWishlist.md` P6 — the presentation seed this epic subsumes.
