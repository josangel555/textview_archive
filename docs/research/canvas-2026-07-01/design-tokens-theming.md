# Agent ac483a70941bb41e6.output

## Prompt (first 300 chars)
You are a web-research agent. Research DESIGN-TOKEN and THEMING systems — how design/visual tools and design systems avoid hardcoded CSS values (raw hex colors, arbitrary pixel spacing, ad-hoc font sizes) by using named, scaled tokens instead.

Context: someone is building a visual editor authored b

## Final message

I have thorough coverage. Compiling the findings.

---

# Design Tokens & Theming — Research Findings (cited)

**Bottom line for your use case:** the industry has converged on a now-stable W3C standard (DTCG, first stable version Oct 2025) and a near-universal **three-tier token architecture** (primitive/global → semantic/alias → component). For an AI agent authoring a visual editor, that maps cleanly to your goal: the agent should emit **tier-2 semantic references** (`color.primary`, `spacing.md`, `type.heading`), which indirect through tier-1 primitives — giving you consistency, mutability, and theme-swap for free. Below are the concrete structures, cited, plus the trade-offs and failure modes.

---

## 1. The W3C DTCG format spec (the standard to target)

The **Design Tokens Community Group** format is the vendor-neutral JSON standard, reaching its **first stable version (2025.10) on 28 October 2025**, developed by 20+ editors backed by Adobe, Google, Microsoft, Meta, Figma, and Shopify. It's "a production-ready, vendor-neutral format for sharing design decisions across tools and platforms." ([w3.org announcement](https://www.w3.org/community/design-tokens/2025/10/28/design-tokens-specification-reaches-first-stable-version/), [designtokens.org spec](https://www.designtokens.org/tr/drafts/format/), [DTCG repo](https://github.com/design-tokens/community-group))

