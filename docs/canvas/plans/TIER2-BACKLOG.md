# Canvas Tier-2 — the deferred-findings design menu (decision-ready)

> **Purpose.** The M0→M6 chain is COMPLETE. This turns the findings deferred during that
> build (M4 gauntlet + M5/M6 scope boundaries + 05-ROADMAP P7+ tracks) into concrete,
> decision-ready design sketches so the owner can PICK tracks in the review. Each item:
> the demonstrated need · the design approach (with the hard part) · slice count · risk ·
> recommendation. Spike+design is auto-approved; implementation of any item is one
> greenlight away. Nothing here is built — these are the next fork.

Ordered by my recommended priority (value ÷ risk), not by roadmap number.

---

## T2-A · L2 style variants — `:hover` (+ later, breakpoints)  ·  REC: build first
**Named in 05-ROADMAP as M5 UI-Design scope; I scoped it to Tier-2 in M5-PLAN.**

- **Need (strong):** hover states are table-stakes for the Q1 "clickable prototype" goal —
  buttons/links/cards that respond on hover. Today an agent can't express one.
- **The hard part (why it wasn't a quick default-build):** hover CANNOT be an inline style —
  it needs a scoped CSS rule (`[data-cv-id="X"]:hover{…}`). The engine's lowering is
  inline-style + INCREMENTAL-patch: an `Update` to a hover prop emits a `ReplaceNode`
  (node HTML), but the `:hover` rule lives in a page-level `<style>` block, so the edit
  would NOT update it → stale hover on the WYSIWYG path. Doing it right needs the rule to
  patch too.
- **Design:**
  - *Expression* (abstraction-respecting, no raw CSS): two convention props `hoverFill`,
    `hoverColor` (the 80% case; extensible), values are literals OR `$token` refs (so hover
    colors retheme via `var(--cv-*)` for free). Author: `use #kit-button #cta hoverFill=$color.accentHover`.
  - *Lowering*: a second page-level block `<style id="cv-hover">` emitting one
    `[data-cv-id="X"]:hover{background:var(--cv-…);color:…}` rule per node with hover props;
    reuses the existing `css_decl` mapping.
  - *Patch path (the real slice):* a `SetHoverRules{css}` patch verb (mirrors M4.S4's
    `SetTheme` — whole-block replace) emitted whenever a hover prop changes, so incremental
    edits stay correct. This is the piece that makes it Tier-2, not Tier-1.
- **Slices (~3):** (1) props + fence + `cv-hover` block in lower_page + vocab (rust, host-testable);
  (2) `SetHoverRules` patch verb + wire/Swift/JS applier (webview-lane); (3) breakpoint variants
  (`@media` — same scoped-block machinery, a later add).
- **Risk:** medium (the patch-path verb is new but modeled on SetTheme). Reversible.

## T2-B · Interactive input primitives  ·  REC: needs an owner product call first
- **Need (medium):** the gauntlet mocked inputs as bordered frames — fine for wireframes,
  but real forms need actual fields.
- **The fork (owner decision):** STATIC input-appearance (an `input` kind rendering a styled
  field, non-interactive) is a small additive kind (~1 slice, low risk). TRULY interactive
  inputs (value state, events, submit) are the **B-tier dynamism ladder** — a genuine
  product-scope decision about how much runtime behavior Canvas owns (02-CORE-ENGINE's TIME
  model is author-time; runtime input state is a different axis).
- **Rec:** ship the static `input`/`field` kind now (closes the mock ergonomics); DEFER
  interactive forms to an explicit owner decision on the dynamism ladder.

## T2-C · Richer identity-morph (path / cross-kind)  ·  REC: defer, low demand
- **Need (low, showcase):** Tier-1 morph is position/size/opacity FLIP (shipped, M6.S5).
  Path morph (SVG shape→shape) and cross-kind morph (text→image) are the flashy extras.
- **Design:** cross-kind = crossfade + FLIP box (approximate, tractable); path morph = real
  SVG path interpolation (hard, needs a geometry lib or hand-rolled — dep-hygiene concern).
- **Rec:** defer both; Tier-1 morph already delivers the differentiator. Revisit only if a
  concrete deck needs it.

## T2-D · Walkthrough dogfood (P7)  ·  REC: owner-priority-gated
- The 05-ROADMAP names walkthrough/explainer as a day-one dogfood CONSUMER of Canvas
  (epic 688). It's a P7 track (integration into the existing walkthrough engine), not a
  Canvas-core gap. Slice when the owner pulls the walkthrough track.

## P7+ tracks (05-ROADMAP, owner-prioritized — not yet designed)
Code-export tier (Q10) · dashboards (live data) · markdown inline figures · `kind:board` ·
state-machine INTERACT escalation · plugin kits/renderers. Each is a milestone-sized track;
none designed here — they await track selection.

---

### Recommendation for the review
Greenlight **T2-A (`:hover`)** and **T2-B static input kind** as the next two slices (both
close named/demonstrated gaps at low-to-medium risk, reversible). Hold T2-B-interactive,
T2-C, T2-D, and the P7+ tracks for explicit prioritization. All owner-gated bars unchanged
(TSK-1334 pixel grant; Q-decisions review).
