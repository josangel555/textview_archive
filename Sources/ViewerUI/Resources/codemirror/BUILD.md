# CodeMirror 6 bundle

`codemirror.js` and `codemirror.css` here are vendored build outputs.
The runtime app does NOT depend on `npm`, `node`, or `node_modules` —
those tools only run when re-bundling.

## What's in the bundle

A single IIFE bundle exposing CodeMirror 6 as `window.CM`. Theme:
one-dark (toggled via Compartment at runtime). See
`scripts/codemirror-build/entry.js` for the exact re-exports.

**Languages (TSK-1135 — all 22 the native tree-sitter set covers):**
- **Official Lezer packs** (`@codemirror/lang-*`, rich CM6 LanguageSupport
  with folding/indent/bracket-matching where the pack provides it):
  `markdown`, `javascript` (covers js / ts / jsx / tsx), `python`, `json`,
  `rust`, `java`, `cpp` (covers C and C++), `sql`, `html` (embeds css + js),
  `css`, `xml`, `go`.
- **`@codemirror/legacy-modes` StreamLanguage modes** (CM5-style stream
  tokenizers, coarser than Lezer but correct — no official Lezer pack exists):
  `swift`, `kotlin` + `csharp` (both from `mode/clike`), `lua`, `shell`,
  `yaml`, `ruby`.

The HTML host's `languageFor(lang)` routes the Swift `jsLanguageName` token
(plus common file-extension aliases — mjs/cjs→js, etc.) to the right pack;
legacy modes are wrapped once via `StreamLanguage.define` and memoized. The
22-language coverage is pinned host-side by
`CodeMirrorBundleTests.testAllTwentyTwoLanguagesMapToANonPlainEditorToken`
+ `testJSBundleExportsAllLanguagePacks`; on-screen per-language highlighting
is WebView/VM-validated. (This is the parallel/additive CM6-Lezer path; the
native-tree-sitter-decoration alternative is TSK-1038 — owner picks between
them.)

Phase 1 additions (`docs/CM6_INTEGRATION_DESIGN_2026-05-23.md` §13):
the bundle now also re-exports `EditorSelection`, `Transaction`,
`closeSearchPanel`, `findNext`, `findPrevious`, `replaceNext`,
`replaceAll`, `foldAll`, `unfoldAll`, `indentUnit`,
`EditorStateTabSize`. These back the v1 dispatch handlers in
`codemirror.html`.

Phase 4 additions (`docs/CM6_INTEGRATION_DESIGN_2026-05-23.md` §18.4 / §22):
- **Bridge protocol bumped to v2.** Decoder accepts `v ∈ [1, 2]` for
  one release cycle so a stale JS bundle still functions during a
  rolling upgrade; encoder always stamps `v = currentVersion`.
- New JS → Swift inbound: `incrementalChange` (`{edits:[{from,to,
  insert}], version, contentLength}`). Replaces `change` whenever
  the v2 emitter is active; v1 `change` remains the drift-recovery
  fall-back.
- New Swift → JS outbound: `applyEdits` (reciprocal batch),
  `setFoldingRanges`, `setGutterMarkers`, `setIndentGuides`.
- Re-exports added to `entry.js`: `StateField`, `StateEffect`,
  `RangeSetBuilder` (`@codemirror/state`); `gutter`, `GutterMarker`
  (`@codemirror/view`); `foldService` (`@codemirror/language`). All
  in the existing approved peer-dep set — **no new npm packages**.
- **Vim mode (`@replit/codemirror-vim` 6.3.0, MIT) — LANDED (owner-approved
  2026-06-15, TSK-679).** Re-exported as `CM.vim`; the HTML host wraps it in a
  `vimCompartment` (off by default), toggled via the `setVimMode` dispatch +
  the View → Vim Mode preference. Build-time dep only — bundles into
  `codemirror.js` (no runtime npm).

Phase 3 additions (`docs/CM6_INTEGRATION_DESIGN_2026-05-23.md` §18.3):
- `hoverTooltip` from `@codemirror/view` — drives the LSP hover
  popover. Handler resolves the body via a Swift round-trip
  (`requestHover` → Swift `LSPPool.hover` → `hoverResponse`).
- No new packages; bundle delta after re-build is essentially zero
  (`hoverTooltip` was already in `@codemirror/view`'s dead-code; the
  re-export just keeps it). Re-bundle command:
  `cd scripts/codemirror-build && npm run build`.
- New outbound types: `hoverResponse`, `setSaveOnBlur`.
- New inbound types: `requestHover`, `requestDefinition`,
  `contextMenuRequested`.

Phase 2 additions (`docs/CM6_INTEGRATION_DESIGN_2026-05-23.md` §18.2):
- `@codemirror/lint` (~80 KB after dedup of view/state to 6.43/6.5) —
  drives inline squiggles + lint gutter. Exposed as
  `lintGutter`, `setDiagnostics`, `forEachDiagnostic`.
