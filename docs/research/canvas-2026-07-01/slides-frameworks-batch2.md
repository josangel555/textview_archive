# Agent a647a75928c316d06.output

## Prompt (first 300 chars)
Do FRESH web research (use web search + fetching the actual documentation/source pages) on three slide/presentation frameworks: **Spectacle** (React-based), **Slidev** (Markdown/Vue-based), and **Marp** (Markdown-to-slides). Prefer PRIMARY sources (official docs, GitHub READMEs, source). Cite every 

## Final message

Fresh research complete across all three frameworks, primary sources fetched. Findings below.

---

# Spectacle (React/JSX)

**1. Document/data model.** The authored source is a **React component tree written in JSX** (or the tagged-template `html` form). `Deck` is the root container; each `Slide` is a direct child. Content elements (`Heading`, `Text`, `UnorderedList`/`ListItem`, `CodePane`, `Image`, `Link`, `Table`) and container/layout elements (`Box`, `FlexBox`, `Grid`) nest inside slides; `Appear`/`Stepper` wrap elements for sequential reveals. Verbatim from the one-page example:
```jsx
<Deck theme={theme} template={template}>
  <Slide>
    <FlexBox height="100%"><SpectacleLogo size={500} /></FlexBox>
  </Slide>
  ...
</Deck>
```
There is **no separate internal document model** — the JSX *is* the model, compiled by React into a virtual DOM. **MDX is a first-class alternate authoring path** via `spectacle-mdx-loader`: a `.mdx` file where slides are split by `---`, presenter notes by a `Notes:` block, standard Markdown renders to the Spectacle components, and JSX components can be embedded inline. Elements are identified by React position/props, not stable IDs (there is no per-element addressing scheme in the source).

**2. Layout representation — FLOW/component, not coordinates.** Confirmed: layout is **CSS-flow driven via layout primitives**, not absolute pixel coordinates. `FlexBox` is a flexbox container (`flexDirection`, `justifyContent`, `height="100%"`), `Grid` is CSS Grid (`gridTemplateColumns="1fr 2fr"`, `gridColumnGap={15}`), and `Box` is a styled generic container. You compose these to arrange a slide; the browser's flex/grid engine does the actual placement. (An older Spectacle API also had `Layout`/`Fit`/`Fill` row primitives; current versions center on `FlexBox`/`Grid`/`Box`.) There is no first-class "drop this at x=300,y=120" primitive — arbitrary positioning would require hand-written CSS (`position:absolute`) on a `Box`, i.e. an escape hatch, not the idiom.

**3. Mutation/authoring API.** You author by **editing JSX/MDX source**; there is no runtime document-mutation API for programmatic deck editing. Because it's real React, the source must be **syntactically valid JSX** (balanced tags, valid props, imported components) — an LLM/program can generate it as text but a malformed tag breaks the whole compile. It is re-editable as text but less forgiving than Markdown.

**4. Persistence.** On-disk format is **JSX/React source files** (`.js`/`.jsx`/`.tsx`) or **`.mdx`**. Not a portable neutral format — it presupposes a React/bundler toolchain to run. MDX decks are more portable/readable than JSX but still require the Spectacle MDX loader. Round-trippable only in the trivial sense that source text is the canonical form.