**Core structure — `$value` + `$type`:**
- A token is any object with a `$value` property — "`$value` is a reserved word." All reserved metadata keys are `$`-prefixed (`$value`, `$type`, `$description`, `$deprecated`, `$extends`), so a parser can unambiguously distinguish tokens, groups, and metadata. ([spec](https://www.designtokens.org/tr/drafts/format/))
- `$type` can be set on the token or **inherited from a parent group** (or resolved via reference). Example:
```json
{ "token name": { "$type": "color", "$value": { "colorSpace": "srgb", "components": [1, 0, 0] } } }
```

**Groups** organize tokens hierarchically (no `$value` of their own); they carry shared `$type`/`$description`. A reserved `$root` name gives a group a base value; `$extends` enables deep-merge inheritance (`"button-primary": { "$extends": "{button}" }`).

**Two reference mechanisms** (this is the load-bearing part for your agent):
- **Curly-brace aliases** — token→token, always resolving to a full `$value`:
```json
{ "colors": { "blue": { "$value": {...} } },
  "semantic": { "primary": { "$value": "{colors.blue}" } } }
```
- **JSON Pointer `$ref`** — property-level access into a specific location (`{ "$ref": "#/colors/blue/$value/components/0" }`).

**Token types** (primitives): `color` (object: `colorSpace` + `components` + optional hex), `dimension` (`{value, unit}`, px/rem), `fontFamily` (string or array), `fontWeight` (1–1000 or aliases like `"bold"`), `duration` (`{value, unit}`, ms/s), `cubicBezier` (4-number array), `number` (unitless, e.g. line-height). Color now supports **Display P3, Oklch, and all CSS Color Module 4 spaces**. ([spec](https://www.designtokens.org/tr/drafts/format/))

**Composite types** (multiple sub-values in one token; sub-values may themselves be references):
- `shadow` — `{color, offsetX, offsetY, blur, spread}`
- `border` — `{color, width, style}` (e.g. `"color": "{color.focusring}"`)
- `transition` — `{duration, delay, timingFunction}`
- `strokeStyle` — enum string (`solid`/`dashed`/`dotted`/…) or `{dashArray, lineCap}`
- `gradient` — stops + angle/position
- `typography` — bundles `fontFamily`, `fontSize`, `fontWeight`, `lineHeight`, etc.

---

## 2. Token tiers (global → semantic → component)

**Universal three-tier model** across essentially every mature system. ([alwaystwisted](https://www.alwaystwisted.com/articles/design-token-naming-conventions), [Medium/Yanamala](https://medium.com/@yamini1020.yanamala/design-system-what-are-global-alias-and-component-tokens-part-1-78420a5827a1), [thedesignsystem.guide](https://thedesignsystem.guide/design-tokens))

| Tier | AKA | Holds | Carries meaning? | Example |
|------|-----|-------|-----------------|---------|
| 1 | **Global / primitive / reference** | Raw values | No — platform-agnostic, no semantics | `blue.500 = #3b82f6`, `space.4 = 16px` |
| 2 | **Semantic / alias** | Intent/role, references tier-1 | Yes — purpose, not appearance | `color.background.default`, `color.border.subtle`, `spacing.component.gap` |
| 3 | **Component** | Local per-component decisions, references tier-2 | Component-scoped | `button.icon.color`, drop-zone bg |

- Primitives "shouldn't carry semantic meaning… their purpose is to ensure consistency in core values." Semantic tokens "reference the Global Tokens but use semantic names to define their role." Component tokens "give you precision — tune one component without side-effect explosions elsewhere." ([thedesignsystem.guide](https://thedesignsystem.guide/design-tokens))
- **This is exactly the indirection your agent needs**: it emits tier-2 names; tier-1 values change once and cascade everywhere. "Changing just the theme token's value would cascade through the entire system, affecting all elements that reference it directly or indirectly." ([David Supik](https://david-supik.medium.com/advanced-theming-techniques-with-design-tokens-bd147fe7236e))

**Nathan Curtis's naming taxonomy** (the canonical reference) decomposes names into ordered levels: **namespace** (system/theme/domain) → **base** (category/property/concept) → **modifiers** (variant/state/scale/mode), appended last. Pattern: `{namespace}-{category}-{concept}-{property}-{variant}-{state}-{scale}`. Key rules: "start within, then promote across components" (elevate a token to global only when reused across 3+ components); alias rather than duplicate (`$ui-controls-color-text-error = $color-feedback-error`). ([EightShapes/Curtis](https://medium.com/eightshapes-llc/naming-tokens-in-design-systems-9e86c7444676))

---

## 3. Scales (the numeric backbone)

**Spacing — 4/8-pt grid:** An 8pt base scale with a 4pt half-step for fine adjustments; multiples of 2/4/8. Critically, **line-heights stay on the grid even when font-size doesn't** (15px text → 24px line-height, a multiple of 8/4). Scales cleanly across DPI/screen sizes. ([freeCodeCamp 8-pt grid](https://www.freecodecamp.org/news/8-point-grid-typography-on-the-web-be5dc97db6bc/), [Carbon spacing](https://carbondesignsystem.com/elements/spacing/overview/), [designsystems.com](https://www.designsystems.com/space-grids-and-layouts/))

**Type — modular scale:** Sizes derived from a ratio (1.5 major-third-ish, 1.618 golden ratio, etc.) applied to a base, producing harmonic size steps rather than arbitrary values. ([Figr typography](https://figr.design/blog/typography-system-design))

**Color — 50–900(–950) ramps:** The Tailwind-popularized convention: 11 steps (50, 100…900, 950) where the number "loosely corresponds to lightness — 50 nearly white, 500 the base, 950 nearly black." Semantic usage: 50–200 backgrounds/fills, 300–500 borders/secondary, 600–900 text/emphasis. The numbering is **perceptual, not mathematical** — modern ramps step through **OKLab/OKLCH** so each step is a roughly equal perceived-lightness distance (RGB mixing produces uneven ramps). ([shade-ramp generator](https://www.generatorcollection.com/en/generators/colors/color-shade-ramp-generator/), [Dreamten](https://www.dreamten.com/insights/mastering-design-system-colors))

**Radix Colors — the semantic 12-step alternative:** Instead of a lightness ramp, each scale's 12 steps are **assigned to specific UI roles** — a more directly "semantic" primitive than 50–900: ([Radix understanding-the-scale](https://www.radix-ui.com/colors/docs/palette-composition/understanding-the-scale))

```
1–2   App / subtle component backgrounds
3–5   Component backgrounds  (3 normal · 4 hover · 5 pressed/selected)
6–8   Borders  (6 subtle non-interactive · 7 interactive · 8 strong/focus ring)
9–10  Solid backgrounds  (9 = highest chroma / purest · 10 hover)
11–12 Text  (11 low-contrast · 12 high-contrast)
```
Text steps are engineered to pass contrast targets (APCA) against the matching background steps; every scale ships a dark-mode variant + alpha variants for blending. ([Radix](https://www.radix-ui.com/colors/docs/palette-composition/understanding-the-scale))

---

## 4. How real systems implement it

**Style Dictionary (Amazon, 2017)** — the reference build tool. Define tokens once in JSON, compile to CSS variables, Sass, Swift, Kotlin, TS, Android, docs, etc. ([styledictionary.com/info/tokens](https://styledictionary.com/info/tokens/), [github/style-dictionary](https://github.com/style-dictionary/style-dictionary), [AWS blog](https://aws.amazon.com/blogs/opensource/style-dictionary-trust-design-consistency/))
- Token shape: `{ "value": "#111111", "type": "color", "comment": …, "themeable": true }`.
- Aliases via dot-notation braces: `"base": { "value": "{size.font.small}" }`.
- **CTI naming** (Category/Type/Item) is the built-in taxonomy convention.
- **Transforms** adapt values per platform (hex→RGBA/UIColor for iOS, dp for Android); **formats** emit the target file. It reads the DTCG format and is a listed DTCG reference implementation.

**Tokens Studio (Figma plugin)** — design-side authoring. Organizes tokens into **Token Sets** + **Themes**; can toggle between **W3C DTCG and Legacy JSON formats** at any time; exports to Figma Variables where **Themes → collection modes** (light/dark/brand) but plain Token-Set export can't create modes. ([docs.tokens.studio token-format](https://docs.tokens.studio/manage-settings/token-format), [export/token-sets](https://docs.tokens.studio/figma/export/token-sets))

**Material Design 3** — three token classes = the same three tiers: **reference** (static values or point to other refs) → **system** (roles/decisions: color, type, elevation, shape) → **component** (per-element properties, e.g. button icon color). Color **roles** are the semantic layer: `primary`/`secondary`/`tertiary`, `surface`, `container` (fills, never text), and **`on-*`** roles (`on-primary` = text/icons on a primary fill), engineered for ≥3:1 accessible pairings. ([m3 design-tokens](https://m3.material.io/foundations/design-tokens/overview), [m3 color roles](https://m3.material.io/styles/color/roles))

**Tailwind (v4)** — the `theme.config` / `@theme` layer *is* a token layer. `@theme` registers CSS custom properties as tokens and **auto-generates utilities**; all design tokens are exposed as native CSS variables at runtime. Namespace prefix drives generation: `--color-*` → `bg-/text-/border-`, `--spacing-*` → padding/margin/gap, `--font-*`, `--shadow-*`, `--breakpoint-*`. Recommended layering mirrors the three tiers (base → semantic → component). ([Tailwind theme docs](https://tailwindcss.com/docs/theme), [v4 blog](https://tailwindcss.com/blog/tailwindcss-v4))

**Adobe Spectrum** — three types: **global** (primitive hard-coded values), **alias** (connectors/references to other tokens), **component** (component-specific, consuming global or alias). Renames are handled by **deprecating the old token and aliasing it to the new** one — a graceful-migration pattern worth copying. Published as `@adobe/spectrum-tokens` / `adobe/spectrum-design-data`. ([spectrum.adobe.com tokens](https://spectrum.adobe.com/page/design-tokens/), [adobe/spectrum-tokens README](https://github.com/adobe/spectrum-tokens/blob/main/packages/tokens/README.md))

**Salesforce Lightning (SLDS)** — evolved **design tokens → "global styling hooks"** (CSS custom properties) in SLDS 2. Namespaced `--slds-` with fallback values, e.g. `var(--slds-g-color-surface-container-1)`; used to rebrand/theme at scale. ([SLDS styling hooks](https://developer.salesforce.com/docs/atlas.en-us.lightning.meta/lightning/styling_hooks.htm), [LWC design tokens](https://developer.salesforce.com/docs/platform/lwc/guide/create-components-css-design-tokens.html))

**Compilation target:** across all of these the dominant runtime output is **CSS custom properties** (`:root { --color-primary: … }`), with Style Dictionary fanning the same source out to iOS/Android/Flutter. DTCG's pitch: "one token file generates platform-specific code for iOS, Android, web, and Flutter." ([w3.org](https://www.w3.org/community/design-tokens/2025/10/28/design-tokens-specification-reaches-first-stable-version/))

---

## 5. Theming — the payoff of semantic indirection

The mechanism is uniform: **keep the semantic token name stable, swap the values it resolves to.** ([alwaystwisted multi-brand](https://www.alwaystwisted.com/articles/a-design-tokens-workflow-part-9), [Contentful](https://www.contentful.com/blog/design-token-system/), [robertcelt95](https://robertcelt95.medium.com/theming-architecture-multi-brand-design-systems-that-actually-work-ad7ed8445fed))

- **Light/dark:** same semantic names (`color.text`, `color.background`), different primitive values per mode. "Semantic colors let us swap entire palettes — light and dark use different values for the same semantic names."
- **Multi-brand:** "swap out the base layer for each brand while maintaining the semantic relationships." Components reference tier-2/tier-3 only, so they're brand-agnostic; only the tier-1 base set is replaced.
- **Implementation:** Figma Variable **modes** / Penpot **token-set themes** (Mode × Brand combinations) at design time; **CSS-variable overrides** under a `.dark` class or `[data-theme]` at runtime. DTCG 2025.10 explicitly added "theming and multi-brand support… without file duplication." ([Penpot guide](https://penpot.app/blog/the-developers-guide-to-design-tokens-and-css-variables/), [w3.org](https://www.w3.org/community/design-tokens/2025/10/28/design-tokens-specification-reaches-first-stable-version/))
- **Critical rule for your agent:** it must reference **semantic** tokens, never primitives, in themeable contexts. A component that emits `blue.500` instead of `color.primary` breaks theming — it won't follow a dark-mode or brand swap.

---

## 6. Trade-offs & pitfalls (design these in up front)

**Indirection vs. directness**
- Every alias hop adds cognitive + resolution cost and can obscure the concrete value. Guidance: "focus on the core and semantic tiers first — they provide the most value"; add component tokens only when you actually need per-component control. ([netguru](https://www.netguru.com/blog/design-token-naming-best-practices), [alwaystwisted](https://www.alwaystwisted.com/articles/design-token-naming-conventions))

**Component-token explosion**
- "Component tokens will dramatically increase the number of tokens in your system, which will eventually make it harder for your taxonomy to be adopted. You might not need component tokens — create them only if you need them." Curtis's "start within, promote across 3+ components" rule is the antidote. ([alwaystwisted](https://www.alwaystwisted.com/articles/design-token-naming-conventions), [Curtis](https://medium.com/eightshapes-llc/naming-tokens-in-design-systems-9e86c7444676))

**Naming taxonomy is the hard problem**
- "Inconsistent or unclear names lead to duplication and hesitation, causing teams to lose trust, drift from shared standards, and the system to slowly erode." Large multi-platform systems creep to 5–6 name levels. ([netguru](https://www.netguru.com/blog/design-token-naming-best-practices), [Smashing](https://www.smashingmagazine.com/2024/05/naming-best-practices/))
- **Inverse relationship between specificity and coverage:** the more precise/contextual a name, the narrower its reuse. Over-specific semantic tokens defeat the purpose. ([alwaystwisted](https://www.alwaystwisted.com/articles/design-token-naming-conventions))
- **Homonyms bite** (`type` vs `text` as variable names collide/confuse); aim for homogeneity within a level and clear distinction between levels. ([Curtis](https://medium.com/eightshapes-llc/naming-tokens-in-design-systems-9e86c7444676))
- **No universal ordering consensus** — you must pin your own convention or teams (and an AI agent) produce inconsistent names.

**Where tokens leak / break**
- **Skipping the semantic tier** (referencing primitives directly, or worse hardcoded hex) — the exact anti-pattern your editor is trying to prevent; it breaks theming silently.
- **Premature globalization** — promoting a token to global before cross-component use pollutes the namespace. ([Curtis](https://medium.com/eightshapes-llc/naming-tokens-in-design-systems-9e86c7444676))
- **Broken aliases** — a reference to a renamed/removed token; Spectrum mitigates via deprecate-and-alias rather than hard delete. ([Spectrum README](https://github.com/adobe/spectrum-tokens/blob/main/packages/tokens/README.md))
- **Composite-token complexity** — typography/shadow/border bundle several sub-values, each possibly a reference; more surface for partial resolution failures and harder platform mapping. DTCG's `$ref` (property-level) helps but adds another resolution mode to support. ([DTCG spec](https://www.designtokens.org/tr/drafts/format/))
- **Format fragmentation (now easing)** — pre-2025 the DTCG draft churned and tools shipped "legacy" vs "W3C" dialects (Tokens Studio still offers both); targeting stable 2025.10 avoids most of this. ([Tokens Studio format](https://docs.tokens.studio/manage-settings/token-format))

---

## Recommendation for the AI-authored visual editor

1. **Adopt DTCG 2025.10 JSON** as the on-disk source of truth (`$value`/`$type`, brace-aliases). It's stable, tool-supported, and future-proof. ([spec](https://www.designtokens.org/tr/drafts/format/))
2. **Three tiers, and constrain the agent to emit tier-2 semantic references** (`color.primary`, `spacing.md`, `type.heading`) — never raw hex/px, never tier-1 primitives in themeable slots. Validate agent output against the token registry and reject raw values.
3. **Scales:** 4/8-pt spacing, modular type scale, OKLCH-based color ramps (or Radix's role-assigned 12-step for built-in semantics + accessibility).
4. **Compile via Style Dictionary** to CSS variables (and other targets if needed) — the de-facto pipeline. ([Style Dictionary](https://styledictionary.com/info/tokens/))
5. **Theming = value swaps behind stable semantic names** (CSS-var overrides / Figma modes). Enforcing "semantic-only references" at authoring time is what makes light/dark + multi-brand work without touching component output.

### Primary sources
- DTCG format spec — https://www.designtokens.org/tr/drafts/format/ · repo https://github.com/design-tokens/community-group · stable-version announcement https://www.w3.org/community/design-tokens/2025/10/28/design-tokens-specification-reaches-first-stable-version/
- Style Dictionary — https://styledictionary.com/info/tokens/ · https://github.com/style-dictionary/style-dictionary
- Material 3 tokens — https://m3.material.io/foundations/design-tokens/overview · roles https://m3.material.io/styles/color/roles
- Radix Colors scale — https://www.radix-ui.com/colors/docs/palette-composition/understanding-the-scale
- Adobe Spectrum — https://spectrum.adobe.com/page/design-tokens/ · https://github.com/adobe/spectrum-tokens
- Tailwind v4 theme/tokens — https://tailwindcss.com/docs/theme
- Salesforce SLDS styling hooks — https://developer.salesforce.com/docs/atlas.en-us.lightning.meta/lightning/styling_hooks.htm
- Tokens Studio DTCG format — https://docs.tokens.studio/manage-settings/token-format
- Nathan Curtis, naming taxonomy — https://medium.com/eightshapes-llc/naming-tokens-in-design-systems-9e86c7444676
