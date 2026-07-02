# Agent a863676171cd21772.output

## Prompt (first 300 chars)
I'm researching a design problem and need genuine, fresh web research with primary sources.

The design problem: someone is building a system where AI agents (and humans) author visual documents — including ANIMATED EXPLAINERS and motion graphics — in a WYSIWYG canvas whose final output is HTML/CSS/

## Final message

I have deep, well-sourced coverage across all the requested tools plus several under-used angles. Here is my synthesis.

---

# How animation & motion graphics are represented as data / high-level models

## The core finding: there are ~4 paradigms, and they are NOT interchangeable for an AI author

Everything I surveyed sorts into four representation paradigms. The tension in your problem is really a tension between these, and the non-obvious answer is that **the best AI-authoring surface and the best persisted/WYSIWYG IR are probably different layers of the same stack, connected by a compiler** — not one format doing both jobs.

| Paradigm | Source of truth | Examples | AI-authorable? | WYSIWYG-editable / round-trippable? | Interactivity |
|---|---|---|---|---|---|
| **Timeline + keyframes (declarative data)** | JSON/XML scene doc | Lottie, Theatre.js state, SMIL, WAAPI keyframes | Emittable but brittle raw; great as a *compile target* | Yes — this is what canvases edit | Weak/bolted-on |
| **State machine / interactive graph** | States + transitions + typed inputs | Rive, dotLottie state machines, XState/SCXML | Very — constrainable & verifiable | Partly (graph editors) | Native/first-class |
| **Code-driven / programmatic** | A program | Motion Canvas, Remotion, Manim | Best fit for LLMs (they emit code) | Poor round-trip (the hard problem) | Via code |
| **Reactive / derived** | Values as functions of other values | Motion Canvas signals, Manim updaters | Very expressive for AI | Hard to represent in a canvas | Via dependencies |

Below, each item with: **(1) what · (2) how it models · (3) why it matters here · (4) what breaks / maturity.**

---

## TIMELINE + KEYFRAME MODELS (declarative data — the natural persisted IR)

