# Mermaid Diagram Rendering & Animation in TextView

Status: design, pre-implementation. Targets the existing `MarkdownRenderedView`
+ `HTMLRenderer` pipeline. No code has been written yet — this doc nails down
choices before any source moves.

---

## 1. Goal

Render fenced `` ```mermaid `` blocks inline as SVG, side-by-side with our
existing prose + tree-sitter-highlighted code. Then layer a small animation
system on top so an author can write a single mermaid source and have the
viewer step through it — nodes/edges appearing one-by-one, paths lighting up,
state machines walking through transitions. Static rendering is v1; animation
is v2. The animation work is the interesting bit; we're picking a substrate in
v1 that doesn't paint v2 into a corner.

Out of scope: editing diagrams in place, PNG/PDF export, live re-render
beyond what the markdown reload already gives us.

---

## 2. Library choice

Three realistic substrates.

| Option              | Bundle cost   | Coverage           | Maintenance      | Animation hooks |
|---------------------|---------------|--------------------|------------------|-----------------|
| mermaid.js bundled  | ~2.5 MB min   | All diagram types  | npm pin, vendor  | DOM + classes   |
| mermaid CLI shellout| ~0 in app     | Same as JS, slow   | Node runtime dep | Same SVG output |
| Swift reimpl        | 0             | Whatever we write  | We own it all    | Native, total   |

**`mermaid.js` bundled.** Vendor the minified UMD build into
`Sources/ViewerUI/Resources/vendor/mermaid.min.js`. Loaded once per WKWebView
session via `WKUserScript` at `.atDocumentEnd`. Render is fast (sub-100ms for
typical diagrams), output is an SVG DOM tree we can walk and animate. Pros:
correctness, every diagram type, large community testing it. Cons: ~2.5 MB
binary growth, supply-chain surface, pin-and-vendor discipline required.

**Mermaid CLI shell-out (`@mermaid-js/mermaid-cli`).** Renders out-of-process,
returns SVG text. Cons: requires Node + Chromium on user's machine (mmdc
launches puppeteer under the hood), tens of seconds first-render, animation
becomes "replace whole SVG every frame" instead of DOM mutation, and we lose
the live JS hooks mermaid exposes. Killer for animation.

**Swift reimpl.** Realistically: flowcharts + sequence + state diagrams
only, many engineering-months, perpetual treadmill chasing upstream syntax.
Core Graphics is theoretically nicer than SVG-in-WKWebView but the cost
swamps the benefit at our scale.

**Recommendation: bundled `mermaid.js`.** The other two have showstoppers.
Pin a specific version (`mermaid@11.x` LTS) and check in the minified file
under `vendor/` with a `VENDOR.md` recording the upstream SHA and license.

---

## 3. Where the JS runs

We already have a precedent for API-injected JS that bypasses the page CSP:
`MarkdownRenderedView.Coordinator.findScript` is fired via
`webView.evaluateJavaScript(...)` on `didFinish`. CSP forbids `<script>` tags
in the page (`script-src` is omitted), but `WKUserScript` and
`evaluateJavaScript` are out-of-band and not subject to that policy.

Two injection points:

1. **`WKUserScript` at `.atDocumentEnd`, `forMainFrameOnly: true`** — loads
   the bundled `mermaid.min.js` once. Defines `window.mermaid` for the page
   lifetime. Wired into `WKWebViewConfiguration.userContentController` in
   `MarkdownRenderedView.makeNSView`.
2. **Bootstrap call on `didFinish`** — walks the freshly-loaded DOM for
   `<pre class="mermaid">` blocks, calls `mermaid.run({ nodes })`, and the
   SVGs replace the `<pre>` children.

`HTMLRenderer.visitCodeBlock` gets a small special-case: when the info string
is `mermaid`, emit `<pre class="mermaid" data-src-hash="…">…raw source…</pre>`
instead of the usual `<pre><code class="language-mermaid">`. Mermaid's runtime
looks for `.mermaid` and renders it in place.

The bootstrap JS (this is the production snippet, not pseudocode):

```javascript
(function(){
  if (!window.mermaid) {
    console.warn('[mdv] mermaid runtime not present');
    return;
  }
  // Theme follows the OS — same trick as our CSS color-scheme.
  var dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  window.mermaid.initialize({
    startOnLoad: false,
    theme: dark ? 'dark' : 'default',
    securityLevel: 'strict',         // strips inline event handlers
    flowchart:   { htmlLabels: false },
    sequence:    { useMaxWidth: true },
    fontFamily:  '-apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif'
  });

  // Render every <pre class="mermaid"> currently in the DOM.
  window.__mdvMermaidRender = async function() {
    var nodes = document.querySelectorAll('pre.mermaid:not([data-rendered])');
    if (!nodes.length) return { rendered: 0 };
    try {
      await window.mermaid.run({ nodes: nodes });
      nodes.forEach(function(n){ n.setAttribute('data-rendered', '1'); });
      return { rendered: nodes.length };
    } catch (e) {
      // mermaid throws on syntax errors; preserve the source as a fallback.
      nodes.forEach(function(n){
        if (n.getAttribute('data-rendered')) return;
        var src = n.textContent;
        n.innerHTML = '';
        var err = document.createElement('div');
        err.className = 'mdv-mermaid-error';
        err.textContent = 'mermaid: ' + String(e && e.message || e);
        var pre = document.createElement('pre');
        pre.textContent = src;
        n.appendChild(err);
        n.appendChild(pre);
        n.setAttribute('data-rendered', 'error');
      });
      return { rendered: 0, error: String(e) };
    }
  };

  // Listen for OS theme flips so re-renders pick up the new palette.
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function(ev){
    window.mermaid.initialize({ theme: ev.matches ? 'dark' : 'default' });
    document.querySelectorAll('pre.mermaid[data-rendered]').forEach(function(n){
      n.removeAttribute('data-rendered');
      // Restore original source from data-mdv-src (set by the visitor).
      var src = n.getAttribute('data-mdv-src');
      if (src) n.textContent = src;
    });
    window.__mdvMermaidRender();
  });
})();
```

`Coordinator.webView(_:didFinish:)` then calls
`webView.evaluateJavaScript("window.__mdvMermaidRender && window.__mdvMermaidRender();", …)`
after the existing find-runtime injection.

`HTMLRenderer.visitCodeBlock` stashes the raw source on `data-mdv-src` so the
theme-flip handler can rerun mermaid against the original text (mermaid mutates
the `.mermaid` element's children when it renders, destroying the source).

---

## 4. Diagram types for v1

Mermaid supports a dozen+ chart types. We don't have to enable them all; the
runtime ships them but we're picking what we'll *test* and *style* properly.
v1 commits to:

1. **Flowchart** (`graph LR`, `flowchart TD`) — the workhorse. Architecture
   sketches, decision trees.
2. **Sequence diagram** — message passing across actors. Heavy use in design
   docs.
3. **State diagram** (`stateDiagram-v2`) — state machines. Animation candidate
   #1 since transitions are explicit.
4. **Class diagram** — for OO/protocol relationships in our Swift docs.
5. **Gantt** — for roadmaps. Cheap to support, often-requested.

Explicitly **not** in v1: ER diagrams, user journey, pie, quadrant, mindmap,
timeline, sankey, requirement, C4. They render fine because mermaid handles
them, but we don't promise styling parity or animation coverage. Document as
"best-effort, may look off in dark mode."

---

## 5. Animation — "how do we make mermaid animations?"

Three approaches, materially different.

**(a) Step-through (N frames, replace SVG each frame).** Mermaid renders
one full SVG per frame; we swap them in. Easiest model, since each frame is
"valid mermaid source with progressively more nodes/edges revealed." Cons:
needs N renders (~50ms each, so a 10-step animation has a noticeable budget),
flicker risk between frames, lose CSS transition continuity (each SVG is a
fresh DOM tree, no morph).

**(b) CSS animation / transitions on the existing SVG.** Render once,
then toggle classes on SVG elements (`.node.mdv-step-0`, `.edge.mdv-step-1`)
to fade/slide them in. Mermaid already gives each node and edge a stable
`id`/`class`, so we can target them. Costs nothing per frame beyond a class
toggle. Limitation: CSS transitions handle opacity/transform well but can't
animate SVG `path` `d` attribute or `stroke-dashoffset` without help.

**(c) SMIL or requestAnimationFrame on SVG primitives.** Walk the rendered
SVG, animate `stroke-dashoffset` to "draw" edges, animate `circle` `r` to
pulse nodes, etc. Most expressive — true cinematic feel. Cost: a small
runtime that knows mermaid's SVG structure, plus the brittleness that comes
with depending on mermaid's internal class naming.

**Recommendation: (b) CSS classes on the rendered SVG, with hooks for (c)
later.** Specifically:

- Author tags steps in the mermaid source with a v1 comment convention:
  `%% @step 1` lines that get parsed out of the source by `HTMLRenderer`
  and translated into a `data-mdv-steps` JSON manifest on the `<pre>`.
- After render, a small JS module walks the SVG, finds each node/edge by
  id, and assigns `data-mdv-step="N"`.
- A CSS rule like `[data-mdv-step]:not(.mdv-visible) { opacity: 0; }` plus a
  `transition: opacity 250ms` makes step advancement a single class toggle.
- For "edge draw-on" we use `stroke-dasharray + stroke-dashoffset` via CSS,
  not SMIL — supported everywhere, no JS frame loop.

This buys us most of the cinematic feel of (c) with the operational
simplicity of (b). v3 can add per-element `requestAnimationFrame` choreography
without changing the authoring contract.

---

## 6. UI surface for animation controls

Diagrams with an `data-mdv-steps` manifest grow a small control strip
*inside* the rendered figure. No SwiftUI changes for v2 — controls live in
the WKWebView, styled to match `markdown.css`:

```
+------------------------------------------------+
|  [SVG of state diagram, step 2 of 5 visible]   |
|                                                |
|  [⏮]  [◀]  [▶]  [⏭]   step 2 / 5  [▢ Auto]    |
+------------------------------------------------+
```

Keyboard: `←` / `→` advance steps when the diagram has focus, `Home` / `End`
jump to first/last, `Space` toggles auto-play. The control strip is
generated by the same JS module that wires up `data-mdv-step` classes.

For the broader app surface (e.g. a global "step all diagrams together"
control) we defer to v3. v2 keeps it scoped per-diagram so we don't entangle
with the SwiftUI document model.

---

## 7. Integration with the walkthrough system

The walkthrough system (`docs/WALKTHROUGH.md`, currently not yet checked in
— planned alongside this work) drives the viewer through a script of
"highlight section X, scroll, pause, advance." Mermaid animations are a
natural extension of that contract.

Design:

- Walkthrough steps can target `mermaid:<id>:<step>` selectors. Example:
  `{ "kind": "mermaid-step", "diagram": "arch-overview", "step": 3 }` in the
  walkthrough JSON tells the runner to advance diagram `arch-overview` to
  step 3 before the next narrator beat.
- The mermaid JS module exposes `window.__mdvMermaidStep(id, n)` and
  `window.__mdvMermaidStepCount(id)` so the walkthrough Swift driver can
  command diagrams the same way it commands scroll position.
- Walkthrough authoring stays in markdown: a diagram block can carry a
  `%% @id arch-overview` directive that gets surfaced to the runner.

The walkthrough doc gets a "Mermaid steps" section once both are landed. We
deliberately don't fold them into one big timeline format — the walkthrough
is the orchestrator, the diagram is one of several things it can poke.

---

## 8. Performance

The mermaid render is JS-CPU-bound and happens on the WebKit main thread,
which is *not* our app main thread — WKWebView runs in a separate process.
Even so, several budgets matter:

- **Bundle parse cost.** `mermaid.min.js` is ~2.5 MB; first-load parse is
  ~80-150ms on M-class Macs. Load it once per WKWebView via `WKUserScript`
  so it's not re-parsed on every navigation.
- **Cache by source hash.** On the Swift side, hash the raw mermaid source
  (SHA-256, 8-char prefix) and stash the rendered SVG on a disk cache
  (`~/Library/Caches/MarkdownViewer/mermaid/<hash>.svg`). On next render of
  the same diagram, inject the cached SVG directly into the page and skip
  the mermaid runtime call entirely. This is a 50ms→<1ms win for unchanged
  diagrams across reloads.
- **Placeholder while rendering.** Emit a `<pre class="mermaid">` with a
  fixed `min-height: 200px` and a subtle "rendering diagram…" overlay so
  the surrounding markdown doesn't reflow when the SVG lands. After render
  the SVG's intrinsic size kicks in.
- **Off-main-thread.** Mermaid's own render is async — `mermaid.run()`
  returns a Promise. We don't block the page on it; the rest of the markdown
  is interactive while diagrams resolve.
- **Lazy render below the fold.** v3: use `IntersectionObserver` to defer
  diagrams that aren't visible. v1/v2 just renders them all on load.

The cache key is `sha256(source + mermaid_version + theme)`. Theme is part
of the key because mermaid's SVG output bakes colors in.

---

## 9. Theming

`markdown.css` already uses `color-scheme: light dark` and `-apple-system-*`
tokens so the page follows the OS. Mermaid has the same notion — `theme:
'default'` for light, `theme: 'dark'` for dark.

- On initial render, query `prefers-color-scheme` from JS and pass through
  to `mermaid.initialize`. Snippet in §3 shows this.
- On theme flip, re-render by stripping `[data-rendered]` and re-running
  `__mdvMermaidRender`. Cached SVGs are keyed on theme, so the second flip
  back is free.
- For the small set of diagram types where we care about exact colors
  (highlighted-edge color in flowcharts, current-state color in state
  diagrams), define overrides in `markdown.css` using the same
  `--mdv-link` / `--mdv-fg` variables. Mermaid lets us pass
  `themeVariables: { primaryColor: 'var(--mdv-link)' }` but the CSS-var
  resolution at SVG-render time is brittle; safer to compute the resolved
  values once in JS and pass concrete hex strings.

---

## 10. Security

Mermaid has a non-trivial XSS history. Two CVE clusters worth knowing:

- **`CVE-2021-43861`** — flowchart node text could break out of the SVG
  `<text>` element when `securityLevel: 'loose'` allowed raw HTML labels.
  Patched in 8.13.8. We mitigate by setting `securityLevel: 'strict'` and
  `flowchart.htmlLabels: false` in `mermaid.initialize`.
- Periodic issues around `<iframe>` embedding via mermaid's link feature.
  Our page-level CSP already denies `frame-src` and `object-src`, so even
  if mermaid emits an `<iframe>` the browser refuses to load it.

Defense in depth, in order:

1. **Page CSP** in `HTMLRenderer.renderPage`: `default-src 'none'` plus
   the existing img/style/font allowances. We'll need to add a narrow
   `script-src` exception for the API-injected mermaid bundle — *no*,
   actually: `evaluateJavaScript` and `WKUserScript` aren't subject to
   `script-src`, so the CSP can stay as-is. Confirmed via the existing
   find-runtime that runs the same way.
2. **`securityLevel: 'strict'`** in `mermaid.initialize` — strips inline
   event handlers and external resource refs from rendered diagrams.
3. **`htmlLabels: false`** — forces SVG `<text>` rendering, no HTML
   pass-through inside diagram labels.
4. **Source treated as untrusted-but-local.** Same trust model as the rest
   of the markdown: the file is something the user opened. We don't add
   special escaping beyond mermaid's own, but we do log parse errors via
   the error fallback in §3 rather than swallowing them.
5. **Vendored bundle integrity.** SHA-256 of the vendored `mermaid.min.js`
   is recorded in `vendor/VENDOR.md`. CI verifies it on each build so a
   future "small refactor" can't silently swap the runtime.

If we ever expose markdown from a truly hostile source (network fetch),
revisit — strict-mode mermaid is good but not airtight, and an allowlist
sanitizer at the HTML layer would become necessary.

---

## 11. Implementation phases

**v0 — Code-fence pass-through (current state).** ` ```mermaid ` blocks
render as `<pre><code class="language-mermaid">` with tree-sitter doing
nothing for them. Source visible, no diagram. No code change needed; this is
where we are.

