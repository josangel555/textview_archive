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
- **P5 — Presentation (first mode).** `kind:deck`, steps/fragments, timing tree + beats,
  **identity-morph transitions**, `timeline_state` query, player, presenter window, deck
  export (standalone HTML player + PDF); walkthrough verbs (explainer). Gates: webview player
  tests + T5 fragment/morph pixels + T6 deck journey.
- **P6+ — Tracks by owner priority.** UI-Design kit + prototype behaviors → dashboards
  (live data) → markdown inline figures → `kind:board` → state-machine INTERACT escalation →
  code export tier → plugin kits/renderers (code components).

## Standing engineering rules (from the analysis — bind all phases)

Flow-first layout, no solver ever · ops only through the fence · migrations with every schema
change · tier-2 token discipline · one-way disposable codegen · documents are data, not
programs · geometry is renderer-owned and only reported · text-JSON canonical format (git +
diff viewer stay useful) · feedback ladder cheap→dear (query → static lint → timeline state →
measured lint → snapshot) · every render guard demonstrates teeth (negative controls).

## The owner decision list (Q1–Q12) — the review surface

| # | Decision | Recommendation |
|---|---|---|
| Q1 | First mode | **Presentation** (epic 688 + wishlist P6; both spikes + evidence converge). |
| Q2 | File extension | `.canvas` + `textview.canvas/v1` discriminator (Obsidian collision is disambiguated by the discriminator). |
| Q3 | Spatial kinds | Page/deck first; `board` later. Rider: 10³⁺-node boards trigger a rendering-backend fork decision *only if prioritized*. |
| Q4 | Dependencies | **Zero new deps v1** — hand-rolled vendored runtime, hand-rolled SVG chart marks, no layout engine (browser computes), no charting lib. Per-layer dep proposals return as parked asks only when scope demands. |
| Q5 | `embed` ceiling | HTML/CSS-only v1 (sandboxed iframe, no script); script-bearing embeds = explicit future owner decision. |
| Q6 | Assets | Single-file base64 ≤ ~2 MB; sidecar `X.canvas-assets/` beyond. |
| Q7 | Content-write MCP precedent | Op fence + tab indicator + events audit trail; **no per-document human grant** (friction kills the loop). |
| Q8 | Naming | "Canvas" (*File ▸ New Canvas*). |
| Q9 | FLOW / text pagination | **Defer.** v1 reports = multi-page with manual breaks; `kind:flow` stays additive for a future docs/reports track (the thing every canvas tool punts on — deliberate, revisitable). |
| Q10 | Code export | Semantic HTML/CSS first, one-way/disposable; framework target (React/SwiftUI/…) chosen when the UI-Design track starts. Multi-framework codegen rejected at v1 (Lona/Mitosis evidence). |
| Q11 | **Engine placement** | **`canvas-core` as a rust-core crate** (owner core-first directive + reusable-core decision + no new Swift-engine port debt + wasm/remote goals + compact-binary FFI). Confirm — this shapes P1 entirely. |
| Q12 | Presenter mode second window | Confirm an AppKit presenter window is acceptable (the app is deliberately window-frugal; it's deck-mode-only, user-invoked). |

## Success criteria for the epic's first release (P0–P5)

1. An agent builds a themed, data-bearing deck **entirely through ops** — no HTML authored.
2. The human reorders/retitles slides WYSIWYG; the agent sees those edits in `canvas_events`
   and continues without clobbering (co-editing demonstrated).
3. Morph transitions play identity-exact; `timeline_state` verifies steps declaratively before
   any pixel check.
4. Export produces a single self-contained HTML deck that plays offline.
5. Every layer gate-green in its lane (cargo / host / webview / T5-with-teeth / T6 journey);
   `main` never carries a red gate.
