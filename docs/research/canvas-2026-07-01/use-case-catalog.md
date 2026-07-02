# Agent ab7523cf01b117e1c.output

## Prompt (first 300 chars)
I'm building ONE foundational "visual canvas" system — agents and humans place and edit visual elements that render as HTML/CSS/JS — and I want to enumerate the WIDEST possible set of end-user products/use-cases that could be built on top of this single foundation.

Seed use-cases already in mind: (

## Final message

**Context:** Pure product/architecture brainstorm — no code needed. I'm treating this as a synthesis task: enumerate the widest use-case space, express each as a *delta* on a shared canvas core, then pressure-test whether one foundation genuinely holds them all. I ran this from domain knowledge rather than web search — competitor pages (Figma/Canva/Miro/Gamma/Framer/tldraw…) mostly re-confirm the categories below; the value you asked for is the "demands / unique / distorts" layer, which is synthesis. Say the word and I'll fan out unprimed research agents to market-size or validate any specific pick.

---

## 1. The shared core (so "demands" can be a delta, not a re-listing)

A canvas foundation that renders to HTML/CSS/JS decomposes into a thin **scene core** plus stackable **capability layers**:

| Layer | What it is |
|---|---|
| `SCENE` | Tree of positioned elements + transforms (x/y/w/h/rot/scale/opacity/z), grouping, named layers, snapping/align. **Always present — this is the core.** |
| `FLOW` | Reflowing text/flow + grid + pagination (the "document" layout mode). |
| `DATA` | Bind element props to a data model: static, computed expressions, collections/repeaters, live sources. |
| `INT` | Interaction model: events (click/hover/input/timer), state machine, navigation/links, conditional visibility, inputs. |
| `TIME` | Ordered steps, keyframes, property transitions, scene-to-scene transitions, triggers. |
| `COMP` | Components/instances + design tokens/themes (reuse + systemic styling). |
| `EXP` | Export targets: self-contained `HTML/JS`, `PDF/print`, raster `IMG`, framework `CODE`, `EMBED` snippet. |
| `AUTH` | Programmatic (agent-placeable) API, multiplayer, history/versioning. **Always present** (agents place elements). |

## 2. Tension axes — the dimensions along which a use-case stresses the core

These are the pressure-test lenses; distortion always shows up as a use-case pinned to an extreme on one of them.

1. **Spatial model:** fixed-page ↔ infinite-canvas ↔ reflowing-flow *(the deepest fork — see §7)*
2. **Temporality:** single frame ↔ sequenced steps ↔ continuous animation ↔ live/reactive
3. **Precision domain:** typographic-flow ↔ vector-precise ↔ pixel/photographic ↔ CAD-metric
4. **Data coupling:** static ↔ author-time data ↔ runtime-live data
5. **Interactivity:** display-only ↔ navigational ↔ stateful-input ↔ full-app-logic
6. **Output fidelity:** raster/PDF-final ↔ responsive-web ↔ production-source-code
7. **Structure:** free placement ↔ schema/graph-constrained (auto-layout from data)
8. **Scale:** a few elements ↔ thousands (rendering-backend pressure)

---

## 3. Use-case catalog

Legend for **Demands** = which layers beyond `SCENE`/`AUTH` it stresses. ★ = your seed four.

### Family A — Design & build (UI / web / email)

| Use-case | One-liner | Demands (delta) | Unique vs core |
|---|---|---|---|
| ★ UI design & prototyping | Agent places UI elements, exports production code | `INT` `COMP` `EXP:CODE` | Semantic component→framework-code emit; design-token fidelity |
| Clickable prototypes | Multi-screen flows with hotspot navigation | `INT` `TIME` (transitions) | Screen graph + navigation map; no real logic |
| Design systems / component libs | Reusable tokens + component catalog | `COMP` (heavy) `EXP:CODE` | Variant matrices, token inheritance, published library |
| Wireframing (lo-fi) | Grey-box layout to agree structure fast | `COMP` (stencils) | Deliberately low-fidelity element kit |
| Landing-page / site builder | Responsive marketing pages | `FLOW` `INT` `EXP:HTML` | Responsive breakpoints + SEO/semantic HTML |
| Email template design | HTML email that survives Outlook/Gmail | `FLOW` `EXP:HTML` (table-based) | Table-layout + inlined CSS + client-quirk constraints |

### Family B — Presentation & narrative

| Use-case | One-liner | Demands | Unique |
|---|---|---|---|
| ★ Slide decks | Slides w/ transitions + presenter mode | `TIME` `EXP:HTML/PDF` | Presenter view, speaker notes, per-slide build steps |
| ★ Explainers / walkthroughs | Canvas + sequenced steps + narration | `TIME` `INT` | Narration track + step-scoped highlight/spotlight |
| Scrollytelling | Narrative bound to scroll position | `TIME` `DATA` | Steps driven by scroll offset, not clicks |
| Storyboards | Sequenced frames for film/UX | `TIME` (ordering) | Frame metadata (shot/camera/duration) |
| Comics / sequential art | Panels + speech balloons + gutters | `FLOW`(panels) | Panel grid + reading-order + balloon tails |
| In-app product tours | Guided overlay tours over a live app | `INT` `TIME` `EXP:EMBED` | Anchors to *host-app* DOM selectors; runs as overlay |
| Interactive fiction | Branching narrative w/ choice map | `INT` (state) `TIME` | Branch graph + variables/inventory state |

### Family C — Data & analytics

| Use-case | One-liner | Demands | Unique |
|---|---|---|---|
| ★ Infographics | Data-driven visuals + charts + annotations | `DATA` `EXP:IMG/PDF` | One-shot data→layout; annotation callouts |
| Dashboards | Live KPI tiles + charts | `DATA`(live) `INT` | Refresh/streaming, filters cross-linking tiles |
| Chart composer | Compose/annotate individual charts | `DATA` `EXP:IMG/EMBED` | Encoding grammar (axes/scales/legends) |
| Reports | Data + narrative, paginated | `FLOW` `DATA` `EXP:PDF` | Pagination, running headers, page breaks, TOC |
| Map / geo annotation | Pins & shapes over a basemap | `DATA` `INT` | Geo-projection + tile basemap element |

### Family D — Diagramming & knowledge

| Use-case | One-liner | Demands | Unique |
|---|---|---|---|
| Flowcharts / process | Nodes + routed edges | `DATA` (graph) auto-layout | Edge routing/orthogonal connectors |
| Mind maps | Radial idea tree | auto-layout(radial) | Collapse/expand branches |
| Org charts | Hierarchy from HR data | `DATA` auto-layout(tree) | Reporting-line rules, generated from records |
| Timelines / roadmaps / Gantt | Time-scaled bars & milestones | `DATA` (time axis) | Time scale + dependency links |
| Architecture / network diagrams | System topology | `DATA` (graph) | Group/containment, port-anchored connectors |
| ER / UML | Schema/model diagrams | `DATA` auto-layout | Formal notation shapes + typed relations |
| Concept / knowledge maps | Free-form linked nodes | `INT` (link) | Bidirectional links, semantic edge labels |

### Family E — Whiteboard & collaboration

| Use-case | One-liner | Demands | Unique |
|---|---|---|---|
| Infinite whiteboard | Boundless brainstorming surface | infinite-canvas + `Scale` | Pan/zoom virtualization, freehand ink |
| Moodboards | Curated inspiration grid | (raster placement) | Bulk image import + masonry arrangement |
| Kanban / sticky / retro | Cards in columns | `DATA` `INT` | Column/lane containers, card drag semantics |
| Journey maps / service blueprints | Cross-swimlane experience map | `DATA` (grid) | Swimlane matrix + phase columns |
| Seating / venue / floor plans | Place seats/tables in a space | vector-precise, `Scale` | Real-space scale, per-seat assignment data |

### Family F — Marketing & social

| Use-case | One-liner | Demands | Unique |
|---|---|---|---|
| Social graphics | Templated sized posts | `COMP` `EXP:IMG` | Platform size presets + brand-kit apply |
| HTML5 ad banners | Animated multi-size ad units | `TIME` `EXP:HTML` | Size-set resize + ad-network clickTag/weight budget |
| Posters / flyers | Print-ready promo art | `EXP:PDF/IMG` | Bleed/large-format sizing |
| Sales one-pagers | Dense info sheet | `FLOW` `EXP:PDF` | Data-merged personalization |

### Family G — Documents & print

| Use-case | One-liner | Demands | Unique |
|---|---|---|---|
| Page layout / brochure | Magazine-style multi-page layout | `FLOW` `EXP:PDF` | Text flow across frames/columns, master pages |
| Résumés / CVs | Structured personal doc | `FLOW` `DATA` `EXP:PDF` | Data model (roles/dates) → template swap |
| Certificates / badges | Personalized award docs | `DATA` `EXP:PDF/IMG` | Bulk mail-merge, verification QR |
| Invoices / business docs | Structured line-item docs | `FLOW` `DATA` `EXP:PDF` | Computed totals, deterministic pagination |
| Menus / labels / packaging | Physical-good surfaces | vector-precise `EXP:PDF` | Dieline/spec constraints |

### Family H — Education & explorables

| Use-case | One-liner | Demands | Unique |
|---|---|---|---|
| Interactive courseware | Lesson modules w/ activities | `INT` `TIME` `EXP:HTML/EMBED` | Progress/completion tracking (xAPI/SCORM-ish) |
| Quizzes / assessments | Scored question sets | `INT` (input+logic) `DATA` | Scoring/branching, answer capture |
| Explorable explanations | Manipulate params, watch model react | `DATA` `INT` `TIME` | Live model + reactive re-render (the "tinkerable" loop) |
| Annotated scientific figures | Labeled anatomy/diagram figures | `INT` (hotspots) | Callout leader-lines, layered reveals |

### Family I — Forms & micro-apps

| Use-case | One-liner | Demands | Unique |
|---|---|---|---|
| Forms / surveys | Data-capture flows | `INT` `DATA` `EXP:HTML/EMBED` | Validation, conditional logic, submission sink |
| Micro-apps / internal tools | Form + logic + data over a table | `DATA`(live) `INT`(logic) | CRUD wiring, actions/queries |
| Configurators / customizers | Build-your-product previews | `DATA` `INT` `TIME` | Option→visual state mapping, price rollup |
| Calculators / widgets | Small interactive computations | `INT` `EXP:EMBED` | Pure input→output binding |

### Family J — Media & creative

| Use-case | One-liner | Demands | Unique |
|---|---|---|---|
| Screenshot annotation | Markup/redline over an image | (overlay) `EXP:IMG` | Precise pixel anchors, arrows/blur-boxes |
| Photo composites / collages | Layered image arrangement | (raster placement) | Masks, CSS filters/blend (see distortion note) |
| Motion-graphics templates | Lower-thirds / intro cards | `TIME` `DATA` | Keyframed reveals, data-fill text |
| Micro-animations | Lottie-style loops/stickers | `TIME` `EXP:EMBED` | Loop control, tiny self-contained bundle |
| Game / level / board layout | Author level/tile/board geometry | grid, `Scale` | Tile grid + entity placement metadata |
| ML data-labeling | Draw regions over media to label | `INT` `DATA` | Region shapes → structured annotation export |

### Family K — Embed & distribution

| Use-case | One-liner | Demands | Unique |
|---|---|---|---|
| Embeddable widgets | Any artifact as a droppable snippet | `EXP:EMBED` | Sandboxed self-contained bundle + resize protocol |
| Interactive docs / API explorers | Docs w/ live try-it panels | `INT` `DATA` | Request/response state, code samples |
| Digital signage / kiosk | Auto-looping full-screen display | `TIME` `DATA`(live) | Unattended loop, playlist scheduling |
| QR microsites / event pages | One-off linked mini-pages | `EXP:HTML` | Single-URL publish, mobile-first |

---

## 4. Ranked shortlist — value × feasibility on the shared foundation

| # | Use-case | Why it ranks | Feasibility |
|---|---|---|---|
| 1 | **Slide decks** | Near-perfect fit: `SCENE`+`TIME`+export, nothing exotic; huge demand | High |
| 2 | **Explainers / walkthroughs** ★ | Already your product's spine; steps+narration reuse the deck engine; strategic dogfood | High |
| 3 | **Infographics** ★ | `DATA`→one-shot layout is exactly what an agent is good at | High |
| 4 | **Diagrams** (flow/org/mind/timeline) | `DATA`+auto-layout; agents *emit graphs* natively; one layer serves 6 diagram types | High |
| 5 | **Social / marketing assets** | Templated + sized + raster export; low tech risk, broad appeal | High |
| 6 | **Scrollytelling** | ~free once `TIME` steps exist (rebind trigger to scroll); high differentiation | High |
| 7 | **Explorable explanations / calculators / widgets** | The `DATA`+`INT`+`TIME` sweet spot; weak incumbents; agent-authored interactives are genuinely novel | Med-High |
| 8 | **UI prototyping** ★ | High value; *wireframe/clickable* tier is easy, `EXP:CODE` is the hard mile — ship the tiers separately | Med (code-export) |
| 9 | **Dashboards / reports** | High value; the lift is `DATA`(live) + `FLOW`/pagination, both reusable | Med |
| 10 | **Forms / surveys** | `INT`+`DATA`+submission sink; ubiquitous, moderate build | Med |

## 5. Non-obvious high-leverage picks

- **Embeddable widget export (`EXP:EMBED`) is a *force-multiplier layer*, not a use-case.** One self-contained-bundle + resize-protocol export turns *every* artifact above into a distributable thing. Build it once; it raises the value of the whole catalog. Highest leverage-per-effort item on the board.
- **Agent-authored diagrams from structured data.** LLMs produce graphs/hierarchies far more reliably than pixel-precise layouts. If `DATA`+auto-layout is solid, the *agent* supplies the graph and the *engine* supplies the geometry — plays to model strengths and sidesteps "the agent nudged a box 3px." Underrated because it looks like "just diagrams."
- **Scrollytelling ≈ slides with a different trigger.** Same `TIME` step engine, driven by scroll offset instead of click. Almost free, and it's a category (data journalism, product marketing) with no good agent-native tool.
- **In-app product tours + screenshot annotation.** Tiny surface (overlay + step + anchor), outsized practical demand, and it exercises the *anchor-to-external-DOM* primitive that also powers embeddable widgets. Cheap, sticky, reuses infra.
- **Design-system / component-library layer.** It's *infrastructure disguised as a use-case*: `COMP`+tokens makes every design use-case (UI, email, social, docs) better and compounds. Invest here early, not late.
- **Explorable explanations.** The single use-case that exercises `DATA`+`INT`+`TIME` *together* — building it forces the reactive core to be real, which de-risks dashboards, configurators, and courseware simultaneously.

## 6. Use-cases that would DISTORT the foundation

Each distorter shares a signature: it's pinned to an extreme on §2's axes and demands a *different substrate, precision model, or temporal model* than DOM/CSS/vector-screen.

| Distorter | Axis pinned | The warp | Safe posture |
|---|---|---|---|
| **CAD / floor plans / technical drawing** | Precision→CAD-metric | Pulls layout into a *constraint solver* + real-world units + dimension lines | Support *diagram-grade* precision only; not a solver |
| **Video / motion-graphics *editor*, DAW timelines** | Temporality→frame-accurate media | `TIME` mutates from "CSS transitions/steps" into a multi-track NLE w/ media decode/scrubbing/audio | Ship *motion templates* (CSS-animation-grade), not an editor |
| **Photo compositing / raster editing** | Precision→pixel | HTML/CSS is the wrong substrate; needs pixel buffers, masks, blend at pixel level (canvas/WebGL) | Allow image *placement* + CSS filters; no pixel editing |
| **3D / spatial / AR layout** | Precision + a 3rd dimension | Needs a 3D scene graph, camera, lighting — a wholly different core | Out of scope |
| **Full micro-apps w/ backend** | Interactivity→full-app-logic | Pulls toward routing/auth/DB/server — a *platform*, not a canvas | Emit the *front end*; stop at the data-sink boundary |
| **Commercial print / prepress** | Output→print engine | CMYK/bleed/imposition/spot colors; HTML→PDF is RGB-screen | "Office-grade PDF" only |
| **Games needing a loop/physics** | Temporality→60fps game state | A game loop + collision + input is a runtime, not a scene | Support *level/board layout* export, not the engine |
| **Very-large diagrams / tile maps (10³–10⁴ nodes)** | Scale | DOM rendering collapses; forces a canvas/WebGL blit backend | Not a *core* distortion but a real **rendering-backend fork** (DOM vs canvas) to plan for |

## 7. Verdict — does one foundation genuinely serve them all?

**Yes for the DOM/CSS-native, vector-or-flow, screen-first majority — which is ~90% of the catalog.** The clean decomposition is a thin scene core with the distorters walled off at three boundaries (different *substrate*, different *precision/units*, different *temporal model*):

```
                       ┌─────────────── EXPORT ───────────────┐
                       │ HTML/JS · PDF · IMG · CODE · EMBED    │
                       └──────────────────┬───────────────────┘
   capability layers  ┌── FLOW ──┬── DATA ──┬── INT ──┬── TIME ──┬── COMP ──┐
   (opt-in per preset)│ pagination│ binding │ state  │ steps    │ tokens   │
                       └──────────┴────┬─────┴────────┴──────────┴──────────┘
                       ┌───────────────▼───────────────┐
   core (always on)    │  SCENE  (positioned elements)  │  +  AUTH (agent API, multiplayer, history)
                       └───────────────┬───────────────┘
                       ┌───────────────▼──────────────────────────────┐
   spatial MODE (pick) │  fixed-page   │  infinite-canvas │  reflow-flow │  ← the deepest fork
                       └───────────────────────────────────────────────┘
     out-of-band ►  raster/WebGL substrate · CAD units/solver · frame-accurate media · game loop
                    (the §6 distorters — reachable only by forking the core; don't absorb them)
```

Each use-case is then a **preset** = *spatial mode + element palette + enabled layers + export target*. A slide deck = `fixed-page + TIME + EXP:HTML/PDF`; a dashboard = `fixed-page + DATA(live) + INT`; a report = `reflow-flow + FLOW + DATA + EXP:PDF`.

**The one architectural fork to decide early is the spatial model** (bottom row). Fixed-page (slides/social/print), infinite-canvas (whiteboard/diagrams/mind maps), and reflowing-flow (docs/reports/email/web) are the deepest divergence in the whole space. A strong core exposes all three as *modes over the same scene model* — but **reflow (`FLOW` + pagination) is the genuinely different beast** most canvas tools punt on (Figma/Canva/Miro have no real text-flow; that's why "make a report/résumé" is weak in all of them). If documents/reports/email matter to you, budget for `FLOW` as a first-class layer, not a bolt-on — it's the difference between "a canvas that also does docs" and "another whiteboard that can't paginate."

**Bottom line:** the foundation holds if you (1) build `EXP:EMBED` and the `DATA`+auto-layout diagram path early (highest leverage), (2) treat `FLOW` as a real spatial mode rather than an afterthought, and (3) hold the §6 line — support the *authoring/layout* of CAD/video/photo/games, never their specialized *runtime*. The moment you try to become the pixel editor, the NLE, the constraint solver, or the app backend, you've forked the core and lost the "one foundation" thesis.
