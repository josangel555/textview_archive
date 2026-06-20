# CodeMirror Lezer language-packs vs native-tree-sitter-decoration highlighting — feature-parity gaps

**Spike:** TSK-1039 · **Date:** 2026-06-20 · **Type:** research (no production code)

> **The question.** The editor today highlights ~6 languages via CodeMirror's own
> Lezer language packs (`@codemirror/lang-markdown / -javascript / -python / -json`).
> The plan is to drop those packs and instead render highlighting from the app's
> **native tree-sitter engine** (Swift `TreeSitterEngine` / Rust `highlight` crate),
> pushing tokens across the JS bridge as CM6 decorations, covering all bundled
> grammars. This document enumerates **what the Lezer-pack approach gives you that a
> "tree-sitter tokens → CM6 decorations" approach does not** (and vice-versa), so the
> implementation team knows exactly what must be rebuilt to avoid regressions.

---

## TL;DR

1. **Highlighting itself is the only thing the editor gets from Lezer today.** The
   editor's syntax highlighting is currently **100% Lezer** (`setLanguage` → CM6's
   `LanguageSupport`). There is no native-token decoration channel in the protocol
   yet. Switching means building a brand-new `setHighlightRuns` decoration pipeline.
2. **The secondary, syntax-tree-driven editor features are NOT a clean cutover.** A
   CM6 `LanguageSupport` silently powers more than color: **code folding fallback,
   auto-indent (`indentNodeProp`), bracket matching disambiguation, comment toggling
   (`Mod-/`), structural selection (`selectParentSyntax`), and language-data resolution
   for embedded languages**. Several of these are wired into our bundle's
   `defaultKeymap` and will **silently regress** (keyboard-only, no menu item => easy to
   miss) when the Lezer tree disappears.
3. **Some of these are already native and will NOT regress** — folds and sticky-scroll
   already run off `TreeSitterEngine.computeFolds`, and indent-guides are hand-rolled.
   The theme palette already crosses the bridge. So the rebuild surface is narrower than
   "everything Lezer did".
4. **The native engine is flat-spans-only, whole-document, non-incremental, no
   injection.** It exposes neither a parse tree to JS nor embedded-language parsing.
   The hardest gaps to close: **incremental/viewport-bounded parsing**, **language
   injection** (JS-in-HTML, CSS-in-HTML, code-fences-in-Markdown), and the **richer
   highlight granularity** Lezer's tag vocabulary provides vs our 20 `TokenKind`s.
5. **Recommended path is a hybrid, not a pure cutover** (see §7): native decorations
   for highlighting; reuse the already-native fold channel; rebuild comment-toggle and
   bracket-match from cheap host/JS config (they need almost no tree); defer or
   hand-roll auto-indent (the industry-wide weakest area); rebuild injection from
   tree-sitter `injections.scm` only where it pays (Markdown fences, HTML).

---

## 1. Ground truth — what the repo actually does today

### 1.1 The editor's highlight path is 100% Lezer

`Sources/ViewerUI/Resources/codemirror/codemirror.html` is the only highlight driver.
`languageFor(lang)` maps a string to a CM6 `LanguageSupport`:

```js
function languageFor(lang) {
  switch ((lang || "").toLowerCase()) {
    case "markdown": case "md":   return markdown();
    case "javascript": case "js": return javascript();
    case "typescript": case "ts": return javascript({ typescript: true });
    case "jsx":                   return javascript({ jsx: true });
    case "tsx":                   return javascript({ jsx: true, typescript: true });
    case "python": case "py":     return python();
    case "json":                  return json();
    default:                      return [];   // every other language = NO highlighting in editor
  }
}
```

The Swift protocol (`Sources/ViewerCore/CodeMirrorBridge.swift`, `CMOutboundMessage`)
has **no `setHighlightRuns` / decoration message** — `setLanguage(String)` is the sole
highlight control. Confirmed by grep: nothing pushes `HighlightRun`s or decorations to
the editor. **So the editor today only highlights the 6 Lezer languages; the other ~16
file types open as plain text in the editor** (they DO get native highlighting in the
read-only *source view*, which is a different render path).

This is the central asymmetry the switch fixes: native decorations would give the
editor highlighting for **all** bundled grammars, matching the source viewer.

### 1.2 The native engine: flat runs + folds, whole-document, no tree, no injection

