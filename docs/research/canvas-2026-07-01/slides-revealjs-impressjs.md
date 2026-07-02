# Agent a524160129b7f47fb.output

## Prompt (first 300 chars)
Do FRESH web research (use web search + fetching the actual documentation/source pages) on two HTML-based slide/presentation frameworks: **reveal.js** and **impress.js**. Prefer PRIMARY sources (official docs sites, GitHub READMEs, source code). Cite every claim with a full URL.

For EACH of the two

## Final message

I now have thorough primary-source coverage. Here's the structured writeup.

---

# reveal.js vs impress.js — HTML slide framework research

Both are client-side JS libraries that turn hand-written HTML into a browser-rendered slide deck. The load-bearing contrast is **dimension 2 (layout)**: reveal.js is DOM-flow + uniform auto-scale (no coordinates), impress.js is manual absolute placement on an infinite 3D canvas (you compute every coordinate).

---

## reveal.js

### 1. Document / data model
- Fixed three-level DOM hierarchy: **`.reveal > .slides > section`**. Each `<section>` is one slide and can repeat indefinitely. ([revealjs.com/markup](https://revealjs.com/markup/))
- **Horizontal vs vertical**: top-level `<section>`s form the horizontal sequence; nesting `<section>` elements inside a `<section>` creates a vertical stack, where the outer/first section is the "root" that participates in the horizontal flow. ([revealjs.com/markup](https://revealjs.com/markup/), [revealjs.com/vertical-slides](https://revealjs.com/vertical-slides/))
- There is **no separate compiled model** — the live DOM tree *is* the model. reveal.js decorates it: the `.reveal` element becomes the viewport and gets a `reveal-viewport` class on init; slides get state classes as you navigate. ([revealjs.com/markup](https://revealjs.com/markup/))
- **Identification / per-slide config is via data-attributes and classes on the plain HTML**, not ids: e.g. `data-state="make-it-pop"` (applies a class to the viewport + fires events when that slide is active), `data-background`, `data-transition`, `data-auto-animate`, `data-id` (auto-animate element matching), `data-markdown`. Slides are also addressable by `(h, v)` index via the API. ([revealjs.com/markup](https://revealjs.com/markup/), [revealjs.com/api](https://revealjs.com/api/))

### 2. Layout representation — **AUTOMATIC (flow + uniform scale), no coordinates**
- Slides are laid out by normal DOM/CSS flow inside a **virtual normalized resolution** you author against; reveal.js then **scales the whole deck uniformly** to fit the viewport while preserving aspect ratio. Defaults: `width: 960, height: 700, margin: 0.04, minScale: 0.2, maxScale: 2.0`; `center: true` vertically centers; `disableLayout: true` turns off the built-in scaling/centering. ([revealjs.com/presentation-size](https://revealjs.com/presentation-size/), [revealjs.com/config](https://revealjs.com/config/))
- **You never write x/y coordinates for slides.** Transitions between slides are declarative styles (`transition: none|fade|slide|convex|concave|zoom`), not positions. ([revealjs.com/config](https://revealjs.com/config/))
- **Fragments** — incremental within-slide reveal: any element with `class="fragment"` is stepped through before advancing. Built-in styles (`fade-out`, `fade-up/down/left/right`, `fade-in-then-out`, `grow`, `shrink`, `highlight-red/green/blue`, `highlight-current-*`); ordering overridden by `data-fragment-index`; `fragmentshown`/`fragmenthidden` events. ([revealjs.com/fragments](https://revealjs.com/fragments/))
  ```html
  <p class="fragment fade-up" data-fragment-index="3">Appears last</p>
  ```
- **Auto-animate** — add `data-auto-animate` to two adjacent `<section>`s and reveal.js tweens matching elements between them (position, font-size, color, padding, etc.) via CSS transforms. Matching is by text content + node type, media `src`, DOM order, or explicit `data-id`. Tunable with `autoAnimateDuration/Easing/Unmatched` (global) or `data-auto-animate-duration/easing/delay/unmatched` (per slide); `data-auto-animate-id` groups sequences, `data-auto-animate-restart` breaks them. ([revealjs.com/auto-animate](https://revealjs.com/auto-animate/))
  ```html
  <section data-auto-animate><div data-id="box" style="height:50px;background:salmon"></div></section>
  <section data-auto-animate><div data-id="box" style="height:200px;background:blue"></div></section>
  ```
- Layout helpers for sizing content inside a slide (still no coordinates): `r-stretch`, `r-fit-text` (fitty-powered), `r-stack`, `r-frame`. ([revealjs.com/layout](https://revealjs.com/layout/))

### 3. Mutation / authoring API
- **Init**: `Reveal.initialize(config)` (global singleton) or `new Reveal(element, config).initialize()` for multiple decks on a page. Returns a **Promise** resolving when ready. `Reveal.destroy()` (v4.3.0+) tears down DOM changes/listeners/plugins. ([revealjs.com/initialization](https://revealjs.com/initialization/))
- **Runtime reconfig**: `Reveal.configure({ ... })` changes config live (e.g. `autoSlide`). ([revealjs.com/config](https://revealjs.com/config/))
- **Navigation / query**: `Reveal.slide(indexh, indexv, indexf)`, `.left/right/up/down()`, `.prev/next()`, `.next/prevFragment()`, `.getCurrentSlide()`, `.getSlide(h,v)`, `.getIndices()`, `.getProgress()`, `.isFirstSlide()/isLastSlide()`, `.availableRoutes()`. ([revealjs.com/api](https://revealjs.com/api/))
- **Re-editability after DOM mutation**: this is a first-class supported path — **`Reveal.sync()`** rebuilds controls/progress/slide classes "if you add or remove slides"; finer-grained `Reveal.syncSlide(slide)` and `Reveal.syncFragments(slide)`; `Reveal.layout()` re-scales. So a program can inject/remove `<section>` nodes then call `sync()`. ([revealjs.com/api](https://revealjs.com/api/))
- **Events**: `Reveal.on('eventname', cb)` / `Reveal.off()`. Key events: `ready`, `slidechanged` (`event.previousSlide, currentSlide, indexh, indexv`), `slidetransitionend`, `resize` (`event.scale, oldScale, size`). ([revealjs.com/events](https://revealjs.com/events/))
- **Plugin system**: register via the `plugins:[]` config array; each plugin is `{ id, init }`; query with `Reveal.hasPlugin(id)`, `Reveal.getPlugin(id)`, `Reveal.getPlugins()`. Official plugins: `RevealHighlight`, `RevealMarkdown`, `RevealSearch`, `RevealNotes`, `RevealMath`, `RevealZoom`. ([revealjs.com/plugins](https://revealjs.com/plugins/))
- The **config object** (subset): `controls`, `progress`, `hash`, `transition`, `autoAnimate`, `center`, `keyboard`, `overview`, `touch`, plus sizing keys above. ([revealjs.com/config](https://revealjs.com/config/))

### 4. Persistence
- **Plain HTML file** is the canonical on-disk format; fully round-trippable text (the DOM literally is the source). ([revealjs.com/markup](https://revealjs.com/markup/))
- **Markdown alternative** via `RevealMarkdown`: inline with `<section data-markdown>` + `<textarea data-template>`, or **external file** `<section data-markdown="example.md">` with configurable separators (`data-separator` default `^\r?\n---\r?\n$`, `data-separator-vertical`, `data-separator-notes` default `notes?:`, `data-charset`). Per-element/slide attributes injected via HTML comments (`<!-- .element: class="fragment" -->`, `<!-- .slide: data-background="#ff0000" -->`); code-line highlight via ```` ```js [1-2|3|4] ````. Markdown is indentation/line-break sensitive. ([revealjs.com/markdown](https://revealjs.com/markdown/))

### 5. Rendering
- Pure **DOM + CSS**. Slides are HTML nodes; transitions/animations are CSS transforms/transitions; scaling is a CSS transform on the deck. No canvas/SVG rendering engine.
- **PDF/static export**: append **`?print-pdf`** to the URL then browser Print → Save as PDF (Landscape, margins none, background graphics on) — confirmed only in Chrome/Chromium. Config: `pdfMaxPagesPerSlide`, `pdfSeparateFragments`, `showNotes`. CLI alternative: **decktape**. ([revealjs.com/pdf-export](https://revealjs.com/pdf-export/), [github.com/astefanutti/decktape](https://github.com/astefanutti/decktape))

### 6. Programmatic-authoring friction — **LOW**
- A program/LLM authors reveal.js by emitting **semantic HTML with zero geometry**: nest `<section>`s for order, add `class="fragment"` / `data-auto-animate` / `data-background` for behavior. No pixel math — reveal.js flow-lays-out and auto-scales. Slide identity is positional (`h/v` index) or by class/data-attr, so edits are structural (add/move/remove a `<section>`) and re-editable, followed by `Reveal.sync()`. ([revealjs.com/markup](https://revealjs.com/markup/), [revealjs.com/api](https://revealjs.com/api/))
- **Limits**: content *within* a slide still relies on CSS flow, so fine visual layout (overlaps, exact placement) means writing CSS/inline styles; auto-animate matching can be ambiguous without explicit `data-id`; there is no absolute free-form canvas — you trade spatial control for zero coordinate math. ([revealjs.com/auto-animate](https://revealjs.com/auto-animate/))

---

## impress.js

### 1. Document / data model
- Root container with **`id="impress"`** holds everything ("All the content of the presentation will be created inside that element"). Slides are `<div class="step">` elements, optionally with `id`s (used for deep-linking + a `impress-on-[stepid]` body class). ([DOCUMENTATION.md](https://github.com/impress/impress.js/blob/master/DOCUMENTATION.md), [GettingStarted.md](https://raw.githubusercontent.com/impress/impress.js/master/GettingStarted.md))
- The DOM is the source, but `init()` **mutates it heavily**: it wraps all children in an injected **canvas `<div>`**, sets inline CSS `transform` (translate/rotate/scale) + `position:absolute` + `transform-style:preserve-3d` on every step, adds `impress-enabled` to `<body>`, and applies state classes `future`/`present`/`past`/`active` to steps. ([impress.js source](https://raw.githubusercontent.com/impress/impress.js/master/js/impress.js))
- Steps identified by `id` (deep links, `goto`) and carry their placement as `data-*` attributes (below). ([DOCUMENTATION.md](https://github.com/impress/impress.js/blob/master/DOCUMENTATION.md))

### 2. Layout representation — **MANUAL absolute coordinates on an infinite 3D canvas**
This is the defining trait. Every step is placed by **you** on a boundless 2D/3D canvas; impress.js then moves a **CSS-3D-transform "camera"** so the active step fills the screen. Attributes (all Strings — quote the numbers; negatives allowed):
- **`data-x`** — px along x (left→right); default `0`.
- **`data-y`** — px along y (top→bottom); default `0`.
- **`data-z`** — px along z (depth); negative = away from camera (e.g. `data-z="-3000"` → 3000px back); default `0`.
- **`data-rotate` / `data-rotate-z`** — clockwise rotation in degrees (aliases); default `0`.
- **`data-rotate-x`, `data-rotate-y`** — rotation about each axis in degrees; default `0`.
- **`data-rotate-order`** — order the rotX/rotY/rotZ transforms apply (matters because each is relative to current orientation); default `"xyz"`.
- **`data-scale`** — multiplier; `data-scale="4"` makes the step appear 4× larger than others; default `1`.

([DOCUMENTATION.md](https://github.com/impress/impress.js/blob/master/DOCUMENTATION.md), [GettingStarted.md](https://raw.githubusercontent.com/impress/impress.js/master/GettingStarted.md))

- **Root-level canvas/camera config** (on `#impress`): `data-width`/`data-height` target screen (default **1920×1080**), `data-perspective` (default **1000**px; `0` disables 3D flattening to 2D), `data-transition-duration` (default **1000**ms), `data-min-scale`/`data-max-scale`. ([DOCUMENTATION.md](https://github.com/impress/impress.js/blob/master/DOCUMENTATION.md))
- Authoring example (note the explicit coordinates):
  ```html
  <div class="step" data-x="1000" data-y="1000" data-z="-1000" data-scale="2" data-rotate-z="90"> ... </div>
  ```
  ([GettingStarted.md](https://raw.githubusercontent.com/impress/impress.js/master/GettingStarted.md))
- **UNVERIFIED**: impress.js's within-step incremental reveal ("substeps", analogous to reveal.js fragments) exists in the plugin ecosystem, but I did not confirm its exact API from primary docs this pass — flag before relying on it.

### 3. Mutation / authoring API
- Factory **`impress([rootId])`** returns the API object; **`.init()`** boots it. Methods: `.init()`, `.tear()` (revert DOM to pre-init), `.next()`, `.prev()`, **`.goto(stepIndex | id | element, [duration])`**. ([DOCUMENTATION.md](https://github.com/impress/impress.js/blob/master/DOCUMENTATION.md))
- **Idempotency / re-editability caveat (verified in source)**: `init()` guards with an `initialized` flag and returns early if already run; the `impress()` factory caches per root (`roots["impress-root-"+id]`) and returns the *same* API on repeat calls. So **you cannot cleanly re-`init()` after mutating the DOM** the way reveal.js's `sync()` allows — you'd `tear()` then re-init, or re-instantiate. There is no documented `sync()` equivalent. ([impress.js source](https://raw.githubusercontent.com/impress/impress.js/master/js/impress.js))
- **Events** (on the root/step els): `impress:init`, `impress:stepenter`, `impress:stepleave` (`event.detail.next` = target step). ([DOCUMENTATION.md](https://github.com/impress/impress.js/blob/master/DOCUMENTATION.md))
- **Fallback**: if the browser lacks DataSet/classList/CSS-3D-transforms/transitions, impress.js adds **`impress-not-supported`** to `<body>` and returns a **dummy no-op API** (skips init). ([impress.js source](https://raw.githubusercontent.com/impress/impress.js/master/js/impress.js), [README.md](https://raw.githubusercontent.com/impress/impress.js/master/README.md))

### 4. Persistence
- **Single self-contained HTML file** (markup + optional inline CSS + a script tag calling `impress().init()`); assets via CDN or local paths. Round-trippable as text, **but** note that after load the DOM carries injected inline transform styles — the *authoring* source stays the `data-*` attributes, not the computed styles. No official Markdown authoring path (unlike reveal.js). ([GettingStarted.md](https://raw.githubusercontent.com/impress/impress.js/master/GettingStarted.md), [README.md](https://raw.githubusercontent.com/impress/impress.js/master/README.md))

### 5. Rendering
- **DOM + CSS3 3D transforms/transitions** exclusively — "based on the power of CSS3 transforms and transitions… inspired by prezi.com." No canvas/SVG. The 3D depth is driven by the CSS `perspective` on the root. Requires modern browser features (DataSet, classList, CSS 3D transforms, CSS transitions). ([README.md](https://raw.githubusercontent.com/impress/impress.js/master/README.md), [DOCUMENTATION.md](https://github.com/impress/impress.js/blob/master/DOCUMENTATION.md))
- **No built-in PDF/static export** documented (contrast reveal.js). MIT-licensed, actively maintained (Bartek Szopka & Henrik Ingo + contributors, 2011–2023). ([README.md](https://raw.githubusercontent.com/impress/impress.js/master/README.md))

### 6. Programmatic-authoring friction — **HIGHER (coordinate math required), but total spatial control**
- To author impress.js a program must **compute absolute `x/y/z` + `rotate*` + `scale` for every step itself** — there is no auto-layout. Placing N steps in a readable path means the agent runs the geometry (grid spacing, rotation sweeps, zoom-in via scale/z), because impress.js just applies whatever numbers you give it. This is real pixel/degree math the LLM owns. ([DOCUMENTATION.md](https://github.com/impress/impress.js/blob/master/DOCUMENTATION.md), [GettingStarted.md](https://raw.githubusercontent.com/impress/impress.js/master/GettingStarted.md))
- **Upside of the friction**: complete, deterministic spatial control — arbitrary overlaps, zoom-through, 3D rotations, an "infinite canvas" narrative impossible in reveal.js's flow model.
- **Downside**: coordinates are brittle to edit (moving one step can require re-spacing neighbors), no `sync()`-style live re-layout after mutation (re-init requires `tear()`), and no responsive auto-scale beyond the root camera fit.

---

## Head-to-head on the key axis (dimension 2)

```
                 reveal.js                     impress.js
layout model     DOM flow + uniform auto-scale absolute placement on ∞ 3D canvas
coordinates      NONE (nest <section>s)        REQUIRED (data-x/y/z/rotate*/scale)
"camera"         slide transitions (CSS)       CSS-3D camera flies between steps
scaling          auto-fit virtual 960×700      root fit of 1920×1080 + per-step scale
agent friction   LOW (semantic edits)          HIGH (agent computes geometry)
spatial control  constrained (flow + CSS)      total (free-form 2D/3D)
live re-layout   Reveal.sync() supported       no sync(); tear()+re-init
export           ?print-pdf / decktape         none built-in
markdown source  yes (RevealMarkdown)          no
```

---

## URLs used (all primary)

- https://revealjs.com/markup/
- https://revealjs.com/vertical-slides/
- https://revealjs.com/layout/
- https://revealjs.com/presentation-size/
- https://revealjs.com/config/
- https://revealjs.com/initialization/
- https://revealjs.com/api/
- https://revealjs.com/events/
- https://revealjs.com/fragments/
- https://revealjs.com/auto-animate/
- https://revealjs.com/markdown/
- https://revealjs.com/plugins/
- https://revealjs.com/pdf-export/
- https://github.com/astefanutti/decktape
- https://github.com/impress/impress.js/blob/master/DOCUMENTATION.md
- https://raw.githubusercontent.com/impress/impress.js/master/DOCUMENTATION.md
- https://raw.githubusercontent.com/impress/impress.js/master/GettingStarted.md
- https://raw.githubusercontent.com/impress/impress.js/master/README.md
- https://raw.githubusercontent.com/impress/impress.js/master/js/impress.js

**UNVERIFIED flags**: (1) impress.js in-step "substep"/fragment reveal API — exists in the ecosystem but not confirmed from primary docs here; (2) reveal.js runtime *removal* of slides is inferred from the `Reveal.sync()` doc wording ("if you add or remove slides") rather than a dedicated remove-slide method — there is no `Reveal.removeSlide()` API; you mutate the DOM then `sync()`.