**5. Rendering.** Renders to the **browser DOM via React** — mounted with React 18's `createRoot`:
```js
const root = createRoot(document.getElementById('root'));
root.render(<Presentation/>);
```
It is a client-side React app. **Export/headless is weak**: there is no dedicated server-side render-to-file CLI. PDF export is done in-browser by appending `?exportMode=true` to the URL (flattens all slides so the browser's Print-to-PDF captures them), and `?exportMode=true&printMode=true` gives a black-and-white printer-friendly flatten. There is no official `marp`/`slidev export`-equivalent headless binary — automated export means driving a headless browser to the export-mode URL yourself.

**6. Programmatic-authoring friction (JSX).** Moderate. It's text, so an agent *can* write it, but it must emit **valid React**: correct imports, closed tags, prop types, and a bundler to compile. The payoff is fine-grained componentization; the cost is that layout still lives in `FlexBox`/`Grid` props and the deck won't render at all on a syntax slip. MDX lowers this friction substantially (prose + `---` + `Notes:`), approaching the Markdown tools.

---

# Slidev (Markdown / Vue)

**1. Document/data model.** Authored source is **one extended-Markdown file** (`slides.md` by default). Slides are separated by `---` padded with blank lines. The **first YAML block is "headmatter"** (configures the whole deck: `theme`, `title`, etc.); **every subsequent YAML block is per-slide "frontmatter"** (`layout:`, `background:`, `class:`, etc.). Trailing `<!-- ... -->` comment blocks become that slide's presenter notes. Vue components can be embedded directly in the Markdown; code blocks use fenced Markdown highlighted by Shiki; LaTeX and Mermaid/PlantUML diagrams are supported inline. Under the hood it **compiles to a Vue 3 + Vite web app** — "Slidev is built on top of Vite" and "you can write Vue components and use them in your slides." Slides aren't given stable IDs in source (addressed by order/frontmatter).

**2. Layout representation — FLOW/component, not coordinates (with a verified absolute escape hatch).** Layouts are declared in frontmatter (`layout: two-cols`, `layout: center`, `layout: image-right`, …) and are **implemented as Vue components that wrap slide content** — i.e. component/CSS flow, not a coordinate system. Built-in layouts include: `center`, `cover`, `default`, `end`, `fact`, `full`, `image`, `image-left`, `image-right`, `iframe`, `iframe-left`, `iframe-right`, `intro`, `none`, `quote`, `section`, `statement`, `two-cols`, `two-cols-header`. Multi-region layouts use **named slots** via `::name::` markers:
```md
---
layout: two-cols
---
# Left
This shows on the left
::right::
# Right
This shows on the right
```
Custom layouts go in a `layouts/` dir (override precedence: built-in → theme → addon → local). UnoCSS utility classes and `<div grid="~ cols-2 gap-4">`-style utilities give in-slide grid/positioning.

**Absolute-positioning escape hatch — VERIFIED to exist: `v-drag`.** Slidev has **draggable elements** that let you place/resize/rotate an element by a `[Left, Top, Width, Height, Rotate]` array. Three forms:
```md
<!-- frontmatter -->
dragPos:
  square: Left,Top,Width,Height,Rotate

<img v-drag="[Left,Top,Width,Height,Rotate]" src="...">

<v-drag pos="Left,Top,Width,Height,Rotate"> ... </v-drag>
```
Plus `<v-drag-arrow />`. You can double-click to edit positions in the UI, and the tool writes the coordinates back into the source. `Height` = `NaN`/`_` auto-fits. So Slidev *does* offer true pixel positioning, unlike Marp — but as an opt-in per-element feature layered on the flow model. **UNVERIFIED:** the exact Slidev version that introduced `v-drag` is not stated in the current docs (I could not pin it to a release number).

**3. Mutation/authoring API.** Primary authoring is **editing the Markdown**. There's a notable extra: the browser dev UI can **edit slides live and persist changes back to the `.md` file** (drag-to-position writes coordinates in; the built-in editor round-trips). So the text stays canonical and machine-writable, and `v-drag` is one of the few cases where a GUI action mutates source.

**4. Persistence.** On-disk = **plain Markdown** (`slides.md`) plus optional sidecar assets (custom `layouts/`, `components/`, `setup/`, theme). Highly readable and diff-able. It is *extended* Markdown (Vue components, directives, UnoCSS), so it round-trips within Slidev but is **not fully portable to a generic Markdown renderer** — embedded Vue/`v-click`/`v-drag` are Slidev-specific.

**5. Rendering.** Output target is a **Vue 3 + Vite single-page app**. `slidev build` produces a **static SPA** in `dist/` (hostable on any static server; `--base /talks/x/` for sub-paths; `npx vite preview` to test) — this is the interactive-web export. **Headless file export** via `slidev export`: default **PDF** (`./slides-export.pdf`), plus `--format pptx` (slides embedded as images, text not selectable), `--format png` (per-slide images), and `--format md`. Export **relies on Playwright** (`playwright-chromium` dev dep) — so it is genuinely headless/CI-capable. There's also an in-browser exporter at `/export`.

**6. Programmatic-authoring friction (Markdown).** Very low. An agent writes **prose + fenced code + YAML frontmatter + `---` separators**; layout is delegated to a named layout/theme (`layout: two-cols` + `::right::`), so **no pixel math** for the common case. The ceiling: you can't place an element at an arbitrary pixel *unless* the layout/theme supports it — but Slidev uniquely lifts that ceiling with `v-drag` (write a coordinate array) and UnoCSS utilities, at the cost of the source no longer being pure portable Markdown.

---

# Marp (Markdown → slides)

**1. Document/data model.** Authored source is **plain CommonMark Markdown** (Marpit is "the skinny framework for creating slide deck from Markdown"). Slides are separated by a **horizontal-ruler `---`**; `<!-- headingDivider: 2 -->` can auto-split before headings of a given level instead. Configuration is via **directives**, expressed either as **YAML front-matter** at the top of the file or as **HTML comments** inline:
```md
---
theme: default
paginate: true
---
```
or `<!-- theme: default -->`. Internally Marpit **compiles Markdown (via markdown-it) to HTML + CSS**; Marp Core adds default themes on top of the Marpit engine, and Marp CLI wraps it for output. No component tree, no VDOM — just HTML/CSS. Slides/elements have no source-level IDs (you target them with directives/`class`).

**2. Layout representation — FLOW/CSS, purely (no coordinate system, no absolute API).** Confirmed and the strongest case of the three: **layout is entirely CSS-theme-driven**. There are **no layout components and no positioning primitives** in the Markdown — the deck is HTML styled by a theme's CSS. Directives that affect layout/appearance are all CSS-level: global `theme`, `style`, `size`; local `paginate`, `header`, `footer`, `backgroundColor`, `backgroundImage`, `color`, and `class`. You steer layout by choosing/writing a **theme** and attaching CSS classes (e.g. a theme's `lead` class centers a title slide). There is **no `v-drag` equivalent** — arbitrary pixel placement is only possible by writing custom CSS in the theme (or an inline `<style>`), never by a coordinate in the Markdown itself.

