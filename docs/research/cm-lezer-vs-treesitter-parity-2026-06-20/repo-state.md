# Repo state — what the native engine and the CM6 editor actually do today

Companion to `FINDINGS.md` (TSK-1039). First-hand code investigation, 2026-06-20.
All paths absolute under `/Users/me/Documents/workspaces/claude/markdown_viewer`.

## 1. The CM6 editor (WKWebView)

- `Sources/ViewerUI/Resources/codemirror/codemirror.html` — the bundled editor bootstrap.
  - **Highlighting = 100% Lezer.** `languageFor(lang)` returns a CM6 `LanguageSupport`
    (`markdown()`, `javascript({typescript,jsx})`, `python()`, `json()`); everything else
    returns `[]` (plain text). `setLanguage` is the only highlight control.
  - `baseExtensions(...)` wires: `lineNumbers`, `foldGutter`, multi-cursor, `history`,
    **`indentOnInput()`**, **`bracketMatching()`**, custom active-line, selection-match
    (drag-gated), `syntaxHighlighting(defaultHighlightStyle)`, the keymap (snippet-tab,
    save, search, history, **fold**, `indentWithTab`, **`...defaultKeymap`**), word-wrap,
    theme, lang, font, indent, lint-gutter, invisibles, hover, **`foldService`**, diff
    gutter, indent-guides.
  - `closeBrackets` and `autocomplete` ARE present in the bundle but are **NOT wired** into
    `baseExtensions` (verified by grep). So we do not offer them today.
  - `...defaultKeymap` (from `@codemirror/commands`) binds `Mod-/` (toggleComment) and
    `selectParentSyntax` — these work today via the Lezer language and have **no menu item**.
  - `applySetFoldingRanges(msg)` wires a `foldService` that answers from `lspFoldRanges`
    (Swift-pushed); when empty, CM6's `foldGutter` falls back to the Lezer language's
    `foldNodeProp`.
  - Indent guides are a hand-rolled `ViewPlugin` (`buildIndentGuidesPlugin`), not Lezer.
- `Sources/ViewerUI/Resources/codemirror/codemirror.js` — 745,773 bytes (the esbuild
  bundle). Dropping the Lezer lang packs + their parsers would reclaim a meaningful chunk.
- `Sources/ViewerCore/CodeMirrorBridge.swift` — `CMOutboundMessage` (Swift -> JS) has
  `setLanguage`, `setFoldingRanges`, `setGutterMarkers`, `setIndentGuides`, `setTheme`,
  `setDiagnostics`, etc. **There is NO `setHighlightRuns` / decoration message** — the
  switch must add one.
- `Sources/ViewerUI/CodeMirrorEditorView.swift` — `setLanguage` dispatched at ~L461;
  native folds pushed via `setFoldingRanges` at ~L573 (from `pendingFoldingRanges`, fed by
  `view.foldingRanges`).

## 2. The native highlight engine (Swift)

`Sources/ViewerCore/Highlight/TreeSitterEngine.swift`:
- `public func tokenize(_ text: String, language: HighlightLanguage) -> [HighlightRun]`
  - `guard text.utf8.count <= highlightMaxBytes else { return [] }` — a size cap exists.
  - **`let parser = Parser(); ... parser.parse(text)`** — fresh parser, **whole-document**
    parse, **no old-tree reuse => non-incremental**.
  - Runs `bundle.query.execute(...)` then `cursor.resolve(with: predicateContext)` —
    evaluates `#match?`/`#eq?`/`#any-of?`; **no locals query is run.**
  - Maps capture name -> `TokenKind` via `CaptureMap.kind(forCapture:)`.
  - `paintOver(...)` sweep-line resolves overlaps into flat runs. **The parse tree is never
    exposed** — output is `[HighlightRun{ NSRange, TokenKind }]` only.
- `warm(_:prioritizing:)` precompiles per-language `Query` bundles (compile is the bulk of
  cold-start; ~400 ms debug / ~130 ms release for swift).
- `languageHandle(for:)` wires **15** grammars: swift/json/markdown (static keeplist),
  xml/python/javascript/typescript/tsx/shell(bash) + java/c/cpp/csharp/rust/lua (lazy via
  `GrammarLoader.load`). `default: return nil`.

`Sources/ViewerCore/Highlight/HighlightRun.swift`:
- `TokenKind` has **20 cases**: keyword, string, comment, number, type, function, variable,
  attribute, operator, punctuation, builtin, regex, escape, heading, link, emphasis, strong,
  tag, tagAttribute, constant.

