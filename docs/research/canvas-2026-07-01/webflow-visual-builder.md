# Agent ae7c9df5229b09d2d.output

## Prompt (first 300 chars)
Do FRESH web research (use WebSearch + WebFetch of official docs, developer/API docs, and any source) on WEBFLOW as a visual-to-code web UI builder. We are designing an agent-first WYSIWYG canvas that outputs HTML/CSS/JS, and want to learn concretely how Webflow models a visual UI and maps it to rea

## Final message

# WEBFLOW

Research dump on how Webflow models a visual UI and maps it to real web output. Primary sources are `developers.webflow.com` (Designer API + Data API), the Webflow engineering blog, and Webflow University/Help Center. Where a Help Center page blocked direct fetch (HTTP 403) and I relied on Webflow's own text via search snippets, or where a claim is inferred, I mark it **[UNVERIFIED]** / **[PARTIAL]**.

## 1. Document / Data Model

Webflow's internal model is a **component tree that mirrors the DOM**, not an absolute-position scene graph. Elements are "the building blocks... from structural elements like sections and containers to content elements like text and images" (https://developers.webflow.com/designer/reference/elements-overview). Nodes form a parent/child hierarchy manipulated with DOM-shaped verbs: `append`, `prepend`, `before`, `after`, `remove`, `getChildren` (https://developers.webflow.com/designer/reference/creating-retrieving-elements).

**Node identity is a composite object, not a flat string.** A DOM element's id is:

```js
el.id = {
  component: "64c813...",              // component identifier (present when inside a component definition)
  element:   "5edf8e59-71f9-..."       // element identifier (UUID)
}
```
(https://developers.webflow.com/designer/reference/dom-element). The `component` slot is how the same element instance is disambiguated across component definition vs instance contexts — i.e., identity is scoped by component, which matters for reuse. **[UNVERIFIED]**: whether `component` is null/absent for page-level (non-component) elements — the docs show it populated but don't state the empty case.

**Element object shape** (from the DOM element + presets pages): capability flags rather than data fields — `type` (e.g. `"DOM"`), and booleans `styles`, `children`, `textContent`, `customAttributes` indicating what the element supports. Content/config is set via methods, not by writing fields: `setTag`, `getTag`, `setAttribute`/`getAttribute`/`removeAttribute`/`getAttributes`, `setTextContent`, `setStyles`/`getStyles` (https://developers.webflow.com/designer/reference/dom-element).

**Styling model = CSS classes, essentially no inline styles.** This is the single most important modeling fact. In Webflow a "Style" *is* a CSS class ("Styles are also referred to as Classes in the Designer"), with four read-only props (https://developers.webflow.com/designer/reference/styles-overview):

- `id` — unique identifier
- `name` — the label shown in the Style panel
- `type` — `'global' | 'combo' | 'tag' | 'element' | 'descendant'`
- `source` — `'site' | 'library'` (Shared Library / AI generation)

The Style-panel-is-CSS mental model: every visual edit in the panel writes a CSS declaration onto whatever selector is active — a **class** (global/combo), an **HTML tag** selector, or a **descendant** selector. Notably the *Designer API* can only create/apply classes: "the Designer API supports only CSS Classes; you can't style HTML Tags with the Designer API" (https://developers.webflow.com/designer/reference/styles-overview) — even though the *UI* can style tag selectors (`type: 'tag'`).

**Class system (from Webflow's own docs via search + Help Center):**
- **Global classes** — a named class applied to any element; styling it restyles every element carrying it. Ideal for utilities (color, spacing) (https://help.webflow.com/hc/en-us/articles/33961311094419-Classes).
- **Combo classes** — a *variant* stacked on a base class that inherits the base and adds/overrides. Created in the API by passing a parent: `webflow.createStyle(name, { parent: baseStyle })` (https://developers.webflow.com/designer/reference/create-style). In the Style panel, inherited props render **orange**, overrides/new props **blue**; an "affected elements" counter shows reuse count (https://help.webflow.com/hc/en-us/articles/33961362040723-Style-panel-overview) **[PARTIAL — Help Center via search snippet]**.

**Design tokens = Webflow Variables**, a first-class layer separate from classes. Five types: **Color, Size, Font, Number, Percentage**, grouped into **Variable Collections**, with **Modes** (same variable resolves differently per light/dark/brand context) and variable-to-variable binding (https://developers.webflow.com/designer/reference/variables-overview, https://help.webflow.com/hc/en-us/articles/33961268146323-Variables). Variables are assigned into style properties: a `PropertyMap` value may be a string literal *or* a Variable object (ColorVariable, SizeVariable, …) (https://developers.webflow.com/designer/reference/styles-overview). This is the design-token → CSS-custom-property mapping.

## 2. Layout Representation — the key question

**Webflow uses real, semantic CSS layout — flow / flexbox / grid — with `display` set on the parent, NOT an absolute-positioning canvas.** Absolute positioning exists but is opt-in and secondary. Two orthogonal axes in the model:

**(a) Layout / display** — chosen on the *parent* container, exactly like CSS `display`:
- Block/flow (default document flow)
- **Flexbox** (1-D) — set `display: flex`; children align via justify/align controls (https://help.webflow.com/hc/en-us/articles/33961242149395-Flexbox-vs-grid-vs-Quick-Stack) **[PARTIAL — Help Center via search snippet; page 403'd on direct fetch]**
- **CSS Grid** (2-D rows+columns; supports overlap)
- **Quick Stack** — Webflow's **Auto-Layout equivalent**: a preset flex-based stacking container (a wrapper that gives you a nestable flex row/column with padding/gap controls without hand-setting every flex prop). It is exposed as first-class element presets in the API: `QuickStack`, `HFlex`, `VFlex`, `Row`, `Grid`, `Section`, `DivBlock` (https://developers.webflow.com/designer/reference/element-presets). So the API literally gives you "horizontal flex" and "vertical flex" containers as primitives — the closest analog to Figma Auto Layout.

**(b) Position** — the standard CSS `position` values, chosen per element and defaulting to `static` (in flow): `static | relative | absolute | fixed | sticky`, plus `z-index` (https://help.webflow.com/hc/en-us/articles/33961228002963-CSS-position-properties) **[PARTIAL — Help Center via search snippet]**. Absolute positioning "removes elements from normal document flow" and is positioned relative to the nearest non-static ancestor — i.e., Webflow teaches the real CSS containing-block rules, not a coordinate canvas.

**How layout is stored:** as CSS properties on the class/selector, set via `style.setProperties({ 'display': 'flex', 'flex-direction': 'column', 'grid-template-columns': '…' }, options)`. Property keys are literal CSS property names and values are literal CSS values (https://developers.webflow.com/designer/reference/set-style-properties). Responsive/state variants are stored by tagging the same property write with an `options` object:

```ts
style.setProperties(
  props: PropertyMap,
  options?: { breakpoint?: BreakpointId; pseudo?: PseudoStateKey; variantId?: string }
): Promise<void>
```
- `breakpoint`: `"xxl" | "xl" | "large" | "main" | "medium" | "small" | "tiny"` — i.e., named media-query buckets around a `main` base (Webflow's breakpoints cascade down from `main`).
- `pseudo`: `"noPseudo" | "hover" | "active" | "focus" | "visited" | "focus-visible" | "focus-within" | "placeholder" | "empty" | "first-child" | "last-child" | "nth-child(odd)" | "nth-child(even)" | "before" | "after"`.
(https://developers.webflow.com/designer/reference/set-style-properties)

Takeaway: layout is **genuine semantic CSS** — flex/grid/flow on parents + standard positioning — so the visual model maps cleanly onto real HTML/CSS. This is materially different from a Sketch/absolute-XY tool.

## 3. Mutation API

Two distinct APIs with **very different power levels**, plus a hard architectural constraint on the powerful one.

**Designer API (Designer Extensions)** — the *only* way to programmatically build/edit the actual element tree and styles. It is a **client-side JavaScript API that runs inside the open Designer**, in a sandboxed iframe app, talking to Webflow over `window.postMessage` + an internal **JSON-RPC** layer; the Designer itself is a **Flux** app whose stores (e.g. `PagesStore`) are mutated and then synced to the server (https://webflow.com/blog/designer-apis-part-1). Concretely an app/agent can:

- **Create elements** from ~100+ presets (`DivBlock, Section, Container, HFlex, VFlex, Grid, QuickStack, Heading, Paragraph, TextBlock, RichText, LinkBlock, Button, Image, Video, HtmlEmbed, FormForm, FormTextInput, NavbarWrapper, TabsWrapper, SliderWrapper, DynamoWrapper (CMS), Slot (component), Commerce*, LogIn/SignUp/UserAccount`, …) or a raw **`DOM`** preset for any custom tag (https://developers.webflow.com/designer/reference/element-presets).
- **Build trees in bulk** with `elementBuilder` then commit atomically:

```ts
const root  = webflow.elementBuilder(webflow.elementPresets.DOM);
root.setTag('nav'); root.setStyles([navStyle]);
const link  = root.append(webflow.elementPresets.DOM);
link.setTag('a'); link.setAttribute('href', '#'); link.setTextContent('Home'); link.setStyles([itemStyle]);
const target = await webflow.getSelectedElement();
await target.append(root);   // one commit for the whole subtree
```
(https://developers.webflow.com/designer/reference/bulk-add-elements)

- **Create/apply styles (classes):** `const s = await webflow.createStyle('Card'); await s.setProperties({ 'background-color': blueVar, 'padding': '16px' }); await el.setStyles([s]);` (https://developers.webflow.com/designer/reference/create-style, https://developers.webflow.com/designer/reference/element-styles/setStyles). `setStyles` takes an **ordered array** — order encodes base-then-combo class stacking.
- **Create Variables/Collections**, set attributes, text content, and select/traverse elements (`getSelectedElement`, `getAllElements`, `setSelectedElement`).

Crucial constraint: **there is NO plain-JSON, server-side "here is my document, import it" endpoint.** You cannot POST a document graph. Mutations are imperative method calls executed live against the running Designer's Flux store; the app must run as an authorized Designer Extension with the Designer open, gated by capability checks (e.g. `canCreateStyleBlocks`, `canManageComponents`) (https://developers.webflow.com/designer/reference/create-style). It is a **live-model API, not codegen and not a document-format import.**

**Data API (REST, server-side, OAuth)** — cannot build the element tree. It covers:
- **CMS**: full CRUD on collection items incl. bulk (≤100/req), staged/live publish (https://developers.webflow.com/data/reference, https://developers.webflow.com/data/docs/working-with-the-cms/manage-collections-and-items). Note: you **cannot create CMS fields via API** — schema is UI-only (https://developers.webflow.com/data/reference).
- **Page/Component *content*** — `GET`/`update` of *content nodes only* (text HTML, image alt/assetId, form choices, component-instance `propertyOverrides`), **not structural elements**, and node updates were introduced primarily for **secondary-locale localization** (https://developers.webflow.com/data/reference/pages-and-components/pages/get-content, https://developers.webflow.com/data/reference/pages-and-components/pages/update-static-content). **[PARTIAL]** on whether primary-locale structural edits are ever allowed — docs frame updates around localization + text/image swaps, not tree mutation.
- **Custom code** injection (site/page `<head>`/`<body>` scripts) via OAuth scopes `custom_code:read/write` (https://webflow.com/blog/webflow-custom-code-API).

So: **agent-builds-a-page ⇒ Designer API only; agent-manages-content ⇒ Data API.**

## 4. Persistence

Design lives in **Webflow's proprietary server-side store** (AWS-backed), synced from the Designer's Flux stores on each mutation (https://webflow.com/blog/designer-apis-part-1). There is **no published, portable document format** and no public "project JSON" schema — the internal representation is not exposed as an editable artifact. Webflow is closed-source/proprietary (https://www.flowninja.com/blog/is-webflow-open-source).

**Export** produces a ZIP of static assets: HTML per page, CSS (Webflow's normalize/base + your generated class CSS), JS (including the **IX2 interactions engine `webflow.js`** that plays back animations), and images (https://help.webflow.com/hc/en-us/articles/33961386739347-How-do-I-export-my-Webflow-site-code). **Excluded from export: CMS/collection content, Ecommerce, user accounts, forms (won't submit), site search, localized pages** — because those require Webflow's backend (https://help.webflow.com/hc/en-us/articles/33961386739347-How-do-I-export-my-Webflow-site-code).

**Round-trip: none. Export is strictly one-way.** Webflow does not support re-importing exported (or hand-edited) code back into the Designer; once you edit exported code you continue in code, outside Webflow (multiple sources incl. Memberstack's teardown: https://www.memberstack.com/blog/the-truth-about-exporting-code-from-webflow, https://help.webflow.com/hc/en-us/articles/33961386739347-How-do-I-export-my-Webflow-site-code). The only "round-trip-ish" path is keeping Webflow as source-of-truth and re-exporting after every edit — which defeats code-editing.

## 5. Rendering

The **Designer canvas renders the real DOM/CSS live** — it is an actual browser rendering of your element tree with your class CSS applied (WYSIWYG in the literal sense), which is why custom `<iframe>`/`<style>` embeds preview on canvas. What the canvas deliberately does **not** do is *execute scripts* — JS only runs in Preview mode and on the published site, for security/perf (https://help.webflow.com/hc/en-us/articles/33961332238611-Custom-code-embed via search). The `DOM` preset element "creates that element on the canvas" as a real node (https://developers.webflow.com/designer/reference/dom-element). Webflow's engine is **not React** — you can't drop React components in without explicit mount code (https://webflow.com/integrations/react).

**Hosting / SSR:** Webflow **pre-renders to static HTML/CSS/JS at publish time**; CMS content is *baked in at publish*, not rendered per-request. Served via Fastly (pull-through cache, purged on every publish) + AWS/Cloudflare CDN (https://werun.dev/blog/webflow-architecture-explained-hosting-cdn-security-and-performance). No traditional per-request SSR for standard sites; **Webflow Cloud** is the separate product that adds real server-rendered app/backend capability (https://webflow.com/feature/hosting). **[PARTIAL — hosting internals mostly from a secondary architecture writeup + Webflow feature page.]**

## 6. Programmatic-Authoring Friction — the central lesson

**Opinionated verdict:** Webflow's *visual model ↔ real HTML/CSS mapping is excellent* (arguably best-in-class), but its *programmatic-authoring ergonomics for an agent are poor*, and it is *heavily locked-in*. These are separable and both matter for your design.

- **The model↔web mapping is clean and semantic.** A Webflow node = a DOM element; a "Style" = a real CSS class; layout = real flex/grid/flow with standard `position`; tokens = CSS-variable-like Variables; breakpoints = media queries; pseudo = pseudo-classes. There is essentially **no lossy visual abstraction** to translate — the panel edits *are* CSS. If you're designing an agent-first canvas that outputs HTML/CSS/JS, **this class-based, display-on-parent, tokens-as-variables model is the one to emulate**, and it's the reason Webflow's *exported code* is genuinely idiomatic (semantic tags, real classes) rather than a soup of absolutely-positioned divs.

- **But you cannot emit Webflow's document JSON directly.** There is no public content-graph format and no import endpoint. The *only* programmatic authoring path is the **Designer API — an imperative, client-side, live-in-the-running-Designer, postMessage/JSON-RPC method API** (https://webflow.com/blog/designer-apis-part-1). An agent must run as an authorized Designer Extension inside an open Designer session and *drive the tool as a user would*, call by call (`createStyle`, `elementBuilder`, `append`, `setProperties`), respecting capability gates. That's a fundamentally different (and heavier) integration than "generate a JSON doc and POST it." For your project this is the key anti-pattern to avoid: **don't couple authoring to a live editor session; make the document a plain serializable artifact an agent can emit whole.**

- **Round-trip / codegen fidelity: the classic one-way trap.** Export is one-directional; hand-edits to exported code cannot flow back; and re-export from Webflow will **overwrite** external edits — so any "regenerate" clobbers downstream changes (https://help.webflow.com/hc/en-us/articles/33961386739347-How-do-I-export-my-Webflow-site-code, https://www.memberstack.com/blog/the-truth-about-exporting-code-from-webflow). Backend-dependent features (CMS, forms, search, ecommerce, auth) simply don't survive export at all. So Webflow has the exact **edits-lost-on-regen** problem you're presumably trying to design *out* of.

- **Lock-in is high.** No portable format, proprietary store, no re-import, CMS content not cleanly exportable — leaving Webflow means abandoning the visual editing model and continuing in raw exported code (https://michalak.world/posts/webflow-and-framer-the-vendor-lock-in-dilemma/, https://www.flowninja.com/blog/is-webflow-open-source). This is precisely why open-source clones (WebStudio, TeleportHQ) pitch "same model, no lock-in, editable code as source of truth."

**Net design lesson for an agent-first WYSIWYG→code tool:** copy Webflow's *semantic model* (DOM-mirroring tree, class-based styles-as-CSS, display-on-parent flex/grid, token variables, breakpoint/pseudo-tagged property writes) — but **invert its two failures**: (1) make the canonical document a **plain, serializable, agent-emittable format** (so an agent writes the doc directly, no live-editor RPC), and (2) treat **code as a first-class round-trippable representation** (or keep a single source of truth that regenerates deterministically without clobbering), so you don't inherit Webflow's one-way export and lock-in.

---

### Sources
- Designer API — Introduction: https://developers.webflow.com/designer/reference/introduction
- Designer API — Elements overview: https://developers.webflow.com/designer/reference/elements-overview
- Designer API — Creating & retrieving elements: https://developers.webflow.com/designer/reference/creating-retrieving-elements
- Designer API — DOM element (id shape, tag/attr methods): https://developers.webflow.com/designer/reference/dom-element
- Designer API — Bulk add / elementBuilder: https://developers.webflow.com/designer/reference/bulk-add-elements
- Designer API — Element presets (full type list): https://developers.webflow.com/designer/reference/element-presets
- Designer API — Styles overview (Style props, types, PropertyMap): https://developers.webflow.com/designer/reference/styles-overview
- Designer API — Create style (combo via parent): https://developers.webflow.com/designer/reference/create-style
- Designer API — Set style properties (breakpoints/pseudo/variant): https://developers.webflow.com/designer/reference/set-style-properties
- Designer API — Set styles on element: https://developers.webflow.com/designer/reference/element-styles/setStyles
- Designer API — Variables & collections: https://developers.webflow.com/designer/reference/variables-overview
- Engineering blog — How we built the Designer APIs (iframe/postMessage/JSON-RPC/Flux): https://webflow.com/blog/designer-apis-part-1
- Data API — reference root: https://developers.webflow.com/data/reference
- Data API — Create CMS items (item JSON shape): https://developers.webflow.com/data/reference/cms/collection-items/staged-items/create-items
- Data API — Manage collections & items (no field creation via API): https://developers.webflow.com/data/docs/working-with-the-cms/manage-collections-and-items
- Data API — Get page content (content-node JSON, not full DOM): https://developers.webflow.com/data/reference/pages-and-components/pages/get-content
- Data API — Update page content (nodes; localization scope): https://developers.webflow.com/data/reference/pages-and-components/pages/update-static-content
- Data API — Designer Extensions overview: https://developers.webflow.com/apps/docs/designer-extensions
- Custom Code API blog: https://webflow.com/blog/webflow-custom-code-API
- Help Center — Classes: https://help.webflow.com/hc/en-us/articles/33961311094419-Classes
- Help Center — Style panel overview: https://help.webflow.com/hc/en-us/articles/33961362040723-Style-panel-overview
- Help Center — Flexbox vs grid vs Quick Stack: https://help.webflow.com/hc/en-us/articles/33961242149395-Flexbox-vs-grid-vs-Quick-Stack
- Help Center — CSS position properties: https://help.webflow.com/hc/en-us/articles/33961228002963-CSS-position-properties
- Help Center — Variables: https://help.webflow.com/hc/en-us/articles/33961268146323-Variables
- Help Center — Custom code embed (canvas doesn't run scripts): https://help.webflow.com/hc/en-us/articles/33961332238611-Custom-code-embed
- Help Center — Export site code (one-way, exclusions): https://help.webflow.com/hc/en-us/articles/33961386739347-How-do-I-export-my-Webflow-site-code
- Webflow hosting feature page: https://webflow.com/feature/hosting
- Architecture writeup (Fastly/CDN/pre-render) — secondary: https://werun.dev/blog/webflow-architecture-explained-hosting-cdn-security-and-performance
- Lock-in analysis — secondary: https://michalak.world/posts/webflow-and-framer-the-vendor-lock-in-dilemma/
- Is Webflow open source — secondary: https://www.flowninja.com/blog/is-webflow-open-source
- Export/round-trip teardown — secondary: https://www.memberstack.com/blog/the-truth-about-exporting-code-from-webflow

**Verification flags:** Help Center layout/positioning/style-panel specifics are from Webflow's own text via search snippets (those pages returned HTTP 403 to direct fetch) — content is Webflow's but I couldn't render the full page; treat exact UI labels as **[PARTIAL]**. The DOM-element `id.component` empty-case, and whether the Data API ever mutates *primary-locale structure* (vs localization-only content nodes), are **[UNVERIFIED]**. Hosting internals lean partly on a secondary architecture writeup.
