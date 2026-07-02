# Agent ab54ec73d2da93deb.output

## Prompt (first 300 chars)
You are a web-research agent. Research LAYOUT ABSTRACTION approaches used by UI/design/visual editors, and their trade-offs specifically for PROGRAMMATIC authoring by a tool/agent that CANNOT see pixels.

Context: someone is building a visual editor whose layout will be set by an AI agent, not a hum

## Final message

**Bottom line:** For an agent that reasons symbolically and cannot verify pixels, a **flow/flex declarative model** (Figma Auto Layout / CSS Flexbox / HTML normal flow) is the least error-prone by a wide margin, and **absolute/free-form coordinates are the worst**. The decisive properties are *determinism* (output is a pure function of the tree, no solver tie-breaks), *no-overlap/no-off-canvas by construction*, *locality of edits* (insert a child → siblings reflow automatically), and *intent-over-measurement* (you declare `gap`/`hug`/`fill`, you don't emit pixel numbers you can't measure). Constraint-based layout (Auto Layout / Cassowary) sits in the middle — expressive and responsive, but it has a **silent-ambiguity failure mode that is uniquely dangerous for a blind author**. Evidence and per-paradigm trade-offs below.

---

## Paradigm-by-paradigm findings

### 1. Absolute / free-form positioning (x/y/w/h)
- Elements are **removed from flow — an absolutely positioned element neither affects nor is affected by others**, so nothing prevents overlap, and there's no automatic responsiveness ([CSS-Tricks](https://css-tricks.com/absolute-relative-fixed-positioining-how-do-they-differ/)).
- "All layout options have unpredictable overlap at certain viewport widths… absolute positioning can lead to issues on different screen sizes… when you define positions in pixels, the design may not adapt" ([Chen Hui Jing](https://chenhuijing.com/blog/so-your-designer-wants-stuff-to-overlap/)).
- Maintainability is non-local: "elements should be isolated; if we change one, we don't want to adjust everything else" — absolute breaks this; every element is "an absolute island and changing the overall layout requires updating many individual elements by hand" ([Unity UI Toolkit docs](https://docs.unity3d.com/6000.3/Documentation/Manual/best-practice-guides/ui-toolkit-for-advanced-unity-developers/layouts.html); [DEV](https://dev.to/domagojvidovic/position-absolute-and-relative-the-simplest-guide-5169)).
- **Directly relevant anti-pattern:** "Older design-to-code tools made problematic layouts by sprinkling `position: absolute` everywhere" — the exact failure mode a naive generator falls into ([DesignersForest](https://www.designersforest.com/dear-llm-heres-how-my-design-system-works/)).

**Blind-agent trade-off:** Its only virtue — total precision and a predictable coordinate→pixel mapping — is *worthless when you can't verify the pixels*. It requires knowing every element's rendered size (which a blind agent can't measure), and overlaps / off-canvas / bad z-order are all silent. Acceptable only as a **scoped escape hatch** (badges, overlays, modals) inside a flow parent ([CSS-Tricks flexbox+absolute](https://css-tricks.com/flexbox-and-absolute-positioning/)).

### 2. Constraint-based layout (Auto Layout / Cassowary)
- Cassowary (Badros, Borning, Stuckey 2002; from Borning et al. UIST'97) is an **incremental dual-simplex solver** for linear equalities/inequalities; constraints are either **requirements or preferences**, and it "now forms the basis for Auto Layout in OS X Lion and iOS 6+" ([UW TR](https://constraints.cs.washington.edu/solvers/cassowary-tr.html); [ACM TOCHI](https://dl.acm.org/doi/10.1145/504704.504705); [Wikipedia](https://en.wikipedia.org/wiki/Cassowary_(software))).
- **Constraint hierarchy** picks among multiple valid solutions: `REQUIRED` must hold; `STRONG`/`MEDIUM`/`WEAK` satisfied with declining priority; **`weight`** is a secondary tie-break within a strength; **stay constraints** pin a variable's current value; **edit variables** feed live values (for dragging) ([Cassowary theory docs](https://cassowary.readthedocs.io/en/latest/topics/theory.html)).
- **Nondeterminism, explicitly:** "if there's an ambiguity in the constraints (more than one possible solution), **the initial value provided to variables will affect the solution on which the system converges**" ([Cassowary theory docs](https://cassowary.readthedocs.io/en/latest/topics/theory.html)). So the result can depend on initial values and add-order, not just the declared constraints.
- **Two catastrophic states an author can create:**
  - *Unsatisfiable (over-constrained):* "two or more **required** constraints conflict… Auto Layout identifies the conflicting set, **breaks one, checks, and continues breaking until it finds a valid layout**," logging to console; runtime catch via the `UIViewAlertForUnsatisfiableConstraints` symbolic breakpoint ([Apple: Unsatisfiable Layouts](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/ConflictingLayouts.html)).
  - *Ambiguous (under-constrained):* "the system of constraints has **two or more valid solutions**… Auto Layout **chooses one of the possible solutions**… the layout may or may not appear as you expect. **Furthermore, there are no warnings written to the console, and there is no way to set a breakpoint for ambiguous layouts**" ([Apple: Ambiguous Layouts](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/AmbiguousLayouts.html)). Detectable only by actively probing `hasAmbiguousLayout` per view.
- **Tie behavior:** equal-priority optional constraints → "the system does not know which to break… you need to change the priorities"; among a tie it "breaks the constraint having the lowest priority first," and among required conflicts "Auto Layout will **arbitrarily select** a constraint to break" ([Apple: Ambiguous](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/AmbiguousLayouts.html); [Kodeco Ch.13](https://www.kodeco.com/books/auto-layout-by-tutorials/v1.0/chapters/13-common-auto-layout-issues)).
- **Hidden coupling surprises:** constraining height relative to width (aspect ratio) "creates a connection between the vertical and horizontal constraints, which can now conflict"; Auto Layout also positions by **alignment rectangle, not frame**, and ignores `transform` — all sources of "why did it move?" ([Kodeco Ch.13](https://www.kodeco.com/books/auto-layout-by-tutorials/v1.0/chapters/13-common-auto-layout-issues); [Apple Debugging](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/DebuggingTricksandTips.html)).
- Research corroborates the authoring difficulty: "**under-specification** (too few constraints) → unpredictable results; **over-specification** (too many) → conflicts and no valid solution" — motivating OR-constraints as a fix ([ORCSolver, CHI 2020](https://yuejiang-nj.github.io/Publications/2020CHI_ORCSolver/paper.pdf); [ScienceDirect: over-constraint usability](https://www.sciencedirect.com/science/article/abs/pii/S001044850300099X)).

**Blind-agent trade-off:** Constraints express *relational intent* beautifully and are responsive — but they demand the agent emit an **exactly-right-cardinality, mutually-consistent** constraint set. Miss by one → silent ambiguous arbitrary layout (no error, no console output, the blind agent never learns). Add one too many → solver silently breaks constraints. The tie-break/initial-value nondeterminism means the same declared intent can render differently. This is high cognitive load and the failure is *invisible* — the worst combination for an author who can't look.

### 3. Figma Auto Layout (flex subset)
- Design philosophy, stated by the team: **"Auto Layout should be a thoughtful subset of flexbox"**; they mirrored flexbox "to drive alignment between code and design" ([Figma blog: Behind the feature](https://www.figma.com/blog/behind-the-feature-the-making-of-the-new-auto-layout/)).
- Maps cleanly to flex: **direction** ≈ `flex-direction`, **gap** ≈ `gap`, **padding**, **alignment/distribution** (packed vs space-between ≈ `justify-content`), **wrap** (horizontal only) ≈ `flex-wrap` ([Figma guide](https://help.figma.com/hc/en-us/articles/360040451373-Guide-to-auto-layout); [LogRocket](https://blog.logrocket.com/ux-design/configuring-figmas-auto-layout-wrap/)).
- **Sizing = intent, not pixels:** `Hug` (container shrinks to fit children) ≈ `width:fit-content`; `Fill` (child stretches to parent) ≈ `flex-grow`/`align-self:stretch`; `Fixed`; plus optional **min/max** clamps ([Figma guide](https://help.figma.com/hc/en-us/articles/360040451373-Guide-to-auto-layout)).
- Escape hatch: **"Ignore auto layout"** (formerly "absolute position") pulls one child out of flow — "much like `position: absolute` in CSS," then governed by constraints ([Figma guide](https://help.figma.com/hc/en-us/articles/360040451373-Guide-to-auto-layout)).

**Blind-agent trade-off:** Best-of-both. The primary model is deterministic flow (no overlap possible among flowed children), sizing is declared as intent (`hug`/`fill`/`gap` — no measurement needed), and absolute exists only as an explicit, scoped opt-out. This is essentially the recommended shape for an agent target.

### 4. CSS Flexbox & Grid (declarative flow / intrinsic sizing)
- **Flexbox is content-out / intrinsic:** "you let the size of the content decide how much space each item takes up"; the engine "does a nice job of adjusting the number of items per row according to available space" — the browser computes positions, the author never emits coordinates ([MDN: Grid vs other methods](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Grid_layout/Relationship_with_other_layout_methods)).
- **Grid is layout-in / 2D:** you declare tracks, items auto-place into cells; `repeat(auto-fit, minmax(200px, 1fr))` yields responsive column counts with zero per-item math ([MDN](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Grid_layout/Relationship_with_other_layout_methods)). Decision rule: 1D (row *or* column) → flex; 2D (row *and* column) → grid; common practice is grid for page skeleton + flex inside sections ([Refine](https://refine.dev/blog/css-grid-vs-flexbox/); [MDN](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Grid_layout/Relationship_with_other_layout_methods)).
- Both share the **Box Alignment** module (`justify-content`, `align-items`, …) — alignment is declared, not hand-tuned.

**Blind-agent trade-off:** Flex is the safest default (self-sizing, 1D, wraps automatically). Grid is nearly as safe and strictly better for tabular/2D structure — the track declaration is a bit more upfront reasoning, but auto-placement into cells is deterministic and overlap-free.

### 5. Document / normal flow (HTML block/inline)
- The baseline: blocks stack vertically, inline runs horizontally and wraps; taking something out of flow (float/absolute) is the deviation ([DEV: CSS flow & positioning](https://dev.to/poulamic/css-flow-positioning-bl8)). Zero coordinates, fully deterministic, but limited expressiveness for rich 2D UI — best thought of as the substrate flex/grid extend.

---

## Direct evidence on the core question (blind/LLM authoring)

This is the strongest, most on-point evidence — recent research on models generating layouts:

- LLMs' "ability to understand and manipulate spatial relationships remains limited," which is precisely bad for layout since it "requires **precise coordination of placement, alignment, and structural organization**"; the paper's fix deliberately **avoids raw absolute-coordinate output** in favor of modeling **inter-element relationships and constraints** ([LaySPA / "LLMs as Layout Designers", arXiv 2509.16891](https://arxiv.org/abs/2509.16891)).
- Models "are prone to **spatial hallucination, including generating physically infeasible or semantically inconsistent layouts**, and often struggle with **fine-grained spatial constraints and precise coordinate positioning**"; early approaches "treat spatial reasoning as an emergent byproduct… neither representing spatial constraints explicitly nor enforcing geometric consistency" ([arXiv 2602.13912 "From Pixels to Policies"](https://arxiv.org/pdf/2602.13912); [arXiv 2507.04293 "AutoLayout"](https://arxiv.org/pdf/2507.04293)).
- On architecture: declarative/component approaches are "balanced (flexibility + safety)" whereas fully-generated raw-coordinate/HTML output is "**brittle and unsafe at runtime**"; reliability comes from an *architectural contract* (author-defined building blocks) that lives outside the model's numeric output ([CopilotKit: Three types of Generative UI](https://www.copilotkit.ai/blog/the-three-kinds-of-generative-ui); [Inferensys](https://inferensys.com/comparisons/adaptive-interfaces-and-generative-ui)).

Interpretation: the exact operation absolute positioning demands (emit correct fine-grained numeric coordinates) is the documented *weakness* of the models doing the authoring; the operations flow/flex demand (containment, ordering, relational intent) are their *strength*.

---

## Ranked answer: least → most error-prone for a blind agent

| Rank | Model | Determinism | Overlap/off-canvas possible? | Edit locality | Needs pixel measurement? | Failure visibility to a blind agent |
|---|---|---|---|---|---|---|
| 1 (best) | **Flow / Flexbox / Figma Auto Layout** | Pure function of tree+props | **No** (flowed siblings can't overlap) | Local — insert child, siblings reflow | No — declare `gap`/`hug`/`fill` | Statically provable safe |
| 2 | **CSS Grid** | Deterministic auto-placement | No (cells) | Local within track structure | No | Provable once tracks declared |
| 3 | **Constraint-based (Auto Layout / Cassowary)** | Tie-breaks depend on priority/weight/**initial values** | Yes if mis-constrained | Semi-local (a bad constraint has global reach) | Sometimes (fixed sizes) | **Ambiguous = silent, no console, no breakpoint** |
| 4 (worst) | **Absolute / free-form** | Fully deterministic mapping… | **Yes, freely** | Non-local — move one, hand-fix neighbors | **Yes, every element** | Invisible; needs full geometry pass to detect |

**Why flow wins the three sub-criteria you asked about:**
- *Determinism:* flow output is a deterministic pure function of (tree, sizing props); there is no solver, no tie-break, no initial-value dependence. Constraints have documented nondeterminism ([Cassowary docs](https://cassowary.readthedocs.io/en/latest/topics/theory.html)); absolute is deterministic but that determinism doesn't help when you can't check the numbers.
- *Self-correction:* the layout engine *computes* positions, so the agent literally cannot emit a wrong coordinate — the class of "I placed it but it overlaps / is off-screen" errors is eliminated *by construction*, not by post-hoc checking. Under absolute and under-constrained Auto Layout, those errors are producible and (for Auto Layout ambiguity) *silent*.
- *Locality:* adding/removing/resizing a child in flow reflows only its siblings within the container — a small, predictable, reasoning-friendly delta. Absolute requires recomputing every affected neighbor's coordinates by hand; a single bad constraint in a constraint system can shift the whole subtree.

**The most dangerous specific trap** for a blind agent is Auto Layout's *ambiguous (under-constrained) layout*: Apple documents it produces **no console warning and cannot be breakpointed** — the solver just silently picks one of the valid solutions ([Apple: Ambiguous Layouts](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/AmbiguousLayouts.html)). An agent that can't see pixels would have no signal that anything is wrong. Flow has no analogous silent-wrong state.

---

## Snapping, alignment guides, responsive automation (how tools remove manual placement)
- **Smart guides / snap:** Figma auto-shows red alignment guides and snaps to other elements' edges/centers when moving or resizing — the tool infers alignment intent instead of the author dialing coordinates ([Figma: adjust alignment](https://help.figma.com/hc/en-us/articles/360039956914-Adjust-alignment-rotation-position-and-dimensions)).
- **Smart Selection:** batch spacing/reordering — "increasing the height of some items in a list might require 10 resizes + 9 moves while tracking spacing"; Smart Selection automates that redistribution ([Figma blog: Smart Selection](https://www.figma.com/blog/introducing-smart-selection/)).
- **Responsive without media queries:** `repeat(auto-fit, minmax(280px, 1fr))` (grid) and `flex: 1 1 <basis>` + wrap (flex) adapt column counts to available width automatically ([MDN](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Grid_layout/Relationship_with_other_layout_methods); [DEV: Grid+Flex](https://dev.to/thebitforge/css-grid-flexbox-mastery-build-responsive-uis-faster-27kn)).
- Constraint tools automate responsiveness via **pin/resize rules + edit variables** (drag one edge, the solver repropagates) ([Cassowary docs](https://cassowary.readthedocs.io/en/latest/topics/theory.html)) — powerful, but reintroduces the ambiguity/conflict risk above.

Takeaway for the agent: a flow/flex target lets you *lean on the engine's snapping/distribution* by declaring `gap`, `space-between`, and alignment — the agent expresses "evenly spaced, centered" and never computes offsets.

---

## Pitfalls to watch (even with the recommended flow model)
- **Intrinsic-sizing blowouts:** a long unbroken string can expand a `hug` container or force wraps the agent didn't intend; `flex-shrink` can crush an item to unreadable width. Mitigation: always set **min/max clamps** (Figma exposes min/max; CSS `min-width`/`max-width`, `min-content`/`clamp()`) ([Figma guide](https://help.figma.com/hc/en-us/articles/360040451373-Guide-to-auto-layout)). These failures are *bounded and local*, unlike overlap/off-canvas.
- **Give the agent a static validator:** flow's big win is that "no overlap / on-canvas" is *statically checkable* without rendering — the agent can prove safety before commit. Build that check in; for any absolute escape-hatch elements, run an explicit geometry/overlap pass.
- **If you must expose constraints,** force *completeness* (reject under-constrained subtrees the way `hasAmbiguousLayout` would flag them) and *consistency* (detect over-constraint before the solver silently drops constraints), and pin initial values so tie-breaks are reproducible — otherwise you inherit every failure mode in section 2.
- **Absolute belongs only as a tagged escape hatch** (Figma "Ignore auto layout", CSS `position:absolute` in a flow parent) for overlays/badges — never as the primary authoring model.
- **Pragmatic recommendation** (mirrors where Figma + modern CSS converged): **flex/Auto-Layout as the default, grid for genuine 2D/tabular structure, absolute as a rare scoped opt-out.** This maximizes determinism and locality while keeping the one capability (free overlap) that flow can't express available where actually needed.

### Primary sources
- Apple: [Ambiguous Layouts](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/AmbiguousLayouts.html) · [Unsatisfiable Layouts](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/ConflictingLayouts.html) · [Debugging Tricks](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/DebuggingTricksandTips.html)
- Cassowary: [theory docs](https://cassowary.readthedocs.io/en/latest/topics/theory.html) · [UW technical report](https://constraints.cs.washington.edu/solvers/cassowary-tr.html) · [ACM TOCHI paper](https://dl.acm.org/doi/10.1145/504704.504705) · [Wikipedia](https://en.wikipedia.org/wiki/Cassowary_(software))
- Figma: [Guide to Auto Layout](https://help.figma.com/hc/en-us/articles/360040451373-Guide-to-auto-layout) · [Behind the feature](https://www.figma.com/blog/behind-the-feature-the-making-of-the-new-auto-layout/) · [Smart Selection](https://www.figma.com/blog/introducing-smart-selection/)
- CSS: [MDN Grid vs other layout methods](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Grid_layout/Relationship_with_other_layout_methods) · [CSS-Tricks absolute/relative/fixed](https://css-tricks.com/absolute-relative-fixed-positioining-how-do-they-differ/)
- Constraint-solver ambiguity: [ORCSolver, CHI 2020](https://yuejiang-nj.github.io/Publications/2020CHI_ORCSolver/paper.pdf) · [Kodeco Ch.13 Common Auto Layout Issues](https://www.kodeco.com/books/auto-layout-by-tutorials/v1.0/chapters/13-common-auto-layout-issues)
- LLM layout generation: [arXiv 2509.16891](https://arxiv.org/abs/2509.16891) · [arXiv 2602.13912](https://arxiv.org/pdf/2602.13912) · [arXiv 2507.04293](https://arxiv.org/pdf/2507.04293) · [CopilotKit: Three types of Generative UI](https://www.copilotkit.ai/blog/the-three-kinds-of-generative-ui)
