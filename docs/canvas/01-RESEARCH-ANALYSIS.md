# Canvas · 01 — Research analysis (detailed)

> Full-read analysis of the 20 salvaged research reports (`docs/research/canvas-2026-07-01/`,
> README there = per-report index). Format: per cluster — what the research established, the
> **verdict** (adopt / adapt / reject / defer) with reasoning, and what it concretely changes
> in `02-CORE-ENGINE.md`/`03-SHELLS.md`. Contradictions *between* reports are resolved
> explicitly in §9. Citations live in the underlying reports; claims they flagged UNVERIFIED
> are treated as directional only.

---

## 1. Document model — flat records beat nested trees (ADOPT, reverses both spikes)

**What the research established** (`document-models-scene-graphs.md`, `tldraw-programmatic-authoring.md`):

- The field splits cleanly: **collab/programmatic-first tools store flat** (tldraw:
  `Map<id, record>` + `parentId` + fractional `index`; Excalidraw: flat element array +
  reference fields; Figma: *logically* a tree, *physically* `Map<ObjectID, Map<Prop, Value>>`),
  while **file-format-first tools nest** (Sketch `layers[]`, Konva, Lottie). Flat wins for
  mutation: reparent = one property write; IDs never move; diffs are per-record.
- **Figma's two hard-won rules:** (a) parent link + sibling position must be **one atomically
  updated property** or concurrent/batched moves orphan nodes; (b) the **plugin API hides
  fractional indices** behind intent ops (`insertChild(node, i)`) — raw index strings are
  engine-internal, never an author-facing concept.
- **Fractional indexing** (Figma base-95 arbitrary-precision strings; tldraw jittered
  `IndexKey`) is the modern consensus for sibling order: insert-between is O(1), no sibling
  renumbering; costs are slow string growth (rebalance occasionally) and collision-without-jitter.
- **tldraw's validated store** is the best engineering blueprint: per-type prop validators run
  on every write (malformed data fails loudly), snapshots carry the schema version, **up/down
  migrations are mandatory for every persisted-shape change**, and `.tldr` is just
  `{fileFormatVersion, schema, records[]}` JSON.
- tldraw's **two-write-tier footgun**: the high-level API accepts partials and fills defaults;
  the raw store requires complete records — and hand-built complete records are where
  programmatic authors produce invalid data.
- **Framer** (the only team that shipped "agent authors a design tree it can't see"): agents
  mutate via **streamed patch deltas against stable IDs**; they compressed the IR for token
  cost (short prop names, omit-default values) — "every token spent is directly used."
- **Excalidraw's reconciliation fields** (`version`, `versionNonce` tiebreaker) are a
  lightweight LWW scheme — evidence you can get far short of a CRDT.

**Verdict — ADOPT, superseding both spikes' nested `children[]` sketches:**
- Store = flat `id → node`; hierarchy via a single atomic `place: {parent, index}` field;
  jittered fractional index; branded prefixed IDs (`nd:`, `pg:`, `cmp:` …), caller-suppliable.