`Sources/ViewerCore/Highlight/CaptureMap.swift`:
- Collapses dotted capture names right-to-left (`@keyword.control.return` ->
  `@keyword.control` -> `@keyword`), table from the canonical `HighlightScopeMap`. This is
  where tree-sitter's rich vocabulary is flattened to the 20 kinds.

`Sources/ViewerCore/Highlight/TreeSitterEngine+Folds.swift`:
- `computeFolds(text:language:) async -> [FoldRegion]` — whole-document parse on a detached
  task, query `*-folds.scm`, post-process markdown headings into span folds. Cached LRU.
- Fold queries exist for **6** languages only: json, xml, swift, javascript,
  typescript(+tsx shares), markdown. **python has none** (will lose folding).

## 3. The native highlight engine (Rust, the default path)

`Sources/ViewerCore/RustHighlightAdapter.swift`:
- Routes `tokenize` through the Rust core when the `.highlight` gate is on (default), Swift
  fallback otherwise. Returns the same flat `[HighlightRun]` shape.
- "no core grammar for X" is a routine fallback (Rust set is a superset but coverage parity
  is staged).

`rust-core/crates/highlight/src/lib.rs`:
- `HighlightConfiguration::new(language, lang.name(), &query, "", "")` — **3rd arg
  (injection_query) and 4th arg (locals_query) are EMPTY STRINGS.** So even though upstream
  grammar crates ship `injections.scm`, **the Rust engine runs no injection and no locals.**
- Pulls each crate's `HIGHLIGHTS_QUERY` constant (js/c/cpp use `HIGHLIGHT_QUERY` singular).
- Enumerates **~22** grammars: json, rust, typescript/tsx, java, c-sharp, swift, kotlin,
  lua, python, yaml, html, css, go, ruby, sql (sequel), + the rest. Evaluates predicates
  (TSK-410 mis-coloring absent here).
- Returns flat runs `{start, len, kind}` — **no tree.**

## 4. What's already native (will NOT regress on the switch)

- **Editor folds** — `DocumentModel` (~L1692) calls `TreeSitterEngine.shared.computeFolds`
  -> `SyntaxFoldRangeMapping.cmFoldRanges` -> `setEditorFoldRanges` -> `setFoldingRanges`
  bridge -> CM6 `foldService`. Already wired end-to-end for the 6 fold-query languages.
- **Sticky-scroll headers** — `StickyScrollHeaders.pinnedRegions/headers`, off fold regions.
- **Indent guides** — hand-rolled JS `ViewPlugin`.
- **Structural search** — `StructuralSearchEngine.structuralSearch` (native tree walk).
- **Theme palette** — `SyntaxTheme+CMPalette.swift` exports `cmPalette` (all 20 `TokenKind`
  raw values + 4 chrome keys -> `#RRGGBB`), crosses the `setTheme` bridge, currently used
  to build CM6's `HighlightStyle`. Reusable for decoration CSS after the switch.
- **App menus:** `Fold All` / `Unfold All` exist (main.swift ~L1597). **No** comment-toggle
  or expand-selection menu items — those are keyboard-only via `defaultKeymap`.

## 5. Grammar / language reconciliation

- `Sources/ViewerKit/HighlightLanguage.swift` — **23 cases** incl. `plainText`. TSK-897
  notes go/html/css/sql/ruby/kotlin (and yaml) have **no Swift grammar** and are excluded
  from the Language Mode menu — but the **Rust** path covers most of them.
- `.build-gate/checkouts/tree-sitter-*/queries/` contains the **full upstream** query sets
  (highlights/injections/locals/tags, and swift even ships folds/indents/textobjects/
  outline) — but the **staged** queries the app actually loads
  (`Sources/ViewerCore/Highlight/Queries/`) are only **14 `*-highlights.scm` + 6
  `*-folds.scm`** — NO indents, NO injections, NO locals, NO tags. So the auxiliary query
  files exist upstream and could be vendored, but are not wired today.

## 6. The bridge edit protocol (relevant to incremental highlighting)

`codemirror.html` v2 protocol already ships `incrementalChange` (JS->Swift edit deltas) and
`applyEdits` (Swift->JS). The native engine could consume these deltas to do incremental
tree-sitter reparse for highlighting — but **no such incremental-highlight code exists**;
`tokenize` re-parses the whole document every call.
