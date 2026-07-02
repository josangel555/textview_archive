# Canvas · 05 — Roadmap, gates, and the owner decision list

> Slices land independently, each gate-green with tests; render slices carry their VM tail.
> Board: TSK-1342 = the epic; on green-light decompose one ticket per phase slice,
> `area:canvas`. **Nothing starts before the Q-list below is answered.**

## Phasing

- **P0 — Risk spike (1 slice).** `canvas.html` + minimal applier hosting a hardcoded record
  set; **the core↔WebView patch loop proven end-to-end** (Rust reducer → binary FFI → patch
  plan → JS applies → geometry query returns) + warm-cache park/re-attach + op→paint
  perf measured (PerfSignpost). *Kills the riskiest unknowns before any schema freeze.*
- **P1 — `canvas-core` document core.** Records/`place`/fractional index · per-type schemas +
  defaults + validation fence · ops + inverses + revisions · migrations skeleton · DTCG token
  store · static lint v1 · deterministic lowering + patch plans · `hole` + `embed` nodes ·
  canonical `.canvas` I/O (Swift store glue + Codable mirrors) · `source` ViewMode (JSON in
  CM6, free). Gates: cargo (proptest invariants + fence fuzz + golden lowering) + host Swift.
- **P2 — Agent surface.** MCP `create/open/apply/query/lint/events/export(HTML)` + script
  verbs + URL scheme; compact query wire form; plan-then-emit guidance; audit trail + tab
  indicator. **Earliest payoff: agents build static pages end-to-end.** Gates: MCP fake-host
  tests; T6 script journey.
- **P3 — WYSIWYG.** Selection/handles/drag/resize/inline text → ops; snap/guides; native
  inspector + layers + palette; shared undo; rev-conflict protocol + locks. Gates: webview
  lane (applier/measurement), T5 handles+occlusion with negative controls.
- **P4 — Design system + data.** Components/instances + first kits (report, KPI/infographic);
  `table`/`chart`(Vega-Lite subset)/`code`/`diagram` nodes; data blocks + `bind` +
  `conditional`/`repeat`; measured lint; CSV-engine + FileWatcher feeds. Gates: cargo + webview.
