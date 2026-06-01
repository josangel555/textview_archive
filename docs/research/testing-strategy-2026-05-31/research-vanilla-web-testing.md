The repo has no vanilla web-UI testing setup to ground against (just a static `markdown.css`). This is a pure-knowledge question. I'll answer it directly and thoroughly from first principles.

---

# Testing a Vanilla Web UI Across All Layers

No framework means no `@testing-library/react`, no component test-runner magic, no virtual DOM diffing you can intercept. You're testing the actual web platform: HTML parsed into a DOM tree, CSS resolved into a computed style + a box layout, JS mutating both, and pixels rasterized by a compositor. The good news: the platform is your component model, and it's far more directly testable than the framework abstractions people are used to. The catch: the layers have wildly different "achievable headlessly" profiles, and the boundary between them is where almost everyone gets fidelity wrong.

## The five layers map to distinct engine stages — test them where they actually live

The single most useful first-principles move is to stop thinking "unit / integration / e2e" and instead map your test layers onto the *browser's own pipeline stages*, because each stage has a different cheapest faithful substitute.

```
  JS source ──parse──▶  [1] pure logic         ── plain JS engine (Node/Bun/QuickJS), no DOM
  HTML ──parse──────▶  [2] DOM structure       ── DOM-in-a-runtime (jsdom/linkedom/happy-dom)
  CSS ──cascade─────▶  [3] computed style       ── needs a real CSS cascade+layout engine
  layout ──reflow───▶      + box geometry        ── needs a real layout engine (headless browser)
  events ──dispatch─▶  [4] interaction          ── DOM runtime (synthetic) OR real browser (trusted)
  raster ──composite▶  [5] visual/pixels         ── needs a real GPU/raster path (headless browser)
```

The fault line is brutal and non-negotiable: **layers 1–2 run faithfully in a JS-only runtime; layers 3–5 require a real engine's cascade, layout, and raster code.** jsdom does not lay anything out. Internalizing exactly *where* that cliff is saves you from the most common failure mode — writing "layout" assertions against jsdom that are pure fiction.

---

## Layer 1 — Pure logic: no DOM at all, and that's the point

**What it is:** Anything that's a function of data, not of the document — parsing, formatting, state reducers, validation, sort/filter, URL building, a finite-state machine driving UI modes.

**How to test it headlessly:** Run it in any JS engine. Node, Bun, Deno, or even QuickJS. No DOM, no browser. This is the fastest, most deterministic layer and should carry the *bulk* of your assertion count.

**The non-obvious first-principles point — architect for this layer to be huge.** In framework land, logic gets smeared into components and is hard to extract. In vanilla land you have *total control of the seam*, so the optimal move is to write your app so the DOM is a thin render of a plain-data model:

```js
// model.js — zero DOM references, 100% headless-testable
export function reducer(state, action) { /* ... */ }
export function viewModel(state) { /* returns a plain object describing what should render */ }

// view.js — the ONLY file that touches document.*
export function render(root, vm) { /* imperatively reconcile DOM from vm */ }
```

Now `reducer` and `viewModel` are pure and tested at layer 1 speed, and the only thing left for the slower layers is "does `render` faithfully project a `vm` onto DOM." This is the vanilla equivalent of the "humble object" / "functional core, imperative shell" pattern, and it's *more* available to you without a framework, not less. Most people skip it because the framework normally owns that seam — owning it yourself is the single highest-leverage decision for testability.

**Counterintuitive technique:** make the view layer return a *description* of mutations rather than performing them, in test mode (a tiny command list: `["setText #x", "addClass .y"]`). Then you can assert on the *intended* DOM ops at layer-1 speed without a DOM at all, and only spot-check that the executor applies them correctly. This is essentially hand-rolling the one genuinely useful idea from virtual DOM, scoped to just your test boundary.

**Fidelity:** Perfect. It's the same engine semantics you ship (assuming you test on the same JS engine family — see the V8-vs-JSC caveat in Layer 4).

---

## Layer 2 — DOM structure & behavior: DOM-in-a-runtime, with sharp eyes on what's faked

