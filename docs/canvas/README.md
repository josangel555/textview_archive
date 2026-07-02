# Canvas — the giga-epic design (v2 doc set)

> **Status: BUILT — the M0→M6 milestone chain is COMPLETE (all slices validated); awaiting
> owner detail-review.** (TSK-1342) The design content below is the as-designed record; see
> **§Built status** for what actually shipped. This doc set **supersedes**
> `docs/CANVAS_DESIGN.md` and `docs/CANVAS_DESIGN_CANVAS-0001.md` (both kept as history). It is
> the product of three passes: two independent design spikes (which converged) + a detailed
> analysis of the 20 salvaged research reports (`docs/research/canvas-2026-07-01/`).

## Built status (2026-07-02) — for the owner review

The full milestone chain is implemented, validated (each slice with teeth), and hardened
beyond its bar; `main` is gate-green. Q-decisions were taken at their 05-ROADMAP defaults
(provisional — rework-if-reversed is accepted); this is the review surface.

| Milestone | Delivers | State |
|---|---|---|
| **M0** patch-loop spike | E2E patch loop GO (p95 30ms < 50ms budget) | ✅ done |
| **M1** canvas-core | record store · ops+fence · tokens · lowering · DSL · io+migrations | ✅ validated |
| **M2** agent surface | 11 `canvas_*` MCP tools · agent builds a page (0% escape) | ✅ validated |
| **M3** WYSIWYG | selection · inline edit · drag-reorder · ⌘Z · inspector/layers · co-editing | ✅ validated (local lane) |
| **M4** design system + gauntlet | components · zero-op retheme · kit · table/code/chart/diagram · each-blocks · measured lint · **THE GAUNTLET: 10/10, 0% escape** | ✅ validated |
| **M5** UI-Design mode | thin-mode preset · artboards · fragment export · kit strip · prototype nav | ✅ validated |
| **M6** Presentation | deck mode · step model · `timeline_state` · JS player · identity-morph FLIP · offline+print export | ✅ validated |

**Beyond the chain (post-M6):** parser/serialization hardening (json/wire/dsl/io totality-fuzz +
io round-trip + undo-identity properties), a real perf fix (`timeline_state` O(steps×nodes)→
single-walk), **PDF deck export** (paginated print → OS Save-as-PDF), **grid layout** (`columns`
prop), vocabulary completeness (Presentation workflow + all props teachable), and the DSL
round-trip law extended over the full M5/M6 prop surface.

**A worked agent example** (everything below is authored through the DSL / `canvas_*` tools —
never raw HTML):
```
token set color.brand #1a6feb
component #card { frame #c-body fill=$color.surface padding=$space.md radius=$radius.md {
  text #c-title "Card" font=$font.h2
} }
frame #page columns=3 gap=16 padding=$space.lg {
  use #card #a override text #c-title "Fast"
  use #card #b override text #c-title "Themed"
  use #card #c override text #c-title "Reusable"
}
```
→ lowers to a 3-column themed card grid; `token set color.brand …` rethemes it live in one
patch; `canvas_export {flavor: standalone|fragment|deck|print}` ships it. Proof-of-function
lives in the UAT journeys (`CanvasUATM2/M5/M6Tests`) + `CanvasGauntletTests`.

**Still the owner's call:** (1) the Q-decisions above (taken at defaults); (2) **TSK-1334** —
grant Screen-Recording to the VM xctest runner (unblocks the T5 visual-*composite* pixel half:
morph motion, occlusion); (3) deferred Tier-2 findings — interactive input primitives, richer
morphs (path/cross-kind), L2 `:hover`/breakpoint style variants, walkthrough dogfood (P7).

## What Canvas is

A **WYSIWYG surface for agents** (and humans) to build user interfaces, infographics,
explainers, and presentations. HTML/CSS/JS is the render substrate and an export target —
**never the authoring model**. The agent authors against a typed, stable-ID **document of
records** through a small **operation API**; the system **lowers** the document to HTML/CSS/JS
live in a WKWebView; the human edits the same document through direct manipulation. Both
authors emit the same ops, so co-editing falls out of the model.

**The spirit (owner):** agent-driven · user-facing · a fundamental, extendable, **broadly
reusable core feature** — the bulk of the work is a pure engine (`canvas-core`, a rust-core
crate), not app UI. Practical and grounded: every layer reuses a proven in-app pattern
(CM6 bridge, trusted-HTML CSP, mermaid vendoring, walkthrough engine, warm WebView caches,
MCP/AutomationHost) or a proven external pattern (Figma's flat property map, tldraw's
validated store + migrations, DTCG tokens, Lottie's keyframe container, Keynote/PowerPoint
morph semantics).