- The **op layer is the only author surface** and speaks intent (`insert(into, at)`, `move`),
  never raw index strings (Figma's API lesson).
- Ops accept **partials; the engine fills per-type defaults** (kills the tldraw footgun).
- **Migrations are day-one** (per-sequence up/down, run on load), not "additive-optional and
  hope" — agent-written documents outlive schema versions.
- Wire/econ: compact canonical prop names + omit-defaults on query output (Framer's token
  economics), full names in docs/schemas.
- Cross-cutting membership (an element in several perceptual groups — Bluefish's compound-graph
  critique of strict trees) is covered Excalidraw-style with **reference fields** (`tags`,
  `groupIds`-like) rather than a graph store — DEFER a true compound graph unless diagram modes
  demand it.

## 2. Layout — flow by construction; the solver is a trap (ADOPT D2, hardened)

**Established** (`layout-abstractions-blind-agents.md`, `declarative-grammars-constraint-layout.md`):

- Ranked for a *blind* author: **flow/flex/auto-layout > grid > constraint solver > absolute**.
  Flowed siblings **cannot overlap by construction** — the error class is eliminated, not
  detected. Absolute demands exactly what the LLM-layout literature documents as the models'
  weakness (precise coordinates, spatial hallucination); flow demands what they're good at
  (containment, ordering, relational intent).
- **Constraint solvers carry silent nondeterminism at production scale.** Apple's own docs:
  under-constrained layouts get an *arbitrary* solution that "may even change between
  launches," with **no console warning and no breakpoint**; conflicting required constraints
  break an arbitrary one "build to build." Cassowary is linear-only; GSS (Cassowary-in-browser)
  died as research. For an author who can't see pixels, a silent-wrong state is the worst
  possible failure shape.
- Flow's safety is **statically checkable without rendering** — "no overlap / on-canvas" is
  provable from the model alone; only `absolute` islands need a measured geometry pass.
- Intrinsic-sizing blowouts (a long word inflating a hug container) are flow's real failure
  mode — bounded and local, mitigated by **min/max clamps** on hug/fill.
- The third path — **combinator layout** (Haskell diagrams' envelope/trace monoids; SwiftUI's
  propose/choose/place) — is deterministic without a solver but pushes global alignment intent
  back on the author.
- **ALM's "tabstops"** (align to shared virtual lines rather than pairwise) is the readable
  middle ground *if* cross-container alignment intent is ever needed.

**Verdict — ADOPT auto-layout default (`stack`/`row`/`grid`/`wrap` lowered to flex/grid),
`absolute` opt-in per-frame; children carry intent (`grow/shrink/align/span` + min/max clamps).
The static half of lint (overlap-impossible proofs, clamp presence, off-canvas absolute) moves
INTO the core. REJECT any constraint solver permanently — record it as an anti-decision with
the Apple citations. DEFER tabstop-style shared guides (a v2 alignment affordance). The
browser computes all geometry — we never implement or vendor a layout engine.**

## 3. Styling & tokens — DTCG shape, semantic-tier discipline (ADOPT, pinned)

**Established** (`design-tokens-theming.md`, `ui-description-languages-machine-irs.md`):

- The convergent industry shape: **three tiers** (primitive → semantic → component), theming =
  swap values behind stable semantic names, runtime output = CSS custom properties. Material 3,
  Spectrum, Tailwind v4, SLDS all instantiate the same pattern.
- **The agent must reference tier-2 semantic tokens, never primitives/raw hex** — that single
  rule is what makes light/dark + retheme work; it's also the constrainability win (a token
  registry the fence can validate against) and the anti-Dreamweaver-bloat win (Webflow's
  shared-classes lesson: style as *named referenced units*, never per-node inline blobs).
- **DTCG format** (`$value`/`$type`, brace aliases, composite types, `$deprecated`): one report
  says the 2025.10 release is the stable version to target; another quotes the draft's "do not
  implement" warning and tool dialect drift (Tokens Studio legacy-vs-W3C) → resolved in §9:
  adopt the *shape*, pin the snapshot.
- Pitfalls to design in: component-token explosion (don't create tier-3 until 3+ components
  need it), broken aliases (renames = deprecate-and-alias, never hard-delete), composite-token
  partial-resolution failures.
- pix2code's durable ML finding: models get the **structural tree** right and hallucinate the
  **fine style detail** — pin structure crisply, delegate style precision to the token layer.

**Verdict — ADOPT: token store is DTCG-shaped, pinned to the 2025.10 snapshot; three tiers with
the fence steering agents to tier-2 (raw literals allowed, lint-flagged); deprecate-and-alias;
default token set derived from the live app theme (`ThemeDefinition` → `--cv-*`). DEFER tier-3
component tokens until kits demand them.**

## 4. Behavior, animation, timelines — four paradigms, one stack (ADAPT: data IR + op/DSL authoring surface)

