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

## How to re-build

```
cd scripts/codemirror-build
npm install --no-audit --no-fund
npm run build
```

That writes:

```
Sources/ViewerUI/Resources/codemirror/codemirror.js   (~571 KB minified)
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
`setLineNumbers`, `setIndentation`, `gotoLine`, `setSelection`,
`openSearch`, `closeSearch`, `findNext`, `findPrev`, `replaceNext`,
`replaceAll`, `foldAll`, `unfoldAll`, `undo`, `redo`, `focus`,
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
