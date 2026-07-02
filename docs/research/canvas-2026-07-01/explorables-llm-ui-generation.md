# Agent a38382fe840dcfb89.output

## Prompt (first 300 chars)
I'm researching a design problem and need genuine, fresh web research with primary sources.

The design problem: someone is building a system where AI agents (and humans) author visual documents — user interfaces, infographics, slide presentations, and especially ANIMATED EXPLAINERS / interactive ex

## Final message

I have comprehensive, primary-sourced coverage across both parts. Here are my findings.

---

# Research findings: higher-level representations for authoring animated/interactive HTML documents

**Framing finding up front:** the single most decision-relevant split I found is **"emit code" vs "emit a spec against a fixed vocabulary."** Nearly every mature system lands on one side, and the empirical evidence (below) says the answer for *AI* authors is nuanced: LLMs generate *code in a purpose-built high-level library* far more reliably than either raw markup *or* rigid JSON schemas. That result (AutoPresent's SlidesLib: executability 2–11% → 80%+) is the most load-bearing thing in this report.

---

## PART 1 — Explorable explanations, reactive documents, the Bret Victor lineage

### Bret Victor as design theory (the "why," not the "how")

**Magic Ink (2006).** Argues most software is "information software," and for it *interactivity is a last resort, not a goal* — the design problem is really **context-sensitive information graphics** (graphic design), with three approaches to context (from user history, environment, and only lastly interaction). ([worrydream.com/MagicInk](https://worrydream.com/MagicInk/))
- *Why it matters:* for an agent-authored explainer, the theory says the primary job is choosing/composing *graphics that adapt to context*, not wiring up controls. A good IR should make "graphic that responds to data/context" the primitive, with interaction layered on.

**Explorable Explanations (2011).** Reframes reading: *"People currently think of text as information to be consumed. I want text to be an environment to think in."* Proposes three techniques — **reactive documents** (reader plays with the author's assumptions and sees consequences live), **explorable examples** (make the abstract concrete; *don't force* the reader to interact), and **contextual information** (just-in-time, cross-checkable). ([worrydream.com/ExplorableExplanations](https://worrydream.com/ExplorableExplanations/))
- *Why it matters:* this is the canonical spec for the *animated explainer* half of your problem. Key design constraint he stresses: the author must *guide*; interaction emerges from curiosity, it isn't mandatory. An IR should encode a guided narrative spine with optional exploration branches.

**Drawing Dynamic Visualizations (2013).** Names the exact tension your product sits on: today's tools give you **directness OR dynamics, never both** — Illustrator (direct-manipulation, static) vs D3/Processing (indirect coding, dynamic). His prototype draws data-driven pictures *by direct manipulation of the picture itself*. ([talk record + Reform reimplementations](https://github.com/laszlokorte/reform-swift); talk summary via [worrydream refs](https://worrydream.com/refs/Schachman_2012_-_Alternative_Programming_Interfaces_for_Alternative_Programmers.pdf))
- *Honest maturity:* Victor never shipped it; it exists as a talk + community reimplementations (Reform). It's a north star, not a codebase.

### Tangle.js — the minimal reactive-document model

- **What:** the JS library behind *Ten Brighter Ideas* / the reactive-document examples. ([worrydream.com/Tangle](https://worrydream.com/Tangle/))
- **How it models the doc:** author writes normal HTML/CSS; marks variables with attributes (`<span data-var="cookies" class="TKAdjustableNumber">3</span>`); writes a JS object with `initialize` (seed values) and `update` (recompute dependents, e.g. `this.calories = this.cookies * 50`). Tangle re-runs `update` on any input change and refreshes bound spans. ([worrydream.com/Tangle](https://worrydream.com/Tangle/))
- **Why it matters:** it's the *smallest possible* reactive-document IR — variables + one recompute function + attribute binding. An agent could target this trivially.
- **Breaks/maturity:** the `update` function is hand-written imperative JS with manual dependency knowledge (no automatic dataflow graph); numerical-stability caveats noted on the page; effectively unmaintained (2010-era). Doesn't scale to large dependency webs.

### Idyll — a compile-to-web *markup DSL* for interactive articles

- **What:** a markup language (Conlen & Heer, UIST 2018) for explorable explanations that compiles to a web bundle. ([idl.uw.edu/papers/idyll](https://idl.uw.edu/papers/idyll); [github.com/idyll-lang/idyll](https://github.com/idyll-lang/idyll))
- **How it models the doc (concrete syntax, verified from docs):**
  - Variables: `[var name:'x' value:10 /]`
  - Derived/reactive state: `[derived name:'xSquared' value:`x * x` /]` — recomputes when `x` changes
  - Component invocation with prop binding: `[Range min:0 max:10 value:value /]`, `[Button onClick:`myVar++` /]`
  - Reactive expressions in backticks: `[Component propName:`2 * 2 * 2` /]` — "if a variable changes, any expressions that reference it are immediately recomputed"
  - Data: `[data name:'myData' source:'myData.csv' /]`
  - ([idyll-lang.org/docs/syntax](https://idyll-lang.org/docs/syntax))
- **Why it matters — this is the closest existing precedent to your exact ask:** a *higher-level markup* that authors declare against and that *compiles to HTML/CSS/JS*, with reactive variables, derived state, scroll/step triggers, and a structured interface to JS components. If you want prior art for "author against an IR, not raw HTML," Idyll is it.
- **Breaks/maturity:** Distill's own review (below) calls out that Idyll "does not offer any design guidance" — it reduces programming tedium but doesn't help you make a *good* explainer; and custom interactivity still drops to JS components. Project momentum has faded (community/Open Collective funded).

### Distill.pub — component-library-over-HTML, plus the best taxonomy of the *cost*

- **What/how:** each post is "a single HTML file with one special script tag"; ships a CSS framework + web components (footnotes, citations, math). Ambitious articles use Svelte components + inlined SVG. The template is a standalone web-components library usable in any workflow. ([distill.pub/guide](https://distill.pub/guide/); [github.com/distillpub/post--example](https://github.com/distillpub/post--example))
- **The taxonomy (very useful for your feature set)** — from *Communicating with Interactive Articles* (Distill 2020): five affordances — connecting people & data, **making systems playful** (play with parameters), prompting self-reflection, personalizing reading, reducing cognitive load ("overview first, zoom & filter, details-on-demand"). ([distill.pub/2020/communicating-with-interactive-articles](https://distill.pub/2020/communicating-with-interactive-articles/))
- **The honest cost (directly relevant to your "agents shouldn't hand-write HTML" thesis):** authoring one today is *"closer to building a website than writing a blog post,"* requires "editorial, design, and programming skills," and even editing text means "clone the source using git, install project-specific dependencies." Plus preservation risk (web churn breaks them in a few years) and an open accessibility problem. Tools are "relatively immature and mainly help with reducing the necessary programming tedium." ([distill.pub/2020/…](https://distill.pub/2020/communicating-with-interactive-articles/))
- *Why it matters:* this is the empirical case *for* your project — the authoring cost is the barrier, and existing tooling only nibbles at it.

### Observable / Observable Framework — reactive dataflow as the document runtime

- **What:** a reactive dataflow runtime (the engine behind Observable notebooks; Framework is the static-site build). ([github.com/observablehq/runtime](https://github.com/observablehq/runtime); [observablehq.com/framework/reactivity](https://observablehq.com/framework/reactivity))
- **How it models the doc:** code blocks run in **topological order by dataflow dependency, not document order** — "like a spreadsheet." Top-level variables are the reactive units and are **immutable** (only the declaring block may assign; reassignment throws) — this constraint is what makes the dependency graph statically analyzable. Inputs use `view()` (renders a DOM element *and* returns a value generator); `Mutable()` is the escape hatch. ([observablehq.com/framework/reactivity](https://observablehq.com/framework/reactivity); [observablehq.com/@observablehq/reactive-dataflow](https://observablehq.com/@observablehq/reactive-dataflow))
- **Why it matters:** this is the *robust* version of Tangle — automatic dependency graph + topological re-execution. If your IR needs "change a value, everything downstream updates," this is the reference design, and the **immutability constraint is the key trick** that makes it analyzable (and would make an agent's output analyzable too).
- **Breaks/maturity:** production-grade and maintained. Constraint cost: components can't hold their own reactive state (only pages declare top-level reactive vars); `Mutable` can cause infinite loops if misused.

### MyST / Curvenote — Markdown superset with directives/roles for computational narratives

- **What:** MyST ("Markedly Structured Text") is a CommonMark superset with **directives** (block extensions) and **roles** (inline extensions) for citations, cross-refs, computational output; Curvenote upstreamed the JS engine; drives Jupyter Book 2. ([executablebooks.org/…/announce-mystjs](https://executablebooks.org/en/latest/blog/2023-02-09-announce-mystjs/); [docs.curvenote.com/publish/authoring-in-myst](https://docs.curvenote.com/publish/authoring-in-myst))
- **How it models the doc:** narrative Markdown + typed directives/roles that reference *labeled computational cells* (e.g. a Jupyter cell) — a clean separation of prose, structured blocks, and embedded computation.
- **Why it matters:** the **directive/role extension model** is a proven pattern for "keep it authorable as text, but with typed, structured, extensible blocks that compile to rich web output." That's a middle path between raw HTML and a rigid schema — and it's Markdown-legible, which agents handle well.
- **Maturity:** actively developed, real user base (scientific publishing). Aimed at documents/textbooks, not animated explainers — no built-in reactivity/animation model.

### Apparatus & Recursive Drawing (Toby Schachman) — a drawing *is* a parameterized dataflow program

- **What:** Recursive Drawing (2012, ITP thesis) and **Apparatus** (Schachman + Joshua Horowitz) — "a hybrid graphics editor and programming environment for creating interactive diagrams," browser-based, embeddable. ([aprt.us](https://aprt.us/); [harc.ycr.org/project/apparatus](https://harc.ycr.org/project/apparatus/))
- **How it represents drawings:** merges **direct-manipulation vector editing with spreadsheet-like dataflow**. Shapes carry **variables**; properties are **JS expressions** (constraints) rather than fixed coordinates; `spread()` parameterizes multiple instances. Direct manipulation on the canvas edits the *same underlying parameterized model* the expressions define — "spatial reasoning as an alternative/complement to symbolic reasoning." ([aprt.us](https://aprt.us/); [mathisonian.com/writing/apparatus](https://mathisonian.com/writing/apparatus))
- **Why it matters:** this is the *conceptual core* of your problem — a WYSIWYG canvas whose real artifact is a **data/constraint model, not pixels**. Notably, Matt Conlen documented **embedding Apparatus diagrams inside Idyll** — a working example of "constraint-drawing IR + reactive-article IR" composed together. ([mathisonian.com/writing/apparatus](https://mathisonian.com/writing/apparatus))
- **Breaks/maturity:** research/art-grade, small; Schachman's commercial successor is **Cuttle** (parametric design, cuttle.xyz — verified via [feelingof.com ep. 51](https://feelingof.com/episodes/051/)). Not a general document system.

### Sketch-n-Sketch — bidirectional canvas↔code, the academic answer to "directness + dynamics"

- **What:** "Output-Directed Programming for SVG" (Hempel, Lubin, Chugh; UIST 2019). Directly tackles Victor's directness-vs-dynamics tension. ([ravichugh.github.io/sketch-n-sketch](https://ravichugh.github.io/sketch-n-sketch/); [arxiv 1907.10699](https://arxiv.org/abs/1907.10699))
- **How it models the artifact:** you write a program that *generates* SVG; you then **directly manipulate the rendered output**, and the system **infers the corresponding program edit** via **trace-based provenance** — every evaluation step tags its result value with the expression and pointers to input values, so dependencies are recoverable; edits not expressible by mouse fall back to text edits. ([ar5iv 1907.10699](https://ar5iv.labs.arxiv.org/html/1907.10699); [dl.acm.org/10.1145/3332165.3347925](https://dl.acm.org/doi/10.1145/3332165.3347925))
- **Why it matters — this is the single most on-point system for your architecture:** it proves you can keep a program/IR as the source of truth *and* let humans manipulate the rendered canvas, with automatic round-trip back to the IR. The **trace/provenance mechanism is the key technique** for canvas→IR propagation. Predecessor concept: "Prodirect Manipulation" ([arxiv 1510.06788](https://arxiv.org/pdf/1510.06788)).
- **Breaks/maturity:** research prototype; SVG-scoped; ambiguity in "which program edit did the user mean" is the hard, unsolved part.

### Ink & Switch — document substrate ideas (not explainer tools, but the *substrate* theory)

- **Potluck (2022):** turns freeform text notes into interactive tools via **searches** (pattern-match `{number:amount}` capture groups) → **formulas** (spreadsheet-like reactive JS) → **dynamic annotations** (overlays/sliders that don't mutate the text). Design invariant: *"state lives explicitly in text… no hidden metadata; searches are just a function of the text."* ([inkandswitch.com/potluck](https://www.inkandswitch.com/potluck/))
  - *Why it matters:* argues for a **legible, no-hidden-state IR** — everything derivable from the visible source — which is exactly what you want when an *agent* must read/modify the doc without a stale side-channel. Limits: needs JS literacy; text-only substrate can't do rich visuals; parsing pre-existing content is "extremely challenging."
- **Cambria (2020):** schema evolution via **bidirectional lenses** — declarative functions that translate JSON between related schemas, editable in either schema and propagated back. ([inkandswitch.com/cambria](https://www.inkandswitch.com/cambria/); [github.com/inkandswitch/cambria-project](https://github.com/inkandswitch/cambria-project))
  - *Why it matters:* directly applicable to **versioning your IR** — as the DSL evolves, lenses let old docs and new renderers interoperate without lossy migrations. Under-used idea worth stealing.
- **Peritext (CSCW 2022):** a **rich-text CRDT** that stores formatting spans keyed to stable char IDs and derives formatting deterministically so concurrent ops commute (generic tree CRDTs produce merge anomalies). ([inkandswitch.com/peritext](https://www.inkandswitch.com/peritext/); [martin.kleppmann.com/2022/11/08/peritext-rich-text-crdt](https://martin.kleppmann.com/2022/11/08/peritext-rich-text-crdt.html))
  - *Why it matters:* if **humans and agents co-edit the same document concurrently**, you need a merge model that preserves intent. Peritext is the state-of-the-art for rich text specifically.
- **Malleable software (2024 essay):** the umbrella thesis — software users can reshape at point of use; "modification becomes routine." ([inkandswitch.com/essay/malleable-software](https://www.inkandswitch.com/essay/malleable-software/))

---

## PART 2 — LLM/AI-driven UI & document generation: what representations actually work

### The two industry camps

**Camp A — emit code (raw HTML/React), sandbox it:**
- **Anthropic Artifacts:** each artifact is a **single-file payload in a sandboxed iframe** (CSP + `sandbox` attr); content types are Markdown/HTML/SVG/Mermaid/code/**React**; React is rendered via `react-runner`, code passed in by `postMessage`. HTML artifacts bundle HTML+CSS+JS in one file. ([reidbarber.com/blog/reverse-engineering-claude-artifacts](https://www.reidbarber.com/blog/reverse-engineering-claude-artifacts); [simonwillison.net/tags/claude-artifacts](https://simonwillison.net/tags/claude-artifacts/))
- **Vercel v0:** a model **fine-tuned specifically on React + Tailwind + shadcn/ui**; outputs JSX/TSX. The fine-tune is the point — vague prompts ("tighter spacing") work because the model has seen enough of *that exact dialect*. ([vercel.com/academy/ai-sdk/ui-with-v0](https://vercel.com/academy/ai-sdk/ui-with-v0))
- **tldraw "Make Real":** snapshots a canvas selection to PNG → GPT-4V → **self-contained Tailwind HTML+JS** (Tailwind via CDN, deps via unpkg/skypack) → embedded back as an iframe on the canvas. Iteration works by feeding *the previous HTML back* plus annotations ("fill in the white box"). ([github.com/tldraw/make-real/blob/main/app/prompt.ts](https://github.com/tldraw/make-real/blob/main/app/prompt.ts); [tldraw.dev/blog/make-real-the-story-so-far](https://tldraw.dev/blog/make-real-the-story-so-far))
  - Non-obvious design insight from tldraw: the **canvas becomes the conversation medium** — resize to test breakpoints, arrange iterations spatially, annotate and resubmit. The representation that matters is the *spatial arrangement of attempts*, not just each artifact.

**Camp B — emit a spec against a fixed component vocabulary (the "higher-level model, not raw HTML" camp — closest to your ask):**
- **Vercel AI SDK "Generative UI":** the LLM does a **tool call**; the tool result is mapped to a **predefined React Server Component** and streamed. The model never writes UI code — it *selects and parameterizes* components from a fixed palette. ([vercel.com/blog/ai-sdk-3-generative-ui](https://vercel.com/blog/ai-sdk-3-generative-ui); [ai-sdk.dev/docs/ai-sdk-ui/generative-user-interfaces](https://ai-sdk.dev/docs/ai-sdk-ui/generative-user-interfaces))
- **Thesys C1:** an OpenAI-compatible API middleware where the LLM returns a **UI specification object ("C1 DSL")** — charts/tables/forms/cards/slides/reports — rendered by the **Crayon** open-source React design system (built on Radix + shadcn). The model emits a *spec*, the SDK renders it; the component vocabulary is fixed and themeable. ([docs.thesys.dev/guides/how-c1-works](https://docs.thesys.dev/guides/how-c1-works); [thesys.dev/blogs/how-to-build-generative-ui-applications](https://www.thesys.dev/blogs/how-to-build-generative-ui-applications))
  - ⚠️ **UNVERIFIED:** thesys's own *stated rationale* for choosing a DSL over code — their architecture blog ([thesys.dev/blogs/generative-ui-architecture](https://www.thesys.dev/blogs/generative-ui-architecture)) didn't render for me; the C1-DSL-maps-to-Crayon description above is from their docs/search summaries, but I could not verify their first-person "why not code" argument.
- **Google Stitch (ex-Galileo AI):** text/sketch → UI, on Gemini 2.5; outputs "structured, responsive interface designs" exportable to Figma or HTML/CSS. Representation details are opaque (closed product). ([codecademy.com/article/google-stitch-tutorial](https://www.codecademy.com/article/google-stitch-tutorial-ai-powered-ui-design-tool); [blog.logrocket.com/ux-design/i-tried-google-stitch](https://blog.logrocket.com/ux-design/i-tried-google-stitch-heres-what-i-loved-hated/))

*Why the camp split matters for you:* Camp B **is your design** — author (agent) targets a higher-level model that maps to a curated component set, gaining reliability/consistency/safety at the cost of expressiveness (you can only make what the palette allows). Camp A gets unlimited expressiveness but inherits every failure mode below.

### What the research says LLMs are actually GOOD and BAD at generating

This is the part with the strongest, most decision-relevant evidence.

**1. LLMs generate *code in a purpose-built high-level library* far better than raw output or rigid schemas — the strongest single result.**
- **AutoPresent / SlidesLib (NAACL/2025):** slides represented as **executable Python programs** via a high-level DSL (`add_title`, `add_bullet_points`, `set_background_color`, `search_image`…) over `python-pptx`. Effects:
  - Code-gen beats end-to-end image generation decisively (diffusion "produces creative figures without aligning with slide design principles" and botches text accuracy).
  - The high-level library vs raw `python-pptx`: **executability 80%+ vs 2–11%**, and **+34 points** for small models (LLaMA-8B) on some metrics; 170-line raw programs collapse to 13-line library calls. ([arxiv 2501.00912](https://arxiv.org/html/2501.00912); [Berkeley NLP PDF](https://nlp.cs.berkeley.edu/pubs/Ge-Wang-Zhou-Peng-Subramanian-Tan-Sap-Suhr-Fried-Neubig-Darrell_2025_AutoPresent_paper.pdf))
  - *Takeaway for you:* **the abstraction level of the target API is the dominant lever on LLM reliability.** A concise, high-level DSL isn't just ergonomic — it's the difference between mostly-broken and mostly-working output. This is the empirical backbone for building an IR instead of letting agents write raw HTML.
- **LIDA (Microsoft, ACL 2023):** **grammar-agnostic** visualization/infographic generation via a pipeline (summarizer → goal explorer → **VisGenerator that writes, executes, refines, and filters viz code** → infographer). Works across matplotlib/seaborn/altair/d3 — i.e., generate *code in whatever library*, don't invent a bespoke chart schema. ([microsoft.github.io/lida](https://microsoft.github.io/lida/); [ar5iv 2303.02927](https://ar5iv.labs.arxiv.org/html/2303.02927))
  - *Non-obvious:* LIDA generates *and then executes + filters* — treating LLM output as fallible and gating it by execution. Your IR should be executable/validatable so you can do the same.

**2. LLMs are BAD at raw SVG / precise coordinate geometry, and it gets worse with complexity.**
- **SVGenius (ACM MM 2025, 2,377 queries):** *"All models degrade with increasing complexity"*; reasoning-enhanced training helps more than scaling — "fundamental limitations in current approaches." ([dl.acm.org/10.1145/3746027.3758287](https://dl.acm.org/doi/10.1145/3746027.3758287); [arxiv 2506.03139](https://arxiv.org/html/2506.03139v1))
- **SVG-processing review (2025):** SVG is *text-based so it's tempting to feed LLMs directly*, but **tokenizers optimized for text encode geometric primitives inefficiently**; real SVGs have "500 or even 1000 paths" while benchmarks are far simpler; models show "artifacts on complex prompts" and "limited ability to edit SVG structures intuitively." Better approaches: **SVG-specific tokens added to the vocabulary** (SVG4LLM), or conditioning via image encoders (StarVector). ([arxiv 2503.04983](https://arxiv.org/html/2503.04983v1))
  - *Takeaway:* do **not** make raw SVG your primary IR for anything spatially complex. Represent graphics as *higher-level shapes/constraints* (Apparatus-style) or *code that draws*, and reserve raw SVG for leaf assets.

**3. Layout is the specific weak spot in screenshot→code — and CSS-shaped representations help because the model has seen tons of CSS.**
- **Design2Code (NAACL 2025, 484 real webpages):** frontier MLLMs "mostly lag in **recalling visual elements** from the input and **generating correct layout designs**." ([arxiv 2403.03163](https://arxiv.org/abs/2403.03163); [aclanthology.org/2025.naacl-long.199](https://aclanthology.org/2025.naacl-long.199/))
- **LayoutGPT (NeurIPS 2023):** represents layouts as **CSS** (x/y → `left`/`top`, `width`/`height`) with in-context "style-sheet" exemplars — deliberately reusing a representation the model saw abundantly in pretraining. GPT-4 best at spatial relations, GPT-3.5 better at numerical. ([layoutgpt.github.io](https://layoutgpt.github.io/); [arxiv 2305.15393](https://arxiv.org/abs/2305.15393))
  - *Non-obvious principle:* **meet the training distribution.** A DSL that *looks like* something the model has seen millions of times (CSS, Markdown, common code) will outperform a novel bespoke syntax of equal expressiveness. This argues against an exotic IR syntax and *for* one that piggybacks on familiar surface forms.

**4. The structured-output paradox: forcing rigid formats HURTS reasoning, even as it guarantees validity.**
- **"Let Me Speak Freely?" (2024):** strict JSON/XML/YAML constraints degrade reasoning accuracy **~10–15%**; the tighter the format, the worse; math/reasoning suffers most; classification *improves*. Recommendation: **looser constraints for reasoning-heavy tasks**; reason first, format after. ([arxiv 2408.02442](https://arxiv.org/html/2408.02442v1))
- **Counterpoint — "Capacity, Not Format" (2026):** argues the failures are about model capacity, not the format per se — worth reading as the skeptical rebuttal. ([arxiv 2606.09410](https://arxiv.org/pdf/2606.09410))
- **Constrained decoding (the reliability side):** grammar-guided decoding (XGrammar, llguidance, TypeFox Langium-AI deriving BNF from a DSL) masks invalid tokens per-step so output is *syntactically guaranteed* valid — the LLM tokenizer acts as lexer, the grammar as parser. ([mbrenndoerfer.com/writing/constrained-decoding-structured-llm-output](https://mbrenndoerfer.com/writing/constrained-decoding-structured-llm-output); [Medium: JSON Schema & grammar-based decoding](https://medium.com/@emrekaratas-ai/structured-output-generation-in-llms-json-schema-and-grammar-based-decoding-6a5c58b698a6))
  - *The synthesis this points to for your IR:* **separate reasoning from emission.** Let the agent plan/reason in free text (a "thinking" or narrative pass), then emit the IR — ideally a DSL that (a) reads like familiar code (distribution match), (b) is high-level (AutoPresent lever), and (c) is grammar-constrainable so emission is *valid by construction*. Don't force the model to *reason inside* a rigid schema.

---

## Cross-cutting synthesis (the non-obvious design implications)

1. **The abstraction level of your IR is the #1 driver of AI-authoring reliability** — not the syntax, not the model. AutoPresent's 2–11% → 80%+ executability jump from adding one high-level library is the strongest evidence in this whole space. Build the "SlidesLib for explainers."

2. **Prefer "code in a curated high-level library" over both raw markup and rigid JSON.** Raw HTML/SVG: expressive but LLMs botch layout/geometry (Design2Code, SVGenius). Rigid JSON schema: reliable to parse but degrades reasoning (Let Me Speak Freely). A high-level, execution-checkable DSL that *looks like familiar code* threads the needle.

3. **Meet the pretraining distribution.** LayoutGPT's CSS trick and v0's Tailwind/shadcn fine-tune both win by targeting representations the model has seen enormously. A novel IR should either mimic a familiar surface (Markdown+directives à la MyST, CSS-like layout) or be backed by a fine-tune/lots of in-context examples.

4. **Make the IR executable and gate output by execution** (LIDA's generate→execute→filter; AutoPresent's executability metric; constrained decoding for syntactic validity). Treat agent output as fallible; validate before render.

5. **Reactivity wants a dataflow graph with immutability, not hand-wired updates.** Observable's "immutable top-level vars → statically analyzable topological re-execution" is the robust pattern; Tangle's hand-written `update` is the fragile one. This also makes the doc *analyzable by agents*.

6. **For a WYSIWYG canvas over an IR, the round-trip is the hard part — and it's been solved in research.** Sketch-n-Sketch's **trace-based provenance** (canvas edit → inferred program edit) and Apparatus's **drawing-as-parameterized-dataflow** are the two proven models. Expect the ambiguity of "which IR edit did this drag mean" to be your central UX/tech challenge.

7. **Keep state legible, no hidden side-channels** (Potluck: "searches are just a function of the text"). An agent editing the doc later must be able to reconstruct everything from the visible IR — hidden metadata is where agent edits will corrupt state.

8. **Plan for evolution and co-editing now:** Cambria lenses for migrating the IR as the DSL grows; Peritext-style CRDT if humans and agents edit concurrently. Both are under-used ideas that map cleanly onto "agents + humans co-author over time."

9. **Interaction is a last resort, per Victor** — the IR's *primitive* should be "graphic/animation that responds to data/context," with a guided narrative spine and *optional* exploration, not a pile of controls.

**Two honest gaps I couldn't fully verify:** thesys C1's first-person rationale for a DSL-over-code (architecture blog wouldn't render — [thesys.dev/blogs/generative-ui-architecture](https://www.thesys.dev/blogs/generative-ui-architecture)); and Sketch-n-Sketch's exact ambiguity-resolution details (PDF wouldn't parse — readable summary via [ar5iv 1907.10699](https://ar5iv.labs.arxiv.org/html/1907.10699)). Everything else above is from primary docs/papers as cited.