- `@codemirror/search` extras `setSearchQuery`, `SearchQuery`,
  `getSearchQuery` so the SwiftUI find bar can drive CM's search
  state without opening CM's built-in panel.
- `Decoration`, `ViewPlugin`, `WidgetType` from `@codemirror/view`
  for the show-invisibles decoration plugin (hand-rolled, no extra
  package needed).
- `@codemirror/view` bumped from 6.28.1 → 6.43.0 + state 6.4.1 →
  6.6.0 so `@codemirror/lint` peer-dep resolves to the same version
  and npm dedupes instead of bundling two copies of view (~167 KB
  saving — the difference between 798 KB and 652 KB minified).
  IMPORTANT: `@codemirror/state` must satisfy the floor that the
  current `@codemirror/view` declares (see view's `package.json`
  peerDependencies). view@6.43.0 declares `^6.6.0`. Pinning state to
  6.5.2 causes npm to nest a second copy of state under view, and
  esbuild bundles both — at runtime `instanceof Facet` checks fail
  and `EditorState.create` throws "Unrecognized extension value in
  extension set... multiple instances of @codemirror/state are
  loaded". After every view bump, re-check view's state peer floor
  and bump `state` to match.

## How to re-build

```
cd scripts/codemirror-build
npm install --no-audit --no-fund
npm run build
```

That writes:

```
Sources/ViewerUI/Resources/codemirror/codemirror.js   (~607 KB minified, Phase 4)
```

CSS is hand-maintained at `codemirror.css` in this directory; CM6
itself injects its base theme via `EditorView.baseTheme` so nothing
upstream needs to be bundled into CSS.

After re-bundling, verify:

```
swift test --filter ViewerUITests.CodeMirrorBundleTests
swift test --filter ViewerCoreTests.CMBridgeV1Tests
swift test --filter ViewerCoreTests.CMBridgeV2Tests
swift test --filter ViewerCoreTests.CMOutboundEncodingTests
swift test --filter ViewerCoreTests.CMEditApplierTests
swift test --filter ViewerCoreTests.CMV2IntegrationTests
```

## Pinning

`scripts/codemirror-build/package.json` pins exact CM6 versions and
the esbuild version used. To bump:

1. Edit the version in `scripts/codemirror-build/package.json`.
2. `rm -rf scripts/codemirror-build/node_modules`.
3. Re-run `npm install` + `npm run build`.
4. Commit `package.json` AND the regenerated `codemirror.js`.
5. Verify with `swift test --filter CodeMirrorBundleTests`.

## Contract with the host (protocol v2; v1 still decodable)

Phase 4 bumped `CMProtocol.currentVersion` to `2`. Decoder accepts
envelopes with `v ∈ [oldestSupportedVersion ... currentVersion]`.
The supported-range policy is so a freshly-bumped Swift binary still
talks to a stale JS bundle (or vice versa) during a rolling app
update; bump the lower bound when you're done with one cycle.

New inbound types (JS → Swift): `incrementalChange`.
New outbound types (Swift → JS): `applyEdits`, `setFoldingRanges`,
`setGutterMarkers`, `setIndentGuides`.

## Contract with the host (protocol v1 baseline)

`codemirror.html` wires the bundle into a single `EditorView`. Two
channels:

### Inbound to JS — single entry point

Swift calls `window.cmDispatch({v: 1, type: "...", ...payload})`
exactly once per message. The host switches on `type`. Unknown types
post `errorOccurred`. Mismatched `v` posts `errorOccurred`.

Supported `type` values: `setText`, `appendText`, `replaceRange`,
`setLanguage`, `setTheme`, `setFontSize`, `setWordWrap`, `setReadOnly`,
`setLineNumbers`, `setShowInvisibles`, `setIndentation`, `gotoLine`,
`setSelection`, `openSearch`, `closeSearch`, `setSearchQuery`,
`findNext`, `findPrev`, `replaceNext`, `replaceAll`,
`setDiagnostics`, `foldAll`, `unfoldAll`, `undo`, `redo`, `focus`,
`flushChanges`, `getDocument`, `getSelection`, `getScrollPosition`,
`hoverResponse`, `setSaveOnBlur`.

### Outbound to Swift — `WKScriptMessageHandler` named `mdvEditor`

Every payload carries `{v: 1, type: "...", ...}`. Messages:
`ready`, `change`, `save`, `cursorPositionChanged`, `selectionChanged`,
`scrollChanged`, `findOpened`, `findClosed`, `findResultChanged`,
`linkClicked`, `editorBlurred`, `errorOccurred`, `requestReply`,
`requestHover`, `requestDefinition`, `contextMenuRequested`.

### Legacy `window.*` helpers

Kept for one cycle so existing call sites (e.g. AppDelegate Undo/Redo)
don't break: `setText`, `getText`, `undo`, `redo`, `setFontSize`,
`setTheme`, `setLanguage`, `setEditable`, `openSearch`, `flushChanges`.
All shims route through the same dispatch path internally.