**v1 — Static rendering.** Vendor `mermaid.min.js`. `HTMLRenderer.visitCodeBlock`
emits `<pre class="mermaid">`. `WKUserScript` injects the runtime. `didFinish`
calls `__mdvMermaidRender`. Cache rendered SVG by source-hash on disk.
Placeholder + error fallback. Five diagram types tested. No animation.

**v2 — Step animation.** Parse `%% @step N` directives out of the mermaid
source in `HTMLRenderer`, emit as `data-mdv-steps` manifest. Inject a
second small JS module that wires `data-mdv-step` classes onto SVG elements
and renders the in-figure control strip. CSS opacity transitions in
`markdown.css`. Keyboard nav inside the diagram.

**v3 — Walkthrough integration + richer animation.** Expose
`window.__mdvMermaidStep` API. Walkthrough runner targets diagrams by id.
Add `stroke-dashoffset` edge-draw transitions, optional auto-play with
configurable pacing. `IntersectionObserver` for lazy render. Per-element
`requestAnimationFrame` choreography where step animation isn't enough.

Each phase is a self-contained PR. v1 is shippable on its own; v2 and v3
build incrementally without rewriting v1's contracts.

---

## 12. Decisions for you

Three yes/no calls only you can make:

1. **Vendor `mermaid.min.js` directly (~2.5 MB binary growth)?** Y/N. The
   alternative is fetching it at runtime, which our CSP forbids and which
   would break offline use. If N, we drop the feature.
2. **Authoring convention `%% @step N` for animation ordering?** Y/N. This
   is a mermaid-comment that mermaid itself ignores, so it's syntactically
   safe. The alternative is a sidecar JSON file per diagram, which is more
   flexible but uglier in the markdown source. If N, propose your preferred
   shape and v2 design adapts.
3. **Bind animation step controls to `←` / `→` when the diagram has
   keyboard focus?** Y/N. Risk: collides with any future "previous/next
   tab" or "scroll" bindings we add at the app level. The diagram steals
   the event only when focused (tabindex), so the collision window is
   narrow but real. If N, we use `[` / `]` or buttons-only.