**Established** (`animation-motion-representations.md`, `scene-identity-timeline-transitions.md`,
`slides-revealjs-impressjs.md`):

- Four paradigms — timeline/keyframe data (Lottie, Theatre.js), state machines (Rive, XState),
  code-driven (Motion Canvas, Remotion, Manim), reactive/derived (signals, updaters) — and the
  report's own conclusion: **"the best AI-authoring surface and the best persisted/WYSIWYG IR
  are different layers of the same stack, connected by a compiler."** That *is* our
  architecture: ops/verbs (code-like, LLM-native) author a declarative document (canvas-editable).
- **Lottie's `{a, k}` container** is the minimum-viable animation IR: *every* animatable
  property is either a constant or a keyframe array, encoded identically → one interpolation
  path for position/color/opacity/path alike. Easing = per-segment cubic-bezier handles with
  the value axis **unclamped** (that's how overshoot/anticipation is expressed). But raw Lottie
  is an *export target, not an authoring model* — agents must never hand-emit bezier tangent
  arrays (python-lottie exists precisely to compile a typed object API down to it).
- **Theatre.js** solves our exact round-trip: a JSON state that *both* code and the visual
  editor mutate — validating "document is the single source of truth, editor and agent are
  peers."
- **SMIL's `par`/`seq`/`excl` timing-container algebra** with **relational timing**
  (`begin="intro.end+0.5s"`) is the serializable, seekable dual of Motion Canvas's
  `all()`/`chain()` coroutines — for a *stored* document, the container tree wins (coroutines
  can't randomly seek). SMIL's fate (browser dead-end) is a distribution lesson, not a model
  refutation: a declarative motion IR needs a first-class runtime, not markup alone.
- **Motion Canvas's named "time events"** — code declares *wait-until("reveal beat")*, the
  human nudges the exact ms in the editor — is the cleanest intent/lowering seam for
  agent-authored, human-polished timing.
- **Rive** contributes two blueprints: the **state machine as the interactivity altitude**
  (states = configured scenes; typed inputs — bool/number/trigger; transitions with mix
  durations; parallel layers) and — the sleeper — **ViewModel data binding**: a *typed schema*
  of properties, separate from motion, instances holding live values; "what data drives the
  artifact" becomes a constrainable, verifiable surface independent of curves. Its `.riv`
  format's per-property type-tagged ToC (old runtimes skip unknown properties and still render)
  is the forward-compat north star.
- **WAAPI is the native compile target** (`KeyframeEffect` maps ~1:1 from a keyframe IR;
  compositor-threaded); **CSS scroll-driven timelines** make scrollytelling a declarative
  *trigger rebinding*, no JS.
- **Manim's `alpha ∈ [0,1] × rate_func`** is the universal tween primitive every system
  reduces to; its `TransformMatching*` family factors **matching out of tweening** via a
  pluggable key function.
- reveal.js (flow + fragments + `sync()`; LOW programmatic friction) validates the deck model;
  impress.js (author computes x/y/z/rotate for every step; HIGH friction) is the absolute-coords
  anti-pattern confirmed in the wild.

**Verdict — ADAPT into one stack:** persisted IR = `{a,k}` property containers + a
`par`/`seq`/`excl` timing tree with relational timing + named beats; deck fragments = step
indices (reveal's model); interactivity = closed verb set at v1, promoted to a Rive/XState-shaped
state machine (+ typed data schema) when state grows; lowering targets WAAPI/CSS (+ scroll-driven
timelines for scrollytelling). Agents author through timeline *ops* (`animate(node, prop, to,
over, after: "beat")`), never raw keyframe arrays. REJECT coroutine-as-truth and code-as-truth
(no seek, no round-trip); REJECT SMIL-as-output (dead target), keep its algebra.

## 5. Transitions & identity — the matching rule is the API (ADOPT; signature feature)

**Established** (`scene-identity-timeline-transitions.md`):

- Cross-state identity strategies: (1) persistent instance (Keynote), (2) author-assigned key
  (PowerPoint `!!name` — morphs *different* shapes), (3) content/structural inference (Manim
  shape-hash / tex-token; Shiki Magic Move via diff-match-patch), (4) none — pure `f(t)`
  (Lottie). **"The matching rule is the real API surface — interpolation is trivial once you
  know which A maps to which B."**
- Keynote's semantics are the cleanest: **set-diff over identity → matched interpolate,
  left-only fade out, right-only fade in** — the three-way partition *is* the animation spec.
  Its granularity ladder (object → word → char) applies one diff at multiple depths.
- PowerPoint's `!!` teaches the **two-tier identity system**: implicit instance matching by
  default, explicit stable key to force correspondence when intent diverges from appearance
  (1:1 per state; same-type constraints).
- Every heuristic matcher (Keynote instances, reveal auto-animate content-matching, Shiki's
  diff) exists because those systems *lack* stable IDs. **We have stable IDs natively.**

**Verdict — ADOPT as the signature presentation feature:** morph transition = set-diff on
record IDs across pages/steps (deterministic, no heuristics — something no HTML deck tool has),
plus an optional `morphKey` for A→B correspondences across *different* nodes (PowerPoint
lesson), plus Manim-style pluggable matching *later* for text-granularity morphs (word/char via
the RichText IR). Lowered as FLIP over WAAPI. Unmatched → fade partition, always.

## 6. Machine-authored IRs & generative UI — the empirical backbone (ADOPT practices)

**Established** (`ui-description-languages-machine-irs.md`, `explorables-llm-ui-generation.md`):

- **The convergent IR shape** across TeleportHQ UIDL, Plasmic, Mitosis, RICO, SwiftUI's
  builders, QML: a recursive typed-node structure where **control flow is structural**
  (`conditional` / `repeat` / `slot` node types — UIDL and SwiftUI's `_ConditionalContent`
  arrived at the same factoring independently) and **data flow is declarative bindings**
  (UIDL `dynamic`, Mitosis `bindings` vs `properties`, QML property bindings) — never embedded
  code strings.
- **AutoPresent: 2–11% → 80%+ executability** moving from raw API to purpose-built DSL; LIDA's
  generate→execute→filter gate; **Design2Code**: layout recall is the specific frontier-model
  weakness; **LayoutGPT**: CSS-shaped representations outperform novel syntax because the
  model has seen CSS at pretraining scale ("meet the training distribution").
- **DesignAsCode's two directly-actionable findings:** a *too-constrained* IR (bare coordinate
  JSON) measurably *hurts* visual quality vs code — the ceiling isn't free; and generated
  structure can't be trusted without **rendering and closing the loop** — the model is blind
  to its own visual output.
- **"Let Me Speak Freely":** forcing schema-constrained output during *reasoning* degrades task
  performance; the fix is plan free-form → emit constrained. Constrained decoding then gives
  100% schema adherence at the emission step.
- **SDUI at production scale** (Airbnb Ghost: self-contained sections + limited component
  vocabulary + small closed action set, one schema across platforms; Lyft Canvas: protobuf
  primitives, 40–60% smaller payloads): *"open-ended expressiveness is the enemy of a
  renderable, cross-target, machine-emitted UI document."*
- **Flutter's three trees** (authored widgets ≠ identity-holding elements ≠ render objects) and
  **Compose's SlotTable** (the "tree" as a flat gap-buffer array): don't conflate the stored
  document, the editing identity layer, and the render output; the store's physical layout is
  an engine freedom.
- Round-trip is "two one-way pipes in a trench coat" — one source of truth, codegen one-way and
  disposable. Dreamweaver's Roundtrip-HTML worked *only because* HTML was its source of truth.
- The no-code **80/20 ceiling**: systems that survive it (Plasmic, Builder) let real code
  components register as first-class nodes. Ship the escape hatch early or hit the wall.

**Verdict — ADOPT wholesale:** structural control-flow nodes (`conditional`/`repeat`/`slot`) +
declarative `bind`; CSS/Figma-familiar naming; plan-then-emit tool guidance + JSON-Schema op
envelopes (constrained decoding possible); lint-on-every-apply as the LIDA/DesignAsCode gate;
`embed` node in P1 and registered code-components as the reserved plugin shape; one-way export.
The Lona graveyard (bespoke multi-target compiler = maintenance liability Airbnb abandoned)
plus Mitosis's intersection-of-targets ceiling **defers multi-framework code export**: one
excellent HTML/CSS target first (Q10).

## 7. Grammars for data & diagrams (ADAPT: Vega-Lite subset; wrap graph layout; defer solvers)

**Established** (`declarative-grammars-constraint-layout.md`, `diagram-as-code.md`):

- The stable chart core across ggplot2 / Vega-Lite / Observable Plot: **marks + encodings +
  scales + transforms — no chart-type menu**; Vega-Lite's unit spec `{data, transform, mark,
  encoding}` + composition algebra (`layer`/`concat`/`facet`/`repeat`) is the de-facto
  LLM chart target already.
- Full Vega (reactive dataflow graph) is the heavyweight model for deeply interactive
  visualization — more than v1 needs.
- Graph auto-layout is a solved sub-problem to **wrap, not reinvent** (Graphviz Sugiyama/
  network-simplex; D2's swappable dagre/ELK engines; mermaid's documented "auto-layout is a
  feature and a cage").
- Penrose (Domain/Substance/Style + differentiable optimization) and Bluefish (relations over
  compound graphs) are the research frontier for constraint diagramming — both explicitly
  not-production.
- Charticulator's architecture lesson: **the GUI and the agent author the same saved spec** —
  the spec is the artifact, the GUI is one editor of it.

**Verdict — ADAPT: `chart` node props follow the Vega-Lite encoding shape (curated subset —
mark + channel encodings + a few transforms), lowered to hand-rolled SVG marks (D4, no dep).
Diagram modes wrap the existing `DiagramRegistry` (mermaid/dot) for graph auto-layout; a
native diagram kit uses connector shapes anchored to node IDs. REJECT (permanently) building a
constraint/optimization layout engine; DEFER Penrose/Bluefish-style declarative diagramming as
a watch-item.**

## 8. Structured documents without text — the obligations we inherit (ADOPT mitigations)

**Established** (`projectional-editing-content-addressed.md`, `semantic-to-visual-cross-domain.md`):

- The projectional-editing graveyard (Intentional, Darklang's editor) vs the survivors (MPS,
  Unison): **the ergonomic tax killed systems where humans hand-drove structure**; it
  evaporates when the human sees a projection (our WYSIWYG) and the machine authors the model.
  What does *not* evaporate: you forfeit grep/diff/git and must consciously re-provide
  **diff/merge/review/search** for the structured format.
- **Unison's content-addressing** buys perfect caching (unchanged subtrees never recompute) and
  move-vs-edit structural diffs; **Hazel's typed holes** keep a document meaningful mid-edit.
- Cross-domain (MusicXML/LilyPond, CAD): semantic and layout models **don't round-trip
  cleanly — decide per-property whether the model or the renderer owns it** (MusicXML's
  advisory `default-x` that importers ignore is the anti-pattern); the **topological-naming
  trap** (CAD's Face13→Face14) is what happens to any system that references by
  ordinal/position — stable IDs at creation + fail-loud on dangling references.
- **Declarative data beats executable models** (PDF vs PostScript): random access, diffing,
  incremental render, safety — a WYSIWYG canvas is retained-mode by definition; commit to it.

**Verdict — ADOPT the mitigations:** canonical **text** JSON on disk (git + the app's own diff
viewer stay useful — this is load-bearing, not cosmetic; rules out binary-only persistence);
`hole` node type; per-property ownership declared in the schema (model-owned vs renderer-owned —
geometry is renderer-owned and only ever *reported back*, never stored as truth); dangling
references fail loud with repair suggestions; content-hash subtree fingerprints as the
incremental-lowering/cache key (deferred perf lever). Documents stay **data, not programs** —
behaviors are a closed interpreted verb set (the PostScript lesson is why).

## 9. Contradictions between reports — resolved

| # | Tension | Resolution |
|---|---|---|
| C1 | DTCG "2025.10 is stable, target it" (tokens report) vs "draft says do-not-implement; tool dialects drift" (IR report) | Adopt the **format shape**, pin the 2025.10 snapshot, write our own validator; treat cross-tool interop as best-effort. The shape is convergent even if the spec churns. |
| C2 | Flat store (research) vs nested trees (both original spikes) | Flat store wins on the evidence (§1); the tree is the *derived* view (and the on-disk records list is still human-diffable). |
| C3 | "Code-driven is the best LLM fit" (animation report ¶1) vs data-IR-as-truth (our design) | Both, layered: the *authoring surface* is ops/verbs (code-shaped, LLM-native); the *truth* is declarative data; the op layer is the compiler between them — the animation report's own synthesis. |
| C4 | "Absolute scene coords are easier for a blind agent" (Excalidraw pitfall note) vs auto-layout default | The agent never computes *inputs* in coordinates (flow default); it reads *outcomes* as resolved absolute boxes via geometry queries. Query-side absolute, author-side intent. |
| C5 | "Meet the training distribution — CSS-shaped reprs win" vs "don't let agents write raw CSS" | Familiar **vocabulary**, constrained **structure**: closed style props with CSS-familiar names and token values — not pass-through CSS strings. |
| C6 | Vega's reactive dataflow (best for deep interactivity) vs a static record store | Static records + declarative `bind` (QML-style) for v1; the dataflow graph is the documented escalation path if explorables outgrow bindings. |
| C7 | reveal.js flow decks (low friction) vs impress.js free spatial decks (total control) | Deck mode is flow-first (fragments/steps); free-spatial "prezi-style" belongs to the deferred `board` kind — not worth absolute-coords friction as the default. |

## 10. What the analysis rejects outright (anti-decisions, recorded)

1. **Constraint-solver layout** — silent ambiguity/unsatisfiability at production scale (Apple's
   own documentation); linear-only limits; the blind author cannot notice arbitrary solutions.
2. **HTML as source of truth** — unlintable, untyped, un-diffable, round-trip trap (both spikes
   agreed; SDUI/Plasmic/Mitosis all model-first).
3. **Raw SVG / raw keyframe arrays as agent surfaces** — documented LLM degradation with
   complexity (SVGenius); bezier-tangent JSON is a compile target, not an authoring format.
4. **Executable documents** (scripts as content) — the PostScript lesson; behaviors stay a
   closed interpreted verb set; arbitrary JS only inside the sandboxed `embed`/code-component
   escape hatch, never in the document model proper.
5. **Bespoke multi-framework codegen at v1** — Lona's fate + Mitosis's intersection ceiling;
   one HTML target done excellently, framework export tiered later (Q10).
6. **A CRDT at v1** — Figma ships LWW-per-property; Excalidraw ships version+nonce; our
   single-writer rev protocol suffices, and the flat-record model keeps the CRDT door open.

## 11. Net effect on the design

Everything above lands in the v2 doc set as: the flat record store + atomic `place` +
migrations (`02-CORE-ENGINE.md` §2–3), the op fence & partials-with-defaults (§4), DTCG tokens
(§5), structural control flow + bindings (§6), the `{a,k}`/timing-tree/state-machine stack
(§7), core static lint + the measured-lint split (§8), lowering/patch plans + per-property
ownership (§9), the morph feature (`04-MODES-AND-USES.md`), and the plan-then-emit +
query-tiers agent contract (`03-SHELLS.md`). The roadmap's P0 adds a patch-loop spike; the
decision list gains Q9–Q12.