`Sources/ViewerCore/Highlight/TreeSitterEngine.swift`:

- `tokenize(_:language:) -> [HighlightRun]` — **fresh `Parser()` per call, full
  `parser.parse(text)` (whole document), no old-tree reuse => no incremental parse.**
- Output is **flat `HighlightRun{ NSRange, TokenKind }`** runs, overlap-resolved by a
  sweep-line `paintOver`. **The parse tree is never exposed** — only painted spans.
- **20 `TokenKind`s** (`HighlightRun.swift`): keyword, string, comment, number, type,
  function, variable, attribute, operator, punctuation, builtin, regex, escape,
  heading, link, emphasis, strong, tag, tagAttribute, constant.
- `CaptureMap` collapses tree-sitter's rich dotted capture names
  (`@keyword.control.return`) down to one of those 20 kinds (right-to-left prefix walk).
- **No injection.** `markdown-highlights.scm` captures `(code_fence_content) @none` —
  fenced code is **not** re-highlighted in its embedded language by the engine.
- Predicate eval is partial on the Swift side (`#match?`/`#eq?` honored; locals not run).

`Sources/ViewerCore/RustHighlightAdapter.swift` routes through the Rust core by default
(`.highlight` gate), falling back to Swift. The Rust `highlight` crate
(`rust-core/crates/highlight/src/lib.rs`):

- Uses `tree-sitter-highlight`'s `HighlightConfiguration::new(language, name, &query,
  "", "")` — **the injection-query and locals-query args are empty strings.** So even
  though many upstream grammar crates ship `injections.scm`, **the Rust engine
  deliberately runs no injection and no locals.**
- Evaluates `#match?`/`#eq?` predicates (the TSK-410 mis-coloring class is absent here).
- Returns **flat highlight runs** (`{start, len, kind}`), same shape as Swift — no tree.

### 1.3 Grammar coverage — "22" is the Rust set; the Swift twin is 15

| Path | Grammars wired | Notes |
|---|---|---|
| **Rust `highlight` crate** (default) | **~22** — incl. yaml, html, css, go, ruby, kotlin, sql | full upstream `HIGHLIGHTS_QUERY`, predicate eval, **no injection/locals** |
| **Swift `TreeSitterEngine`** (fallback) | **15** — swift, json, markdown, xml, python, js, ts, tsx, bash, java, c, cpp, csharp, rust, lua | go/html/css/sql/ruby/kotlin/yaml have **no Swift grammar** (TSK-897) |

`HighlightLanguage` enumerates 23 cases (incl. `plainText`). When the editor switches to
native decorations it routes through `RustHighlightAdapter`, so the editor inherits the
Rust set (22) with the Swift set (15) as fallback — a **highlight-coverage gain** of
~16 languages over today's 6.

### 1.4 What is ALREADY native (and therefore will NOT regress)

This is the good news that narrows the rebuild:

- **Code folding (editor).** `DocumentModel` already calls
  `TreeSitterEngine.shared.computeFolds` and pushes results via the `setFoldingRanges`
  bridge message -> CM6 `foldService`
  (`TreeSitterEngine+Folds.swift`, `CodeMirrorEditorView.swift:573`,
  `codemirror.html:applySetFoldingRanges`). **Fold queries exist for 6 languages**
  (`json, xml, swift, javascript, typescript(+tsx), markdown` — `*-folds.scm`).
- **Sticky-scroll headers** (`StickyScrollHeaders.swift`) — native, off the fold regions.
- **Indent guides** — hand-rolled JS `ViewPlugin` (`buildIndentGuidesPlugin`), not Lezer.
- **Structural search** (`StructuralSearchEngine.swift`) — native tree walk, host-only.
- **Theme palette parity** (`SyntaxTheme+CMPalette.swift`) — the 20-kind `TokenKind`
  palette already crosses the `setTheme` bridge and currently recolors Lezer's
  `HighlightStyle` tags. The same palette feeds decoration CSS classes after the switch.
- **`closeBrackets` and `autocomplete` are bundled but NOT wired** into our editor's
  `baseExtensions`. So there is **no parity loss** there — we never offered them.

### 1.5 What is wired via Lezer today and WILL regress unless rebuilt

The bundle's `keymap` includes `...defaultKeymap` (from `@codemirror/commands`), which
binds (verified `"Mod-/"` is present in the bundle):

