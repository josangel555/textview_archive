# CodeMirror 6 bundle

`codemirror.js` and `codemirror.css` here are vendored build outputs.
The runtime app does NOT depend on `npm`, `node`, or `node_modules` —
those tools only run when re-bundling.

## What's in the bundle

A single IIFE bundle exposing CodeMirror 6 as `window.CM`. Languages:
markdown, javascript (+ typescript / jsx / tsx), python, json. Theme:
one-dark (toggled via Compartment at runtime). See
`scripts/codemirror-build/entry.js` for the exact re-exports.

Phase 1 additions (`docs/CM6_INTEGRATION_DESIGN_2026-05-23.md` §13):
the bundle now also re-exports `EditorSelection`, `Transaction`,
`closeSearchPanel`, `findNext`, `findPrevious`, `replaceNext`,
`replaceAll`, `foldAll`, `unfoldAll`, `indentUnit`,
`EditorStateTabSize`. These back the v1 dispatch handlers in
`codemirror.html`.

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
Sources/ViewerUI/Resources/codemirror/codemirror.js   (~652 KB minified, Phase 2)
```

CSS is hand-maintained at `codemirror.css` in this directory; CM6
itself injects its base theme via `EditorView.baseTheme` so nothing
upstream needs to be bundled into CSS.

After re-bundling, verify:

```
swift test --filter ViewerUITests.CodeMirrorBundleTests
swift test --filter ViewerCoreTests.CMBridgeV1Tests
swift test --filter ViewerCoreTests.CMOutboundEncodingTests
```

## Pinning

`scripts/codemirror-build/package.json` pins exact CM6 versions and
the esbuild version used. To bump:

1. Edit the version in `scripts/codemirror-build/package.json`.
2. `rm -rf scripts/codemirror-build/node_modules`.
3. Re-run `npm install` + `npm run build`.
4. Commit `package.json` AND the regenerated `codemirror.js`.
5. Verify with `swift test --filter CodeMirrorBundleTests`.

## Contract with the host (protocol v1)

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
`flushChanges`, `getDocument`, `getSelection`, `getScrollPosition`.

### Outbound to Swift — `WKScriptMessageHandler` named `mdvEditor`

Every payload carries `{v: 1, type: "...", ...}`. Messages:
`ready`, `change`, `save`, `cursorPositionChanged`, `selectionChanged`,
`scrollChanged`, `findOpened`, `findClosed`, `findResultChanged`,
`linkClicked`, `editorBlurred`, `errorOccurred`, `requestReply`.

### Legacy `window.*` helpers

Kept for one cycle so existing call sites (e.g. AppDelegate Undo/Redo)
don't break: `setText`, `getText`, `undo`, `redo`, `setFontSize`,
`setTheme`, `setLanguage`, `setEditable`, `openSearch`, `flushChanges`.
All shims route through the same dispatch path internally.