**What it is:** "Given this HTML/these mutations, is the tree shaped right?" — element presence, attributes, `textContent`, ARIA wiring, `<template>` cloning, `data-*`, form-control `.value`/`.checked` state, `classList`, dataset, `querySelector` results, mutation observers firing.

**How to test it headlessly — the three real options, and they are not interchangeable:**

| Runtime | What it actually is | Layout? | Speed | Fidelity stance |
|---|---|---|---|---|
| **jsdom** | Most complete spec reimplementation of DOM/HTML in JS | No (everything is 0×0, `getComputedStyle` returns *declared* inline/stylesheet values, not resolved) | Slowest of the three | Highest correctness for *structure/semantics*; honest about not doing layout |
| **happy-dom** | Lighter, faster reimplementation | No (some fake layout numbers) | Fast | Cuts corners; occasionally *invents* layout values that look real and aren't |
| **linkedom** | Minimal, parse-and-serialize focused | No | Fastest | Great for server-side HTML assembly/parsing; thin on live-DOM APIs |

**Non-obvious truths about this layer:**

- **jsdom has no rendering engine, by design.** `el.getBoundingClientRect()` returns all zeros. `offsetWidth`/`offsetHeight` are 0. `getComputedStyle(el).width` gives you `"auto"` or whatever was *declared*, never a resolved px value. This is correct behavior, not a bug — there is no layout pass. Any test asserting a *number* of pixels in jsdom is testing a lie. happy-dom is more dangerous here precisely because it sometimes returns plausible-looking fake numbers, so a green test gives false confidence.
- **The selector engine and HTML parser *are* real and spec-grade in jsdom.** So `querySelectorAll` semantics, attribute reflection (`el.id` ↔ `id=`), `<template>.content` document-fragment behavior, form association, `innerHTML` parsing quirks (e.g. `<td>` outside a table getting dropped), and case-folding of tag names are all faithful. This is genuinely valuable and underused: people reach for a full browser to check "does my function build the right `<ul>`," when jsdom answers that in single-digit milliseconds with real parser semantics.
- **Underused: test the parsing edge cases deliberately.** Vanilla apps that build HTML by string concatenation have a huge surface of injection / malformed-markup bugs. Feeding hostile strings through jsdom's *real* parser and asserting the resulting tree (e.g. that a `<script>` didn't materialize, that `&lt;` stayed escaped) is a cheap security-relevant test most people never write.
- **Counterintuitive: `MutationObserver` works in jsdom**, so you can test *that your code reacts to DOM changes* without a browser. Asserting on observer callbacks is a clean way to test reactive-ish vanilla code at layer-2 speed.

**Hard limit:** Anything where behavior depends on geometry — IntersectionObserver firing on scroll, `scrollIntoView`, focus-on-visible, "is this element clipped" — is **not** faithfully testable here. jsdom stubs Intersection/ResizeObserver as no-ops or you polyfill them with hand-fed fake rects, which means you're testing your fakes. Push these to Layer 3/4.

---

## Layer 3 — Computed style & layout geometry: the cliff, and where most teams quietly cheat

**What it is:** The resolved cascade (which rule actually won, with specificity/`!important`/`@layer`/custom-property resolution), and the *box model output* — actual widths/heights, wrapping, fl/grid track sizing, position of elements, overflow/clipping, `z-index` stacking, media-query and container-query resolution.

