# M6 — Presentation mode, Tier 1 (TSK-1348) — implementation plan

**Goal (05-ROADMAP §P6 + Q1-rationale; 06 success criteria 1–5):** the
second MODE — a themed, animated DECK built entirely through ops. It
showcases the epic's differentiators (identity-morph transitions;
`timeline_state` declarative verification before any pixel) and dogfoods the
walkthrough vision. Presentation was deferred to M6 precisely because its
subsystems (TIME/steps/morph) are LOW-RISK proven prior art (reveal.js /
WAAPI / FLIP) — M5 already de-risked the make-or-break CSS ladder.

## Architecture — stay THIN (M5's law held; keep holding it)

A deck is a MODE, not a fork: `mode.presentation` token + a slide template +
presentation presets. The TIME model rides as PROPS + ENGINE QUERIES, not
new record kinds:
- **slides** = `role=slide` frames (reuse M5's artboard chrome/machinery,
  relabelled).
- **steps/fragments** = a `step` prop (u16) on any node — it reveals at that
  step within its slide (step 0 = base). NO new kind.
- **morph** = identity-morph: nodes sharing a `morphId` across consecutive
  slides animate position/size (FLIP). The pairing is a pure set-diff the
  ENGINE computes; JS only runs the animation.
- **timeline** = `timeline_state(slide, step)` — a pure engine query
  returning the visible node set. Declarative verification (success #3)
  lands BEFORE any pixel.

THE THIN-MODE KILL (unchanged from M5): if a slice needs an engine branch on
the mode token or mode-specific op semantics, STOP — the design leaked.
Exception watched closely: the step model is GENERAL node state (not
mode-gated) — any doc may carry `step`; presentation mode just gives it a
player. That keeps it law-abiding.

## Slices

### S1 — deck mode infra + slide template
- `canvas_new {mode: "presentation", slides?: N}`: mode token + N `role=slide`
  frames (16:9 preset, 1280×720) from a template; kit imported.
- `CanvasPresentationMode` (mirrors `CanvasUIDesignMode`); isPresentation().
- Tests: template seeds slides + token + kit; io round-trip; plain new untouched.

### S2 — the step model (rust, pure)
- `step` prop (interned key, u16, fence-capped); `timeline_state(slide, step)`
  in a new `deck.rs`: given a slide subtree, return the ordered step count +
  the visible-id set at a step (id visible iff its step ≤ current; step
  absent = base = always visible). Deterministic, proptest-friendly.
- Lint: `step` on a node not under a `role=slide` warns (orphan-step); a
  slide with steps reports its step count.
- Vocab teaches `step`. Round-trips (generic prop path).
- Tests: visibility monotonic in step; step count = max(step); orphan lint;
  proptest (visible set grows monotonically, base always in).

### S3 — timeline_state FFI + query tool
- `mdvcore_canvas_timeline` FFI + `canvas_timeline` MCP tool → per-slide
  `{stepCount, steps: [{step, visibleIds}]}`. The agent's declarative
  verification surface (success #3).
- Tests: tool returns the step structure over the real surface; teeth.

### S4 — the deck player (JS/webview)
- canvas.js PLAYER mode (a `setDeckMode` command): render the deck, show ONE
  slide, advance slide/step via commands (deckGoto{slide,step}) + arrow keys;
  a node reveals when its step ≤ current (CSS visibility, matching
  timeline_state exactly — same rule both sides).
- Bridge: CVOutbound.setDeckMode/deckGoto; CVInbound.deckStateChanged.
- Webview tests: advancing steps reveals exactly the timeline_state set
  (the two sides agree — the declarative check GUARDS the pixel one); teeth.

### S5 — identity-morph transitions
- Engine: `morph_pairs(slideA, slideB)` in deck.rs — the shared-morphId set
  with each id's from/to nodes (pure diff). Vocab/fence for `morphId`.
- JS: on slide advance, FLIP-animate the paired nodes (WAAPI: measure first/
  last, invert, play). Non-paired nodes cross-fade.
- Tests: rust pair-set diff (added/removed/morphed classified); webview FLIP
  (a morphed node's transform animates between the two slide positions —
  assert an in-flight transform, teeth on the pairing); T5 morph pixels
  pinned to TSK-1334.

### S6 — deck export (standalone offline player)
- `canvas_export {flavor: "deck"}`: a self-contained HTML deck — the lowered
  slides + the player JS INLINED (arrow-key nav, step reveal, morph) + theme
  block; ZERO network (success #4; assert no external URLs).
- PDF export (one page per slide): if the headless print path is available,
  wire it; else record as a finding + owner-decision (don't block the deck).
- Tests: exported deck is self-contained (no http(s):// refs), plays (the
  inlined player advances), slide count correct.

### S7 — UAT-M6: the deck journey (the milestone artifact)
- Per success criteria 1–4: agent builds a themed deck through ops → human
  reorders/retitles slides WYSIWYG (controller) → agent sees the edits in
  canvas_events → timeline_state verifies steps declaratively → morph plays
  (webview) → export a self-contained offline deck → reopen identical.
- Teeth: MDV_ENABLE_BROKEN_* on the reveal rule → UAT RED.
- Host + local webview lanes; T5 morph pixels pinned to TSK-1334.

## Budgets
- timeline_state over a 200-node slide: < 5ms (a single walk).
- morph_pairs over two 200-node slides: < 5ms (a hash-join on morphId).
- Deck export of a 20-slide deck: < 100ms.

## Risks / kill-criteria
- **THIN-MODE KILL** (as M5): any engine branch on the mode token = stop.
- **Morph scope creep:** Tier 1 morphs position/size/opacity via FLIP only —
  no path morphing, no cross-kind morphs (text→image). Record richer morphs
  as findings.
- **PDF export** may have no clean headless path — it is the ONLY part
  allowed to become an owner-decision finding; the standalone HTML player is
  the success criterion and must ship.
- **Walkthrough verbs (explainer dogfood)** stay a P7 finding — Tier 1 is the
  deck itself, not the walkthrough integration.

## Validation ladder
Rust: cargo gate (S2/S3/S5 engine). Swift: host gate (S1/S6/S7 model) +
local webview (S4/S5/S7 player/morph) with negative-control teeth. T5 morph
pixels pinned to TSK-1334 (owner Screen-Recording grant). The UAT is the
milestone artifact.
