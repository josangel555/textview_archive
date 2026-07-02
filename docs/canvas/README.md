# Canvas — the giga-epic design (v2 doc set)

> **Status: DESIGN — blocked on owner review. Nothing implemented.** (TSK-1342)
> This doc set **supersedes** `docs/CANVAS_DESIGN.md` and `docs/CANVAS_DESIGN_CANVAS-0001.md`
> (both kept as history). It is the product of three passes: two independent design spikes
> (which converged) + a detailed analysis of the 20 salvaged research reports
> (`docs/research/canvas-2026-07-01/`).

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