**This is the layer that fundamentally cannot be faked in a JS DOM runtime.** Computing it correctly *is* reimplementing a browser layout engine (Blink's LayoutNG, WebKit, Gecko). There is no lightweight honest substitute. So the choice is binary:

1. **Real headless browser** (Chromium via Playwright/Puppeteer/CDP, WebKit & Firefox via Playwright). Headless here means *no on-screen window*, but the **full Blink/WebKit/Gecko cascade + layout + (for screenshots) raster pipeline runs**. `getComputedStyle` returns real resolved px. `getBoundingClientRect` is real. This is the correct tool for this layer, full stop.
2. **Give up and don't assert layout in JS** — instead pin it visually (Layer 5) or via explicit invariants.

**First-principles fidelity nuance most people miss:** "headless" is not one thing.

- **Old headless Chrome (pre-2023)** was a *separate code path* from headed Chrome — it could and did render differently. Bugs and even differing default behaviors existed between `--headless` and real Chrome.
- **"New headless" (`--headless=new`, default in modern Chrome/Playwright)** runs the *same* browser code, just without surfacing a window. Layout/raster fidelity vs. headed is now essentially exact. **If your tooling still pins old headless, your "it passed headless" signal is weaker than you think** — verify which mode you're on. This is a genuinely underappreciated correctness footgun.
- Even with new-headless, **`devicePixelRatio`, fonts, and GPU-vs-software raster** still differ from a real user's machine. More on that in Layer 5.

**Underused / high-leverage techniques at this layer:**

- **Assert computed style, not pixel boxes, where you can.** `getComputedStyle(el).gridTemplateColumns` resolving to `"200px 1fr"` → real resolved track sizes is a far more *stable* assertion than a screenshot, and it directly tests the cascade. People jump straight to screenshots and skip this precise, fast, real-engine signal.
- **Test the cascade itself in isolation.** You can attach a stylesheet, then read back `getComputedStyle` to prove *which rule won* under specificity / `@layer` / `:has()` / custom-property fallback. This catches CSS regressions (a refactor that changed specificity) that screenshots only catch incidentally and can't localize.
- **CSS `@property` + computed-value reads** let you unit-test design-token resolution (does `--accent` cascade and clamp correctly) without any visual diff.
- **Counterintuitive: drive layout *into edge states* programmatically.** Set the viewport to the exact container-query breakpoint ±1px, set `font-size` huge to test reflow/overflow, force `prefers-reduced-motion`/`forced-colors` via emulation — then read computed geometry. This tests *responsive correctness* deterministically, which visual snapshots do poorly (they capture one size).
- **WebKit matters if you ship to Safari/iOS.** Chromium-only headless testing structurally misses WebKit-only layout/flex/`backdrop-filter`/sticky bugs. Playwright's bundled WebKit is the only practical cross-engine headless option; it's an approximation of Safari (same WebKit core, different OS integration) but far better than pretending Blink == everything.

**Candid limit:** Headless layout is faithful to *that engine*, not to *all browsers your users have*. And it's an order of magnitude slower than Layers 1–2 (process startup, real layout). So you want *few, high-value* layout assertions, not thousands.

---

## Layer 4 — Interactions & events: the trusted-vs-synthetic divide that nobody talks about enough

**What it is:** clicks, typing, focus traversal, hover, drag, keyboard nav, form submission, `pointer`/`touch`, paste, the actual `Event` dispatch + bubbling/capture + default actions.

**Two mechanisms, and the difference is load-bearing:**

1. **Synthetic dispatch (`el.dispatchEvent(new MouseEvent('click'))`, or `el.click()`)** — works in jsdom *and* real browsers. The event flows through capture/bubble, your listeners fire. **But these events are `isTrusted: false`.** That has real consequences: they **do not trigger default browser actions** the way user input does, they **can't cross security boundaries** (no real clipboard, no file-picker, no `requestFullscreen`, no autofill, no media autoplay-unlock), and `:hover`/`:active`/`:focus-visible` styling and IME/composition aren't genuinely exercised.
2. **Real input injection via CDP/WebDriver** (Playwright's `page.click()`, `page.keyboard.type()`) — synthesizes input at the *browser input layer*, producing **`isTrusted: true`** events that behave exactly like a user: real focus, real default actions, real hover states, real native dialogs. This requires a real (headless-OK) browser.

**The non-obvious guidance:**

- **In jsdom, you only ever get synthetic events** — so jsdom interaction tests verify *"my listener does the right thing when an event reaches it"*, which is genuine and useful, but they **cannot verify** "the user can actually trigger this," "default action happened," "focus moved correctly with `:focus-visible`," or anything geometry-gated (clicking the element that's actually on top at those coordinates). Knowing this boundary stops you from over-trusting jsdom interaction suites.
- **Real-browser input + hit-testing catches a whole bug class jsdom can't:** an invisible overlay intercepting clicks, a `pointer-events: none` that breaks a button, a `z-index` stacking issue where the click lands on the wrong element. These are *layout-coupled interaction bugs* — only a real engine doing real hit-testing finds them. This is the strongest argument for owning a small Playwright suite even for a "simple" vanilla app.
- **Underused: `el.click()` for `<label>`/checkbox association and form semantics.** jsdom *does* implement enough form semantics that label→control activation and `form.requestSubmit()` validation flows are testable cheaply. Good middle ground.
- **JS-engine fidelity caveat folds in here:** Node/jsdom and Chromium run **V8**; Playwright-WebKit runs **JavaScriptCore**. Subtle JS-engine differences (number formatting in `Intl`, regex edge cases, GC timing affecting `WeakRef`, even stack-trace shape) mean "passes in Node" ≠ "passes in JSC." Rare, but real, and invisible if you only ever test on V8.

**Candid limit:** Truly native interactions — OS file pickers, real clipboard with permission prompts, drag-out-of-window, OS-level IME, screen readers — are only partially reachable even in a real headless browser, and some only in a real *headed* session (or not automatable at all). Accessibility-tree *structure* is inspectable headlessly (Playwright exposes the a11y tree; axe-core runs in-page); actual screen-reader *speech output* is not — that needs a real AT on a real OS (or specialized tooling like NVDA-in-CI on Windows VMs).

---

## Layer 5 — Visual / pixel output: real raster required, and determinism is the whole game

**What it is:** What it actually *looks like* — the rendered pixels. Catches everything the upper layers structurally can't: font rendering, anti-aliasing, gradients, shadows, `backdrop-filter`, blend modes, sub-pixel positioning, the *combination* of correct-individually styles producing a wrong-looking whole.

**Headless reach:** **Yes — headless browsers rasterize.** `page.screenshot()` in Playwright/Puppeteer produces real pixels from the real raster pipeline without a visible window. So visual testing is *achievable headlessly*; "headless" was never the obstacle. **Determinism** is.

**The first-principles problem: a screenshot is a hash over a huge pile of environment.** Font files + hinting, sub-pixel AA, GPU vs. software rasterizer, `devicePixelRatio`, OS text stack, even GPU driver version all perturb pixels. Two machines rendering identical correct DOM produce *different* PNGs. So naive screenshot diffing is the flakiest thing in the whole stack — and the flakiness is *not* signal, it's noise that destroys the signal.

**How the good harnesses actually defeat this (the real mechanisms, not "use a tool"):**

- **Pin the renderer, not just the browser.** Force **software rasterization / disable GPU** so the raster path is deterministic across machines; lock `deviceScaleFactor`; freeze the viewport. GPU raster is faster but non-deterministic across drivers — for *diffing* you deliberately give up speed for reproducibility.
- **Eliminate font variance — the #1 cause of diff noise.** Either run inside a **fixed container image** with pinned fonts (so dev-Mac vs. CI-Linux stop disagreeing), or **embed/subset fonts as base64** so the page never depends on host fonts. Disable subpixel antialiasing. This is why serious visual suites run in Docker even when the rest of the tests don't.
- **Freeze time, animation, and randomness.** Inject `prefers-reduced-motion`, set `animation-duration: 0`, stub `Date`/`Math.random`/`requestAnimationFrame`, await fonts (`document.fonts.ready`) and network-idle *before* the shot. A screenshot taken mid-animation or pre-font-swap is the classic flake.
- **Diff perceptually, with a tolerance, not byte-exact.** Use anti-alias-aware perceptual diffing (the SSIM / pixelmatch family) with an explicit threshold and ignore-regions for genuinely dynamic content. Byte-exact diffing of a rendered page is a trap.

**Counterintuitive but powerful options at this layer:**

- **DOM-snapshot instead of pixel-snapshot.** Serialize the *post-render DOM + computed styles* and diff *that*. It catches "the output changed" with a *localizable, reviewable* diff (you see `color: red → color: blue`, not "47 pixels differ") and is far less flaky than pixels. It misses pure raster bugs (a shadow that renders wrong from correct CSS) but catches the 80% that are actually style/structure regressions. Wildly underused versus pixel snapshots.
- **Render to SVG/Canvas and assert on the vector/draw-call level** for chart-like or canvas UIs — deterministic and inspectable, no raster fuzz.
- **Component-isolation pages.** Vanilla doesn't give you Storybook for free, but you can hand-roll a static "gallery" HTML that mounts each widget in known states; screenshotting *that* is faster and far more stable than navigating the live app into each state. Cheap to build, high payoff.

**Candid limits:**
- A passing visual test proves "pixels match the *approved baseline on this render config*," **not** "looks right on a user's Safari-on-M3-Retina." Cross-real-device fidelity (true Retina subpixel, real iOS WebKit text, HDR, color-managed displays) is only fully verifiable on real hardware or a paid device-cloud. Headless gets you regression-protection, not ground-truth-across-the-fleet.
- Visual tests are *expensive to maintain* — every intentional design change re-baselines everything. Over-snapshotting whole pages is a known anti-pattern; snapshot small, stable, meaningful regions.

---

## Cross-cutting first-principles takeaways

**The pyramid, by faithful-cost, for vanilla specifically:**

```
        ▲  Layer 5 visual      — real headless browser, pinned render env; FEW, small regions
        │  Layer 4 trusted     — real headless browser (Playwright); the layout-coupled
        │   interaction          interaction bugs jsdom CANNOT see
        │  Layer 3 layout/      — real headless browser; assert COMPUTED STYLE > pixel boxes
        │   computed style
        │  Layer 2 DOM struct  — jsdom (real parser+selectors), FAST, MANY; never assert px here
   ████████  Layer 1 logic     — plain JS engine, no DOM; the MASS of your assertions
```

**The boundary you must hold in your head:** structure & semantics are faithful in a JS-only runtime; **anything that's a function of *geometry or pixels* requires a real engine.** Every fidelity mistake I see is someone testing a geometry/pixel concern in jsdom (false confidence) or testing a pure-logic/structure concern through a slow flaky browser (wasted time and flake).

**Vanilla-specific advantages people don't exploit:**
- You own the model↔DOM seam, so Layer 1 can be enormous and Layer 2 can be a thin "projection" test. Frameworks hide this seam; you should weaponize it.
- No framework = no virtual DOM, so the DOM you assert on *is* the real DOM — your jsdom structural tests have no abstraction gap to the browser. (Ironically, vanilla DOM tests are *more* faithful to production than framework component tests, which assert against a render tree the browser never sees.)
- You can hand-roll a "render produces this command list" seam (Layer 1) and a static state-gallery (Layer 5) cheaply — both are things frameworks usually need extra tooling for.

**Highest-leverage underused techniques, ranked:**
1. **Functional-core / DOM-projection architecture** so 80% of behavior is Layer-1 testable.
2. **Computed-style assertions** (Layer 3) instead of, or before, pixel snapshots — real-engine signal, localizable, low-flake.
3. **DOM+computed-style snapshots** instead of pixel snapshots for most "did output change" needs.
4. **Verify you're on `--headless=new`**, not legacy headless, before trusting any headless layout/visual result.
5. **Pinned-render container (fonts + software raster)** for the visual layer — turns flaky pixel diffs into a real signal.
6. **A small WebKit (Playwright) lane** if Safari/iOS users matter — the only practical cross-engine headless coverage.

**The honest ceiling of headless:** Layers 1–4 are *substantially* achievable headlessly (1–2 in a JS runtime; 3–4 in a real-but-windowless browser with full fidelity to *that engine*). Layer 5 is achievable headlessly for *regression detection* but **not** for ground-truth "looks right on every real device." The things headless genuinely cannot give you: real OS-native input/clipboard/file dialogs, real assistive-technology speech, true cross-device subpixel/color/HDR fidelity, and any guarantee about browser engines you didn't run. For those you need real hardware or a device cloud — there is no JS-runtime or headless shortcut, and any tool claiming otherwise is faking the numbers.