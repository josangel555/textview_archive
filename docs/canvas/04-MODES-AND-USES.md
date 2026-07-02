# Canvas · 04 — Modes, use-cases, and the hard boundaries

> A **mode/preset = document kind + element palette + enabled layers (DATA/INTERACT/TIME) +
> export targets + starter templates.** All modes share one core; a use-case that needs a new
> *core primitive* means the core is wrong — that test shaped the schema (fragments →
> steps, charts → data blocks, UI kit → components).

## 1. The four named modes (the epic's asks)

### Presentation (recommended first mode — Q1)
`kind:deck` · TIME (steps/fragments, timing tree) · morph transitions · presenter mode
(second window: current/next/notes/timer) · keyboard/remote nav · export standalone-HTML
player + PDF. Evidence-shaped: reveal.js's flow+fragments model is the validated LOW-friction
deck shape; impress.js's coordinate authoring is the documented anti-pattern. **The
identity-morph is the wedge feature:** deterministic Magic-Move (set-diff on real IDs +
`morphKey` overrides) — no HTML deck tool has exact matching; agents get "morph slide 3 into
slide 4" for free from IDs they already hold. Serves epic 688 / OwnerWishlist P6 directly.

### Explainers-in-Walkthroughs
Presentation's engine + walkthrough verbs (`openCanvas`, `canvasGoto(page|beat)`,
`canvasSpotlight(nodeId)`) + checkpoint postMessage back to the tour engine. Strategic
dogfood: the walkthrough system is the in-house consumer that keeps the agent surface honest.
Scrollytelling = the same timeline with a scroll-driven trigger binding (CSS scroll timelines)
— near-free once TIME exists.

### UI Design (Claude-Design-like)
Auto-layout + component kit (buttons/inputs/nav/cards) + device-frame presets + prototype
navigation (behaviors) → **tiered delivery:** wireframe → clickable prototype → code export.
Code export is the hard mile and explicitly LAST (Q10): semantic HTML/CSS first; framework
targets later; always one-way/disposable (Lona + Mitosis lessons).

### Infographics
`kind:page` + DATA (data blocks ← the existing CSV engine; FileWatcher keeps them live) +
chart nodes (Vega-Lite-shaped encodings → hand-rolled SVG marks) + stat-tile/callout kit +
connector shapes + PNG/SVG/PDF export. Agent sweet spot: data→structure is what models are
good at; geometry stays the engine's job.

## 2. The wider catalog the same core carries

Near-term unlocks (each = a kit + at most one mechanic): **dashboards over live project data**
(watched data blocks; build-health/perf boards) · **diagrams** (agents emit graphs natively;
DiagramRegistry wraps mermaid/dot layout; connector shapes for freeform) · **annotated
screenshots / visual bug reports** (image + absolute callouts; pairs with UAT snapshots) ·
**rich reports** (charts+code+prose page kit, PDF; pagination caveat → Q9) · **interactive
tutorials & quizzes** (conditional/setState verbs; walkthrough completion log) · **algorithm/
step animations** (timeline + code nodes) · **live figures in markdown** (`![](x.canvas)`
inline projection — editable diagrams in READMEs; distinctive and cheap once export exists) ·
**app-native surfaces** (welcome tour, release notes — dogfooding that keeps the runtime honest).

Longer tail (research catalog, ~60 across 11 families — `docs/research/canvas-2026-07-01/use-case-catalog.md`):
social/marketing assets · email templates (table-layout export — genuinely different lowering) ·
storyboards/comics · in-app product tours · forms/surveys · explorables (the DATA+INTERACT+TIME
forcing function) · kanban/planning boards (`kind:board`) · certificates/invoices/résumés
(FLOW-dependent → Q9) · moodboards/whiteboards (`kind:board`) · maps/geo · courseware.

**Highest-leverage non-obvious picks:** the **embed/self-contained export** (one bundle +
resize protocol makes *every* artifact distributable) · **DATA+auto-layout diagrams** (model
strengths) · **the component+token layer itself** (compounds across every design use-case) ·
**explorables** (forces the reactive core to be real, de-risking dashboards/configurators).

## 3. Hard boundaries — what would DISTORT the foundation (hold this line)

Support the *authoring/layout*; never become the specialized *runtime*:

| Distorter | The warp | Posture |
|---|---|---|
| CAD / floor plans / technical drawing | constraint solver + real-world units + dimension lines | diagram-grade precision only; **no solver ever** (anti-decision, `01` §10) |
| Video NLE / motion-graphics editor / DAW | multi-track media decode/scrub/audio | motion *templates* (CSS/WAAPI-grade); not an editor |
| Photo compositing / raster editing | pixel buffers, masks, pixel blend | image placement + CSS filters; the image editor stays its own feature |
| 3D / AR | 3D scene graph, camera, lighting | out of scope |
| Micro-apps with backends | routing/auth/DB = a platform | emit front-ends; stop at the data-sink boundary |
| Commercial prepress | CMYK/bleed/imposition | office-grade RGB PDF only |
| Games | 60fps loop/physics/input | level *layout* export at most |
| 10³–10⁴-node boards/diagrams | DOM rendering collapses | not a distortion but a **scaling fork** (virtualize or canvas-backend) — trigger only if such a use-case is ever prioritized (Q3 rider) |

## 4. Mode acceptance test

A new mode ships as: palette (components) + starters + at most one new *mechanic* record type +
export target — **zero core-schema changes**. If a mode needs more, that's a design review on
the core, not a mode patch.