**3. Mutation/authoring API.** Authoring = **editing the Markdown**; directives are set via front-matter or `<!-- -->` comments. **Local directives** apply to their slide and cascade forward; **prefix with `_` to scope to a single slide** (spot directive), e.g. `<!-- _backgroundColor: aqua -->` or `<!-- _class: lead -->`, which does not inherit to following pages. Programmatic extension exists at the API level (`customDirectives.global` / `customDirectives.local` on a Marpit instance) but that's a JS integration point, not source syntax.

**4. Persistence — the portability standout.** On-disk = **plain, portable Markdown**. This is the emphasis point: a Marp `.md` is **valid CommonMark that renders as ordinary Markdown anywhere** (GitHub, any editor) — the Marp-specific parts are just front-matter keys and HTML comments that non-Marp renderers harmlessly ignore. Fully round-trippable, diff-friendly, no toolchain lock-in for reading the source. Nothing to compile to keep the text authoritative.

**5. Rendering.** Marpit's own output is **HTML + CSS**. **Marp CLI** provides real **headless server-side export** (needs one of Chrome/Edge/Firefox for the non-HTML formats):
- `marp deck.md` → **HTML** (default; Bespoke template with nav/fullscreen/presenter view, or a `bare` template).
- `marp --pdf` → **PDF** (`--pdf-notes`, `--pdf-outlines`).
- `marp --pptx` → **PowerPoint** (images); `--pptx-editable` (experimental, needs LibreOffice) → editable shapes.
- `marp --images png|jpeg` → per-slide images; `--image` → title slide only; `--image-scale 2` for hi-res.
- `--notes` → presenter notes as text.
- Operational: `-w` watch, `-s` server (on-demand `?pdf` etc.), `-p` preview window.
This is the most CI/headless-friendly export story of the three (a single binary, scriptable, no browser UI needed beyond a headless Chromium).

