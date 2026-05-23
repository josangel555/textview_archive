# CodeMirror 6 bundle

`codemirror.js` and `codemirror.css` here are vendored build outputs.
The runtime app does NOT depend on `npm`, `node`, or `node_modules` —
those tools only run when re-bundling.

## What's in the bundle

A single IIFE bundle exposing CodeMirror 6 as `window.CM`. Languages:
markdown, javascript (+ typescript / jsx / tsx), python, json. Theme:
one-dark (toggled via Compartment at runtime). See
`scripts/codemirror-build/entry.js` for the exact re-exports.

## How to re-build

```
cd scripts/codemirror-build
npm install --no-audit --no-fund
npm run build
```

That writes:

```
Sources/ViewerUI/Resources/codemirror/codemirror.js   (~570 KB minified)
```

CSS is hand-maintained at `codemirror.css` in this directory; CM6
itself injects its base theme via `EditorView.baseTheme` so nothing
upstream needs to be bundled into CSS.

## Pinning

`scripts/codemirror-build/package.json` pins exact CM6 versions and
the esbuild version used. To bump:

1. Edit the version in `scripts/codemirror-build/package.json`.
2. `rm -rf scripts/codemirror-build/node_modules`.
3. Re-run `npm install` + `npm run build`.
4. Commit `package.json` AND the regenerated `codemirror.js`.
5. Verify with `swift test --filter CodeMirrorBundleTests`.

## Contract with the host

`codemirror.html` wires the bundle into a single `EditorView` and
exposes these helpers on `window` (called from Swift via
`evaluateJavaScript`):

- `setText(text)` — replace document
- `getText()` — read document
- `undo()` / `redo()`
- `setFontSize(px)`
- `setTheme("light" | "dark")`
- `setLanguage("markdown" | "js" | "ts" | "jsx" | "tsx" | "python" | "json" | …)`
- `setEditable(bool)`
- `openSearch()` — bring up CM's built-in search panel (⌘F)
- `flushChanges()` — force-emit any debounced change before a save

And it posts these messages to the `mdvEditor` WKScriptMessageHandler:

- `{type: "ready"}` — page loaded, helpers are live
- `{type: "change", text: "…"}` — debounced 200 ms after the last edit
- `{type: "saveRequested"}` — user hit ⌘S inside the editor
