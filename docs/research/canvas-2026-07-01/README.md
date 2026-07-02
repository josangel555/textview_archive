# Canvas design research — salvaged fan-out results (2026-07-01)

**Provenance:** these are the final reports of the canvas-related research subagents from the
2026-07-01 runaway fan-out (see `LESSONS.md` 2026-07-01; raw transcripts:
`~/canvas-subagent-salvage-2026-07-01/`). Salvaged at the owner's request, mined 2026-07-01,
and folded into **`docs/CANVAS_DESIGN.md` §0.5/§0.6** (the deltas) — read that first; this
folder is the per-dimension detail + citations. Findings carry citations but were **not**
independently re-verified; each report flags its own UNVERIFIED items.

## The decision-relevant reports (read these)

| File | One-line takeaway |
|---|---|
| `document-models-scene-graphs.md` | **Flat record map + `parentId` + fractional index is the load-bearing choice** (tldraw/Figma) — O(1) reparent, patch-friendly, CRDT-ready; parent+order must be one atomic property; Framer compresses its IR for agent token cost. |
| `layout-abstractions-blind-agents.md` | **Flow/flex eliminates overlap *by construction*; absolute coordinates are the documented LLM weakness; constraint solvers fail *silently* (never add one).** Flow safety is statically provable without rendering. |
| `design-tokens-theming.md` | **Adopt W3C DTCG 2025.10** token JSON; three tiers; constrain the agent to semantic references; deprecate-and-alias renames; compile to CSS custom properties. |
| `ui-description-languages-machine-irs.md` | The umbrella synthesis: typed-node tree + tokens + registered component vocabulary + declarative bindings is the *convergent* shape (UIDL/Plasmic/Mitosis/SDUI/v0); one-way codegen; escape hatch first; **plan free-form, emit schema-constrained**; close the render loop. |
| `explorables-llm-ui-generation.md` | **AutoPresent: a high-level DSL took LLM slide-gen executability from 2–11% → 80%+** — the empirical backbone of the whole epic. LLMs are bad at raw SVG/coordinates; "meet the training distribution" (CSS-like vocab wins). |
| `tldraw-programmatic-authoring.md` | The closest engineering blueprint: headless validated store, `{version, schema, records}` file, mandatory up/down migrations, branded fractional `IndexKey`s, two-write-tier footgun (ops must accept partials + fill defaults). |
| `animation-motion-representations.md` | Four animation paradigms; **Lottie's `{a,k}` every-property-is-constant-or-keyframed container** is the IR archetype; **MoVer's synthesize→verify loop took motion correctness 58.8%→93.6%**; derived/bound values are the hard-to-WYSIWYG fourth paradigm. |
| `scene-identity-timeline-transitions.md` | **Keynote Magic-Move / PowerPoint Morph are identity-matching heuristics — our stable IDs make morph transitions deterministic** (signature feature); SMIL `par/seq/excl` timing-container algebra; Rive's type-tagged forward-compatible format + state-machine altitude. |
| `projectional-editing-content-addressed.md` | The structured-editing graveyard (Intentional, Darklang) — **the ergonomic tax falls on humans hand-driving structure; a WYSIWYG projection + agent-authored model dodges it**, but you inherit diff/merge/search obligations (keep the format text/git-friendly); Unison content-hashing → subtree render caching; Hazel typed holes → placeholder nodes. |
| `semantic-to-visual-cross-domain.md` | Semantic vs layout models don't round-trip (decide per-property who owns it); the topological-naming trap (never reference by ordinal); **retained-mode declarative data beats executable models** (PDF-over-PostScript). |
| `declarative-grammars-constraint-layout.md` | Vega-Lite as chart-IR template; Penrose/Bluefish (constraint diagramming — defer); **combinator layout (envelope/trace, SwiftUI-style) is the deterministic third path**; Idyll = the closest prior art for explainers; 2024–26 literature converges on "LLM authors via DSL mediation". |
| `slides-revealjs-impressjs.md` | reveal.js = flow + fragments + `sync()` (LOW agent friction — validates our model); impress.js = absolute 3D coordinates (HIGH friction — the anti-pattern). |
| `use-case-catalog.md` | ~60 use-cases / 11 families + distortion analysis (already folded into CANVAS_DESIGN §9/§10). |
| `music-engraving-lowering.md` | LilyPond/MEI/SMuFL lowering patterns (already folded into CANVAS_DESIGN §3). |

## Supporting tool deep-dives
`fabricjs-canvas-library.md` · `konvajs-canvas-library.md` · `framer-visual-builder.md` ·
`webflow-visual-builder.md` · `diagram-as-code.md` · `slides-frameworks-batch2.md`