- **`Mod-/` -> `toggleComment`** — works today via Lezer language data
  (`commentTokens`). **No menu item** — keyboard-only => a silent regression risk.
- **`selectParentSyntax` (expand-selection)** — bound in `defaultKeymap`, tree-driven.
  No menu item. Silent regression risk.
- **Auto-indent on Enter (`insertNewlineAndIndent`)** and **`indentOnInput`** electric
  reindent — both resolve through the active language's `indentNodeProp` / language data.
  After the switch there is no Lezer language => Enter falls back to copy-previous-line
  indent (CM6's no-language default) and electric reindent stops.
- **Bracket matching** (`bracketMatching()` is wired) — currently uses the Lezer tree's
  `openedBy`/`closedBy` props for disambiguation, degrading to a char scan. After the
  switch it loses the tree path and runs pure char-scan (mostly fine; see §4).
- **Fold *fallback* for the 16 languages without a `*-folds.scm`.** CM6's `foldGutter()`
  falls back to the Lezer language's `foldNodeProp` when our `lspFoldRanges` is empty.
  Today JS/TS/Python/JSON/Markdown get Lezer fold fallback; after the switch, only the 6
  languages with a native `*-folds.scm` fold at all (python notably has **no**
  `*-folds.scm` -> python loses folding).

---

## 2. How CM6/Lezer features map onto the parser (the two seams)

CodeMirror cleanly separates features by *how* they reach their data — this determines
how hard each is to rebuild without a Lezer tree.

```
Feature -> languageDataAt("key", pos) -> [config values]        Seam 2: config, tree-optional
Feature -> fooService facet (functions) -> [default reads tree]  Seam 1: service, tree-optional
Feature -> syntaxTree(state).resolveInner(pos) -> [tree nodes]   hard tree dependency
```

- **Seam 1 — service facets (`foldService`, `indentService`).** A facet of
  `(state, pos) -> result` functions; the Lezer default is just one registered function.
  Folding and indentation each have a **tree-free escape hatch** here. We already use
  `foldService` for native folds.
- **Seam 2 — `languageData` facet (`EditorState.languageDataAt`).** A position->config
  map. Comment tokens, close-bracket pairs, autocomplete source selection, word chars,
  and the indent-on-input trigger regex all resolve here. **None of these need a parse
  tree** — only a per-language config object. The single catch: in a *mixed* document,
  *which* language is active at a position is decided by the tree's nested mounts.
- **Hard tree dependency** — structural selection (`selectParentSyntax` via
  `resolveStack`), syntax navigation, syntax-aware completion (`ifIn`/`ifNotIn`),
  HTML tag auto-close/match, and mixed-language mounting (`parseMixed`). These genuinely
  need a tree-shaped structure, not a token stream.

Implication: the **config-shaped** features (comment toggle, bracket pairs) are cheap to
rebuild from a static per-language table — no tree needed. The **service-shaped**
features (fold, indent) have official tree-free paths. The **tree-bound** features
(structural selection, injection mounting) are the expensive ones.

(Full mechanism detail and source citations in `cm6-lezer-capabilities.md`.)

---

## 3. The tree-sitter side — query model and maturity

Tree-sitter core standardizes only **four** query files (`highlights.scm`,
`injections.scm`, `locals.scm`, `tags.scm`); **`folds.scm`, `indents.scm`,
`textobjects.scm` are editor conventions, not core**, with *incompatible* capture
vocabularies across Neovim / Helix / Zed / Pulsar. Key maturity facts that shape the
rebuild plan:

- **Folding (`folds.scm`)** — the *safe* `.scm` bet; node-range based. Budget for
  stale-fold update bugs and comment-endpoint handling.
- **Auto-indent (`indents.scm`)** — **the weakest area by industry consensus.**
  nvim-treesitter labels it *experimental* and opt-in; **Helix explicitly disabled
  tree-sitter Python indents and reverted to its hand-written fallback** ("the fallback
  actually works better"); **VS Code never adopted it**. The root cause: while typing,
  the buffer is invalid, so the node you'd indent against doesn't exist yet. **Do not
  rebuild auto-indent from `indents.scm`** — hand-roll or defer.
- **Injection (`injections.scm`)** — solid for JS/CSS-in-HTML (static, valid top-level),
  fragile for code-in-strings (fragments aren't valid top-level -> ERROR soup). The
  *integration layer* (making injection retrieval incremental) is where perf dies, not
  the C core. Lezer's **overlay** model is the cleaner design on the web.
- **Parsing is whole-document and memory-heavy** — ~300 MB retained for a 1.6 MB JSON
  (two trees), 50K-line C++ ~2 s. No first-class viewport-only parse. Editors push it to
  a background thread (Zed's copy-on-write sum-tree).
- **Auto-pairs / bracket-jump** — every editor hand-rolls these as character logic;
  tree-sitter appears only as a `not_in: [string, comment]` guard.
- **Symbols/outline** — syntactic and single-file; pair with LSP for cross-file accuracy.
- **Migration lessons (Atom/Pulsar/Emacs):** tree-sitter grammars **regressed
  highlighting** vs the old TextMate grammars (Atom JS lost `const`/`this`/`=>`
  coloring -> users disabled it); theme/scope granularity collapsed; **grammar
  versioning is broken** (pin SHAs); `.scm` queries and themes are **not portable**
  across editors.

(Full per-query-file detail, citations, and migration retrospectives in
`tree-sitter-editor-integration.md`.)

---

## 4. Parity matrix

Legend — **L** = CM6 Lezer language pack (today), **TS** = native tree-sitter ->
CM6 decorations (proposed). Rebuild cost: **none** (already native / not used) ·
**low** (config table or trivial JS) · **med** (host plumbing) · **high** (needs a tree
or incremental parser on the JS side).

| Capability | L today | TS path | Rebuild cost | How to rebuild / note |
|---|:--:|:--:|:--:|---|
| **Syntax highlighting** (6 langs) | yes | **yes, ~22 langs** | med | New `setHighlightRuns` decoration channel; reuse `RustHighlightAdapter` + existing palette. **Net gain.** |
| Highlight **granularity** (tags) | rich (`@lezer/highlight` tag set) | **coarse (20 `TokenKind`s)** | med | Expand `TokenKind` + `CaptureMap` to preserve `keyword.control` vs `keyword`, `function` vs `property`, delimiter styling. Else colors flatten. |
| **Code folding** (6 native langs) | fallback via `foldNodeProp` | **already native** | none | `computeFolds` -> `setFoldingRanges` already wired. |
| Code folding (python + 16 others) | **yes (Lezer fallback)** | **no** | med | Add `*-folds.scm` for python etc. (only 6 exist today). **Regression for python/JS-pack langs without a fold query.** |
| **Auto-indent on Enter** | yes (`indentNodeProp`) | **lost** | high | Don't use `indents.scm` (weakest area). Hand-roll per-language electric indent or accept copy-previous-line default. |
| **Indent-on-input** (electric `}`,`:`) | yes | **lost** | high | Same — hand-roll; not derivable cheaply from flat spans. |
| **Indent guides** | n/a (ours is hand-rolled) | hand-rolled | none | Already a JS `ViewPlugin`. |
| **Bracket matching** | tree-disambiguated | char-scan only | low | `bracketMatching()` degrades to `matchPlainBrackets`; mostly fine. Minor: can't restrict to handle sub-range (HTML `<...>`). |
| **Auto-close brackets** | not wired | not wired | none | We don't offer it. If desired later: hand-rolled char logic + `not_in string/comment` guard. |
| **Comment toggle** (`Mod-/`) | yes (language data) | **lost** | low | Static per-language `{line, block}` table in JS, fed to `@codemirror/commands` comment cmds (or push `commentTokens` from host). **No tree needed.** Currently keyboard-only -> silent regression. |
| **Structural selection** (`selectParentSyntax`) | yes (tree) | **lost** | high | Needs tree shape. Options: ship node ranges from host (native tree exists in Swift/Rust), or drop. Keyboard-only -> silent regression. |
| **Syntax navigation / next-sibling** | available (tree) | **lost** | high | Same as above; not currently exposed via menu. |
| **Autocomplete** (`ifIn`/`ifNotIn`) | not wired | not wired | none | Not offered today. |
| **HTML tag auto-close / match** | yes *if* `lang-html` loaded | **n/a** | — | We never loaded `lang-html` (not in `languageFor`); no parity loss. |
| **Language injection** — MD fences | yes (`@lezer/markdown codeLanguages`) | **lost** | high | Today the editor highlights JS/py/json **inside** fenced code in a `.md` file via the Lezer markdown pack's nested parser. Native engine returns `@none` for fence content. **Real regression for Markdown editing.** Rebuild via host-side injection (parse fence, re-tokenize per info-string) or accept flat fences. |
| Language injection — JS/CSS-in-HTML | n/a (no `lang-html`) | n/a | — | Not offered; the native engine also runs no injection. |
| Embedded **language-data** switch | yes (mounts) | **lost** | high | In mixed docs, comment/indent config follows the inner language via tree mounts. Without a tree it's the outer language everywhere. |
| **Incremental reparse** | yes (Lezer fragments) | **no (whole-doc)** | high | Engine re-parses whole document each call; no `applyEdits`-driven incremental TS parse. Perf risk on large files (see §5). |
| **Error recovery** | yes (GLR) | yes (TS GLR) | none | Both parsers are error-tolerant; no loss. |
| **Viewport-bounded parse** | yes (CM skips beyond viewport) | **no** | high | CM6's Lezer worker parses viewport-first + skips ahead; native engine parses the whole doc on every tokenize. |
| **Async / off-main parse** | yes (CM idle-callback worker) | partial | med | `computeFolds` uses a detached task; highlight `tokenize` is sync on the caller. Needs debounced async + main-thread budget. |

---

## 5. Performance characteristics — the asymmetry that matters most

| Dimension | Lezer (CM6 worker) | Native TS engine (today) |
|---|---|---|
| Parse scope | **viewport-first**, skips beyond viewport + `MaxParseAhead` | **whole document, every call** |
| Incrementality | fragment reuse + `applyChanges` | **none** — fresh `Parser()`, full `parse(text)` |
| Scheduling | time-sliced (idle-callback, ~20-100 ms slices), yields on input | highlight is sync; folds detached |
| Where it runs | WebView JS worker (off the Swift main actor) | Rust/Swift; crosses the bridge as spans |
| Memory | compact trees, in JS heap | two retained CST trees can be heavy (300 MB / 1.6 MB JSON) |

The native engine's whole-document, non-incremental parse is the biggest scaling
concern. Today it's masked because the editor doesn't use it for highlighting at all
(Lezer does the viewport-bounded incremental work). After the switch, **every edit (or
debounced batch) must re-tokenize**, and unless we (a) debounce, (b) cap by file size
(`highlightMaxBytes` already exists), and/or (c) bound to the viewport, large files will
regress vs Lezer's incremental worker. The `applyEdits`/`incrementalChange` v2 protocol
already ships edit deltas across the bridge — the native engine could consume them to
do incremental TS reparse, but **that code does not exist yet.**

---

## 6. Gaps ranked by user impact

1. **(HIGH) Markdown fenced-code highlighting inside the editor** — Lezer's markdown
   pack highlights JS/Python/JSON *inside* fenced blocks. The native engine emits
   `@none` for fence content. For a *Markdown* viewer/editor this is a flagship feature;
   losing it in the editor is the most visible regression. **Needs host-side injection.**
2. **(HIGH) Large-file performance** — whole-document non-incremental re-tokenize per
   edit vs Lezer's viewport-bounded incremental worker. Mitigate with debounce + size
   cap + viewport bounding, ideally incremental TS reparse via the existing edit deltas.
3. **(HIGH) Highlight granularity flattening** — 20 `TokenKind`s vs Lezer's much richer
   tag set. Without expanding `TokenKind`/`CaptureMap`, themes lose distinctions
   (control vs plain keyword, function vs property, delimiter styling) the source view
   may already mask, but which will read as "blander" colors than today's JS/TS/Python.
4. **(MED) Comment toggle (`Mod-/`)** — silent keyboard-only regression. Cheap to
   rebuild (config table), but easy to forget precisely because there's no menu item.
5. **(MED) Auto-indent on Enter + electric reindent** — Lezer indents structurally;
   the native fallback is copy-previous-line. Real editing friction, but the industry
   says do NOT rebuild from `indents.scm`. Hand-roll the common cases or accept the
   simpler default. (Folds/structural already cover the "where am I" needs.)
6. **(MED) Folding for python and other JS-pack langs without a `*-folds.scm`** — python
   gets Lezer fold fallback today and has no native fold query. Add fold queries.
7. **(MED) Structural / expand-selection (`selectParentSyntax`)** — silent keyboard-only
   regression. Needs a tree on the JS side or host-shipped node ranges. Lower impact
   because it's undiscoverable today (no menu item).
8. **(LOW) Bracket-matching precision** — degrades from tree-disambiguated to char-scan;
   acceptable for our languages.

---

## 7. Recommended rebuild path

A **hybrid**, sequenced by value and cost. Do **not** attempt a pure "tree-sitter does
everything Lezer did" cutover — the tree-bound features (indent, injection mounting,
structural selection) are exactly where every tree-sitter editor struggles.

### Phase A — highlighting (the actual switch)
1. **Add a `setHighlightRuns` decoration channel.** Host runs `RustHighlightAdapter`,
   ships `[{from, to, kind}]` runs (UTF-16 offsets, like the existing fold ranges) across
   the bridge; a CM6 `StateField`/`ViewPlugin` turns them into `Decoration.mark`s styled
   by the existing palette CSS. **Debounce + viewport-bound + reuse `highlightMaxBytes`.**
2. **Expand `TokenKind` + `CaptureMap`** before the switch so granularity doesn't
   regress vs the JS/TS/Python users see today.
3. **Drop the Lezer packs from `languageFor`** only after 1-2 land and are validated.
   This also reclaims bundle weight (the lang packs + their Lezer parsers are a
   meaningful chunk of the 745 KB `codemirror.js`).

### Phase B — preserve the cheap config features (no tree)
4. **Comment toggle** — ship a per-language `{line, block}` table; either push it as
   `commentTokens` language data from the host or wire it in JS. Trivial, kills gap #4.
5. **Bracket matching** — keep `bracketMatching()`; it self-degrades to char-scan. Done.

### Phase C — reuse what's already native
6. **Folding** — already wired; **add `*-folds.scm` for python** and any other
   regressing language. Reuses the existing `computeFolds` -> `setFoldingRanges` channel.

### Phase D — the expensive, deferrable features
7. **Markdown fence injection** — highest-value tree feature. Rebuild host-side: detect
   `fenced_code_block` + info-string (the engine already parses these for folds),
   re-tokenize the content range with the embedded grammar, emit runs offset into the
   fence. This is a bounded, MD-specific injection — far cheaper than general
   `injections.scm` support and targets our flagship use case.
8. **Auto-indent** — **defer / hand-roll, do not use `indents.scm`.** Start with the CM6
   no-language default (copy previous line) + a small set of hand-rolled electric rules
   for the hottest languages if friction is reported. This matches Helix/VS Code.
9. **Structural selection** — lowest priority (undiscoverable today). If rebuilt, ship
   enclosing-node ranges from the host's native tree on demand (the tree exists in
   Swift/Rust) rather than reconstructing a tree in JS.

### What to explicitly NOT rebuild
- `closeBrackets` / autocomplete (`ifIn`) / HTML tag auto-close — **not offered today**,
  so no parity obligation. Adding them is new scope, not parity.
- General `injections.scm` support / mixed-language `languageDataAt` switching — too
  costly for the payoff; the MD-fence special case (D7) covers the real need.

---

## 8. Net assessment

The switch is **net-positive on highlighting** (6 -> ~22 languages in the editor, single
source of truth with the source view, smaller bundle) but carries a **handful of real
regressions** concentrated in: **Markdown fence highlighting**, **large-file perf**,
**highlight granularity**, and a cluster of **silent keyboard-only features** (comment
toggle, expand-selection, structural auto-indent). The good news the repo already bought:
**folds, sticky-scroll, indent-guides, structural search, and the theme palette are
already native**, so the rebuild surface is much smaller than "re-implement
`LanguageSupport`." The disciplined path is the phased hybrid above — ship highlighting,
preserve the cheap config features, reuse native folds, and treat injection + auto-indent
as targeted follow-ups rather than blockers.

---

## Companion files

- `cm6-lezer-capabilities.md` — exhaustive web research on what a CM6 `LanguageSupport`
  derives from the Lezer tree vs from facets/language-data, with source citations.
- `tree-sitter-editor-integration.md` — exhaustive web research on the tree-sitter query
  model, per-feature maturity, and Atom/Pulsar/Helix/Zed/Emacs migration lessons.