**6. Programmatic-authoring friction (Markdown) — lowest.** An agent authors a Marp deck by **writing prose + `---` separators + a few directives**. No coordinates, no components, no valid-React/valid-Vue constraint — just Markdown that degrades gracefully even if the Marp layer is stripped. Layout is 100% the theme's job. The hard ceiling: **you cannot place an element at an arbitrary pixel from the Markdown at all** — if the theme doesn't express a layout, you must edit CSS. That's the deliberate trade: maximum portability and minimum authoring friction, minimum per-element positioning control.

---

## Cross-cutting summary

| Dimension | Spectacle | Slidev | Marp |
|---|---|---|---|
| Source | JSX/React (or MDX) | Extended Markdown (`slides.md`) | Portable CommonMark Markdown |
| Compiles to | React VDOM → DOM | Vue 3 + Vite SPA | HTML + CSS |
| Layout model | Flow: `FlexBox`/`Grid`/`Box` | Flow: layout components + slots + UnoCSS | Flow: CSS theme only |
| Absolute positioning | CSS escape hatch only | **`v-drag` coordinate array (verified)** | None in source (theme CSS only) |
| Persistence | JSX/MDX (toolchain-bound) | Extended MD (Slidev-bound) | **Plain portable MD** |
| Headless export | Weak (browser `?exportMode`) | `slidev export` via Playwright (PDF/PPTX/PNG/MD) | **`marp-cli`: HTML/PDF/PPTX/PNG/JPEG** |
| LLM authoring friction | Highest (valid React) / MDX lower | Low | **Lowest** |

**All three are flow/component/CSS layout systems — none is a coordinate/canvas model.** Confirmed. The only place a raw pixel coordinate enters the *source* is Slidev's opt-in `v-drag`; Spectacle and Marp require CSS for anything the layouts/themes don't express.

### Flagged as UNVERIFIED
- **Slidev `v-drag` introduction version** — the feature is current and documented, but the docs page states no version number; I could not pin it to a release.
- **Slidev `v-motion`** — docs say available "since v0.48.9" and the click-animation system was "rewritten since v0.48.0" (this *is* verified from the animations doc); I did not independently confirm those version numbers against a changelog.
- **Spectacle legacy `Layout`/`Fit`/`Fill` primitives** — appeared in older docs/search snippets; current core centers on `FlexBox`/`Grid`/`Box`. Treat `Fit`/`Fill` as possibly-deprecated (not confirmed in the current README).

## Sources (full URLs)

Slidev
- https://sli.dev/guide/syntax
- https://raw.githubusercontent.com/slidevjs/slidev/main/docs/guide/syntax.md
- https://sli.dev/guide/layout
- https://raw.githubusercontent.com/slidevjs/slidev/main/docs/builtin/layouts.md
- https://raw.githubusercontent.com/slidevjs/slidev/main/docs/guide/animations.md
- https://sli.dev/features/draggable
- https://raw.githubusercontent.com/slidevjs/slidev/main/docs/features/draggable.md
- https://raw.githubusercontent.com/slidevjs/slidev/main/docs/guide/exporting.md
- https://raw.githubusercontent.com/slidevjs/slidev/main/docs/guide/hosting.md
- https://raw.githubusercontent.com/slidevjs/slidev/main/docs/guide/why.md

Marp
- https://marpit.marp.app/directives
- https://raw.githubusercontent.com/marp-team/marpit/main/docs/directives.md
- https://raw.githubusercontent.com/marp-team/marp-cli/main/README.md

Spectacle
- https://github.com/FormidableLabs/spectacle
- https://raw.githubusercontent.com/FormidableLabs/spectacle/main/README.md
- https://raw.githubusercontent.com/FormidableLabs/spectacle/main/examples/one-page/index.html
- https://raw.githubusercontent.com/FormidableLabs/spectacle-mdx-loader/main/examples/mdx/slides.mdx
- https://raw.githubusercontent.com/FormidableLabs/spectacle/main/docs/faq.md
- https://nearform.com/open-source/spectacle/docs/faq/