### Lottie / Bodymovin — the reference "animation as portable JSON"
**(1)** JSON vector-animation format, originally exported from After Effects via the Bodymovin plugin, now with a community spec and independent tooling. There is a formal spec at `lottie.github.io/lottie-spec` and a machine-readable JSON Schema. ([spec home](https://lottie.github.io/lottie-spec/1.0/), [JSON Schema](https://lottiefiles.github.io/lottie-docs/schema/))

**(2)** Concrete model — this is worth internalizing because it's the most battle-tested "portable animation document" on the planet:
- Top-level **Animation** object: `fr` (framerate), `ip`/`op` (in/out point in frames = the duration), `w`/`h`, `layers[]`, `assets[]`. ([single-page spec](https://lottie.github.io/lottie-spec/1.0/single-page/))
- **Layers** discriminated by `ty`: `0` precomp, `1` solid, `2` image, `3` null (grouping), `4` shape, plus text. Every visual layer has a transform `ks` with animatable `a` anchor, `p` position, `s` scale, `r` rotation, `o` opacity, `sk`/`sa` skew. Parenting via `parent` → another layer's `ind`, and the CTM compounds `CTM(child) = CTM(parent) × Transform(child)`. Precomps get time controls: `sr` time-stretch, `st` start-time, `tm` time-remap. ([single-page spec](https://lottie.github.io/lottie-spec/1.0/single-page/))
- **The keyframe model is the crux.** Any property is an object with `a` (0/1 = animated?) and `k`. If static, `k` is the value; if animated, `k` is an **array of keyframes sorted by ascending `t` (frame number)**. Each keyframe: `t` time, `s` value, `h` hold flag, and `i`/`o` **easing handles**. Easing is a cubic Bézier from `[0,0]`→`[1,1]` where handle `x` is the time axis (clamped 0–1) and `y` is the value axis — and crucially **`y` is NOT clamped**, which is how overshoot/anticipation is expressed. ([Properties spec](https://lottie.github.io/lottie-spec/1.0/specs/properties/))
- Shapes are a nested tree inside a shape layer's `shapes[]`: groups (`gr` with child array `it`), paths (`sh`), fills (`fl`), strokes (`st`), with a transform (`tr`) required as the *last* item of a group; rendered bottom→top. ([single-page spec](https://lottie.github.io/lottie-spec/1.0/single-page/))

**(3)** Why it matters: Lottie is the existence proof that a **flat, declarative, keyframe-based scene graph** can be authored in one tool and played anywhere on the web (lottie-web), mobile, etc. It's the obvious shape for your *persisted, WYSIWYG-editable IR*. The layer+transform+keyframe+easing quadruple is close to the minimum viable animation IR.

**(4)** What breaks: (a) **It is an export target, not an authoring model** — hand-writing/hand-editing raw Lottie JSON (bezier tangent arrays!) is impractical, which is exactly why you don't want your AI emitting it directly. (b) **Feature portability is uneven across players** — AE "expressions" and many effects don't survive; lottie-web, rlottie, and Skia's Skottie have different feature coverage. (c) **Interactivity is not in the core** — it was bolted on later via dotLottie state machines (below). Maturity: very high for linear vector animation; the vendor-neutral spec effort (`lottie.github.io/lottie-spec`) is comparatively young.

### python-lottie — the "author against high-level objects, compile to the JSON" pattern (directly answers your ask)
**(1)** A Python library that builds and manipulates Lottie animations programmatically and converts between formats, with no dependency on native rlottie. ([PyPI](https://pypi.org/project/lottie/), [API docs](https://mattbas.gitlab.io/python-lottie/group__Lottie.html))

**(2)** It exposes a **typed object model** — `Animation`, `Composition`, `Layer`/`ShapeLayer`/`NullLayer`/`SolidColorLayer`/`TextLayer`/`PreCompLayer`, `Transform`, `Bezier`, `ShapeElement` (Rect/Ellipse/Star/Path/Group) — and a base class that **maps Python attributes to Lottie's abbreviated JSON keys** (`name→nm`, `type→ty`, `transform→ks`, `in_point→ip`, `out_point→op`). You instantiate objects, populate them, then serialize to `.json`. ([API docs](https://mattbas.gitlab.io/python-lottie/group__Lottie.html))

**(3)** This is the pattern your problem is reaching for, concretely demonstrated: **a higher-level, human/AI-friendly object API that *compiles down* to the portable declarative format.** The AI reasons about `ShapeLayer` + `Transform` + intent; the library handles the `nm/ty/ks/ip/op` and keyframe serialization. Generalize this and you get "author against a semantic model → emit the IR (Lottie-like) → play on web."

**(4)** Maturity: solid niche library (GitLab-hosted, one primary maintainer). It's still Lottie-shaped, so it inherits Lottie's "linear, weak-interactivity" ceiling.

### Theatre.js — arguably the closest existing shape to your exact ask
**(1)** An open-source JS "motion design editor for the web": a **declarative animation state that a visual Studio editor mutates**, aimed at high-fidelity motion graphics with three.js / R3F / HTML/SVG. ([GitHub](https://github.com/theatre-js/theatre), [docs](https://www.theatrejs.com/docs/0.5/manual/projects))

**(2)** Model: you declare a **Project → Sheets → Objects**, and on each Object you declare the **props you want to animate**. All tweaks + keyframes + easing you make in the Studio *are* the "project state," which is **serialized as a JSON object** (localStorage while editing) and **exportable to a JSON file**; you rehydrate deterministically with `getProject(name, { state: json })`. ([Projects manual](https://www.theatrejs.com/docs/0.5/manual/projects), [Threlte/Theatre getting started](https://threlte.xyz/docs/reference/theatre/getting-started/))

**(3)** Why it matters most: it directly solves the **round-trip problem** that kills the code-driven tools. The **JSON state is the single source of truth**; both the code (which declares what's animatable) and the visual editor (which sets keyframes/easing) mutate that same declarative doc. That's precisely the "WYSIWYG canvas over an editable IR, with a programmatic API on the side" split you need. It cleanly separates *what is animatable* (declared in code) from *how it's animated* (edited visually, stored as JSON).

**(4)** What breaks / maturity: **it animates *existing* objects (DOM/SVG/three) rather than authoring a whole scene document** — it's the timeline/keyframe layer, not the scene-authoring/asset layer. It's **pre-1.0 (0.x)**; the sustained maintenance/funding status is something I'd verify before betting on it — **UNVERIFIED** (I only confirmed 0.5-era docs are current in search).

### SMIL (SVG `<animate>`) — the cautionary tale of declarative-XML motion
**(1)** XML declarative animation built into SVG: `<animate>`, `<animateMotion>`, `<animateTransform>`, `<set>`. ([MDN](https://developer.mozilla.org/en-US/docs/Web/SVG/Guides/SVG_animation_with_SMIL), [W3C SVG 1.1 animate](https://www.w3.org/TR/SVG11/animate.html))

**(2)** Keyframe model: `values` (semicolon list), `keyTimes` (0–1 fractions), `keySplines` (per-segment cubic-Bézier control points), `calcMode` (`discrete`/`linear`/`paced`/`spline`), plus `from`/`to`/`by`. Declarative "describe what happens, not frame-by-frame." ([CSS-Tricks SMIL guide](https://css-tricks.com/guide-svg-animations-smil/), [MDN](https://developer.mozilla.org/en-US/docs/Web/SVG/Guides/SVG_animation_with_SMIL))

**(3)** Why it matters: it's the closest prior art to "declarative XML/markup that animates a vector scene," and its `keyTimes`/`keySplines` model is basically Lottie's keyframe/easing idea in markup. Useful reference for what a *markup-native* IR looks like.

**(4)** What breaks: **essentially the anti-pattern to copy.** Chrome once announced deprecation, tooling is thin, it's SVG-only, and it lost to CSS/WAAPI/JS. Lesson for your design: a declarative motion IR needs a first-class programmatic runtime and tooling, not just markup.

---

## STATE-MACHINE / INTERACTIVE MODELS (behavior, not just linear motion)

### Rive — the strongest interactive model; note the schema/motion separation
**(1)** An interactive animation editor + runtime; the editor exports a compact **binary `.riv`** played by Rive runtimes on web/mobile. ([format doc](https://rive.app/docs/runtimes/advanced-topic/format))

**(2)** Two representations stacked:
- **The `.riv` binary.** 4-byte `"RIVE"` fingerprint; **little-endian**; LEB128 varuints; **major version 7** (major versions are mutually incompatible — a v6 runtime cannot read v7). A **Table of Contents** maps property IDs to backing types (0=uint/bool, 1=string, 2=float, 3=color) so a runtime can **skip properties it doesn't understand** (forward-compat). Objects are keyed by core-type varuints; each has a property stream keyed by stable property IDs (e.g. "property key 13 is always a Node's X"), null-terminated. Parent/child via explicit integer indices; some relationships are positional ("a Shape always follows an Artboard"). ([format doc](https://rive.app/docs/runtimes/advanced-topic/format)) This is a **schema-evolvable binary scene graph** — a much more sophisticated wire format than Lottie's JSON.
- **The state machine.** States are usually timeline animations (`Idle`, `Run`) but can be **blend states** or placeholders. There's an **Entry** node, an **Any State** (transition from anywhere — interrupts/errors), and Exit. **Transitions** are edges with **conditions** and a **mix duration** (e.g. `0.05s`). **Inputs** drive transitions: **boolean** (persistent), **number/double** (continuous), **trigger** (one-shot, auto-resets). **Blend states** mix animations along an input — **1D** (`0→Idle, 50→Walk, 100→Run`) or **2D/direct**. **Multiple layers run in parallel** (body vs. face), with rightmost/bottom layer winning conflicts. **Listeners** (Pointer Enter/Exit/Click) fire logic. ([Rive SM blog](https://rive.app/blog/how-state-machines-work-in-rive), [engineering deep-dive](https://dev.to/uianimation/engineering-interactive-mascots-with-rives-state-machine-and-runtime-architecture-4e2h))

**(3)** The **most non-obvious idea for your problem** lives in Rive's newer **Data Binding / View Models**: a **View Model** is a *schema* — it declares typed properties (`boolean, number, string, color, enum, trigger, nested view model, list`) and their types, **not values**. A **View Model Instance (VMI)** is the live copy holding actual values; the app reads/writes the VMI and every bound element + state-machine transition updates. Rive explicitly frames this as **replacing the older state-machine-inputs model** with "typed properties, two-way binding, nested structures/lists — closer to how UI frameworks think." ([Rive data binding explainer](https://www.rive.best/rive-data-binding.html) — secondary source, but corroborated by Rive's own docs). **This cleanly separates DATA (typed schema) from MOTION (the state graph).** For an AI author that's gold: the agent can reason about "what typed properties/states exist and what data drives them" *independently* from pixel-level curves — a far more constrainable, verifiable surface than raw keyframes.

**(4)** What breaks / maturity: **the authoring tool (the Rive editor) is proprietary/closed** — the `.riv` format is documented and runtimes are open, but you can't easily generate `.riv` from your own AI pipeline without reimplementing the writer; the format is tooling-dependent and **major-version-incompatible** across runtime updates. It's **overkill for linear explainers** (its sweet spot is interactive characters/components) and requires the Rive runtime at play time. Maturity of the *runtime + SM model*: high and production-used; data-binding is comparatively new.

### dotLottie — bundling interactivity + theming *on top of* Lottie
**(1)** Open `.lottie` container: a **ZIP (Deflate)** bundling one or more Lottie JSONs plus images, **themes**, and **state machines**, with a root `manifest.json`. ([dotLottie v2.0 spec](https://dotlottie.io/spec/2.0/), [intro](https://dotlottie.io/intro/))

**(2)** Structure: dirs `a/` (animations), `s/` (state machines), `t/` (themes); `manifest.json` indexes them. **State machines** add interactivity — hover/click transitions, scroll-driven, data-bound state changes — **with no custom JS**. **Themes** are override objects (color/opacity/stroke/gradient tokens) switchable at runtime via one API call. Plus markers, slots, segments, layouts, playback modes. ([dotLottie v2.0 spec](https://dotlottie.io/spec/2.0/))

**(3)** Why it matters: this is the ecosystem **retrofitting a state-machine + theming layer onto a keyframe format** — evidence that a pure timeline IR is insufficient for interactive web artifacts, and a model for how to layer interactivity + runtime theming *over* a declarative animation doc without hand-written JS (very AI-friendly: emit a manifest + SM definition, not code).

**(4)** Maturity: the format + web player are active (LottieFiles), but the state-machine spec is younger and less universally implemented than plain Lottie playback.

### Statecharts / SCXML / XState — the formal behavior layer (no visuals of its own)
**(1)** Harel statecharts: hierarchical/nested + parallel (orthogonal) states, history, guarded transitions, entry/exit actions. **SCXML** is the W3C XML standard; **XState** is the JS/TS implementation that models the whole machine as a **serializable JSON object**. ([XState](https://xstate.js.org/), [statecharts.dev UI use-case](https://statecharts.dev/use-case-statecharts-in-user-interfaces.html), [SCXML repo](https://github.com/GnomesOfZurich/scxml))

**(2)** UI states map to "modes"; transitions are events; the machine is a declarative JSON graph that visualizers can render/round-trip. ([statecharts.dev](https://statecharts.dev/use-case-statecharts-in-user-interfaces.html))

**(3)** Why it matters: the **rigorous, verifiable, serializable model for interaction/behavior** — and it's the theoretical parent of what Rive/dotLottie encode ad-hoc. If your artifacts need interactivity beyond linear playback, a statechart is the constrainable IR an AI can emit *and* you can formally check. **But** it says nothing about the visual/motion layer — you still bolt a motion model onto each state.

**(4)** Maturity: XState is mature/production. The gap: no built-in notion of "tween between state A and state B's visuals" — you compose it with a motion layer yourself.

---

## CODE-DRIVEN / PROGRAMMATIC MODELS (the animation *is* a program — best LLM fit, worst round-trip)

### Remotion — video as a *pure function of frame → pixels* (React)
**(1)** Framework to make videos programmatically as React components; renders via headless Chromium. ([fundamentals](https://www.remotion.dev/docs/the-fundamentals))

**(2)** The model is unusually clean: **"a video is a function of images over time."** A `<Composition>` registers `id, fps, durationInFrames, width, height, component`. Inside, **`useCurrentFrame()`** yields the current frame; you map frame→value with **`interpolate()`** and **`spring()`**; **`<Sequence>`** time-shifts a subtree into a window. First frame `0`, last `durationInFrames - 1`. ([fundamentals](https://www.remotion.dev/docs/the-fundamentals), [useCurrentFrame](https://www.remotion.dev/docs/use-current-frame), [Sequence](https://www.remotion.dev/docs/sequence))

**(3)** Why it matters: **determinism.** `frame → pixels` as a pure function is trivially testable, cacheable, and *verifiable* — and React composition lets an AI express parametric, data-driven motion compactly. This is the cleanest mental model for AI-authored motion I found.

**(4)** What breaks: **output is rendered video, not a live interactive web doc** by default (no state-machine interactivity); requires a Chromium render farm; and **licensing is commercial for larger companies** (company-size-based license — flag this). Round-trip to a WYSIWYG canvas is not a native concept — the code is the truth.

### Motion Canvas — generators as timeline, signals as reactivity
**(1)** TypeScript library where **generator functions describe motion graphics** (the "Manim-but-TypeScript" niche); has a companion editor for tweaking. ([GitHub](https://github.com/motion-canvas/motion-canvas), [flow docs](https://motioncanvas.io/docs/flow/))

**(2)** Two ideas, both relevant:
- **Flow via generators.** `yield` = "this frame is ready, come back next frame"; `yield*` delegates to a sub-generator (composition/reuse). Timing: `tween`/`waitFor`, and flow combinators **`all()`** (parallel), **`chain()`/`sequence()`** (sequential), `loop`, `delay`. A tween like `circle().fill('#e6a700', 1)` returns a generator that consumes 1 second. ([flow docs](https://motioncanvas.io/docs/flow/), [flow source](https://github.com/motion-canvas/motion-canvas/blob/main/packages/docs/docs/getting-started/flow.mdx))
- **Signals (reactive).** Every node property is a **signal** made with `createSignal()`; a signal can be a **computed function of other signals** (`createSignal(() => Math.PI * radius() * radius())`), lazily recomputed on demand, with `createEffect()` for side effects. ([signals docs](https://motioncanvas.io/docs/signals/))

**(3)** Why it matters: (a) generators are a surprisingly elegant, *linear-reading* way to express sequencing that an LLM can emit and a human can read — closer to prose than to keyframe tables. (b) **Signals are a distinct fourth paradigm** (see below).

**(4)** What breaks: **code is the source of truth; the visual editor is limited** — you don't freely round-trip arbitrary hand-drawn canvas edits back into generator code. Output is canvas/video, not a portable declarative web doc. Niche community/maturity.

### Manim — scene graph + interpolate-by-alpha, plus **updaters** (reactive)
**(1)** 3Blue1Brown's Python math-animation engine (Community fork `manim`). ([building blocks](https://docs.manim.community/en/stable/tutorials/building_blocks.html))

**(2)** Three classes: **Mobject** (any displayable; most are `VMobject` vector objects with `.points`; compose via submobjects/`VGroup`), **Animation**, **Scene**. All code lives in `Scene.construct()`; `self.add/remove` toggle display; `self.play(...)` runs animations sequentially; `self.wait(t)`. **Every `Animation` interpolates its mobject via `interpolate_mobject(alpha)` where `alpha ∈ [0,1]` is `rate_func(elapsed/run_time)`** — you subclass and override to define custom motion. The **`.animate`** syntax turns any mutator into a tween: `square.animate.set_fill(WHITE)`. `Transform(a, b)` morphs by point correspondence. ([building blocks](https://docs.manim.community/en/stable/tutorials/building_blocks.html), [deep dive](https://docs.manim.community/en/stable/guides/deep_dive.html))

**(3)** Why it matters: `alpha∈[0,1] × rate_func` is the *universal* tween primitive under every timeline system (Lottie easing, WAAPI, GSAP all reduce to this). Manim also has **updaters** (`mobject.add_updater(fn)`) — "this object's state is continuously a function of time/other objects," the same reactive idea as Motion Canvas signals.

**(4)** What breaks: Python, video output, steep, math-explainer niche, **not web-native** (there are experimental JS ports — treat as **UNVERIFIED** for production). Scene is code, not an editable doc.

---

## THE WEB-NATIVE DECLARATIVE LAYER (your likely *compile targets*)

### Web Animations API (WAAPI) + CSS `@keyframes`
**(1)** The browser's own animation model. `element.animate(keyframes, options)` = constructing a **`KeyframeEffect`** wrapped in an **`Animation`** on a **timeline**. ([WAAPI concepts](https://developer.mozilla.org/en-US/docs/Web/API/Web_Animations_API/Web_Animations_API_Concepts))

**(2)** A `KeyframeEffect` = (target, keyframes array, timing options), and **can be constructed detached from any element, then reused across elements** — i.e. a portable, reusable motion descriptor. Runs on the **compositor thread** where possible (jank-resistant), unlike main-thread rAF libraries. ([WAAPI vs CSS](https://blog.logrocket.com/the-web-animations-api-vs-css/), [tier list](https://motion.dev/magazine/web-animation-performance-tier-list))

**(3)** Why it matters: **this is the native compile target.** A declarative keyframe IR (Lottie-ish) maps almost 1:1 to WAAPI `KeyframeEffect`s. No library weight; compositor-threaded.

**(4)** What breaks: DOM/CSS-property-only (no canvas/WebGL, no scene graph, no rich sequencing model natively). ([Motion GSAP-vs comparison](https://motion.dev/docs/gsap-vs-motion))

### CSS Scroll-driven & View timelines (declarative triggers)
**(1)** Animate along a **scroll-based** timeline instead of the time-based document timeline, via `animation-timeline: scroll()` / `view()`. ([MDN scroll-driven](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Scroll-driven_animations), [Chrome docs](https://developer.chrome.com/docs/css-ui/scroll-driven-animations))

**(2)** **Scroll progress timelines** (0%=startmost, 100%=endmost scroll) and **View progress timelines** (element crossing the viewport). Both declarative in CSS, layered on WAAPI/CSS Animations. Chrome shipped scroll-driven in 2023; **scroll-*triggered* animations are landing ~Chrome 145 (2026), declaratively, without `IntersectionObserver`.** ([MDN timelines](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Scroll-driven_animations/Timelines), [Chrome blog](https://developer.chrome.com/blog/scroll-triggered-animations))

**(3)** Why it matters: for *explainers* on the web, "advance the animation as the reader scrolls" is a huge interaction primitive that is now **declarative and compositor-driven** — a clean, AI-emittable target (just a timeline binding, no JS).

**(4)** Maturity: scroll-driven is shipping but cross-browser support is still uneven; scroll-triggered is 2026-fresh. Verify current browser matrix before relying on it.

### GSAP timelines — the imperative baseline (no serializable doc)
**(1)** The dominant JS animation library; `Timeline` sequences tweens. ([GSAP Timeline docs](https://gsap.com/docs/v3/GSAP/Timeline/))

**(2)** A **Timeline** is a container for tweens/other timelines with insert-at-time, labels, callbacks, play/pause/reverse/seek. **Imperative** — the animation exists as a sequence of JS calls, **not a serialized declarative document**. Runs on the main thread (rAF). ([GSAP Timeline docs](https://gsap.com/docs/v3/GSAP/Timeline/), [WAAPI vs GSAP](https://ics.media/en/entry/14973/))

**(3)** Why it matters mostly as contrast: GSAP is the power tool an AI could *emit code for*, but there's **no inspectable IR** — you can't easily round-trip it into a WYSIWYG canvas. (Note: GSAP became fully free including all plugins after Webflow's acquisition — **exact date UNVERIFIED**.)

### Framer Motion (now "Motion") — declarative variants vs imperative escape hatch
**(1)** React animation library. ([Motion component docs](https://motion.dev/docs/react-motion-component))

**(2)** **Variants** = named sets of animation states referenced declaratively (`variants={...}`, `animate="open"`), which propagate to children — clean declarative state-to-visual mapping. For sequencing/scrubbing it drops to the **imperative `useAnimate()`**. ([Framer Motion animation](https://www.framer.com/motion/animation/), [variants](https://mariposablog.hashnode.dev/framer-motion-variants))

**(3)** Why it matters: **variants are a mini-state-machine expressed declaratively** — "define states upfront, reference by name" — a good ergonomic model for how an AI might name and switch visual states without touching curves.

---

## REACTIVE / DERIVED — the under-discussed fourth paradigm
Motion Canvas **signals** ([docs](https://motioncanvas.io/docs/signals/)) and Manim **updaters** both express **a property as a function of other properties/time** rather than as keyframes or explicit steps. This is powerful for *relationships* ("the label always sits above the moving dot," "the bar height always equals the data value") that are painful to keyframe. It's the same idea as spreadsheet formulas or React derived state. **For an AI author it's very expressive** (declare intent/relationship once), but it's **the hardest to surface in a WYSIWYG canvas** because the "value" isn't a fixed thing to drag — it's a computation. Worth explicitly deciding whether your IR supports derived/bound values (Rive's data-binding is the interactive-graph cousin of this).

---

## The payoff: which paradigm for AI vs WYSIWYG-human, and the killer pattern

**The synthesize-verify loop (MoVer) is the most important non-obvious result for your problem.** MoVer targets **LLM-generated motion graphics**: the LLM synthesizes animation code (GSAP-style, rendered to a generic per-frame SVG transform representation) **and, in parallel, a formal spec in a verification DSL** — a first-order logic over motion predicates (`type/dir/mag/origin/duration`), **169 rectangle-algebra spatial predicates**, and **13 Allen-interval temporal predicates** (e.g. `before()`, `while()`). A checker runs the spec against the rendered motion; failures are **fed back to the LLM to iteratively self-correct**. Reported correctness went from **58.8% (no iteration) → 93.6% (≤50 iterations)** ([MoVer, arXiv 2502.13372](https://arxiv.org/html/2502.13372v1)). Related work (PromptVFX) has LLMs emit **parametric functions of time** for motion/color/opacity rather than keyframes ([arXiv 2506.01091](https://arxiv.org/pdf/2506.01091)). Treat the specific numbers as one paper's benchmark, not a general law — but the *architecture* is the lesson.

**Synthesized recommendation shape (the tension resolved):**

```
   AI author  ──emits──▶  HIGH-LEVEL SEMANTIC LAYER            ◀── human types/prompts
                          (objects + intents + relationships;
                           a DSL or object-API à la python-lottie,
                           + a formal motion spec à la MoVer)
                                    │ compile
                                    ▼
   WYSIWYG canvas ◀──edits──▶  DECLARATIVE IR  (the persisted, round-trippable doc)
                          (Lottie-like scene graph + keyframes/easing
                           for LINEAR motion;
                           statechart / Rive-style graph + typed
                           data-binding schema for INTERACTIVITY)
                                    │ compile
                                    ▼
   WEB OUTPUT              WAAPI KeyframeEffects / CSS @keyframes +
                           scroll/view timelines  (+ generated JS only
                           where the declarative layer can't express it)
```

Rationale, tied to the tension:
- **Humans in a WYSIWYG canvas want the declarative IR** — a Lottie/Theatre-shaped scene+keyframe JSON you can drag, scrub, and round-trip. **Timeline data is the right *persisted* model, wrong *authoring* model for AI.**
- **AI wants to author a level up** — semantic objects, parametric motion, and *relationships*, not bezier tangent arrays. Emitting raw Lottie is "AI writing assembly." python-lottie proves the object-API→JSON compile; MoVer proves you should also have the AI emit a **checkable spec** so a verifier closes the loop instead of you eyeballing pixels.
- **Interactivity forces a second IR axis**: linear explainers → timeline/keyframes; interactive components → a **state machine + a typed data-binding schema** (Rive's View Model / VMI split, or a statechart). Keep *data* (typed schema) separate from *motion* (the graph) — it's the most constrainable, AI-verifiable decomposition I found.
- **Theatre.js is the closest existing prior art** to "visual editor over an editable declarative JSON that code also mutates" — study its round-trip model even if you don't adopt it (pre-1.0; maintenance status **UNVERIFIED**).

**Honest caveats flagged inline above:** Rive editor is proprietary (can't easily generate `.riv` yourself); Remotion is video-output + commercially licensed; Motion Canvas/Manim are code-source-of-truth with weak round-trip; SMIL is the "don't do markup-only" cautionary tale; scroll-triggered CSS is 2026-fresh with uneven support; GSAP/Framer imperative modes have no serializable IR. Items I could not fully verify: Theatre.js current maintenance/version-1.0 status, GSAP-free-license exact date, Manim JS-port production-readiness — all marked **UNVERIFIED**.

### Primary sources
- Lottie: [spec](https://lottie.github.io/lottie-spec/1.0/) · [properties/keyframes](https://lottie.github.io/lottie-spec/1.0/specs/properties/) · [single-page (layers/transform/shapes)](https://lottie.github.io/lottie-spec/1.0/single-page/) · [JSON Schema](https://lottiefiles.github.io/lottie-docs/schema/) · [python-lottie](https://mattbas.gitlab.io/python-lottie/group__Lottie.html)
- dotLottie: [v2.0 spec](https://dotlottie.io/spec/2.0/) · [intro](https://dotlottie.io/intro/)
- Rive: [.riv format](https://rive.app/docs/runtimes/advanced-topic/format) · [state machines blog](https://rive.app/blog/how-state-machines-work-in-rive) · [SM/runtime deep-dive](https://dev.to/uianimation/engineering-interactive-mascots-with-rives-state-machine-and-runtime-architecture-4e2h) · [data binding / VMI](https://www.rive.best/rive-data-binding.html)
- Theatre.js: [GitHub](https://github.com/theatre-js/theatre) · [projects/state manual](https://www.theatrejs.com/docs/0.5/manual/projects)
- Motion Canvas: [GitHub](https://github.com/motion-canvas/motion-canvas) · [flow](https://motioncanvas.io/docs/flow/) · [signals](https://motioncanvas.io/docs/signals/)
- Remotion: [fundamentals](https://www.remotion.dev/docs/the-fundamentals) · [useCurrentFrame](https://www.remotion.dev/docs/use-current-frame) · [Sequence](https://www.remotion.dev/docs/sequence)
- Manim: [building blocks](https://docs.manim.community/en/stable/tutorials/building_blocks.html) · [internals deep dive](https://docs.manim.community/en/stable/guides/deep_dive.html)
- Web platform: [WAAPI concepts](https://developer.mozilla.org/en-US/docs/Web/API/Web_Animations_API/Web_Animations_API_Concepts) · [scroll-driven animations](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Scroll-driven_animations) · [scroll/view timelines](https://developer.mozilla.org/en-US/docs/Web/CSS/Guides/Scroll-driven_animations/Timelines) · [Chrome scroll-triggered](https://developer.chrome.com/blog/scroll-triggered-animations) · [SMIL (MDN)](https://developer.mozilla.org/en-US/docs/Web/SVG/Guides/SVG_animation_with_SMIL) · [SVG 1.1 animate](https://www.w3.org/TR/SVG11/animate.html)
- Behavior models: [XState](https://xstate.js.org/) · [statecharts in UIs](https://statecharts.dev/use-case-statecharts-in-user-interfaces.html)
- Libraries: [GSAP Timeline](https://gsap.com/docs/v3/GSAP/Timeline/) · [Framer Motion animation](https://www.framer.com/motion/animation/) · [Motion: GSAP vs Motion](https://motion.dev/docs/gsap-vs-motion)
- AI-authored motion: [MoVer (arXiv 2502.13372)](https://arxiv.org/html/2502.13372v1) · [PromptVFX (arXiv 2506.01091)](https://arxiv.org/pdf/2506.01091) · [SMooGPT (arXiv 2509.04058)](https://arxiv.org/html/2509.04058)
