# Agent addb77f4127859ff2.output

## Prompt (first 300 chars)
I'm doing open-ended design research. Background: we're designing a system where a program authors visual artifacts against a HIGH-LEVEL SEMANTIC / INTENT model, which is then rendered ("lowered") to a final visual/display form. Some artifacts are ANIMATED (slide decks with transitions, animated exp

## Final message

I have comprehensive primary-source material across all 7 systems plus a bonus (Shiki Magic Move). Here are the findings.

---

# Scene / identity / timeline / transition models across presentation & animation systems

**Lead synthesis (the transferable core, expanded per-system below).** Across these systems, the single most transferable distinction for your "author intent, then lower" design is *how object identity is established across states*, and it splits into four strategies:

1. **Identity by persistent instance/ID** (Keynote, PowerPoint default, Rive) — the object literally *is* the same object across states; the tool diffs two configurations of one scene graph.
2. **Identity by stable name/key the author assigns** (PowerPoint `!!`, Manim `TransformMatchingTex` on `tex_string`) — decouples identity from instance, lets *different* things morph into each other.
3. **Identity by content hash / structural matching** (Manim `TransformMatchingShapes`, Shiki Magic Move via diff) — identity is *inferred* from the artifacts themselves, no author bookkeeping.
4. **No cross-state identity — everything is a function of time** (Lottie, Remotion, SMIL, Motion Canvas) — there are no "two states to reconcile"; a value is a pure function `f(t)` and transitions are just the shape of that function.

The "specify WHAT changes, not HOW to tween" goal is realized by strategies 1–3 (you declare two end-states + a matching rule; the engine *derives* the tween), whereas strategy 4 makes you (or a helper) still author the interpolation curve. The richest lesson is that **the matching rule is the real API surface** — position, size, color interpolation is trivial once you know *which A maps to which B*.

---

## 1. Keynote "Magic Move" (Apple)

**What it is.** A slide-to-slide transition that auto-animates objects shared between two slides.

**Model.** Apple's official help states the model plainly: *"Any objects appearing on both slides become part of the transition"*, with three matching granularities — **By Object**, **By Word**, **By Character** — and the fallback: *"Any objects appearing on the first slide, but not the following slide, fade out. Any objects appearing on the following slide, but not the original slide, fade in."* ([keynote.skydocu.com](https://keynote.skydocu.com/en/animate-your-slides/add-a-magic-move-transition/)) So the transition is a **set-diff over a shared identity space**: matched → interpolate, left-only → fade out, right-only → fade in. The By-Word / By-Character modes are notable: identity descends *into* a text object down to sub-glyph granularity, so a paragraph reflow animates each word/char to its new position.

**Transferable idea.** The set-diff-with-fade-fallback is the cleanest possible transition semantics: you never specify a tween, only which elements exist in each state; the three-way partition (matched/entering/leaving) *is* the animation spec. The graduated granularity (object → word → char) is a strong pattern for a document system — the same "diff two states" machinery applied at multiple structural depths.

**What breaks / honest limits.** Identity is by **persistent object instance**, not a user-facing name. Duplicating the slide (or copy-pasting the object forward) is what preserves identity. Community-documented failure mode: *"Magic Move doesn't support linking different objects so that they can be animated between — the objects must be the same,"* and the workaround is to stack both objects on both slides and cross-fade via opacity, **not** any naming mechanism ([georgegarside.com](https://georgegarside.com/blog/macos/keynote-magic-move-two-different-objects/)). **Correction to a common claim:** the widely-repeated "objects must have the same *name*" rule is **UNVERIFIED** against Apple's own docs — that page describes no naming mechanism (it appears to be conflated with PowerPoint's `!!` feature; see below). Best read: Keynote = pure instance-identity, no author-assignable key.

---

## 2. PowerPoint "Morph" (Microsoft)

**What it is.** Microsoft's counterpart transition, and the interesting divergence from Keynote is that it exposes an **author-assignable matching key**.

**Model.** Default identity is by instance (duplicate the slide / copy-paste the object forward). But Microsoft documents an explicit override: *"begin an object name with `!!` (two exclamation points) and… assign the same custom name to the two objects,"* and then *"If Morph sees two objects of the same type with the same name, starting with `!!`, across two slides, it'll morph one to the other"* — including *"between different shapes (such as a circle and a square)."* Interpolated properties: position, size, rotation, color/formatting, 3-D rotation, and text by word/character ([support.microsoft.com](https://support.microsoft.com/en-us/office/morph-transition-tips-and-tricks-bc7f48ff-f152-4ee8-9081-d3121788024f)).

**Transferable idea.** This is the key lesson for programmatic authoring: **a two-tier identity system — implicit instance identity, with an explicit named-key escape hatch.** Most matches are automatic (cheap, no bookkeeping), but when the author *knows* two semantically-different things are "the same element playing a new role," a stable string key forces the correspondence and unlocks shape-to-shape morphing. A program authoring documents wants exactly this: default to structural/instance matching, allow an explicit `id` to override when intent diverges from appearance.

**What breaks / honest limits.** Microsoft notes Morph expects a **1:1 mapping** — a given `!!name` should be unique per slide, else matching is ambiguous. Same-type constraint applies for the `!!` morph (circle→square works, but type matters). Fade fallback for unmatched, same as Keynote.

---

## 3. Manim (mobject model + Transform family)

**What it is.** The Python engine behind 3Blue1Brown; scenes are authored as code, animations are objects.

**Model — the mobject.** A `Mobject` stores geometry as a `points` NumPy array plus a **tree of `submobjects`** ("The contained objects"), color, and `z_index`; `target` supports deferred-state animation. Key methods: `become()` ("Edit points, colors and submobjects to be identical to another Mobject"), `match_points()`, `align_data()` ("Aligns the family structure and data of this mobject with another mobject"), and `interpolate()` ("Turns this Mobject into an interpolation between mobject1 and mobject2") ([docs.manim.community/Mobject](https://docs.manim.community/en/stable/reference/manim.mobject.mobject.Mobject.html)).

**Model — Transform internals.** `Transform.begin()` copies the target and calls `align_data()`/`align_data_and_family()` to force source and target to have **matching point counts and submobject hierarchies** (padding the shorter side). Then `get_all_families_zipped()` zips the source, starting-copy, and target families into aligned tuples, and `interpolate_submobject()` calls `submobject.interpolate(start, target, alpha, self.path_func)` — so every point travels along `path_func` (default straight-line; `path_arc` bends it) as `alpha` goes 0→1 ([docs.manim.community transform source](https://docs.manim.community/en/stable/_modules/manim/animation/transform.html)). This is the "align then lerp every point" approach — brute-force but general.

**Model — the transferable jewel: `TransformMatching*`.** `TransformMatchingAbstractBase` builds identity via three overridable hooks: `get_mobject_parts()` (which submobjects to consider), `get_mobject_key()` (the matching key), and `get_shape_map()` (bucket parts by key). Two concrete keying strategies ([docs.manim.community transform_matching_parts source](https://docs.manim.community/en/stable/_modules/manim/animation/transform_matching_parts.html)):
- **`TransformMatchingShapes`** keys on a **geometry hash**: normalize each piece (center to origin, set height to 1 unit, round points to 3 decimals), then `hash(rounded_points.tobytes())`. Two pieces with the same *normalized shape* are declared "the same object" and morph into each other — **identity inferred from appearance, no author labels**.
- **`TransformMatchingTex`** keys on `mobject.tex_string` — two glyphs match iff their LaTeX source substring matches. **Identity by semantic source token**, not appearance. So `x^2 + y^2` → `x^2 + z^2` animates the shared `x^2`, `y^2` fades to `z^2`.

Matched keys → `Transform`; unmatched → three configurable policies: default `FadeOut(source)` + `FadeIn(target)`, or `transform_mismatches=True` → `Transform`, or `fade_transform_mismatches=True` → `FadeTransformPieces`. A `key_map` param lets the author manually override specific pairings.

**Transferable idea.** Manim cleanly *factors matching out of tweening*: the key function is a plug-in. Same tween machinery, swap the identity policy (shape-hash vs. source-token vs. manual `key_map`). For a document system this is the exact abstraction — one interpolation engine, pluggable "what counts as the same element" strategies, with fade as the universal fallback for the unmatched set.

**What breaks / honest limits.** `align_data`'s pad-to-match-point-counts produces visually odd interpolations when shapes are structurally very different (points get invented/split). The shape-hash key is brittle to sub-threshold geometry differences (rounding to 3 decimals means near-identical-but-not shapes fail to match). `ReplacementTransform` vs `Transform` have a notorious footgun around which mobject remains in the scene afterward (identity-in-the-scene-graph confusion). It is an *offline render* engine — no interactivity, no real-time constraint.

---

## 4. Motion Canvas

**What it is.** A TypeScript library + editor for programmatic motion graphics, built on **generator/coroutine timelines** plus a **reactive signal** graph.

**Model — coroutines as timeline.** Scenes are generator functions: `makeScene2D(function* (view) { … })`. `yield` means *"the current frame is ready, display it and come back to me later"*; the player advances the generator frame-by-frame via `next()`. `yield*` delegates to sub-generators, so animation logic composes. Tweens are themselves generators: `yield* myCircle().fill('#e6a700', 1)` animates fill over 1 second. Flow combinators: `all()` (concurrent), `any()` (finish on first), `chain()`/`sequence()` (sequential), `loop()`, `delay()`, `waitFor()`, `waitUntil()` ([raw flow.mdx](https://raw.githubusercontent.com/motion-canvas/motion-canvas/main/packages/docs/docs/getting-started/flow.mdx)).

**Model — reactive signals.** *"Signals represent animatable properties of nodes."* `SimpleSignal` for scalars (opacity), `Vector2Signal`/`CompoundSignal` for compounds (position); all are *"tweened over time using the `yield*` syntax."* The `Project` orchestrates a `PlaybackManager` (time), `Renderer` (output), and `Scene` node hierarchies ([deepwiki motion-canvas](https://deepwiki.com/motion-canvas/motion-canvas)). Signals are functions with dependency tracking — read a signal, get its current value; computed signals recompute reactively.

**Transferable idea — two of them.** (a) **Coroutines make "sequence vs. parallel" a language-level concern, not a data-structure concern:** `yield*` A then `yield*` B is sequential; `all(A, B)` is parallel; the timeline is *implicit in control flow* rather than an explicit keyframe table. This is a very different authoring model from Lottie/Remotion and is arguably the most natural for a *program* emitting animation (you write the story; the timeline falls out). (b) **`waitUntil` + named Time Events** — the editor surfaces named sync points on the timeline whose delay the human can nudge without touching code (search-derived from [motioncanvas.io/docs/time-events](https://motioncanvas.io/docs/time-events/), page not fetched — **partially verified**). That's a clean intent/lowering seam: code declares *"wait until the 'reveal' beat"*; the exact millisecond is a lowering-time parameter.

**What breaks / honest limits.** The team explicitly weighed and *rejected* async/await in favor of generators because *"you can explicitly progress them each frame by calling `next` and cancel them by calling `return`"* — async promises can't be stepped or cancelled deterministically (search-derived, [discussion #941](https://github.com/orgs/motion-canvas/discussions/941), not fetched — **UNVERIFIED**). Practical cost: generator-based timelines are hard to *randomly seek* (you may have to replay from the start to reach frame N, unlike a pure `f(t)` model), which complicates scrubbing/caching.

---

## 5. Rive

**What it is.** An interactive-animation tool where **design + state logic ship together** in one binary runtime format; the defining feature is a **state machine** as a first-class authoring primitive.

**Model — the `.riv` format (genuinely instructive IR design).** Little-endian binary. Header = `Fingerprint` (4 bytes ASCII "RIVE", `0x52 0x49 0x56 0x45`), `Major Version` (varuint; current major = **7**, hard-incompatible across majors), `Minor Version` (forward-compatible within a major), `File ID`, then a **Table of Contents**. The ToC lists every property key present with a **2-bit backing-type tag** (0=Uint/Bool, 1=String, 2=Float, 3=Color). Content is *"a list of objects, each containing a list of their properties,"* each object a varuint type-key, properties terminated by a `0` varuint; parent links are *"an unsigned integer representing the index within the Artboard"* and objects are emitted in hierarchical context (a Shape always after its Artboard) ([rive.app/docs/…/format](https://rive.app/docs/runtimes/advanced-topic/format)).

The **killer design property:** *"If a runtime knows the type key, it will know the backing type… If it is unknown, it can determine from the ToC what the backing type is and read past it."* An old runtime can load a newer file, skipping objects/properties it doesn't understand, and still render. This is **schema-evolution baked into the wire format** via per-property type tags — the single most transferable idea in this whole cluster for anyone designing a persisted IR.

**Model — the state machine.** States are *"timeline animation (like 'Idle' or 'Pressed')… also a blend of animations or a placeholder state like 'Exit.'"* States are connected by **transitions** with conditions; **Layers** run in parallel and mix; **Listeners** (Pointer Enter/Exit/Click) fire logic on interaction; **Data Binding** maps live app data (selections, API responses) onto artboard properties ([rive.app/blog/how-state-machines-work](https://rive.app/blog/how-state-machines-work-in-rive)). **Inputs** drive transitions and come in exactly three kinds: **Trigger** (`fire()`), **Number** (`SMINumber`, `.value`), **Boolean** (`SMIBool`, `.value`), retrieved via `stateMachineInputs('name')` / `useStateMachineInput` / `findInput<T>(name)` ([help-center state-machines.md](https://raw.githubusercontent.com/rive-app/help-center/master/runtimes/state-machines.md)).

**Model — blending math.** `BlendStateInstance` orchestrates several `BlendStateAnimationInstance`s, each wrapping a `LinearAnimationInstance` + an `m_Mix` weight (0–1). Final weight is hierarchical: `finalMix = stateMachineMix × animationMix`. Two-phase per frame: **`advance()`** progresses *all* animations regardless of mix (so events still fire at mix 0), then **`apply()`** writes each animation's keyed property values at its mix strength onto shared properties (skipping mix==0). `NestedRemapAnimation` extends this to nested artboards; `AnimationReset` restores properties when leaving a state ([deepwiki animation-blending](https://deepwiki.com/rive-app/rive-runtime/4.3-animation-blending)).

**Transferable idea.** (a) The **self-describing, type-tagged, forward-compatible binary IR** — directly relevant to your "lowered" artifact format. (b) **State machine as the authoring altitude**: the author declares *states* (each a whole configured scene) and *transition conditions over typed inputs*; the runtime derives the moment-to-moment blend. That's "specify WHAT (which state) not HOW (the tween)" at the coarsest useful grain. (c) **advance/apply split** — decoupling "time progresses everywhere" from "what's visible this frame" is a clean pattern for deterministic, mixable state.

**What breaks / honest limits.** Blending assumes animations touch *overlapping properties additively/proportionally*; conflicting absolute writes to the same property across layers need explicit ordering. Major-version incompatibility is hard (a v7 runtime cannot open a v6 file at all — the graceful-degradation is *within* a major only). Data-binding logic living inside the file blurs the design/logic boundary (powerful, but a versioning/testing liability).

---

## 6. Lottie / Bodymovin

**What it is.** After Effects animations exported (by the Bodymovin plugin) to a **declarative JSON IR** that platform-native runtimes replay. The purest "designed in a GUI, lowered to portable data" example.

**Model.** Root **Animation** object: `ip` (in-point frame), `op` (out-point / duration), `fr` (fps), `w`/`h`, `ver`, `layers`, `assets`, `markers` (named sections), `slots` (id-keyed property overrides). **Layers** typed by `ty`: 0=precomp, 1=solid, 2=image, 3=null (grouping), 4=shape. Every **animatable property** is a container `{a, k}`: `a:0` static (`k` is the value) vs `a:1` animated (`k` is a keyframe array). **Keyframes**: `t` (frame), `s` (value at keyframe), `h` (hold flag), and `i`/`o` = *"easing tangent going into the next keyframe"* / *"leaving the current keyframe"* (the bezier control handles). Transform `ks`: `a` anchor, `p` position, `s` scale, `r` rotation, `o` opacity, `sk`/`sa` skew. Shapes array typed by string `ty`: `"sh"` path, `"el"` ellipse, `"rc"` rect, `"sr"` polystar, `"gr"` group, `"fl"` fill, `"st"` stroke, `"tm"` trim-path. Precomps referenced via `refId` into `assets`. Keys are deliberately 1–2 chars to shrink payload ([lottie-spec schema](https://lottie.github.io/lottie-spec/1.0.1/specs/schema/)).

**Transferable idea.** The **`{a, k}` animated-property container** is a beautifully uniform design: *every* property is either a constant or a keyframed function, encoded identically, so the runtime has one interpolation code path for all of position, color, opacity, path vertices. Interpolation between keyframe `n` and `n+1` is a cubic-bezier ease defined by the `o` of `n` and `i` of `n+1` (with `h` for stepped/hold) — the *transition shape is data, per-property, per-segment*, not code. This is the archetype of your "high-level model lowered to a replayable declarative artifact."

**What breaks / honest limits.** Lottie is a *lowered* format — it has **no notion of object identity across two authored states to reconcile**; it's already the flattened `f(t)` per property. So it teaches IR design, *not* the intent-level matching problem (that lives in After Effects, upstream). Runtime feature parity is famously uneven across platforms (web/iOS/Android/renderers support different subsets of shape/effect/matte features) — the open **Lottie spec** effort (lottie.github.io) exists precisely because Bodymovin's output outran any single spec. Expressions and many AE effects don't export.

---

## 7. SMIL

**What it is.** W3C's XML language for declarative multimedia timelines (SMIL 1.0 in 1998, SMIL 3.0 Recommendation Dec 2008); its timing/animation modules were factored to be *embeddable* in other XML languages — notably SVG animation.

**Model.** Timeline containers: **`<par>`** (children play in parallel), **`<seq>`** (sequentially), **`<excl>`** (exclusive/event-interrupt — only one child active at a time). Timing attributes: `begin`, `end`, `dur`, `repeatCount`, plus event- and `wallclock()`-based triggers. Animation module: `<animate>` (interpolate a value), `<set>` (assign), `<animateMotion>` (move along a path), `<animateColor>`. SMIL is *"one of three means by which SVG animation can be achieved (the others being JavaScript and CSS)"* ([Wikipedia: SMIL](https://en.wikipedia.org/wiki/Synchronized_Multimedia_Integration_Language)).

**Transferable idea.** The **`par`/`seq`/`excl` container algebra** is the declarative dual of Motion Canvas's `all`/`chain` coroutine combinators — the same "parallel vs. sequential vs. exclusive" composition, but as a *nestable tree of timing containers* you can serialize, rather than control flow you must execute. For a document IR that must be *stored and re-timed*, the container-tree form is more inspectable and seekable than coroutines. Timing is **relational** (`begin="X.end+2s"` — start relative to another element's event), which is exactly intent-level ("after the intro finishes") rather than absolute-millisecond.

**What breaks / honest limits.** SMIL-in-SVG (declarative SVG animation) is effectively a dead-end on the web: browser support stalled and Chrome announced intent to deprecate SVG SMIL around 2015 (later suspended under pushback), pushing developers to CSS/Web Animations API — **UNVERIFIED here** (widely reported; I did not fetch a primary source this session). The relational timing model, while elegant, has notoriously subtle edge semantics (restart, fill, syncbase resolution) that made robust cross-implementation behavior hard — a cautionary tale that *expressive declarative timing is hard to implement consistently*.

---

## Bonus find — Shiki Magic Move (Anthony Fu)

**Why it matters to you.** A from-scratch reimplementation of Keynote's Magic Move *for code tokens*, and the author documents the matching algorithm explicitly — directly relevant to animating *text/structured documents*.

**Model.** Transitions partition tokens into **Move** (in both), **Enter** (after only), **Leave** (before only). The naive approach — pair tokens by content — fails on **1-to-many / many-to-1** (a common token like `(` appears many times and "transitions off to the wrong place"). The fix: run **Google's `diff-match-patch`** text-diff between the two code strings to find *matched chunks*, and pair Move tokens *within* those chunks, so tokens can't jump to the wrong instance. Enter/Leave animate via opacity; Move animates via the **FLIP technique** (First-Last-Invert-Play: measure old & new positions, apply an inverting transform, then animate it to zero) using absolute positioning ([antfu.me/posts/shiki-magic-move](https://antfu.me/posts/shiki-magic-move)).

**Transferable idea.** Two gems. (1) **Use a sequence-diff (LCS/diff-match-patch) as the identity oracle for content that has order and repetition** — it solves the exact "which of the N identical `x`s maps to which" problem that pure content-hashing (Manim's approach) can't. For animating document text/AST changes, diffing the token stream *is* the object-matching layer. (2) **FLIP** is the standard trick to get "specify only end-states, browser computes the tween" — you never write the motion, you let layout settle then invert-and-release. That's the DOM-native embodiment of "declare WHAT, derive HOW."

---

## Cross-cutting comparison

| System | Identity across states | Timeline representation | Transition = ? | "WHAT not HOW"? |
|---|---|---|---|---|
| Keynote Magic Move | persistent instance | two slides (state pair) | set-diff → interp/fade | yes (declare 2 states) |
| PPT Morph | instance + `!!name` key | two slides | set-diff w/ named override | yes, + escape hatch |
| Manim | shape-hash / `tex_string` / `key_map` | imperative `play()` calls | align-points + lerp per submobject | yes (pluggable matcher) |
| Motion Canvas | node refs (persistent) | **coroutines** (`yield*`) + signals | generator tween | partial (you write tween gens) |
| Rive | persistent objects + typed inputs | **state machine** + blended layers | condition-driven state blend | yes (declare states+conditions) |
| Lottie | none (already lowered) | keyframe tables per `{a,k}` prop | bezier ease data per segment | no (it's the HOW, lowered) |
| SMIL | element id / relational | **container tree** (`par`/`seq`/`excl`) | declarative animate elements | yes (relational timing) |
| Remotion | none (pure `f(frame)`) | `Composition` + nested `Sequence` | `interpolate()`/`spring()` you write | no (you compute per frame) |

**Two axes worth internalizing for your design:**

- **Matching altitude:** instance-identity (Keynote/Rive) < author-key (PPT `!!`, Manim `key_map`/`tex_string`) < inferred (Manim shape-hash, Shiki diff). Your program-authored system probably wants *inferred-by-default with an author-key override* — Manim's factored `get_mobject_key()` + `key_map`, or PPT's implicit+`!!`, are the two proven blueprints.
- **Timeline altitude:** pure `f(t)` (Lottie/Remotion — seekable, cacheable, but you author the HOW) vs. coroutines (Motion Canvas — natural to *emit* from a program, but hard to seek) vs. container-tree (SMIL) vs. state-machine (Rive — coarsest, most "intent"). For *animated documents authored by a program*, the sweet spot is likely a **state/keyframe declaration lowered to `f(t)`** (Lottie's `{a,k}` uniform-property container is the reference IR) with **object identity carried by stable keys** so successive states auto-diff (Magic Move / Morph semantics) — i.e., combine Rive's forward-compatible type-tagged IR + Lottie's uniform animated-property container + PowerPoint/Manim's implicit-plus-named matching + Magic Move's matched/enter/leave partition as the universal transition primitive.

### Fetched primary sources (all verified this session unless labeled)
Keynote: [skydocu help](https://keynote.skydocu.com/en/animate-your-slides/add-a-magic-move-transition/), [georgegarside](https://georgegarside.com/blog/macos/keynote-magic-move-two-different-objects/) · PPT Morph: [Microsoft Support](https://support.microsoft.com/en-us/office/morph-transition-tips-and-tricks-bc7f48ff-f152-4ee8-9081-d3121788024f) · Manim: [Mobject ref](https://docs.manim.community/en/stable/reference/manim.mobject.mobject.Mobject.html), [transform source](https://docs.manim.community/en/stable/_modules/manim/animation/transform.html), [transform_matching_parts source](https://docs.manim.community/en/stable/_modules/manim/animation/transform_matching_parts.html) · Motion Canvas: [flow.mdx (raw)](https://raw.githubusercontent.com/motion-canvas/motion-canvas/main/packages/docs/docs/getting-started/flow.mdx), [DeepWiki](https://deepwiki.com/motion-canvas/motion-canvas) · Rive: [.riv format](https://rive.app/docs/runtimes/advanced-topic/format), [state-machines.md (raw)](https://raw.githubusercontent.com/rive-app/help-center/master/runtimes/state-machines.md), [blog](https://rive.app/blog/how-state-machines-work-in-rive), [DeepWiki blending](https://deepwiki.com/rive-app/rive-runtime/4.3-animation-blending) · Lottie: [lottie-spec schema](https://lottie.github.io/lottie-spec/1.0.1/specs/schema/) · SMIL: [Wikipedia](https://en.wikipedia.org/wiki/Synchronized_Multimedia_Integration_Language) · Remotion: [fundamentals](https://www.remotion.dev/docs/the-fundamentals), [interpolate](https://www.remotion.dev/docs/interpolate), [use-current-frame](https://www.remotion.dev/docs/use-current-frame) · Bonus: [Shiki Magic Move](https://antfu.me/posts/shiki-magic-move).

**Labeled UNVERIFIED / not-fetched:** Keynote "same-name required" claim (contradicted by Apple's own help); Chrome's SVG-SMIL deprecation history; Motion Canvas Time-Events editor detail and the async-vs-generator rationale (search snippets only, source pages 403'd/not fetched). The Lottie per-segment cubic-bezier easing math is inferred from the confirmed `i`/`o` tangent fields; the tangent handles themselves are verified.
