# Agent abede79b4f7cb5cc4.output

## Prompt (first 300 chars)
Do FRESH web research (use WebSearch + WebFetch of official docs, developer/API docs, and any source) on FRAMER (framer.com) as a visual-to-code web UI builder. We are designing an agent-first WYSIWYG canvas that outputs HTML/CSS/JS, and want to learn concretely how Framer models a visual UI and map

## Final message

# FRAMER

Research dump on framer.com as a visual-to-code web UI builder, oriented to designing an agent-first WYSIWYG canvas. Primary sources are the Framer Developers docs (`framer.com/developers/*`), Framer Help, Framer Academy, and the Framer dictionary; secondary/community sources flagged as such. Where a claim is inferred or not formally documented, it's marked **UNVERIFIED** or **inferred**.

Key gaps up front (couldn't retrieve literal source): the plugins Quick Start and the `framer/plugins` GitHub README are JS-rendered and returned no code; `npmjs.com/package/framer-plugin` returned HTTP 403. So the exact `createFrameNode(...)` attribute-object literal is **reconstructed from the API reference field list**, not copied from a running example. The full node type list comes from `framer.com/developers/nodes` which itself defers to a bundled `index.d.ts` I could not fetch.

---

## 1. DOCUMENT / DATA MODEL

Framer's canvas is a **node tree** (a design-scene graph), not a raw DOM mirror — but the node types are deliberately close to DOM/React primitives so they can render to real elements.

**Node types** (from https://www.framer.com/developers/nodes): `FrameNode`, `TextNode`, `SVGNode`, `CodeComponentNode`, and `UnknownNode`. Per the changelog summary (https://www.framer.com/developers/changelog), `CodeComponentNode` was formerly `ComponentInstanceNode`, and there is a `ComponentNode` (formerly `SmartComponentNode`) for Framer's "Smart Components." So the practical hierarchy is: **Frame** (the generic container/box → maps to `<div>`), **Text**, **SVG**, **CodeComponent** (an instance of a React code component), **Component/SmartComponent** (Framer-native design components with variants), plus `UnknownNode` for forward-compat.

**Identity**: nodes carry an opaque **string id**; the API is `await framer.getNode("some-node-id")` (https://www.framer.com/developers/nodes). The exact id format is not documented — **UNVERIFIED** beyond "string."

**Traits / mixins** (https://www.framer.com/developers/nodes): type discriminators `isFrameNode`, `isTextNode`, `isSVGNode`, `isCodeComponentNode`; capability probes prefixed `supports*` — `supportsPosition`, `supportsVisible`, `supportsRotation`, `supportsBackgroundGradient`, `supportsBorderRadius`, `supportsBackgroundImage`. Every node has `isReplica` (true when it inherits attributes from a primary variant or breakpoint). The reference (https://www.framer.com/developers/reference) also exposes variant/breakpoint traits: `inheritsFromId`, `isPrimaryVariant`, `isVariant`, `isBreakpoint`, `isPrimaryBreakpoint`, and `gesture` (variant gesture state).

**Styles are attached primarily as per-node attributes** (not CSS classes). The reference lists visual attributes directly on nodes: `backgroundColor`, `backgroundGradient`, `backgroundImage`, `border`, `borderRadius`, `opacity`, `visible`, `zIndex`, `overflow`/`overflowX`/`overflowY`, `rotation`, `font`, plus content (`svg`, `imageRendering`), metadata (`name`, `locked`, `link`, `path`, `collectionId`), and `controls` ("property control values for code components") (https://www.framer.com/developers/reference).

**Design tokens / shared styles do exist as first-class referencable objects.** `backgroundColor` is documented as "RGBA format **or a ColorStyle instance**" (https://www.framer.com/developers/reference) — i.e. a color can be a literal or a reference to a shared **Color Style** (Framer's color token). Text has `inlineTextStyle` — "apply a text style preset" — i.e. shared **Text Styles**. So the model is a **hybrid**: literal per-layer properties by default, with optional references to shared Color/Text styles acting as tokens. (The token graph shape itself isn't published — **inferred** from these attribute types.)

---

## 2. LAYOUT REPRESENTATION — the key question

**Framer emits real CSS flow (flexbox + CSS grid) AND absolute positioning; it is not a pure absolute-canvas.** There are three container layout modes:

- **Frame (free / absolute)** — elements placed freely; children are absolutely positioned. Attributes: `position`, `top`/`bottom`/`left`/`right`, `centerX`/`centerY` (anchor %), `zIndex` (https://www.framer.com/developers/reference). This is the canvas-style escape hatch → CSS `position:absolute` + offsets (**inferred** from the field names).
- **Stack (1D auto layout → flexbox)** — "Framer's auto layout is powered by flexbox concepts" (https://www.framer.com/dictionary/flexbox); Academy: Stacks are "just like auto-layout in Figma or **flexbox in CSS**" (https://www.framer.com/academy/lessons/framer-fundamentals-stacks-and-relative-positioning). Attributes map directly to flex: `layout` ("enables stack or grid"), `stackDirection` (flex-direction), `stackAlignment` ("aligned perpendicular to the stack" = align-items/cross axis), `stackDistribution` ("how items are distributed" = justify-content/main axis), `gap`, `padding`, `stackWrapEnabled` (flex-wrap) (https://www.framer.com/developers/reference).
- **Grid (2D → CSS grid)** — `gridColumnCount`, `gridRowCount`, `gridColumnWidth`/`gridRowHeight` (+ `*Type`, e.g. fixed vs fr), `gridColumnMinWidth`, `gridAlignment`, and per-item `gridItemColumnSpan`/`gridItemRowSpan`, `gridItemFillCellWidth/Height`, `gridItemHorizontalAlignment`/`VerticalAlignment` (https://www.framer.com/developers/reference).

**Sizing** is a per-element enum: **Fixed** (exact px), **Fill** (stretch to available space), **Fit Content** (shrink-wrap), **Relative** (% of parent), plus `minWidth`/`maxWidth`/`minHeight`/`maxHeight` and `aspectRatio` (https://www.framer.com/developers/reference; https://www.framer.com/academy/lessons/framer-fundamentals-fixed-and-relative-sizing; https://www.framer.com/academy/lessons/framer-fundamentals-sizing-to-fill-and-fit-content). This is a direct visual analog of flex `flex-grow`/`width:100%`/`fit-content`/`%`.

**User picks the mode** by setting a container to Frame vs Stack vs Grid; Framer community framing: "Frame is the basic design space where elements can be placed freely, Stack aligns elements horizontally or vertically (1D), and Grid aligns in rows and columns (2D)" (https://www.framer.community/c/support/frame-vs-stack-vs-grid-which-concept-is-correct).

**Constraints / pins**: absolute children use pin constraints (top/bottom/left/right/center) so they anchor as the parent resizes (https://designcode.io/framer-web-design-adaptive-layout/). Framer University explicitly warns that absolute positioning breaks reflow — "Framer stops treating that element as part of the stack… won't adjust when the screen resizes" — and experts keep everything in stack/flex flow (https://framer.university/blog/why-framer-experts-avoid-using-absolute-positioning). This is the same tension your agent canvas will face: free positioning is easy to author but doesn't reflow.

**Responsive / breakpoints**: breakpoints are width thresholds represented as breakpoint nodes (`isBreakpoint`, `isPrimaryBreakpoint`), and layout **cascades by inheritance from larger to smaller** — overrides at a smaller breakpoint diverge, otherwise inherit (`isReplica`/`inheritsFromId` are the mechanism) (https://www.framer.com/academy/lessons/framer-fundamentals-breakpoints; https://www.framer.com/blog/responsive-breakpoints/; https://www.framer.com/developers/nodes). This is a **cascade/override model**, not per-breakpoint duplicate trees.

---

## 3. MUTATION API

There are **three** distinct programmatic surfaces, and a crucial constraint: **all three run inside the Framer editor — there is no published open document format you can emit from outside.**

**(a) Plugin API (`framer-plugin` SDK)** — plugins are "small apps that interact with the editor… inserting images, layers and code components or **modifying anything on the Canvas**" (https://www.framer.com/developers/plugins-introduction). They render a floating UI window on the canvas (an iframe-hosted app; sandbox specifics **UNVERIFIED**). The imperative API (https://www.framer.com/developers/reference) is the canvas mutation surface:
- Create/edit/structure: `createFrameNode(attributes)`, `cloneNode`, `removeNode`, `getNode`, `getParent`, `getChildren`, `setAttributes(nodeId, attributes)`, `setParent(nodeId, parentId)`, `getRect`, `getCanvasRoot`, `subscribeToCanvasRoot`.
- Query: `getNodesWithType`, `getNodesWithAttribute`, `getNodesWithAttributeSet`.
- Text: `getText`/`setText`/`addText`/`subscribeToText`.
- Assets/components: `addImage`, `setImage`, `uploadImage(s)`, `uploadFile(s)`, `addSvg`, `addComponentInstance({url, attributes})`, `addDetachedComponentLayers({url, layout, attributes})`.
- Selection/nav: `getSelection`/`setSelection`/`subscribeToSelection`, `navigateTo`, `zoomIntoView`.
- Plugin-scoped storage & code injection: `getPluginData`/`setPluginData`, `setCustomCode`/`getCustomCode` (locations `headStart`/`headEnd`/`bodyStart`/`bodyEnd`).
- Permission gating: `isAllowedTo(method)`, `subscribeToIsAllowedTo`, `useIsAllowedTo()` — capabilities depend on the user's plan/role, so a mutation call can be denied.
- The changelog notes recently-added canvas capabilities: **layout traits (stack, grid, padding, gap)**, **border traits** and **variant traits** on `FrameNode`, and node props `overflow`, `zIndex`, `textTruncation` (https://www.framer.com/developers/changelog). So full auto-layout authoring via plugin is relatively recent.

A `createFrameNode` call therefore looks (**reconstructed**, not copied) like `framer.createFrameNode({ width, height, backgroundColor, layout, stackDirection, gap, padding, position, top, left, ... })`.

**(b) Code Components** — React 18 components that "render directly on the canvas, in the preview, and on your published site" (https://www.framer.com/developers/components-introduction). Authored in Framer's built-in code editor (Assets → Code → Create Code File). They expose UI via **`addPropertyControls(Component, {...})`** with **`ControlType`** (from the `framer` library) (https://www.framer.com/developers/property-controls). The full `ControlType` set: `String`, `Number`, `Boolean`, `Color`, `Enum` (`options`/`optionTitles`/`displaySegmentedControl`), `ComponentInstance`, `Array` (`control`, `maxCount`), `Object` (`controls`), `ResponsiveImage` (returns `{src, srcSet, alt}`), `Date`, `EventHandler`, `File` (`allowedFileTypes`), `Transition` (Framer Motion), `Link`, `Padding`, `BorderRadius`, `Border`, `BoxShadow`, `Gap`, `Font`, `Cursor`, `TrackingId` — all support `title`/`description`/`hidden:(props)=>boolean`. Example:
```javascript
import { addPropertyControls, ControlType } from "framer"
function MyComponent(props){ return <div>{props.text}</div> }
addPropertyControls(MyComponent, { text: { type: ControlType.String, title: "Text" } })
```
Components auto-size and are shareable via versioned URLs (https://www.framer.com/developers/components-introduction).

**(c) Code Overrides** — "normal React Higher-Order Components" (https://www.framer.com/developers/overrides-introduction) applied to existing canvas layers to mutate props/behavior at render; the full Motion for React API is available (`whileHover`, etc.), e.g. a `withRotateOnHover` HOC (https://www.framer.com/developers/overrides-examples; https://motion.dev/docs/framer). Overrides take a `ComponentType` and must spread existing props / use `forwardRef`.

**Can an external program author the doc as JSON?** No sanctioned path. The document format is **closed** — there is no published project JSON schema and no offline authoring API. An agent's only sanctioned surfaces are: mutate the live canvas via the in-editor plugin API (imperative JS, permission-gated), or write React code components/overrides that Framer renders. You cannot serialize a project offline and hand it to Framer.

---

## 4. PERSISTENCE

- **Modern Framer (web)**: projects live in **Framer's proprietary cloud**; encrypted at rest (AES-256), SOC2/ISO27001/GDPR (https://www.framer.com/help/articles/guide-to-framer-hosting-infrastructure/). The on-disk/cloud document schema is not published — treat as **closed/opaque**.
- **Legacy Framer X**: the deprecated desktop product used a **`.framerfx` folder** (looks like a file in Finder, actually a directory → git-versionable) (https://github.com/aron/example.framerfx; https://learnreact.design/tips/git-integration). This is legacy; the current web product does not expose it.
- **Code export of the project source: none.** Framer does not let you download your site as HTML/CSS/JS source you can edit (https://pentaclay.com/blog/can-i-export-code-from-framer-here-s-the-truth; https://convertframer.com/blog/can-you-export-code-from-framer). Framer's marketing line "built on open web standards… data is never locked in" refers only to the **published** site being standard HTML/CSS/JS on a CDN (https://www.framer.com/help/articles/guide-to-framer-hosting-infrastructure/), not to source/document portability.
- **Third-party exporters** (NoCodeExport ~$89, letaiworkforme ~$15, React Export Plugin) **scrape the published/rendered site** — HTML per page, CSS, JS with animations, WebP images, WOFF2 fonts — they do **not** read the source document (https://www.nocodeexport.com/en/framer; https://letaiworkforme.com/blog/export-framer-website-to-code).
- **Round-trip: effectively none.** Export is one-way (published DOM → scraped code); there is no re-import of code back into a Framer project, and no doc↔code round-trip. Plugin-scoped KV persists via `getPluginData`/`setPluginData` (https://www.framer.com/developers/reference); structured content lives in CMS Collections (https://www.framer.com/developers/plugins-introduction).

---

## 5. RENDERING

**Framer renders real React/DOM, not a canvas approximation.** Code Components are React 18 components that render "directly on the canvas, in the preview, and on your published site" (https://www.framer.com/developers/components-introduction) — i.e. the same React tree in all three contexts, so the editor canvas is a live DOM render. The animation runtime is **Framer Motion / Motion for React** (https://motion.dev/docs/framer), and Framer's design attributes (`backgroundColor`, `borderRadius`, stack/grid traits) resolve to real CSS on real elements (**inferred** from the trait→CSS mapping in §2 and confirmed by the fact that scraped exports yield real CSS/DOM).

**Publishing / hosting** (https://www.framer.com/help/articles/guide-to-framer-hosting-infrastructure/; https://www.framer.com/dictionary/server-side-rendering):
- **SSR**: most-visited pages are server-rendered **at publish time**; less-visited pages render **on first request**, then cached globally. CMS content is baked in server-side.
- **CDN**: served via **AWS CloudFront**, static IPs, global edge caching; Gzip/Brotli; images resized/compressed to AVIF dynamically without adding TTFB.
- **Immutable, versioned publishes** with instant cache invalidation and instant rollback.
- Since Sept 2025 the bundler is **Rolldown** (Rust-based, tree-shaking, smarter chunking) (https://brixtemplates.com/blog/is-framer-fast-speed-and-performance-analysis).

Net: the visual model → real React → real DOM → SSR'd static-ish HTML on a CDN. React is genuinely under the hood, not a metaphor.

---

## 6. PROGRAMMATIC-AUTHORING FRICTION (opinionated)

**How well does the visual model map to real HTML/CSS/React?** In the **output** direction, very well — and this is the part worth stealing. Framer's canvas concepts are near-isomorphic to CSS:

```
Frame + free position   →  <div style="position:absolute; top/left/right/bottom; z-index">
Stack (auto layout)     →  display:flex  (direction/justify/align/gap/wrap = stack* traits)
Grid                    →  display:grid  (gridColumnCount/…/gridItemColumnSpan)
Sizing Fixed/Fill/Fit   →  px / flex-grow|100% / fit-content
Color/Text Styles       →  shared tokens (ColorStyle / inlineTextStyle references)
Code Component (node)   →  a React component (real 18 API)
Breakpoints             →  a cascade/override tree (inherit larger→smaller)
```
There is no impedance mismatch of the "canvas coordinates only" kind — a Stack really is flexbox, a Grid really is CSS grid. The escape hatch (absolute Frame) is exactly CSS `position:absolute`, with the same reflow downside the CSS itself has, which Framer's own guidance tells users to avoid.

**But for an agent, the friction is structural and severe:**

1. **No open, serializable document format to emit.** You cannot generate "a Framer project JSON" and load it. The doc is closed/cloud-opaque (§4). The only authoring surfaces are (a) the in-editor **plugin API** — imperative JS calls (`createFrameNode`/`setAttributes`/…) that must run **inside the Framer editor** in a sandboxed plugin window, permission-gated by `isAllowedTo`; or (b) writing **React code components/overrides**. So an external agent can't batch-emit a document offline; it must drive a live editor session or ship React source.

2. **Two very different "programmatic" mental models, neither ideal for agents.** The plugin API is *imperative canvas manipulation* (good for tools, awkward for whole-page generation, and gated behind a running editor + plugin infra). The React route means the agent's real output is **React/TSX**, which Framer then renders — i.e. Framer becomes a *host/runtime* for agent-authored React, not a document store the agent controls. If your agent already emits HTML/CSS/JS, Framer adds nothing here — you'd be writing to its React component contract instead of your own output.

3. **No round-trip / lossy one-way codegen.** Framer's published output is real HTML/CSS/JS, but there is no supported source export and no re-import; the only way "back to code" is third-party **scraping of the rendered site** (§4). You cannot treat Framer as a codegen backend you own — you'd be reverse-engineering its published DOM, which drifts with every Framer runtime/bundler change (e.g. the Rolldown switch).

**Verdict for our design.** Copy Framer's *model→CSS mapping* (Stack=flex, Grid=grid, Fill/Fit/Fixed sizing, shared Color/Text tokens, a breakpoint **cascade** rather than duplicate trees, absolute as an explicit opt-out mode) — it's a proven, clean visual↔real-CSS correspondence. Do the **opposite** of Framer on the surface that matters for an agent: make the document an **open, serializable schema the agent emits directly**, with **deterministic, inspectable codegen to HTML/CSS/JS and lossless round-trip**. Framer's closedness (no doc schema, editor-only imperative API, one-way export) is precisely the friction an agent-first tool must not reproduce; its layout semantics are precisely what it should reproduce.

### Sources
- https://www.framer.com/developers/reference
- https://www.framer.com/developers/nodes
- https://www.framer.com/developers/property-controls
- https://www.framer.com/developers/components-introduction
- https://www.framer.com/developers/plugins-introduction
- https://www.framer.com/developers/plugins-quick-start
- https://www.framer.com/developers/overrides-introduction
- https://www.framer.com/developers/overrides-examples
- https://www.framer.com/developers/changelog
- https://www.framer.com/dictionary/flexbox
- https://www.framer.com/academy/lessons/framer-fundamentals-stacks-and-relative-positioning
- https://www.framer.com/academy/lessons/framer-fundamentals-stacks-vs-grids
- https://www.framer.com/academy/lessons/framer-fundamentals-fixed-and-relative-sizing
- https://www.framer.com/academy/lessons/framer-fundamentals-sizing-to-fill-and-fit-content
- https://www.framer.com/academy/lessons/framer-fundamentals-breakpoints
- https://www.framer.com/blog/responsive-breakpoints/
- https://www.framer.com/help/articles/guide-to-framer-hosting-infrastructure/
- https://www.framer.com/dictionary/server-side-rendering
- https://framer.university/blog/why-framer-experts-avoid-using-absolute-positioning
- https://designcode.io/framer-web-design-adaptive-layout/
- https://www.framer.community/c/support/frame-vs-stack-vs-grid-which-concept-is-correct
- https://motion.dev/docs/framer
- https://github.com/aron/example.framerfx
- https://learnreact.design/tips/git-integration
- https://pentaclay.com/blog/can-i-export-code-from-framer-here-s-the-truth
- https://convertframer.com/blog/can-you-export-code-from-framer
- https://www.nocodeexport.com/en/framer
- https://letaiworkforme.com/blog/export-framer-website-to-code
- https://brixtemplates.com/blog/is-framer-fast-speed-and-performance-analysis
- https://github.com/framer/plugins