- **P5 — UI-Design mode, Tier 1 (first mode; owner criterion: earliest assumption
  validation).** UI component kit (buttons/inputs/nav/cards/forms), device-frame page presets,
  prototype navigation + interactions (behaviors + `conditional`), shared style rules
  (ladder L2: `:hover` + breakpoint variants), the **Claude-Design gauntlet** as the
  acceptance bar (see §Q1-rationale addendum). NO code export (that's the later tier, Q10).
  Gates: webview interactions + T5 with negative controls + T6 prototype journey.
- **P6 — Presentation mode.** `kind:deck`, steps/fragments, timing tree + beats,
  **identity-morph transitions**, `timeline_state` query, player, presenter window, deck
  export (standalone player + PDF); walkthrough verbs (explainer). Gates: webview player
  tests + T5 fragment/morph pixels + T6 deck journey.
- **P7+ — Tracks by owner priority.** Code-export tier (Q10) → dashboards (live data) →
  markdown inline figures → `kind:board` → state-machine INTERACT escalation → plugin
  kits/renderers (code components).

## Standing engineering rules (from the analysis — bind all phases)

Flow-first layout, no solver ever · ops only through the fence · migrations with every schema
change · tier-2 token discipline · one-way disposable codegen · documents are data, not
programs · geometry is renderer-owned and only reported · text-JSON canonical format (git +
diff viewer stay useful) · feedback ladder cheap→dear (query → static lint → timeline state →
measured lint → snapshot) · every render guard demonstrates teeth (negative controls).

## The owner decision list (Q1–Q12) — the review surface

| # | Decision | Recommendation / status |
|---|---|---|
| Q1 | First mode | ✅ **DECIDED (owner criterion, 2026-07-01: "pick whichever validates our assumptions earliest") → UI-Design, Tier 1 (wireframe + clickable prototype, NO code export).** It stress-tests the two riskiest assumptions (Q13 CSS ladder; the seed vision "agent inserts elements instead of writing HTML for UI") earliest; Presentation's subsystems (TIME/morph) are lower-risk (proven prior art) and move to M6. Addendum in §Q1-rationale. |
| Q2 | Format & interface language | **SPLIT per owner (2026-07-01):** (a) serialization = canonical JSON `.canvas` — **DECIDED, fine**; (b) the agent *interface language* is NOT settled — JSON ops are wrong for multi-turn incremental patching. → **Q2b spike (TSK-1350):** terse Canvas DSL + projection editing over the op layer (`02-CORE-ENGINE.md` §4b). Blocks M2. |
| Q3 | Spatial kinds | Page/deck first; `board` later. Rider: 10³⁺-node boards trigger a rendering-backend fork decision *only if prioritized*. |
| Q4 | Dependencies | ✅ **DECIDED (owner, 2026-07-01): zero new deps v1** — hand-rolled vendored runtime, hand-rolled SVG chart marks, no layout engine (browser computes), no charting lib. Per-layer dep proposals return as parked asks only when scope demands. |
| Q5 | `embed` ceiling | HTML/CSS-only v1 (sandboxed iframe, no script); script-bearing embeds = explicit future owner decision. |
| Q6 | Assets | Single-file base64 ≤ ~2 MB; sidecar `X.canvas-assets/` beyond. |
| Q7 | Content-write MCP precedent | Op fence + tab indicator + events audit trail; **no per-document human grant** (friction kills the loop). |
| Q8 | Naming | "Canvas" (*File ▸ New Canvas*). |
| Q9 | FLOW / text pagination | **Defer.** v1 reports = multi-page with manual breaks; `kind:flow` stays additive for a future docs/reports track (the thing every canvas tool punts on — deliberate, revisitable). |
| Q10 | Code export | Semantic HTML/CSS first, one-way/disposable; framework target (React/SwiftUI/…) chosen when the UI-Design track starts. Multi-framework codegen rejected at v1 (Lona/Mitosis evidence). |
| Q11 | **Engine placement** | ✅ **DECIDED (owner, 2026-07-01): `canvas-core` as a rust-core crate.** |
| Q12 | Presenter mode second window | Confirm an AppKit presenter window is acceptable (the app is deliberately window-frugal; it's deck-mode-only, user-invoked). |
| Q13 | **CSS expressiveness / escape-hatch ladder** | Owner concern (2026-07-01): CSS may be impossible to fully encapsulate; Claude-Design-class complexity must stay reachable. **Design answer adopted:** don't encapsulate — *grade* it. The 5-rung ladder in `02-CORE-ENGINE.md` §3b (closed props → raw-CSS passthrough → shared style rules → embed → code components), lint steering to the lowest sufficient rung. Confirm the ladder. |

### Q1-rationale — what "first mode" decides, and why Presentation

M0–M4 are **mode-agnostic foundation** either way (core, agent surface, WYSIWYG, components,
data). Q1 only decides *what M5 ships as the first complete user-facing product* and which kit
gets polished first:

- **Presentation (recommended):** cleanest core fit — pages + steps + TIME, no code-export
  hard mile, no live-data dependency, the *least* CSS-expressiveness pressure (slides are
  self-contained fixed pages). Immediate in-app value chain: OwnerWishlist P6 ("walkthrough as
  a presentation — slides, docs, source code, terminal") + epic 688 make the Walkthrough
  system a day-one dogfood consumer. Showcases the identity-morph differentiator. Its export
  (self-contained player) is infrastructure every other mode reuses.
- **UI-Design first (the alternative):** the biggest strategic prize (Claude-Design-like), but
  it front-loads the three hardest problems simultaneously — code export, full-CSS
  expressiveness (Q13), richest component kit + responsive breakpoints. Better attacked from a
  proven core. **Note it is not actually delayed much:** M3 (interactions) + M4 (components)
  ARE its foundation; wireframe + clickable-prototype tiers become possible immediately after
  M4 even with Presentation as M5.
- **Infographics first:** needs M4's DATA layer anyway; simple export; but no in-app dogfood
  consumer and no differentiator showcased.

**ADDENDUM — the decision, under the owner's criterion (2026-07-01).** The owner picked the
selection criterion, not the mode: *"whichever validates our assumptions earliest."* That
flips the answer to **UI-Design Tier 1**. Honest risk ranking of the epic's assumptions:

| Assumption | Risk | Validated earliest by |
|---|---|---|
| Op/DSL surface makes agents effective authors | med (strong evidence, unproven here) | M2 — mode-agnostic |
| Patch loop + perf over binary FFI | med | M0 — mode-agnostic |
| **CSS ladder suffices for Claude-Design-class output (Q13)** | **HIGHEST — the industry graveyard (80/20 ceiling); owner's own stated doubt** | **UI-Design content only** |
| Auto-layout + components carry real UI design | high | UI-Design content only |
| TIME/steps/morph work | low-med (reveal/WAAPI/FLIP = proven prior art; morph is a set-diff over IDs we control) | Presentation |

Presentation validates the *low-risk* mode assumptions; UI-Design validates the *make-or-break*
ones. If the CSS-ladder assumption fails, the epic's flagship pillar needs redesign — we must
learn that at M4/M5, not after shipping decks. Cost accepted: walkthrough dogfood + the morph
showcase defer one milestone (Presentation = M6; its core subsystems TIME/beats/timeline_state
still land in M4/M5 where prototypes need interactions).

**Pulled-forward validation — the "Claude-Design gauntlet" (new M4 exit criterion):** the
agent replicates 2–3 real-world-complexity designs (a marketing landing page, a settings
screen, a dashboard shell) through the ladder; we measure the rung distribution (% of styling
at L0/L1/L2 vs escaping to L3/L4), op/token cost per design, and lint noise. **Pivot
criterion: if >~30% of styling pressure lands in embed/code-components, the ladder gets
redesigned before the UI-Design mode ships.** This is the epic's cheapest early kill-switch
for its riskiest assumption.

## Success criteria for the epic's first release (P0–P5)

1. An agent builds a themed, data-bearing deck **entirely through ops** — no HTML authored.
2. The human reorders/retitles slides WYSIWYG; the agent sees those edits in `canvas_events`
   and continues without clobbering (co-editing demonstrated).
3. Morph transitions play identity-exact; `timeline_state` verifies steps declaratively before
   any pixel check.
4. Export produces a single self-contained HTML deck that plays offline.
5. Every layer gate-green in its lane (cargo / host / webview / T5-with-teeth / T6 journey);
   `main` never carries a red gate.
