# Agent a3625795254408581.output

## Prompt (first 300 chars)
I'm researching a design problem and need genuine, fresh web research with primary sources.

The design problem: someone is building a system where AI agents (and humans) author visual documents — user interfaces, infographics, slide presentations, and animated explainers — in a WYSIWYG canvas whose

## Final message

Research complete. Here are my findings, organized by cluster, with concrete data-structure detail and honest maturity notes for each system.

---

# Declarative grammars & constraint-based layout — for an author-facing IR that compiles to HTML/CSS/JS

**The through-line for your problem:** every mature system here refuses to let authors touch pixels directly. They split the artifact into (a) *content/intent* (what exists, what relates to what, what maps to what) and (b) *a solver/compiler* that turns intent into geometry. The recurring architectural choice is **where** the "figure out the pixels" step lives — a fixed layout algorithm (grammar of graphics, DOT), a numerical optimizer (Penrose, Charticulator), or a linear constraint solver (Cassowary/Auto Layout). That choice is the main design lever for you.

---

## Cluster A — The grammar-of-graphics lineage (map data → visual channels)

### 1. Wilkinson's *Grammar of Graphics*
- **What:** The 1999 book that reframed "a chart" not as a picked-from-a-menu type (bar/pie/line) but as a *composition of orthogonal components*. It's the intellectual root of nearly everything else here.
- **Model:** A graphic is specified by components — **Data → Trans (transform) → Scale → Coord (coordinate system) → element/geom (marks) + aesthetics (guides)**. Crucially there is *no "bar chart" primitive*; a bar chart is `interval` geom + Cartesian coord, and switching coord to polar yields a pie/coxcomb from the *same spec*. ([Wikipedia](https://en.wikipedia.org/wiki/Wilkinson's_Grammar_of_Graphics), [ggplot2 book: The Grammar](https://ggplot2-book.org/mastery))
- **Why it matters:** This is the canonical proof that a small orthogonal component algebra can express a combinatorial explosion of artifacts. For an authoring IR, "expose orthogonal knobs, not a type menu" is the key transferable idea.
- **What breaks / maturity:** Fully mature *as a theory*; Wilkinson's own concern was that the pure grammar is abstract and hard to map to an ergonomic API — which is exactly why Wickham's *layered* grammar exists (below).

### 2. Layered grammar of graphics / ggplot2 (Wickham)
- **What:** The pragmatic re-cut of Wilkinson that made the grammar usable, and defines the "+ layer" mental model most people know.
- **Model:** A plot = **a default dataset + aesthetic mappings**, **one or more layers** (each = a *geom* + a *statistical transformation* + a *position adjustment*), **one scale per aesthetic**, **a coordinate system**, and **a faceting spec**. ([A Layered Grammar of Graphics, Wickham PDF](https://byrneslab.net/classes/biol607/readings/wickham_layered-grammar.pdf), [vita.had.co.nz](https://vita.had.co.nz/papers/layered-grammar.html))
- **Why it matters:** It shows the value of a *default-and-override* structure (a top-level default dataset/mapping that layers inherit and locally override) — great for AI authors, who can emit a minimal spec and refine incrementally.
- **What breaks:** It's tabular-data-shaped; it does not model free-form diagrams, UI, or narrative — it assumes "rows → marks."

### 3. Vega-Lite — the JSON grammar that's the closest existing template for your IR
- **What:** A high-level *declarative JSON* grammar of interactive graphics (Satyanarayan et al., IEEE InfoVis 2017). This is probably the single most directly relevant artifact to study, because it's (a) a machine-authorable JSON IR, (b) it *compiles down* to a lower-level runtime, and (c) it's already the de-facto target for LLM chart generation.
- **Model (concrete):** A **unit spec** = `{ data, transform, mark, encoding }`, where `encoding` maps *data fields → visual channels* (`x`, `y`, `color`, `size`, `shape`, …), each channel carrying a field + type + scale. Interaction is modeled by **selections** — enumerable semantic units (point / list / interval) that parameterize encodings, scale extents, or conditional logic. Multi-view artifacts come from a **view-composition algebra**: `layer`, `concat` (h/v), `facet` (trellis), `repeat` — and these nest recursively. ([Vega-Lite paper PDF](https://idl.cs.washington.edu/files/2017-VegaLite-InfoVis.pdf), [morning paper summary](https://blog.acolyer.org/2019/10/21/a-grammar-of-interactive-graphics/), [docs](https://vega.github.io/vega-lite/docs/))
- **Why it matters:** It's an existence proof that a *concise JSON spec* + *a compiler* is enough to author rich interactive visuals — and the composition algebra (layer/concat/facet/repeat) is a clean model for building "an infographic panel out of sub-panels." The selection abstraction is a rare example of modeling *interaction* declaratively.
- **What breaks:** By design it trades expressiveness for concision — anything outside the "Cartesian plot with channel encodings" frame (bespoke non-tabular layouts, hand-placed annotations) forces you down to full Vega. The compiler makes layout/interaction decisions *for* you, which is great until you need a pixel-exact result it won't produce.

### 4. Vega (the layer *below* Vega-Lite) — a reactive dataflow graph as IR
- **What:** The lower-level grammar Vega-Lite compiles into. Important for you because it demonstrates a *different* kind of IR — not a static tree but a **reactive dataflow graph**.
- **Model (concrete):** The spec parses into a **dataflow graph of operators** (data sources → transforms → scales → marks). The radical move ("Reactive Vega"): **input data, scenegraph elements, and interaction events are ALL first-class streaming data**. Events become **signals** composed into expressions; the scenegraph itself is modeled as data tuples that can feed *further* encoding ("reactive geometry"). On an event, changesets are "pulsed" through the graph in topological order, with unchanged branches pruned. ([Reactive Vega, morning paper](https://blog.acolyer.org/2015/12/11/reactive-vega/), [vega.github.io/vega](https://vega.github.io/vega/))
- **Why it matters:** If your artifacts are *interactive/animated* (UIs, explainers), a reactive dataflow IR gives you incremental re-render and a uniform treatment of "data changed" vs "user interacted" vs "scene updated" — you don't hand-write event handlers, you declare dependencies. This is arguably a better model than a static scene tree for the animated/interactive legs of your use case.
- **What breaks:** Dataflow graphs are heavier to author by hand (hence Vega-Lite sitting on top), and can be hard to reason about / debug when signals interact. Server-side scaling issues spawned a whole follow-up (VegaFusion).

### 5. Observable Plot — the "concise API" data point
- **What:** Bostock's JS library, explicitly a layered grammar of graphics as a *practical* tool.
- **Model:** Rejects a chart typology entirely — only **marks, scales, and transforms**. Transforms are functions taking mark channels+options and returning new channels+options (e.g. bin→histogram, group→bar). ([GitHub README](https://github.com/observablehq/plot/blob/main/README.md), [Observable Plot in practice](https://data.europa.eu/apps/data-visualisation-guide/grammar-of-graphics-in-practice-observable-plot))
- **Why it matters:** Confirms the "marks + scales + transforms, no chart types" decomposition is the stable core across a decade of independent re-implementations (ggplot2, Vega-Lite, Plot). If you converge on a grammar, that triple is the load-bearing part.

---

## Cluster B — Content/style separation + solver-produced geometry (the diagramming frontier)

### 6. Penrose (CMU) — the cleanest content/style split, layout as optimization
- **What:** "From Mathematical Notation to Beautiful Diagrams" (SIGGRAPH 2020). Generates diagrams from an abstract description by *optimizing* a layout. The most rigorous separation-of-concerns design in this whole survey.
- **Model (concrete — three languages):**
  - **Domain** (`.domain`): the vocabulary — `type Set`, `predicate IsSubset(Set, Set)`, functions. Defines what *kinds* of things and relations can exist.
  - **Substance** (`.substance`): the *content* — declares instances and relations: `Set A, B; IsSubset(B, A)`. Notation-like, close to how a mathematician writes.
  - **Style** (`.style`): the *visualization* — pattern-matches Substance objects and assigns shapes (`Circle`, etc.), then declares layout as **`ensure`** (hard constraints, satisfied `≤0` or not) and **`encourage`** (soft objectives, minimize "badness"). Example primitives: containment `d − (r₁−r₂) < 0`, disjointness, `repel` = `1/d²`. ([SIGGRAPH PDF](https://www.cs.cmu.edu/~kmcrane/Projects/Penrose/Penrose_SIGGRAPH.pdf), [docs/ref](https://penrose.cs.cmu.edu/docs/ref), [constraints ref](https://penrose.cs.cmu.edu/docs/ref/constraints))
  - **Solver:** all shape params become variables in an **energy function Φ**; layout = **gradient-based numerical optimization** (uses `∇Φ` via **automatic differentiation**); finds a *local* minimum. ([constraints ref](https://penrose.cs.cmu.edu/docs/ref/constraints))
- **Why it matters — a lot for you:** The Domain/Substance/Style split is *exactly* the "author declares intent, style layer + solver produce pixels" model you want. The killer property: **the same Substance can be rendered by a completely different Style** (sets as circles *or* as a tree of inclusions) — total content/appearance decoupling. And "add a shape → it re-solves to satisfy all constraints" is the anti-hand-placement property.
- **What breaks / maturity — read this carefully:**
  - Their own docs say Penrose is *"an early-stage system... not ready for contributions or public use yet."* ([siggraph20 page](https://penrose.cs.cmu.edu/siggraph20))
  - It optimizes to a **local minimum**, so results are **non-deterministic and can be surprising / ugly**; the paper leans into this by *generating multiple candidate diagrams* rather than one canonical answer — because "best" is subjective. ([siggraph20](https://penrose.cs.cmu.edu/siggraph20))
  - Every constraint must be **differentiable** (autodiff), which shapes/limits what you can express. Convergence/perf guarantees are not stated in the docs I could read (**UNVERIFIED** on runtime cost).

### 7. Bluefish (MIT, Josh Pollock et al., UIST 2024) — relations instead of components
- **What:** A diagramming framework that borrows from component UI libraries but *relaxes* the component idea into **relations**. The freshest rethink of "how do you compose a diagram."
- **Model (concrete):** A **relation** = a declarative, composable, extensible diagram fragment. The two ways it relaxes a UI component: (a) a relation **does not need exclusive ownership of its children**, and (b) it **need not fully specify layout**. To support this, Bluefish extends the usual **tree scenegraph into a compound graph** capturing *both* hierarchy *and* adjacency; **references** let one element participate in *multiple* relations, and **constraints** specify layout. ([arXiv abstract](https://arxiv.org/abs/2307.00146), [MIT vis page](https://vis.csail.mit.edu/pubs/bluefish/), [thesis "A Grammar of Discrete Diagrams" PDF](https://dspace.mit.edu/bitstream/handle/1721.1/144944/Pollock-jopo-SM-EECS-thesis.pdf))
- **Why it matters:** This is the answer to a real problem your IR *will* hit: strict scene *trees* force every element to have exactly one parent, but real diagrams have elements that belong to many overlapping perceptual groups (a node that's both "in the cluster" and "on the critical path"). Bluefish's compound-graph + references model is a principled fix. Its thesis framing — "perceptual groups visualize discrete relations" — is a good conceptual anchor.
- **What breaks / maturity:** Explicitly positioned as *"both a usable tool and a research platform"* — i.e. active research, not production. The **specific layout solver is not confirmed** in the sources I fetched (relations "use constraints" but the solver identity is **UNVERIFIED** — the thesis likely specifies it).

### 8. Charticulator (Microsoft Research, IEEE VIS 2018) — WYSIWYG that emits a constraint spec
- **What:** An interactive, no-code tool for *bespoke* chart layouts — the WYSIWYG-front-end-over-a-constraint-solver pattern, which is *precisely your canvas → IR → output stack*.
- **Model (concrete):** The user's direct-manipulation actions are compiled into **mathematical layout constraints**; a **constraint-solving algorithm** computes the concrete layout attributes. Authors build **glyphs (compound marks)** and **links** between them without ever seeing the constraints. Output is an **exportable reusable template** (importable into Power BI etc.). ([MSR publication](https://www.microsoft.com/en-us/research/publication/charticulator-interactive-construction-of-bespoke-chart-layouts-2/), [paper PDF](https://donghaoren.org/publications/infovis18-charticulator.pdf), [GitHub](https://github.com/microsoft/charticulator))
- **Why it matters:** It's the closest existing thing to "WYSIWYG canvas → declarative spec → portable output" for infographics specifically. The design lesson: the constraint spec is the *saved artifact / IR*, and the GUI is just one editor of it — meaning an AI agent could emit the *same* spec the GUI does. That "GUI and agent author the same IR" property is exactly what you want.
- **What breaks:** Constraint solving over bespoke layouts can be under-constrained (many valid solutions) or produce non-obvious results; the exact solver internals aren't detailed in the sources I read (**UNVERIFIED** which solver / how it handles the bilinear cases).

---

## Cluster C — Constraint-based layout lineage ("declare relations, solver produces geometry")

This is the deepest and oldest vein, and it carries the clearest *honest warnings*.

### 9. Sketchpad (Sutherland, 1963) — the origin
- **What/Model:** The first system where users *declared relations* (parallelism, coincidence, equal length) and the machine *maintained* them while you edited — plus recursive subpictures (reusable components) and a ring data structure. ([Sketchpad, Wikipedia-style history](https://novedge.com/blogs/design-news/design-software-history-ivan-sutherlands-sketchpad-pioneering-the-evolution-of-computer-aided-design-and-interactive-graphics), [instadeq writeup](https://instadeq.com/blog/posts/no-code-history-sketchpad-a-man-machine-graphical-communication-system-1963/))
- **Why it matters:** Every "specify intent, solver fills in geometry" system is a descendant. The reusable-subpicture idea = your "components."

### 10. ThingLab (Borning, late 1970s, Smalltalk) — constraints + part/whole hierarchy
- **What/Model:** Generalized Sketchpad into a constraint *laboratory*; integrated constraints with **part-whole hierarchies** and the class hierarchy ("kit-building kit"). ([cdglabs/thinglab](https://github.com/cdglabs/thinglab))
- **Why it matters:** First serious marriage of *constraints* with *object composition* — relevant if your IR is component-tree-shaped but wants cross-cutting constraints (cf. Bluefish's compound graph rediscovering this).

### 11. Cassowary (Badros, Borning, Stuckey, TOCHI 2001) — the workhorse solver
- **What:** *The* linear-arithmetic constraint solver behind real UI layout at scale.
- **Model (concrete):** Handles **linear equalities and inequalities** (e.g. "window A left-of B", "pane = leftmost ⅓"). Supports a **constraint hierarchy** with **strengths (required / strong / medium / weak)**: stronger constraints dominate weaker; non-required ones are *preferences*. Algorithm: **incremental dual simplex**, tuned so *re-solving on edit* (drag/resize) is fast rather than a full re-solve. ([TR](https://constraints.cs.washington.edu/solvers/cassowary-tr.html), [TOCHI PDF](https://constraints.cs.washington.edu/solvers/cassowary-tochi.pdf), [Wikipedia](https://en.wikipedia.org/wiki/Cassowary_(software)))
- **Why it matters:** It's the proven engine for "relative intent" ("keep 8px gap", "align these", "prefer this size") that survives window/viewport resize — which is what you want if your HTML output must be responsive. Widely reported to underlie **Apple Auto Layout / iOS & macOS** ([Wikipedia](https://en.wikipedia.org/wiki/Cassowary_(software)); commonly stated, treat the "powers Auto Layout" claim as strongly-reported rather than officially-specced).
- **What breaks:** **Linear only** — no multiplication/division of two constrained variables (no aspect-ratio-as-product, no nonlinear). Constraint hierarchies resolve conflicts, but *which* required constraint gets broken can be surprising (see Auto Layout below).

### 12. Constraint CSS / Grid Style Sheets (GSS) — Cassowary in the browser
- **What:** A CSS-preprocessor + JS runtime that *replaced the browser layout engine* with Cassowary.js. The most direct "constraints → web output" experiment.
- **Model (concrete):** Constraints written as `selector[property] operator value` with strengths: `p[line-height] <= ::window[height] / 12`; `#light[years] == 300 !strong`. Strengths `!weak / !medium / !strong / !require`, with `!require` risking system failure on conflict. Ran the solver in Web Workers, applied results via Matrix3D transforms. ([Constraint CSS guide](https://gss.github.io/guides/ccss), [SitePoint intro](https://www.sitepoint.com/introducing-gss-grid-style-sheets/), [GSS 2.0, bram.us](https://www.bram.us/2015/09/29/grid-style-sheets-2-0/))
- **Why it matters:** It's the cautionary *and* inspirational precedent for exactly your target (declarative constraints compiling to positioned DOM). The syntax is a clean template for a human/agent-writable constraint DSL.
- **What breaks:** Same linear-only limit ("everything except multiplication/division of two constrained variables"). And note: GSS is a **research/experimental project**; I **could not verify** its current maintenance status or that modern CSS Grid/Flexbox superseded it (**UNVERIFIED** — but it is not a mainstream production tool today).

### 13. Apple Auto Layout + Visual Format Language (VFL) — the shipped-at-scale version, and its scars
- **What/Model:** `NSLayoutConstraint`s (`attr1 = m·attr2 + c`, with priorities) solved by a Cassowary-family engine. VFL adds an **ASCII-art string DSL**: `H:|-[view1]-[view2]-|` reads as "superview edge, gap, view1, gap, view2, gap, edge." ([VFL guide](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/VisualFormatLanguage.html))
- **Why it matters — the honest-limitations goldmine:** Apple documents the two failure modes of constraint layout at production scale, which you *will* inherit if you go constraint-based:
  - **Unsatisfiable layouts:** conflicting required constraints → the system is *forced to break one*, and "the effect... can vary greatly from layout to layout, or even from build to build." ([Unsatisfiable Layouts](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/ConflictingLayouts.html))
  - **Ambiguous layouts:** under-constrained → the system *picks one solution arbitrarily*, "may even change between launches." ([Ambiguous Layouts](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/AmbiguousLayouts.html))
  - Debugging is hard: "Interface Builder cannot detect all possible ambiguities; many errors can be found only through testing." ([Debugging Tricks](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/DebuggingTricksandTips.html))
  - **Takeaway for an AI author:** a partial/loose constraint set doesn't error — it silently produces a *plausible but arbitrary* layout that can differ run-to-run. That non-determinism is dangerous when the author is an LLM that won't notice.

### 14. Auckland Layout Model (ALM) — "tabstops," and soft constraints done right
- **What/Model:** Constraint GUI layout where the primitives are **tabstops** — virtual horizontal/vertical grid lines — with **linear equalities/inequalities** on them, solved via **linear programming**. Notably it **auto-translates soft constraints into hard constraints + objective-function terms**, and gives areas domain-specific min/max/preferred sizes. ([ALM site](https://aucklandlayout.sourceforge.net/), [Springer: Domain-Specific High-Level Constraints](https://link.springer.com/article/10.1007/s10601-008-9043-2), [Auckland Layout Editor PDF](https://www.semanticscholar.org/paper/The-auckland-layout-editor:-an-improved-GUI-layout-Zeidler-Lutteroth/e2b3a211423ee597566ee1f8571d1263c05fc33b))
- **Why it matters:** The **tabstop abstraction** is an elegant middle layer between raw coordinates and free constraints — align to shared virtual lines, not to each other pairwise. That's more author-legible (and more like how designers think in grids) than a soup of pairwise constraints, while still being solver-backed. The soft→hard translation is a reusable technique.
- **What breaks:** ALM is a research artifact (implementations for .NET/Java/Haiku; the reference GitHub is marked **deprecated** — [AucklandHCI/ALM-deprecated](https://github.com/AucklandHCI/ALM-deprecated)). Maturity = academic.

---

## Cluster D — Diagram-as-text with fixed auto-layout algorithms

These skip constraint *optimization* for **specialized layout algorithms** — faster and more predictable, less flexible.

### 15. Graphviz / DOT
- **What/Model:** DOT text (`a -> b; b -> c;`) → the `dot` engine runs the **Sugiyama-style layered algorithm, in Gansner et al.'s 4-pass form**: (1) assign nodes to discrete **ranks** via a **network-simplex** integer program minimizing edge length; (2) **order** within ranks to cut crossings; (3) assign **coordinates**; (4) compute **spline** control points for edges. ([Gansner TSE93 PDF](https://www.graphviz.org/documentation/TSE93.pdf), [dot layout docs](https://graphviz.org/docs/layouts/dot/))
- **Why it matters:** The gold standard for *directed-graph / hierarchy* auto-layout. If your artifacts include flow/architecture diagrams, this is a solved sub-problem you'd wrap, not reinvent. The text model is trivially LLM-authorable.
- **What breaks:** It's a *graph* layout, not a general 2D-composition engine — you don't get pixel control, and layouts of dense graphs can sprawl or look mechanical.

### 16. D2 (Terrastruct) — the modern diagram-scripting take, pluggable layout
- **What/Model:** A declarative text language (nodes, connections, containers) compiled to SVG, with **swappable layout engines**: **dagre** (default), **ELK** (Eclipse Layout Kernel; better edge routing on big graphs), and the proprietary **TALA** ("Terrastruct's AutoLayout Approach") — an orthogonal engine built specifically for *software-architecture* diagrams that aims to lay things out "like a human would on a whiteboard," not forced into hierarchy/tree/radial. ([D2 GitHub](https://github.com/terrastruct/d2), [TALA docs](https://d2lang.com/tour/tala/), [layout engines overview](https://deepwiki.com/terrastruct/d2-docs/3.5-layout-engines-and-export-system))
- **Why it matters:** Demonstrates the **"one text IR, multiple layout backends"** architecture — the language is stable while you swap the geometry engine. That decoupling is a strong pattern for an IR that must serve multiple artifact types.
- **What breaks:** TALA is closed-source/paid (MPL-2.0 for the rest); non-hierarchical "whiteboard" layout is genuinely hard and results still vary. Maturity: young (launched late 2022) but actively developed.

### 17. Mermaid — the ubiquitous one, and its layout caveats
- **What/Model:** Markdown-ish text; first token declares diagram type, parser dispatches to a per-type renderer; layout via **dagre** (default) or **ELK**. ([syntax reference](https://mermaid.js.org/intro/syntax-reference.html), [GitHub](https://github.com/mermaid-js/mermaid))
- **Why it matters:** The clearest evidence that a *tiny, learnable* text grammar is enough for broad adoption — and it's already a common LLM output target.
- **What breaks (documented):** "automatic layout sometimes moves shapes to positions the diagram maker does not want"; large diagrams render slowly; and the community guidance is explicitly "switch to specialized tools when pixel-perfect layouts... are required." ([Obsibrain guide 2026](https://www.obsibrain.com/blog/mermaid-diagram-a-complete-guide-to-diagrams-as-code-in-2026)) — i.e. **auto-layout is a feature and a cage**; you trade control for concision.

---

## Cluster E — Grammars for the *animated / narrative* leg (your "animated explainers")

The grammar-of-graphics world extended into *time* and *prose*, which is directly relevant and under-appreciated.

### 18. Gemini (Kim & Heer, IEEE VIS 2020) — a grammar for animated *transitions*
- **What/Model (concrete):** A declarative grammar for animated transitions between statistical graphics. A **step ≔ (component, change, timing, enumerator)**; **component** ∈ {marks, axes, legends, views, pause}; **change ≔ (data, encode, scale, signal, mark-type)**; **timing ≔ (duration, delay, ease, staggering)** where **staggering** sequences elements by a data field with a controllable overlap ratio. Steps compose via **sync** (align at start/end anchors) and **concat** (sequence), with `autoScaleOrder` to avoid scale overflow. ([ar5iv HTML](https://ar5iv.labs.arxiv.org/html/2009.01429), [arXiv](https://arxiv.org/abs/2009.01429), [IDL page](https://idl.uw.edu/papers/gemini))
- **Why it matters:** It's a *declarative* answer to "how do I author an animation without hand-writing keyframe JS." The `(what-changes, timing, staggering)` decomposition + sync/concat is a ready-made model for the animation layer of your IR.
- **What breaks (stated):** single-view charts only; can't give different timings to sub-properties within one step; **no shape interpolation / trajectory bundling / geometric (SVG-scale) transforms**. So it's expressive for chart-to-chart morphs, weak for general motion graphics.

### 19. Canis / CAST (Ge, Zhao et al.) — data-driven chart animation on top of SVG
- **What/Model:** A high-level DSL that applies a **grammar of animations** to *data-enriched SVG* charts: select marks → **partition into "mark units" by data attribute** → apply timed effects with start-control. CAST+ adds a keyframe direct-manipulation authoring GUI. ([Canis, Semantic Scholar PDF](https://www.semanticscholar.org/paper/Canis:-A-High%E2%80%90Level-Language-for-Data%E2%80%90Driven-Chart-Ge-Zhao/5564c984a22cd46f9cae02fbe38184ccb1136769))
- **Why it matters:** Because it animates *existing SVG* (not a bespoke runtime), it's a model for "layer animation onto whatever your compiler already emits." The "partition marks by data → animate the partitions" idea is a clean authoring primitive.

### 20. Idyll (Conlen & Heer, UIST 2018) — markup → interactive article (compiles to HTML/JS/CSS)
- **What/Model:** A **markup language** for interactive articles / explorable explanations that **compiles to a full HTML+JS+CSS bundle**. Gives authors a flexible article model: document style/layout, reader-driven events (clicks, scroll triggers), and a **structured interface to JS components** (interop with D3/P5/npm libs). ([Idyll paper PDF](https://idl.cs.washington.edu/files/2018-Idyll-UIST.pdf), [idyll-lang.org](https://www.idyll-lang.org/), [GitHub](https://github.com/idyll-lang/idyll))
- **Why it matters — very directly:** This is the *most similar existing artifact to your actual output goal*: a high-level authoring language whose *compile target is exactly HTML/CSS/JS*, that lets non-coders wire interactivity without hand-writing the JS. Study its "markup + typed component slots + reactive variables" model closely — it's a proven "prose author → web bundle" pipeline.
- **What breaks:** It's markup-first (prose with embedded components), so it's strong for *narrative* explainers, weaker as a general UI/infographic canvas; component interactivity still bottoms out in JS components someone wrote.

---

## Cluster F — The under-used idea: compositional *combinator* IRs (no solver at all)

### 21. Haskell `diagrams` — geometry by algebraic composition, not constraints
- **What/Model:** An embedded DSL for "compositional, declarative drawing." The non-obvious core: diagrams, transforms, **envelopes**, **traces**, trails, paths, styles are all **monoids/semigroups**, so composition is *algebraic* (`atop`, `beside`, `===`, `|||`). The **envelope** (a diagram's directional extent) and **trace** (ray-intersection) are the contracts that make "put B to the right of A" compute *without a solver* — each diagram carries enough geometric metadata to be composed locally. ([Diagrams user manual](https://diagrams.github.io/doc/manual.html), [diagrams-lib on Hackage](https://hackage.haskell.org/package/diagrams-lib), [Diagrams.Combinators](https://hackage.haskell.org/package/diagrams-lib/docs/Diagrams-Combinators.html))
- **Why it matters (and why it's the surprising one):** It's a *third path* between "fixed layout algorithm" and "constraint solver": **make layout compositional and deterministic** by giving every element a small geometric interface (envelope/trace) and defining composition as a monoid. This is essentially what **SwiftUI/Flutter layout** do too (parent proposes size → child chooses → parent places — no global solver, fully deterministic, fast). For an AI-authored IR this is attractive: *no ambiguity, no non-determinism, no solver blow-ups* — the properties Auto Layout/Penrose warn about — at the cost of not being able to state global "align these three far-apart things" constraints as easily.
- **What breaks:** Global/relational intent ("these two distant elements must share a width") is awkward in a purely local-composition model; you push that complexity back onto the author.

---

## Cluster G — Directly on your nose: *AI agents authoring via a DSL* (2024–2026 work)

This literature has independently concluded exactly what your problem statement asserts: **don't let the model write low-level code; interpose a DSL.**

### 22. Raiven (2026) — "LLM authoring via Domain-Specific Language Mediation"
- **The argument, verbatim-ish:** Direct LLM code-gen is *"opaque, costly, non-deterministic, and fragile... with no guarantee of correctness,"* and worst of all LLMs *"can silently fabricate or substitute data, producing plausible-looking visualizations built on invented values."* Raiven interposes **RaivenDSL** — a formally-defined IR that captures visualization intent *without* backend specifics. Pipeline: NL request → **LLM fills a structured schema (operating only on dataset *metadata*)** → **validate the schema** → **deterministic compilation** to executable code (D3/VTK.js). Claimed guarantees: *"outputs are deterministic, specifications are verifiable before execution, and data fabrication is impossible by construction,"* and *"every syntactically valid RaivenDSL program is guaranteed to compile, which eliminates an entire class of errors."* ([Raiven PDF](https://arxiv.org/pdf/2604.10008))
- **Why it matters:** This is the strongest external validation of your architecture, and it names the concrete payoffs of an IR: (1) **validate before execute** (parse/typecheck the spec — impossible with raw HTML/JS), (2) **total-compilation guarantee** (well-formed IR ⇒ it renders), (3) **data-fabrication firewall** (the model touches metadata/structure, not raw values → it can't invent pixels *or* numbers). Design your IR so these three properties hold.
- **Caveat:** one fetched quote ("Raiven... hallucinates data across any prompt") appears garbled/negated in extraction — the paper's evaluation reports baselines fabricating in ~2–4% of outputs and Raiven eliminating it by construction; treat the specific number as **lightly-verified** pending a direct read.

### 23. The broader NL/LLM→spec ecosystem (corroborating pattern)
- **NL4DV:** input = tabular data + NL query → output = an **analytic specification as a JSON object** (data attributes + analytic tasks + candidate **Vega-Lite** specs). ([NL4DV PDF](https://arjun010.github.io/assets/papers/nl4dv-vis20.pdf))
- **VegaChat:** LLM framework generating **Vega-Lite** specs (chosen precisely because it's a concise, engine-portable JSON grammar). ([arXiv HTML](https://arxiv.org/html/2601.15385v1))
- **ChartGPT** uses *"a thin intermediate chart representation that resolves to an established grammar,"* and **Vega-Zero** introduces a **seq2seq-friendly linearization of Vega-Lite** — i.e. people are actively shaping the IR to be *LLM-emittable* (per the VegaChat related-work summary). ([VegaChat](https://arxiv.org/html/2601.15385v1))
- **Why it matters:** The field's consensus target for machine authoring is a **declarative JSON grammar (Vega-Lite)**, and there's active work on making such grammars *easier for models to emit* (thin intermediate reps, linearizations). That's a strong signal for your IR design: JSON-ish, structurally validatable, with a "thin" surface the model can hit reliably.

---

## Cross-cutting synthesis — what this means for your IR

**Three families of "figure out the pixels," with a real tradeoff triangle:**

| Approach | Examples | Determinism | Expressiveness | Failure mode |
|---|---|---|---|---|
| **Fixed layout algorithm** | Grammar of graphics, DOT/dagre/ELK | High (deterministic) | Narrow (per artifact type) | Auto-layout "moves things you didn't want"; no pixel control |
| **Constraint solver** | Cassowary/Auto Layout, GSS, ALM, Charticulator | **Low** (under-constrained ⇒ arbitrary; conflicts ⇒ silently break a constraint; can vary run-to-run) | Broad relational intent, responsive | Ambiguous/unsatisfiable systems; hard to debug; linear-only |
| **Numeric optimization** | Penrose, Bluefish | **Low** (local minima, non-deterministic, "multiple candidates") | Very broad, novel diagrams | Slow/surprising; needs differentiable constraints; early-stage |
| **Compositional combinators** | Haskell `diagrams`, SwiftUI/Flutter model | **High** (deterministic, fast, no solver) | Local composition easy, global relations awkward | Author must decompose; hard to state long-range constraints |

**The non-obvious recommendations that fall out of the research:**

1. **Copy the layered/orthogonal decomposition, not a chart menu.** The stable core across 25 years and four independent re-implementations is *marks + scales + transforms* + a *composition algebra* (layer/concat/facet/repeat). Bake that in; don't ship "templates."
2. **Separate content from style like Penrose does.** Domain/Substance/Style (or Vega-Lite data/encoding/config) means one content spec renders many ways — and an agent can author *content* while a *style layer* (human-curated or another agent) owns aesthetics. This also gives you the data-fabrication firewall Raiven proves matters: **let the model manipulate structure/metadata, not raw geometry/values.**
3. **Prefer deterministic geometry (fixed algorithm or compositional combinators) for the default path; reserve constraint/optimization solvers for where relational intent genuinely needs them** — because the mature systems (Apple's own docs, Penrose's own docs) *warn in writing* that solvers produce ambiguous, non-deterministic, hard-to-debug layouts, which is uniquely dangerous when an LLM (that won't eyeball the result) is the author.
4. **Design the IR to be validated *before* it renders** (Raiven's central claim): a well-formed IR should be *guaranteed to compile*, and parseable/typecheckable so you catch the agent's errors at spec time, not in the pixels. This is the single biggest advantage of an IR over raw HTML/CSS/JS, and it only exists if you *design for it*.
5. **For the animated/interactive legs, look at reactive-dataflow (Vega) and transition grammars (Gemini/Canis) rather than a static scene tree** — declaring *dependencies* and *what-changes+timing* beats hand-wiring event handlers, and Idyll is a direct precedent for "high-level markup → HTML/JS/CSS bundle."

**Flagged as UNVERIFIED / lightly-verified:** Bluefish's specific layout solver; Charticulator's exact solver internals; GSS's current maintenance status (it is clearly not mainstream today, but I did not confirm "abandoned"); the exact Raiven fabrication percentages (one extracted quote was garbled); and "Cassowary powers Apple Auto Layout" (widely reported, not officially specced in a primary Apple doc I fetched).

---

### Primary sources
- Grammar of graphics: [Wilkinson (Wikipedia)](https://en.wikipedia.org/wiki/Wilkinson's_Grammar_of_Graphics) · [Wickham, Layered Grammar PDF](https://byrneslab.net/classes/biol607/readings/wickham_layered-grammar.pdf) · [ggplot2 book](https://ggplot2-book.org/mastery) · [Observable Plot](https://github.com/observablehq/plot/blob/main/README.md)
- Vega-Lite / Vega: [Vega-Lite paper PDF](https://idl.cs.washington.edu/files/2017-VegaLite-InfoVis.pdf) · [docs](https://vega.github.io/vega-lite/docs/) · [Reactive Vega (morning paper)](https://blog.acolyer.org/2015/12/11/reactive-vega/) · [vega.github.io/vega](https://vega.github.io/vega/)
- Penrose: [SIGGRAPH 2020 PDF](https://www.cs.cmu.edu/~kmcrane/Projects/Penrose/Penrose_SIGGRAPH.pdf) · [docs/ref](https://penrose.cs.cmu.edu/docs/ref) · [constraints ref](https://penrose.cs.cmu.edu/docs/ref/constraints) · [siggraph20 page](https://penrose.cs.cmu.edu/siggraph20)
- Bluefish: [arXiv 2307.00146](https://arxiv.org/abs/2307.00146) · [MIT vis](https://vis.csail.mit.edu/pubs/bluefish/) · [thesis PDF](https://dspace.mit.edu/bitstream/handle/1721.1/144944/Pollock-jopo-SM-EECS-thesis.pdf)
- Charticulator: [MSR](https://www.microsoft.com/en-us/research/publication/charticulator-interactive-construction-of-bespoke-chart-layouts-2/) · [paper PDF](https://donghaoren.org/publications/infovis18-charticulator.pdf) · [GitHub](https://github.com/microsoft/charticulator)
- Constraint layout: [Sketchpad history](https://novedge.com/blogs/design-news/design-software-history-ivan-sutherlands-sketchpad-pioneering-the-evolution-of-computer-aided-design-and-interactive-graphics) · [ThingLab](https://github.com/cdglabs/thinglab) · [Cassowary TR](https://constraints.cs.washington.edu/solvers/cassowary-tr.html) / [TOCHI PDF](https://constraints.cs.washington.edu/solvers/cassowary-tochi.pdf) / [Wikipedia](https://en.wikipedia.org/wiki/Cassowary_(software)) · [Constraint CSS/GSS](https://gss.github.io/guides/ccss) · [VFL](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/VisualFormatLanguage.html) · Auto Layout [Unsatisfiable](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/ConflictingLayouts.html) / [Ambiguous](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/AmbiguousLayouts.html) · [ALM](https://aucklandlayout.sourceforge.net/) / [Springer](https://link.springer.com/article/10.1007/s10601-008-9043-2)
- Diagram-as-text: [Graphviz Gansner TSE93](https://www.graphviz.org/documentation/TSE93.pdf) / [dot docs](https://graphviz.org/docs/layouts/dot/) · [D2 GitHub](https://github.com/terrastruct/d2) / [TALA](https://d2lang.com/tour/tala/) · [Mermaid](https://mermaid.js.org/intro/syntax-reference.html)
- Animation/narrative: [Gemini ar5iv](https://ar5iv.labs.arxiv.org/html/2009.01429) / [arXiv](https://arxiv.org/abs/2009.01429) · [Canis](https://www.semanticscholar.org/paper/Canis:-A-High%E2%80%90Level-Language-for-Data%E2%80%90Driven-Chart-Ge-Zhao/5564c984a22cd46f9cae02fbe38184ccb1136769) · [Idyll PDF](https://idl.cs.washington.edu/files/2018-Idyll-UIST.pdf) / [site](https://www.idyll-lang.org/)
- Compositional: [Haskell diagrams manual](https://diagrams.github.io/doc/manual.html) / [diagrams-lib](https://hackage.haskell.org/package/diagrams-lib)
- LLM→DSL: [Raiven PDF](https://arxiv.org/pdf/2604.10008) · [VegaChat](https://arxiv.org/html/2601.15385v1) · [NL4DV PDF](https://arjun010.github.io/assets/papers/nl4dv-vis20.pdf)