## Why this is worth a giga-epic (the evidence, one paragraph)

LLM authoring against a **purpose-built high-level API** took slide-generation executability
from **2–11% (raw low-level API) to 80%+** and collapsed 170-line programs to 13 lines
(AutoPresent). LLM layout literature shows models are *specifically* bad at raw coordinates
("spatial hallucination") and *specifically* good at containment/ordering intent — which flow
layout turns into provably-overlap-free output. Production LLM-UI systems (Vercel generative
UI, Airbnb/Lyft server-driven UI, Framer's agents) all converged on "select + parameterize
from a registered vocabulary against stable IDs, patch deltas, never emit markup." Canvas is
that architecture, built once, as a foundation for many products.

## The doc set

| Doc | Contents |
|---|---|
| **`01-RESEARCH-ANALYSIS.md`** | The detailed analysis of all research: per-cluster findings → **adopt / adapt / reject / defer** verdicts with reasoning; contradictions between reports resolved; the evidence table. |
| **`02-CORE-ENGINE.md`** | `canvas-core` (the bulk of the work): document/record model, schema + migrations, ops + validation fence, selectors, tokens, components, data binding, the timeline model, lowering + DOM-patch plans, static lint, events/revisions, FFI contract, testing. |
| **`03-SHELLS.md`** | The thin shells: JS runtime (patch applier, measurement, direct manipulation, player), Swift host (persistence, MCP/verbs, SwiftUI chrome), the bridge, security envelope, app integration. |
| **`04-MODES-AND-USES.md`** | Domain modes as presets (presentation / explainer / UI design / infographic / diagram / board), the identity-morph signature feature, the wide use-case catalog, hard anti-scope boundaries. |
| **`05-ROADMAP.md`** | Phasing (P0–P6) with per-phase test gates and board decomposition, plus **the consolidated owner decision list (Q1–Q12)** — the review surface. |
| **`06-MILESTONES-UAT.md`** | Per-milestone exit validations + the T6 UAT journey scripts (the acceptance artifacts, now implemented as `CanvasUATM2/M5/M6Tests` + `CanvasGauntletTests`). |
| **`07-DSL-SPIKE.md`** | The authoring DSL spike (element/edit grammar, `#anchors`, `$tokens`, components/`use`, the round-trip law) — realised in `rust-core/…/canvas/dsl.rs`. |
| **`plans/M<N>-PLAN.md`** | The per-milestone implementation plans (slice breakdown, file-level design, test matrix, risks/kill-criteria, perf budgets) authored before each build. |

## Architecture in one diagram

```
        agent (MCP canvas_* / script verbs)         human (WYSIWYG canvas + SwiftUI chrome)
                  │      ops in, JSON/PNG out                │  gestures → ops
                  ▼                                          ▼
  ┌────────────────────────────────────────────────────────────────────────────┐
  │  canvas-core  (rust-core crate — pure, sans-IO, deterministic)             │
  │  flat record store (id → node, parentId + fractional index)               │
  │  ops + fence + undo/invert · selectors · DTCG tokens · components ·       │
  │  data binding · timeline/{a,k} · static lint · MIGRATIONS ·               │
  │  LOWERING → HTML/CSS + DOM-patch plans · export assembly · rev/event log  │
  └───────────────┬───────────────────────────────┬────────────────────────────┘
        FFI (compact binary)                      │ file: .canvas = canonical JSON
                  │                               │ {formatVersion, schema, records}
   ┌──────────────┴─────────────┐   ┌─────────────┴──────────────────────────┐
   │ Swift shell                │   │ JS runtime shell (WKWebView, vendored) │
   │ files/sessions/undo-stack  │   │ applies patch plans to the DOM         │
   │ MCP + verbs + URL scheme   │   │ measurement (geometry/lint/hit-test)   │
   │ inspector/layers/palette   │   │ direct manipulation → ops              │
   │ (SwiftUI, native)          │   │ behavior + timeline player · snapshot  │
   └────────────────────────────┘   └────────────────────────────────────────┘
```

## Reading order for review

1. `05-ROADMAP.md` §Decisions (Q1–Q12) — what we need from you.
2. `01-RESEARCH-ANALYSIS.md` — why the design is shaped this way.
3. `02-CORE-ENGINE.md` — the engine (the bulk).
4. `03-SHELLS.md`, `04-MODES-AND-USES.md` — the rest.
