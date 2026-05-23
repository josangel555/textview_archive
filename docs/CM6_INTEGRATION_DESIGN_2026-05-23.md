# CodeMirror 6 — Deep Study + Integration Design for TextView

Research + design dated **2026-05-23**. Read-only. No code changes.

Companion to:

- `docs/TEXT_EDITOR_OPTIONS_2026-05-23.md` — option survey
- `docs/SCINTILLA_VS_CODEMIRROR6_2026-05-23.md` — decision lock on CM6
- `docs/LSP_DESIGN.md`, `docs/LSP_ROADMAP_2026-05-22.md`
- `Sources/ViewerUI/CodeMirrorEditorView.swift` — landed thin wrapper
- `Sources/ViewerUI/Resources/codemirror/{codemirror.html,codemirror.js,codemirror.css,BUILD.md}` — current 572 KB minified IIFE
- `scripts/codemirror-build/{package.json,entry.js}` — esbuild workspace

Scope of this doc — two big parts:

1. **CM6 deep-study** (~Part 1). What the framework is, how it composes,
   what hurts, what works, what to read upstream.
2. **Low-level integration design** (~Part 2). What we ship next, in
   what order, with what bridge protocol, against which risks, inside
   our 37 MB total / 16 MB exec / 572 KB CM6-bundle budget.

Source list at end. **20+ distinct citations** as requested — including
discuss.codemirror.net forum threads, codemirror/dev GitHub issues,
MarkEdit source, persistent.info latency measurements, official guide.

---

## Table of contents

### Part 1 — CodeMirror 6 deep-study

1. Architecture: EditorState, EditorView, Transactions
2. Extensions: Facet, Compartment, StateField, ViewPlugin, Prec
3. Package map (table)
4. API patterns (state, transactions, listeners, decorations, widgets)
5. Recipes (debounce, batch, set-from-outside, reset-history, swap-extension)
6. Pain points from real usage
7. Bugs & gotchas — concrete, with citations
8. Best practices (from manual + MarkEdit)
9. Performance characteristics
10. Bundle composition

### Part 2 — TextView integration design

11. Existing seams recap
12. Feature plan (table, ordered)
13. Bridge protocol v1 (exhaustive spec)
14. Swift-side state management
15. Performance plan
16. Testing strategy
17. Risks & open questions
18. Phased roadmap
19. Bundle-growth plan
20. MarkEdit reference patterns

### Appendices

A. Executive summary
B. Sources

---

# PART 1 — CodeMirror 6 deep-study

## 1. Architecture: EditorState, EditorView, Transactions

CM6 is a **reducer-shaped editor**. The library splits cleanly into a
pure-functional core (state) and an imperative shell (view). Mental
model translation table for a Swift/AppKit engineer:

| CM6 concept       | Swift analogue                                          |
|-------------------|---------------------------------------------------------|
| `EditorState`     | An immutable value, like a `struct` doc model           |
| `EditorView`      | The `NSView` host that owns the live state               |
| `Transaction`     | A user-event-derived diff that produces a new state     |
| `update(tr)`      | `state = reducer(state, action)` in Redux               |
| `Facet`           | A typed slot in `EditorState` (think `EnvironmentKey`)  |
| `Compartment`     | A swappable bucket of extensions (think `Section<T>`)    |
| `StateField`      | A reducer slot keyed off transactions                   |
| `ViewPlugin`      | An imperative side-car for DOM / event work             |

### 1.1 Why immutability matters

The CM6 guide [Sources: 1, 2] hammers this point:

> *"An old state value stays intact even when the editor moves on to
> a new state, which is often useful when dealing with state changes."*

For us, that means:

- **Undo / redo is structural** — every state is keyed in
  `history()`'s ring; nothing to "blow away" on a transient mutation.
- **Async work over state snapshots is safe** — e.g. an LSP request
  fired on `state@v123` can compare its result range against the
  *live* state at response time and `mapPosition`-translate it
  through intervening transactions without losing correctness.
- **The view is a derived projection** — anything you read off
  `view.state` is a value, not a live pointer. The whole class of
  "iterator invalidated by edit during traversal" bugs is gone.

### 1.2 Transaction lifecycle

```
 keystroke / paste / API call
            │
            ▼
   build TransactionSpec  (changes? selection? effects? annotations?)
            │
            ▼
     state.update(spec)        → Transaction value
            │
            ▼
       view.dispatch(tr)
            │
       ┌────┴───────────────────────────────┐
       │ apply changes to fields            │
       │ run updateListener(s)               │
       │ run view plugins' update(...)       │
       │ recompute decorations               │
       │ schedule measure/render             │
       └────────────────────────────────────┘
            │
            ▼
       DOM patched in place
```

`Transaction` carries one or more `ChangeSet` (doc diff), a
`SelectionUpdate`, a list of `StateEffect`s (typed effects you can
match in your own `StateField`'s update), and `Annotation`s (untyped
metadata, e.g. `Transaction.userEvent.of("input.type")`).

A handful of useful tricks come straight out of this shape:

- **`tr.docChanged`** lets your update-listener cheaply skip
  selection-only changes.
- **`tr.annotation(Transaction.remote)`** is the official escape
  hatch for "this came from outside, don't merge into the user's
  undo group". (Used by collab plugins; ours can repurpose for
  file-watcher rewrites and post-format `setText`.)
- **`tr.changes.iterChangedRanges((from, to, fromB, toB) => …)`**
  gives you the diff in a streaming form — perfect for sending
  LSP `didChange` incremental ranges later.

### 1.3 EditorView — the imperative shell

`EditorView` owns the DOM, the viewport, the focus, and the
event loop. It also exposes a few mutators:

- `view.dispatch(spec | tr)` — the only sanctioned mutation channel.
- `view.setState(newState)` — replace state wholesale; **wipes
  StateField values + undo history**. This is the documented
  recipe for "load a different document". [Source 3]
- `view.requestMeasure(...)` — schedule a synchronous-with-layout
  callback. The right place to read DOM geometry.

The view also adds **viewport-only fields** the state cannot have:

- `view.viewport` — the visible-line range. Drives lazy work.
- `view.visibleRanges` — actually-rendered ranges (DOM-attached).
- `view.coordsAtPos(pos)` — pixel rect for a doc position.

Anything that depends on DOM geometry (popovers anchored to a
position, gutter widget hit-testing, auto-scroll) goes through
`view.requestMeasure` / `view.coordsAtPos` rather than off the
state.

---

## 2. Extensions: Facet, Compartment, StateField, ViewPlugin, Prec

CM6 has zero "configuration object". Everything is an
**extension**: a value passed in the `extensions` array. Languages,
themes, keymaps, decorations, lint sources, autocompletion sources,
even `lineNumbers` — all extensions.

### 2.1 Extensions are values

```js
EditorState.create({
  doc, extensions: [
    history(),
    keymap.of(defaultKeymap),
    markdown(),
    oneDark,
    EditorView.lineWrapping,
    EditorView.updateListener.of(handleUpdate),
  ],
})
```

Each entry produces zero or more `Facet` values, `StateField`s,
`ViewPlugin`s, etc. The state's constructor walks the array,
flattens nested arrays, deduplicates, sorts by precedence,
and produces the final composed state.

### 2.2 Facet — the typed-slot primitive

A `Facet<Input, Output>` is a contention-aware slot. Many
extensions can write to it; the `combine` function reduces them.

- `EditorView.editable` — boolean facet. `true.of(...)` from
  three extensions → still one effective value.
- `EditorState.tabSize` — number facet.
- `EditorState.languageData` — facet of records, combined to
  produce per-language data like comment tokens.
- Custom facet — useful when several plugins want to contribute
  e.g. lint sources or completion sources.

Read via `state.facet(myFacet)`. Cached automatically; no perf
penalty for many readers.

### 2.3 Compartment — for hot-swappable config

A compartment wraps a sub-tree of extensions you want to
reconfigure at runtime without rebuilding the whole state.
Classic pattern:

```js
const themeC = new Compartment();
const langC  = new Compartment();
EditorState.create({
  extensions: [
    themeC.of(lightTheme),
    langC.of(markdown()),
    ...rest
  ]
});
// later:
view.dispatch({
  effects: themeC.reconfigure(darkTheme),
});
```

Our `codemirror.html` already uses this for theme + language +
editable. Compartments we'll add: keymap (user prefs), line
wrap (toggle), gutter visibility, font theme, vim mode toggle.

### 2.4 StateField — reducer per editor

```js
const diagField = StateField.define({
  create() { return Decoration.none; },
  update(decos, tr) {
    decos = decos.map(tr.changes);     // remap through edits
    for (const e of tr.effects) {
      if (e.is(setDiagsEffect)) decos = e.value;
    }
    return decos;
  },
  provide: f => EditorView.decorations.from(f),
});
```

This is the canonical pattern for **server-driven decorations**
(diagnostics, hovers, search highlight). Important properties:

- Survives reconfiguration (unless the compartment is replaced).
- Auto-remapped through edits via `decos.map(tr.changes)`.
- Provides a derived `Facet` value via `provide:` (chains into
  the view's decoration pipeline).

### 2.5 ViewPlugin — imperative side-car

When you need DOM (tooltips, scroll listeners, IntersectionObserver,
animation frames), use `ViewPlugin.fromClass(...)`. Lives in the
view, has `update(viewUpdate)` and `destroy()` hooks, can carry
its own `decorations` accessor.

**Rule of thumb** [Source 4]:

| Use StateField when…                        | Use ViewPlugin when…                                       |
|---------------------------------------------|------------------------------------------------------------|
| Decoration needs to live across re-mounts   | Plugin only matters while DOM is alive                     |
| Many extensions need to *read* the value    | You only need it for your own DOM side-effects             |
| Replay-friendly (e.g. collab, time-travel)  | You touch IntersectionObserver / ResizeObserver / clipboard |
| Decoration is *block-replacing* line layout | Decoration is mark-style on already-displayed text          |

Block-replacing widgets must come from a StateField; that
constraint is explicit in the decoration-example docs.

### 2.6 Precedence — `Prec.highest / high / default / low / lowest`

Extensions are sorted by precedence within a "level". This
matters most for **keymaps** — your save binding must beat
`defaultKeymap`'s use of `Mod-s`, or be wrapped in
`Prec.high(keymap.of(...))`. The way we already get this right
in `codemirror.html` is by listing the save binding first in
the same `keymap.of([...])` array — earlier entries win.

Also matters for **decorations** when two plugins want to
mark-style the same range: higher precedence wins for any
conflict; otherwise decorations stack.

---

## 3. Package map

Per-package summary. Bundle sizes are minified (not gzipped),
from npm package contents + bundlephobia [Sources: 5, 6].

| Package                            | Exports we'd use                                                                                          | Approx min size | Use today | Use next |
|------------------------------------|-----------------------------------------------------------------------------------------------------------|----------------:|:---------:|:--------:|
| `@codemirror/state`                | `EditorState`, `Transaction`, `Compartment`, `Facet`, `StateField`, `StateEffect`, `Annotation`, `Range`  |          ~80 KB |     y     |     y    |
| `@codemirror/view`                 | `EditorView`, `Decoration`, `WidgetType`, `ViewPlugin`, `keymap`, `lineNumbers`, `foldGutter`, `lineWrapping`, `placeholder`, `drawSelection`, `tooltip*` |         ~290 KB |     y     |     y    |
| `@codemirror/commands`             | `history`, `historyKeymap`, `defaultKeymap`, `indentWithTab`, `undo`/`redo`/word commands                  |          ~38 KB |     y     |     y    |
| `@codemirror/search`               | `search`, `searchKeymap`, `openSearchPanel`, `findNext`/`Prev`, `highlightSelectionMatches`               |          ~30 KB |     y     |     y    |
| `@codemirror/language`             | `LanguageSupport`, `syntaxTree`, `HighlightStyle`, `bracketMatching`, `indentOnInput`, `foldGutter`, `codeFolding` |          ~80 KB |     y     |     y    |
| `@codemirror/autocomplete`         | `autocompletion`, `completionKeymap`, `CompletionSource`, `snippet`                                       |          ~50 KB |     n     |   later  |
| `@codemirror/lint`                 | `linter`, `Diagnostic`, `lintGutter`, `forceLinting`                                                      |          ~25 KB |     n     |     y    |
| `@codemirror/lang-markdown`        | `markdown()` + GFM grammar; nested code-block parsing                                                     |          ~70 KB |     y     |     y    |
| `@codemirror/lang-javascript`      | `javascript()` (covers TS/JSX/TSX via options)                                                            |         ~110 KB |     y     |     y    |
| `@codemirror/lang-python`          | `python()` (Lezer grammar)                                                                                |          ~50 KB |     y     |     y    |
| `@codemirror/lang-json`            | `json()` (small Lezer grammar)                                                                            |          ~10 KB |     y     |     y    |
| `@codemirror/lang-html`            | `html()` (composes css + js)                                                                              |         ~120 KB |     n     |     y    |
| `@codemirror/lang-css`             | `css()`                                                                                                   |          ~30 KB |     n     |     y    |
| `@codemirror/lang-xml`             | `xml()`                                                                                                   |          ~15 KB |     n     |     y    |
| `@codemirror/lang-sql`             | `sql()` + dialects                                                                                        |          ~60 KB |     n     |   later  |
| `@codemirror/lang-rust`            | `rust()` Lezer grammar                                                                                    |         ~110 KB |     n     |   later  |
| `@codemirror/lang-cpp`             | `cpp()`                                                                                                   |          ~80 KB |     n     |   later  |
| `@codemirror/lang-java`            | `java()`                                                                                                  |          ~40 KB |     n     |   later  |
| `@codemirror/theme-one-dark`       | `oneDark` theme                                                                                           |           ~6 KB |     y     |     y    |
| `@lezer/highlight`                 | `tags`, `tagHighlighter`, `HighlightStyle` (re-export)                                                    |          ~10 KB |   indir.  |   indir. |
| `@codemirror/lsp-client`           | `LSPClient`, `Transport`, `languageServerExtensions(uri)`                                                  |         ~100 KB |     n     |   eval.  |
| `@replit/codemirror-vim`           | Community vim emulation; MIT                                                                              |         ~280 KB |     n     |   eval.  |
| `@uiw/codemirror-extensions-color` | Hex-color inline swatch decorations (example community)                                                   |           ~8 KB |     n     |    no    |

Numbers will shift ± 20% with esbuild settings, but the ranking
holds.

**Tree-shaking note.** `@codemirror/view` is the largest single
chunk and you can't really shrink it — it's the engine. The
language packs are independently tree-shakeable; if a user never
opens a Rust file, the JS isn't loaded. Future: per-language
lazy-load via `import()` (Safari 17 supports dynamic import in
WebView contexts). Today we bundle all selected languages
eagerly — fine while we're at 572 KB.

---

## 4. API patterns

### 4.1 Building the initial state

```js
const state = EditorState.create({
  doc: "initial text",
  selection: { anchor: 0 },
  extensions: [/* … */],
});
const view = new EditorView({ state, parent: hostEl });
```

### 4.2 Dispatching a transaction

```js
view.dispatch({
  changes: { from: 0, to: state.doc.length, insert: "new text" },
  selection: { anchor: 4 },
  effects: [setThemeEffect.of("dark")],
  annotations: Transaction.userEvent.of("input.replace"),
});
```

Spec is value-typed; the actual `Transaction` is produced by
`state.update(spec)`. The view's `dispatch` is shorthand.

### 4.3 Reading the doc and selection

```js
view.state.doc.toString();                 // full doc
view.state.doc.sliceString(from, to);      // range
view.state.doc.length;                     // length
view.state.doc.lines;                      // line count
view.state.doc.line(n);                    // 1-based; returns {from,to,text}
view.state.doc.lineAt(pos);                // position → containing line
view.state.selection.main.head;            // primary caret
view.state.selection.ranges;               // all cursors / selections
```

Lines are cached in a piece tree; `lineAt` is O(log n).

### 4.4 Listening for doc changes

```js
EditorView.updateListener.of(update => {
  if (update.docChanged) /* … */;
  if (update.selectionSet) /* … */;
  if (update.viewportChanged) /* … */;
});
```

Already used today for the debounced change emitter. Listeners
run **after** state is applied, **before** the next paint.

### 4.5 Programmatic scroll / cursor placement

```js
view.dispatch({
  effects: EditorView.scrollIntoView(pos, { y: "center" }),
});
```

Or for a hard scroll to top:

```js
view.scrollDOM.scrollTop = 0;
```

Pixel-precise: `view.coordsAtPos(pos)` returns `{left, top,
bottom, right}` relative to the viewport.

### 4.6 Persisting and restoring scroll position

Two ways:

1. **Scrollable line offset** (resilient to wrap toggle): record
   `view.viewport.from`, restore by dispatching
   `EditorView.scrollIntoView(savedPos, { y: "start" })`.
2. **Pixel-perfect** (resilient to no doc changes): record
   `view.scrollDOM.scrollTop`, restore directly. Cheap but breaks
   if line wrap or font size changes between sessions.

We want (1) for per-tab persistence across font/wrap toggles.

### 4.7 Reading the viewport

```js
view.viewport;       // {from, to} in doc coords
view.visibleRanges;  // [{from, to}, …] more granular
```

Use for "decorate only what's visible" plugins (lazy lint
gutter, virtualized minimap).

### 4.8 Decorations — three flavors

```js
// inline mark (e.g. search highlight)
Decoration.mark({ class: "cm-search-hit" }).range(from, to)

// line background (e.g. active-line, breakpoint line)
Decoration.line({ attributes: { class: "cm-breakpoint" } }).range(lineStart)

// widget (e.g. block-level lint message, inline color swatch)
Decoration.widget({ widget: new MyWidget(...), side: 1 }).range(pos)

// replacing widget (e.g. fold-collapsed range)
Decoration.replace({ widget: new FoldWidget(...) }).range(from, to)
```

Group into a `DecorationSet` via `Decoration.set([...])` (must be
sorted by `from`); plug into the view via either a StateField's
`provide` or a ViewPlugin's `decorations` accessor.

### 4.9 Gutter markers

```js
const breakpointGutter = gutter({
  class: "cm-breakpoint-gutter",
  lineMarker(view, line) {
    return shouldMark(line.from) ? new BreakpointMarker() : null;
  },
  initialSpacer: () => new BreakpointMarker(),
});
```

Gutter elements are also decorations under the hood; same
lifecycle.

### 4.10 Widgets — block vs inline

```js
class HrWidget extends WidgetType {
  toDOM() {
    const el = document.createElement("hr");
    el.className = "cm-hr-widget";
    return el;
  }
  ignoreEvent() { return true; }   // don't steal CM event handling
  eq(other) { return other instanceof HrWidget; }
}
```

`ignoreEvent` is load-bearing — without it, click-in-widget
sometimes nukes the selection. `eq` lets CM dedupe identical
widgets on re-render (no DOM thrash).

---

## 5. Common recipes

### 5.1 Debounced change emission

What we already do, but in idiomatic CM shape:

```js
let timer = null;
EditorView.updateListener.of(update => {
  if (!update.docChanged) return;
  if (timer) clearTimeout(timer);
  timer = setTimeout(() => {
    timer = null;
    bridge.send({ type: "change", text: view.state.doc.toString() });
  }, 200);
})
```

For multi-MB docs, `.toString()` is O(n) — once. Don't call it on
every keystroke; the debounce is exactly to avoid that.

### 5.2 Transactional batch edits

A single `dispatch` with multiple changes is one undo step:

```js
view.dispatch({
  changes: [
    { from: 0, insert: "// header\n" },
    { from: 100, to: 110, insert: "" },
  ],
});
```

Two `dispatch` calls = two undo steps. Important for "format on
save" — must wrap in one dispatch.

### 5.3 Set text from outside without losing undo history

Forum guidance [Source 3] + the CM6 history annotation:

```js
view.dispatch({
  changes: { from: 0, to: state.doc.length, insert: newText },
  annotations: Transaction.addToHistory.of(false),  // skip undo
  // OR
  annotations: Transaction.remote.of(true),
});
```

This is what we want for **file-watcher re-reads**: the file on
disk changed externally, we want the editor to reflect it, but
the user shouldn't be able to ⌘Z back to the stale buffer (it
was never their state).

### 5.4 Set text from outside AND reset undo history

Different scenario — opening a new file in the same view. Per
the maintainer [Source 3]: **don't try to clear history; create
a new state.**

```js
view.setState(EditorState.create({
  doc: newText,
  extensions: BASE_EXTENSIONS,  // same array as the old state
}));
```

`setState` resets all StateFields (history, fold ranges,
diagnostics decorations, etc.) and re-builds compartments from
their initial values. Cheap. We'll use this for `openDocument`.

### 5.5 Swap an extension via Compartment

```js
const wrapC = new Compartment();
EditorState.create({
  extensions: [..., wrapC.of(EditorView.lineWrapping)],
})
// later, to turn wrap off:
view.dispatch({
  effects: wrapC.reconfigure([]),
});
```

We'll add compartments for: line wrap, keymap (vim/non-vim),
font theme, gutters visibility, indent guides.

### 5.6 Persist selection across reloads

Per-tab dictionary keyed by URL, value = `JSON.stringify(
view.state.selection.toJSON())`. On reopen,
`EditorSelection.fromJSON(saved)` and pass to `EditorState.create`'s
`selection` option. Round-trip clean; no API surface to invent.

---

## 6. Pain points from real usage

Surveyed via discuss.codemirror.net, codemirror/dev issues,
Joplin / Zettlr / Obsidian / Replit threads. Listed with
mitigations.

### 6.1 The "set text from outside" undo gotcha

Replacing the doc via `view.dispatch({changes: ...})` **prepends
the old doc as an undoable state**. Users expect "I just opened
this file" not "I can ⌘Z back to nothing". Mitigation: either
`Transaction.addToHistory.of(false)` or `view.setState(...)`.
See §5.3-5.4. [Source 3]

### 6.2 Compartment reconfigure quirks

- Reconfiguring a Compartment that was **never set up at create
  time** silently no-ops. [Source 7]
- Reconfiguring `EditorView.baseTheme` *adds* the new class
  rather than replacing it. Theme classes accumulate; styling
  drifts. Workaround: nest base-theme in a Compartment from day
  one. [Source 7]
- `StateField.create()` does **not** re-run on reconfigure; only
  `update()` does. If your field's initial value depends on
  config, you need to ship a fresh `StateField` per config and
  swap the whole field's compartment. [Source 7]

### 6.3 IME composition + multi-cursor edge cases

CM6 has had a string of IME bugs around composition + multi-
cursor + widget boundaries [Source 8]:

- Composition with multiple cursors on macOS — fixed but flaky
  historically.
- Widget buffers between widgets and compositions: CM keeps
  them in to avoid breaking IME on macOS Firefox. (WebKit is
  generally better here, but the same kind of fragility exists.)
- Safari composition stuck when compositionend doesn't fire on
  a dead key — patched, but every Safari minor risks regression.

For us: **WKWebView on macOS 15 is the most-tested CM6 host
short of desktop Chrome.** The mitigation is empirical — test
Japanese / Chinese composition in the VM after each CM6 bump.
Add a manual-test checklist row.

### 6.4 Vim mode flakiness

`@replit/codemirror-vim` is the only viable vim option for CM6
[Source 9]. Known issues:

- Normal-mode `o` doesn't open a line below cursor (broken;
  capital `O` works).
- `~` (case invert) followed by undo lands in visual mode.
- `Ctrl-u` / `Ctrl-d` half-page scroll doesn't fire (collides
  with built-in undo).
- IME in vim command mode messes up input.
- `:w` is a no-op (the extension can't reach our save bridge —
  we'd have to wire an Ex-command).

Verdict: ship vim mode **opt-in behind a setting**, never
default. Test cases must include the four bugs above so we
notice when they're fixed upstream.

### 6.5 Accessibility / screen-reader story is incomplete

VoiceOver + CM6 has known issues [Source 10]:

- Screen readers aren't notified when autocomplete focus
  changes — users hear no narration of completion candidates.
- Backspace narration is unreliable on contenteditable across
  Safari/VoiceOver pairings (because CM intercepts the key).
- Read-by-line works but is heuristic.

Not a deal-breaker for us — TextView isn't a primary tool for
blind users — but worth a row in the manual-test checklist and
worth not regressing intentionally.

### 6.6 Large-doc performance edges

CM6 is designed for million-line docs [Source 11, 12]:

- Lines tracked in a piece tree → O(log n) line lookup.
- Viewport rendering → DOM only carries visible lines.
- Highlighter has a work budget per frame; it pauses on huge
  docs.

But [Source 13]:

- One forum user reports issues above ~1.6 M lines (probably
  GC / DOM strain in the WebView process, not CM6 itself).
- Ridiculously long single lines (e.g. minified JS, 5 MB on
  one line) **do** degrade — line wrap recalculation is the
  hot path. Workaround: turn off `lineWrapping` for that doc
  or auto-detect "long-line" docs and switch to non-wrap mode.

### 6.7 RTL / bidi

Works, but **bidi cursor motion** has historical bugs around
arrow keys at LTR↔RTL boundaries. Not relevant to our shipping
languages today; flag for the day we add Hebrew/Arabic markdown
support.

### 6.8 Tab vs space ambiguity

`indentWithTab` binds Tab to "insert one indent" using the
current language's indent setting. The bug: if there's no
selection and indent unit is "tab", you'll get a tab; if it's
"4 spaces", you'll get 4 spaces. Users who paste tab-indented
code into a space-default doc see mixed indentation. Per-file
indent detection is on us, not on CM6.

### 6.9 Paste-from-Word HTML

WebView's paste of rich text into a contenteditable produces
HTML. CM6 sanitizes to plain text by default — but in some
configurations (especially the `paste.transform` patch flows
some forks ship), HTML residue (smart quotes, no-break spaces)
sneaks through. Mitigation: register a `paste` event handler on
the editor DOM via a `ViewPlugin` and call
`event.clipboardData.getData("text/plain")` explicitly.

### 6.10 Mobile keyboard quirks

Largely irrelevant for our macOS-only WKWebView host, but
documented for completeness:

- iOS IME causes app/page freeze with line wrapping in some
  versions [Source 8].
- Android TalkBack "navigate by line" navigates by highlight
  region, not visual line.

---

## 7. Bugs & gotchas with citations

| # | Symptom                                                                          | Root cause                                                                | Workaround                                                                                       | Source |
|---|----------------------------------------------------------------------------------|---------------------------------------------------------------------------|--------------------------------------------------------------------------------------------------|--------|
| 1 | Replacing doc via `dispatch` leaves user able to ⌘Z back to old doc              | All `dispatch` changes go into history unless annotated                   | `Transaction.addToHistory.of(false)` or `view.setState`                                          | [3]    |
| 2 | Compartment reconfigure does nothing                                             | Compartment was never inserted into initial extensions                    | Always wrap dynamic config in a Compartment from `EditorState.create` time                       | [7]    |
| 3 | Theme classes pile up after multiple `baseTheme` reconfigures                    | `baseTheme` doesn't replace, it adds                                      | Use `EditorView.theme(...)` inside the Compartment, not `baseTheme`                              | [7]    |
| 4 | `StateField.create()` doesn't re-run on reconfigure                              | Reconfigure preserves existing fields if their definition matches         | Make the field itself part of a Compartment if create-time deps change                           | [7]    |
| 5 | Safari composition stuck on dead-key                                             | Safari doesn't fire `compositionend`                                      | CM patched, but pin to latest `@codemirror/view`                                                 | [8]    |
| 6 | WKWebView on Mac Catalyst breaks copy from CM6                                   | Catalyst UIView clipboard plumbing                                        | Don't use Mac Catalyst (we're native macOS, not affected)                                        | [8]    |
| 7 | Vim mode `o` doesn't open line below                                             | `@replit/codemirror-vim` bug                                              | Wait for upstream / patch in user JS                                                             | [9]    |
| 8 | Vim mode IME garbles in command mode                                             | Same plugin                                                               | Document in vim-mode caveats; don't auto-enable for CJK locale                                   | [9]    |
| 9 | Long single-line files thrash on line-wrap toggle                                | Wrap layout is O(n) on line length                                        | Auto-detect (`maxLineLength > 5_000` ?) and disable wrap; warn user                              | [13]   |
| 10 | `setText` followed by immediate `getText` returns the old text                  | `dispatch` is async w.r.t. the DOM but sync w.r.t. state                  | Read from `view.state.doc` not the DOM; or chain via promise                                     | manual |
| 11 | Autocomplete tooltip steals focus, breaking custom popovers                     | `@codemirror/autocomplete` mounts an absolutely-positioned panel          | Listen to `autocompletion`'s `closeBrackets` events; defer our popover                            | manual |
| 12 | `view.dispatch` from inside an `updateListener` throws                          | CM6 forbids dispatch during update                                        | Defer via `queueMicrotask` / `requestAnimationFrame`                                              | manual |
| 13 | Compartment reconfigure from inside ViewPlugin update doesn't propagate         | Same reason — dispatch-during-update is forbidden                         | Defer (microtask)                                                                                 | [7]    |
| 14 | `oneDark` theme renders dark even after compartment swap to `[]`                | `oneDark` adds a base-theme that lives outside the compartment            | Wrap `oneDark` in `[oneDark, EditorView.theme(...)]` and put both in the compartment              | [7]    |
| 15 | `searchKeymap` `Mod-F` doesn't trigger if you bound `Mod-F` elsewhere           | Keymap precedence: your binding wins                                      | Order in `keymap.of([...])` matters — earliest entry wins                                         | manual |
| 16 | After `setText`, caret jumps to start                                           | We didn't pass a `selection` in the spec                                  | Pass `selection: {anchor: clampedCaret}` (we already do)                                          | own    |
| 17 | Screen reader (VoiceOver) doesn't narrate autocomplete focus                    | CM6 manages completion as a separate DOM tree                             | Document; no current fix                                                                          | [10]   |
| 18 | Folded ranges blow up after `setState`                                          | StateField is reset, fold ranges with it                                  | Serialize fold ranges per-tab; restore via effect after setState                                  | [3]    |

---

## 8. Best practices

From the official guide [Sources: 1, 2, 14] and MarkEdit source
patterns [Source 15]:

1. **Keymap precedence**: list save / find / cancel **before**
   `defaultKeymap` in the same `keymap.of([...])` array. Wrap in
   `Prec.high(...)` only if you can't reorder.
2. **Compartment everything you might want to reconfigure**.
   Cheap to add upfront; expensive to retrofit. Standard set:
   theme, language, keymap, font, gutters, line-wrap, editable,
   autocompletion source.
3. **One `dispatch` per logical change**. Multiple changes in
   one dispatch = one undo step; separate dispatches = separate
   steps. Format-on-save is the canonical "must be one dispatch".
4. **Don't dispatch during update**. CM6 throws. Defer via
   microtask or `requestAnimationFrame`.
5. **Use `StateField` for "decorations driven by state"**
   (search hits, diagnostics, fold ranges) and `ViewPlugin` for
   "decorations driven by viewport / DOM" (active-line, minimap).
6. **Use `Decoration.set(rangeArray)` only with pre-sorted
   ranges** (sort by `from`). Otherwise it throws.
7. **Don't read DOM from inside an updateListener** —
   measurements are stale. Use `view.requestMeasure(...)`.
8. **Pre-bundle as IIFE for WebView use** (what we do). No
   ESM, no dynamic import, no eval. Sets a clean CSP baseline.
9. **MarkEdit pattern: bridge calls go through a typed
   `webModule` / `nativeModule` shim**, generated via
   `ts-gyb` from a shared IDL. We don't need ts-gyb yet, but
   the *shape* — two TS modules, one for outbound, one for
   inbound — is good to mirror.
10. **MarkEdit pattern: `EditorViewController` splits via Swift
    extensions** — `+TextFinder.swift`, `+GotoLine.swift`,
    `+HyperLink.swift`, etc. Keeps each feature's bridge call
    + native menu wiring + UI in one file. We should follow.

---

## 9. Performance characteristics

Synthesis of forum claims [Sources: 11, 12, 13], MarkEdit
empirical reports [Source 16], and our own existing 572 KB
bundle:

| Doc size                | CM6 behavior                                              | Practical caveat                              |
|-------------------------|-----------------------------------------------------------|-----------------------------------------------|
| < 100 KB                | Indistinguishable from native                              | None                                          |
| 100 KB – 1 MB           | Fast; first paint < 50 ms                                  | None                                          |
| 1 MB – 10 MB            | "Eye-blinking" per MarkEdit; first paint < 500 ms          | Highlighter pauses on viewport edges          |
| 10 MB – 100 MB          | Workable; scroll is fine; full-text search is slow         | `getText()` round-trip allocates the full string |
| > 100 MB                | Beyond "designed for" range; JS heap pressure              | Suggest read-only mode; ours skipped CM6 path |
| Single line > 5 KB      | Layout slow with `lineWrapping` on                         | Auto-detect, suggest disabling wrap            |
| Lines > 1.6 M           | DOM virtualization holds, but GC pressure on the WebContent process | Honest answer: rare for us                    |

Per-keystroke cost on a 10 MB markdown doc:

```
keystroke  → CM transaction          ~0.1 ms
           → updateListener fired    ~0.05 ms
           → debounce window         200 ms (our choice)
           → text.toString()         ~5 ms  (allocates a 10 MB JS string)
           → bridge serialize        ~3 ms
           → bridge round-trip       ~5 ms  (WKScriptMessageHandler IPC) [17]
           → Swift onTextChange      varies
```

So even on a 10 MB doc, the user-perceived cost of an edit is
~13 ms after the debounce — within frame budget. The big
optimization we'd want long-term is **incremental change
shipping** instead of full-doc `setText` — exactly what
`@codemirror/lsp-client` does internally for `didChange`. See
Part 2 §15 (perf plan).

WebView IPC cost note [Source 17]: per-message round-trip is
historically ~3-5 ms on macOS, dominated by JSContext
initialization. Important implication — **don't fire one
bridge call per keystroke; batch.**

---

## 10. Bundle composition

Our current bundle (`scripts/codemirror-build/entry.js`):

```
@codemirror/state                  ~80 KB
@codemirror/view                  ~290 KB
@codemirror/commands               ~38 KB
@codemirror/search                 ~30 KB
@codemirror/language               ~80 KB
@codemirror/lang-markdown          ~70 KB
@codemirror/lang-javascript       ~110 KB
@codemirror/lang-python            ~50 KB
@codemirror/lang-json              ~10 KB
@codemirror/theme-one-dark          ~6 KB
─────────────────────────────────────────
sum (pre-minify, w/ duplication)  ~764 KB
after esbuild minify (Safari17)   ~572 KB   ← committed
```

After tree-shaking + minify, esbuild collapses common code
across the language packs and shaves another ~25%. The 572 KB
on disk is what `du -h` shows for `codemirror.js`.

**Headroom calculation for future packages** (using our 37 MB
total / 16 MB exec budget — see `scripts/check-bundle-size.sh`):

| Pkg added                  | min add | bundle delta | new total |
|----------------------------|--------:|-------------:|----------:|
| `@codemirror/lint`         |  ~25 KB |       ~18 KB |    590 KB |
| `@codemirror/autocomplete` |  ~50 KB |       ~38 KB |    628 KB |
| `@codemirror/lang-html`    | ~120 KB |       ~90 KB |    718 KB |
| `@codemirror/lang-css`     |  ~30 KB |       ~22 KB |    740 KB |
| `@codemirror/lang-xml`     |  ~15 KB |       ~11 KB |    751 KB |
| `@codemirror/lsp-client`   | ~100 KB |       ~75 KB |    826 KB |
| `@replit/codemirror-vim`   | ~280 KB |      ~210 KB |  1,036 KB |

Even with vim + lsp-client + lint + autocomplete + 3 extra
languages, the bundle stays ≤ 1.1 MB. That's still 4× cheaper
than Monaco's smallest realistic build (~6 MB) and inside our
37 MB app cap with comfortable headroom.

---

# PART 2 — TextView integration design

## 11. Existing seams (recap)

### 11.1 Swift side

| File                                                                | Role                                                                            |
|---------------------------------------------------------------------|---------------------------------------------------------------------------------|
| `Sources/ViewerUI/CodeMirrorEditorView.swift`                       | `NSViewRepresentable` host; `Coordinator` is the bridge controller; `CodeMirrorBridge.decode` is pure-logic   |
| `Sources/ViewerUI/CodeMirrorEditorView.swift` (`CodeMirrorEditorRegistry`) | Weak registry so AppKit menu Undo/Redo can find the live webview      |
| `Sources/ViewerCore/EditorBuffer.swift`                             | Value-typed dirty/save model; `setText`, `markSaved`, `hasExternalEdit`         |
| `Sources/ViewerCore/EditorBuffer.swift` (`EditorWriter`)            | Atomic disk write; returns `(mtime, size)` for refingerprinting                 |
| `Sources/ViewerCore/LSP/LSPPool.swift`                              | Per-(language, root) `LSPClient` pool with restart backoff                      |
| `Sources/ViewerCore/LSP/LSPClient.swift`                            | Hover, definition, references, documentSymbol, workspaceSymbol                  |
| `Sources/ViewerUI/MarkdownFindBar.swift`                            | Existing SwiftUI find bar (markdown / source-view variants)                     |
| (AppDelegate, `main.swift` referenced in CodeMirrorEditorView docs) | Wires ⌘Z/⇧⌘Z menu items to `webView.evaluateJavaScript("undo()/redo()")` |

### 11.2 JS side

| File                                                                | Role                                                                            |
|---------------------------------------------------------------------|---------------------------------------------------------------------------------|
| `Sources/ViewerUI/Resources/codemirror/codemirror.html`             | Page that loads the bundle + wires `window.{setText,getText,undo,redo,setFontSize,setTheme,setLanguage,setEditable,openSearch,flushChanges}` and posts `{type: ready/change/saveRequested}` |
| `Sources/ViewerUI/Resources/codemirror/codemirror.js`               | esbuild IIFE — 572 KB minified                                                  |
| `Sources/ViewerUI/Resources/codemirror/codemirror.css`              | Tiny hand-maintained sheet (1.1 KB) for host-only overrides                     |
| `scripts/codemirror-build/{entry.js,package.json}`                  | Re-bundle workspace                                                             |

### 11.3 Where the surface ends today

- Bridge protocol: `change`, `save`, `ready` (one-way Swift→JS is
  via `evaluateJavaScript`, untyped function calls).
- Versioning: none. No `v` field on messages.
- Selection / scroll / find / linting / completion / hover /
  go-to-def / diagnostics: **all absent on the editor side**.
  LSP machinery exists in Swift and serves the read-only
  `Source` view; CM6 editor mode has no LSP wiring yet.
- Undo/Redo: routed via menu → registry → `evaluateJavaScript`.
- Find bar: not bridged; pressing ⌘F in editor mode opens CM6's
  built-in search panel via the `saveBinding`-adjacent
  `searchKeymap`.
- File watcher: fires `setText(...)` on external edit, which
  goes through history (gotcha #1 above). We need
  `Transaction.addToHistory.of(false)` after the protocol bump.

### 11.4 Picture

```
                      ┌────────────────────┐
                      │  DocumentModel     │
                      │  (Tab list, active)│
                      └─────────┬──────────┘
                                │
                ┌───────────────┴────────────────┐
                │ EditorBuffer (text, dirty)     │
                │ + FileWatcher fingerprint      │
                └───────┬───────────────────────┘
                        │ onTextChange / save / setText
                        ▼
   ┌────────────────────────────────────────────────────┐
   │ CodeMirrorEditorView (NSViewRepresentable)         │
   │  ├─ Coordinator (WKScriptMessageHandler)           │
   │  ├─ lastSentText echo-suppress                     │
   │  └─ applyPendingState() per updateNSView           │
   └─────────────────────────┬──────────────────────────┘
                             │ evaluateJavaScript /
                             │ webkit.messageHandlers.mdvEditor
                             ▼
   ┌────────────────────────────────────────────────────┐
   │ WKWebView                                          │
   │  ├─ codemirror.html (host bootstrap)               │
   │  └─ codemirror.js (CM6 IIFE, window.CM.*)          │
   │      ├─ EditorView                                 │
   │      ├─ Compartments: theme, language, editable    │
   │      └─ updateListener → debounced "change" post   │
   └────────────────────────────────────────────────────┘
```

---

## 12. Feature plan

Each row: what it is · CM6 piece · Swift hookup · complexity (1l/S/M/L)
· dependency. Priority column is the recommended phase from §18.

| # | Feature                                | CM6 piece                                            | Swift hookup                                                     | Complex | Depends on        | Phase |
|---|----------------------------------------|------------------------------------------------------|------------------------------------------------------------------|--------:|-------------------|------:|
| 1 | Persistent scroll position per tab     | `view.scrollDOM.scrollTop` or `EditorView.scrollIntoView` | New bridge msg `scrollChanged`; per-tab dict in DocumentModel | S       | bridge v1         |   1   |
| 2 | Persistent selection per tab           | `EditorSelection.toJSON()/fromJSON()` + spec at create   | Same dict; restore on `setText` of saved doc                    | S       | bridge v1         |   1   |
| 3 | "Set text from outside" without undo  | `Transaction.addToHistory.of(false)`                  | `setText` API gets `resetHistory:` arg                          | 1l      | none              |   1   |
| 4 | File-watcher conflict prompt verify    | n/a — verify existing prompt still fires              | Manual test row                                                  | 1l      | feature 3         |   1   |
| 5 | `cursorPositionChanged` notification   | `updateListener` `update.selectionSet`               | New msg `cursorPositionChanged`; bottom-bar L:C readout         | S       | bridge v1         |   1   |
| 6 | Word-wrap toggle                       | `EditorView.lineWrapping` in Compartment             | New `setWordWrap(bool)` bridge; menu item                       | S       | none              |   1   |
| 7 | Active-line highlight                  | `highlightActiveLine()` (already on)                  | n/a — already enabled                                            | 0       | —                 |   0   |
| 8 | Bracket matching                       | `bracketMatching()` (already on)                      | n/a                                                              | 0       | —                 |   0   |
| 9 | Code folding (markdown headings, JS)   | `foldGutter()` (already on); per-language fold service | Menu items "Fold All / Unfold All"                              | S       | —                 |   1   |
|10 | Multi-cursor (cmd-click, alt-drag)     | Built-in to `@codemirror/view`                        | None — works out of box; manual-test row                         | 0       | —                 |   0   |
|11 | Inline indent guides                    | Community pkg (no official one)                       | Skip; punt to Phase 4+                                           | M       | bundle audit      |   4   |
|12 | Find / Replace using CM6 panel         | `searchKeymap` (already on)                           | Currently works; menu wiring + replace                          | S       | bridge v1         |   1   |
|13 | Find / Replace bridged to MarkdownFindBar | `findNext`/`findPrev`/`replaceNext`/`replaceAll` JS API | Swift-side FindBar drives JS; receives match index/count        | M       | bridge v1         |   2   |
|14 | Vim mode (opt-in)                      | `@replit/codemirror-vim`                              | Compartment swap; setting toggle                                 | M       | Phase 4 bundle eval |  4   |
|15 | Inline diagnostics squiggles           | `@codemirror/lint` linter source from LSP            | New `setDiagnostics` bridge fed from `LSPDiagnosticsStore`       | M       | LSP phase E       |   2   |
|16 | Lint gutter markers                    | `lintGutter()`                                        | Same `setDiagnostics`                                            | S       | feature 15        |   2   |
|17 | Hover popover via LSP                  | `hoverTooltip(...)` (CM6 built-in) OR `@codemirror/lsp-client` | New `requestHover(pos)` round-trip; renders LSP markup       | M       | bridge v1, LSP    |   3   |
|18 | Go-to-definition                       | Custom `domEventHandlers` for ⌘-click                 | New bridge `requestDefinition(pos)` → returns `[Location]`; opens via `DocumentController.openTab` | M | bridge v1, LSP | 3   |
|19 | References panel from editor selection | Custom keybinding + bridge call                       | Reuse Phase B references panel from LSP roadmap                  | S       | LSP refs panel    |   3   |
|20 | Autocompletion via LSP                 | `@codemirror/autocomplete` + custom `CompletionSource` calling LSP | Decision: **defer**; viewer mandate currently rejects     | L       | scope expansion   |   X   |
|21 | Folding via LSP `foldingRange`         | Custom `foldService.of(...)` extension                | New `requestFoldingRanges(uri)` bridge                           | M       | LSP method add    |   4   |
|22 | Symbol outline (already Swift-side)    | `view.state.selection.main.head` → notify Swift on caret move | `cursorPositionChanged` drives outline "current symbol" highlight | S    | feature 5         |   2   |
|23 | Per-tab editor state (preserve across switch) | `view.state` snapshot + restore via `setState` | New `getStateSnapshot` / `setStateSnapshot` bridge calls         | M       | bridge v1         |   3   |
|24 | Shared WebView for multiple tabs (perf) | One `EditorView` per WebView, swap state on tab switch  | Refactor `CodeMirrorEditorView` from one-WebView-per-tab to shared single WebView + state map | L | feature 23 | 4   |
|25 | Theme sync — richer SyntaxTheme bridge | Custom `HighlightStyle` derived from our SyntaxTheme  | Map our `SyntaxTheme.colors` → CM6 `HighlightStyle.define([...])` | M    | none              |   3   |
|26 | Font size sync                         | Already wired via inline `<style>` swap               | Already works; cleanup: move into a Compartmented theme         | 1l      | —                 |   1   |
|27 | Save-on-blur                           | DOM `blur` event in ViewPlugin                        | New `editorBlurred` bridge; Swift decides if dirty + autosave   | S       | bridge v1         |   3   |
|28 | Save-on-window-close                   | n/a — purely Swift-side `windowWillClose`             | Already partially wired                                          | S       | —                 |   1   |
|29 | Undo across mode switches (source↔editor) | n/a — would require merging NSTextView undo + CM6 history | Decision: **don't unify**; document that switching mode forks undo stacks | L | scope            |   X   |
|30 | Diff view / Git blame integration      | `Decoration.line` + gutter widgets                    | New `setBlame` / `setDiffMarkers` bridge calls                  | L       | Git panel hookup  |   4   |
|31 | Search-in-folder (cross-file) tie-in   | n/a — Swift owns this                                 | Open the result tab in editor mode + `gotoLine` + select         | S       | feature 32        |   2   |
|32 | Go-to-line                             | `view.dispatch({selection, effects: scrollIntoView})` | New `gotoLine(n)` bridge; menu item                              | S       | bridge v1         |   1   |
|33 | Show invisible chars                    | `EditorView.contentAttributes` + custom CSS         | New `setShowInvisibles` bridge; toggled menu                    | M       | bridge v1         |   3   |
|34 | Indent settings (tabs/spaces, size)    | `EditorState.tabSize.of(n)` + `indentUnit.of(...)`    | New `setIndentation` bridge; per-file detection later           | S       | bridge v1         |   1   |
|35 | Read-only toggle                       | `EditorView.editable.of(false)`                       | New `setReadOnly` bridge; already partial via `setEditable`     | 1l      | bridge v1         |   1   |
|36 | Snippets                               | `@codemirror/autocomplete` snippet API                | Out of scope (viewer mandate)                                    | —       | —                 |   X   |
|37 | Settings UI for editor (font/theme/etc.)| n/a — pure Swift                                     | New SettingsView section; bridges every dial via Compartment    | M       | features 1, 6, 26, 33, 34 | 2 |
|38 | Symbol-outline-drives-editor-jump      | `gotoLine` + scroll + select range                    | Wire outline → `setSelection` bridge                             | S       | feature 32        |   2   |

Total **new** complexity to ship Phase 1 = roughly 12 small + a few
medium items. Phase 2 layers on Find-bar bridge + diagnostics +
settings. Phase 3 is the LSP-in-editor work + theme.

---

## 13. Bridge protocol v1 — exhaustive spec

### 13.1 Goals

- **Versioned.** Every message has `v` (currently `1`). Bumping
  to `2` is a flag day; old + new run side-by-side during
  rollout via a "supported version" handshake.
- **Typed.** Swift side has a single `CodeMirrorBridge` Codable-
  ish enum (or Swift `enum` + `Codable` if we're feeling fancy)
  per direction. Today's `CodeMirrorBridge.Action` enum grows.
- **Reply-able.** Some Swift→JS calls want a return value
  (`getDocument`, `requestHover`). We add a `replyId` field for
  request/response pairs.
- **Forward-compatible.** Unknown message types are ignored
  (already the behavior in `CodeMirrorBridge.decode`).

### 13.2 Envelope

```jsonc
{
  "v": 1,
  "type": "<message-name>",
  "replyId": "abc-123",   // optional; present for requests + responses
  "...payload...": ...
}
```

`replyId` is a string (UUID4 or monotonic counter). When Swift
sends `{type: "getDocument", replyId: "r1"}`, JS replies with
`{type: "getDocumentReply", replyId: "r1", text: "..."}`.

### 13.3 Editor → Swift messages

| `type`                  | Payload                                                                 | Sent on…                                                       | Cardinality                                  |
|-------------------------|-------------------------------------------------------------------------|----------------------------------------------------------------|----------------------------------------------|
| `ready`                 | `{}`                                                                    | After `EditorView` constructed                                  | Once per webview load                        |
| `change`                | `{text: string, version: int, contentLength: int}`                      | 200 ms after last edit (existing debounce)                      | Many                                         |
| `incrementalChange`     | `{ranges: [{from, to, insert}], version: int}`                          | Future (Phase 3+); same debounce window                         | Many — replaces `change` if both supported  |
| `save`                  | `{}` (was `saveRequested`)                                              | User hits `Mod-s`; sent immediately after a flushed `change`    | Per `Mod-s` press                            |
| `cursorPositionChanged` | `{line: int, column: int, head: int, ranges: int}`                      | `updateListener` with `selectionSet` true; debounced ~50 ms      | Many                                         |
| `selectionChanged`      | `{selection: SelectionJSON, hasSelection: bool}`                        | `updateListener` with `selectionSet` true; same debounce         | Many                                         |
| `scrollChanged`         | `{top: int, left: int, viewportFromLine: int, viewportToLine: int}`     | `scroll` event on `view.scrollDOM`; debounced ~100 ms            | Many                                         |
| `findOpened`            | `{query: string}`                                                       | CM search panel opens                                            | Per open                                     |
| `findClosed`            | `{}`                                                                    | CM search panel closes                                           | Per close                                    |
| `findResultChanged`     | `{matches: int, current: int}`                                          | After a find action                                              | Per find step                                |
| `linkClicked`           | `{href: string, line: int, column: int}`                                | Click on a CM-decorated link (markdown / autolink)               | Per click                                    |
| `editorBlurred`         | `{}`                                                                    | Editor DOM loses focus                                           | Per blur                                     |
| `errorOccurred`         | `{phase: string, message: string, stack?: string}`                       | Uncaught JS errors during a bridge handler                        | Per error                                    |
| `requestReply`          | `{replyId: string, value: any}`                                          | Reply to a Swift `request` call (e.g. `getDocument`)              | Per request                                  |
| `lspDispatchRequest`    | `{replyId: string, method: string, params: any}` (only when CM6 internal LSP client is used) | Future — if we ever adopt `@codemirror/lsp-client`             | n/a today                                    |

`version` is a monotonic doc version owned by JS; bumps on every
applied transaction with `docChanged`. Swift mirrors it to
detect out-of-order responses (we discard responses whose
version is older than the current doc).

### 13.4 Swift → Editor messages

| `type`               | Payload                                                                 | Reply?                  | Effect                                                                  |
|----------------------|-------------------------------------------------------------------------|-------------------------|-------------------------------------------------------------------------|
| `setText`            | `{text: string, resetHistory: bool, preserveSelection: bool}`            | none                    | Replace doc. `resetHistory: true` → `view.setState`; otherwise `dispatch` with `Transaction.addToHistory.of(!source.isUser)` |
| `appendText`         | `{text: string}`                                                         | none                    | Append at doc end; for log-tail mode (future)                            |
| `replaceRange`       | `{from: int, to: int, insert: string, version: int}`                     | none                    | Targeted edit; respects `version` (drop if stale)                       |
| `setLanguage`        | `{lang: string}`                                                         | none                    | `langCompartment.reconfigure(languageFor(lang))`                        |
| `setTheme`           | `{name: "light"|"dark", syntaxTheme?: HighlightStyleJSON}`               | none                    | Theme compartment swap; optional richer syntax theme                     |
| `setFontSize`        | `{px: number}`                                                           | none                    | Existing inline `<style>` swap                                           |
| `setWordWrap`        | `{enabled: bool}`                                                        | none                    | Wrap compartment swap                                                    |
| `setReadOnly`        | `{enabled: bool}`                                                        | none                    | `editableCompartment.reconfigure(EditorView.editable.of(!enabled))`     |
| `setLineNumbers`     | `{enabled: bool}`                                                        | none                    | Gutter compartment swap                                                  |
| `setShowInvisibles`  | `{enabled: bool}`                                                        | none                    | Custom decoration plugin toggled                                         |
| `setIndentation`     | `{useTabs: bool, size: int}`                                             | none                    | `tabSize.of(size)` + `indentUnit.of(useTabs ? "\t" : " ".repeat(size))`  |
| `gotoLine`           | `{line: int, column?: int, select?: bool}`                               | none                    | Dispatch a selection-set + `scrollIntoView` effect                        |
| `setSelection`       | `{anchor: int, head: int, scroll: bool}`                                 | none                    | Dispatch selection-set; optional scroll                                  |
| `openSearch`         | `{query?: string, replace?: bool}`                                       | none                    | `openSearchPanel(view)`                                                  |
| `closeSearch`        | `{}`                                                                     | none                    | `closeSearchPanel(view)`                                                 |
| `findNext`           | `{}`                                                                     | none                    | Programmatic                                                              |
| `findPrev`           | `{}`                                                                     | none                    | Programmatic                                                              |
| `replaceNext`        | `{}`                                                                     | none                    | Programmatic                                                              |
| `replaceAll`         | `{}`                                                                     | none                    | Programmatic                                                              |
| `setDiagnostics`     | `{diagnostics: [{from, to, severity, message, source?, code?}]}`         | none                    | Dispatched as a StateEffect to a `diagField`                            |
| `requestCompletion`  | `{pos: int}`                                                             | n/a                     | Future                                                                   |
| `undo`               | `{}`                                                                     | none                    | `undo(view)`                                                              |
| `redo`               | `{}`                                                                     | none                    | `redo(view)`                                                              |
| `focus`              | `{}`                                                                     | none                    | `view.focus()`                                                            |
| `flushChanges`       | `{}`                                                                     | none                    | Force-emit the debounced change (existing)                               |
| `getDocument`        | `{replyId: string}`                                                      | yes — `requestReply`    | `view.state.doc.toString()` returned                                     |
| `getSelection`       | `{replyId: string}`                                                      | yes                     | `view.state.selection.toJSON()` returned                                 |
| `getScrollPosition`  | `{replyId: string}`                                                      | yes                     | `{top, left}` of `view.scrollDOM`                                        |
| `getStateSnapshot`   | `{replyId: string}`                                                      | yes                     | `view.state.toJSON({history: historyField, ...})`                        |
| `setStateSnapshot`   | `{snapshot: StateJSON}`                                                  | none                    | `EditorState.fromJSON(snapshot, ...)` + `view.setState`                  |

### 13.5 Concrete JSON shapes

**Change emit (today + post-v1)**

```jsonc
{ "v": 1, "type": "change",
  "text": "# Heading\n...",
  "version": 42,
  "contentLength": 9 }
```

**Cursor position**

```jsonc
{ "v": 1, "type": "cursorPositionChanged",
  "line": 12, "column": 4,
  "head": 138, "ranges": 1 }
```

**Set diagnostics (Swift → JS, drives squiggles)**

```jsonc
{ "v": 1, "type": "setDiagnostics",
  "diagnostics": [
    { "from": 120, "to": 134, "severity": "error",
      "message": "use of undeclared identifier 'foo'",
      "source": "sourcekit-lsp", "code": "1234" }
  ] }
```

JS side translates `from/to` to `Diagnostic` records and feeds
them into a `setDiagsEffect` dispatched on the `diagField`
StateField (§4.4).

**Goto line**

```jsonc
{ "v": 1, "type": "gotoLine", "line": 42, "column": 0, "select": false }
```

**Request → reply (getDocument)**

Swift sends:
```jsonc
{ "v": 1, "type": "getDocument", "replyId": "r-7af3" }
```
JS replies:
```jsonc
{ "v": 1, "type": "requestReply",
  "replyId": "r-7af3",
  "value": { "text": "the full doc", "version": 42 } }
```

### 13.6 Versioning policy

- **v1 = the spec above.** Land it as one change. JS broadcasts
  `{type: "ready", v: 1}`; Swift refuses to communicate if v
  isn't 1 (logs error, falls back to legacy "untyped" mode for
  one more cycle, then errors hard).
- **v2 evolution** — when we add `incrementalChange`, the
  protocol gets `v: 2`. Both versions remain in the JS bundle
  for one cycle; Swift can request `setProtocolVersion(2)` on
  startup. Removed messages stay decodable as `unknown` and are
  dropped (no throw).
- **Unknown types** (Swift→JS): JS logs `console.warn` + posts
  `{type: "errorOccurred", phase: "dispatch", message: "unknown
  swift→js type 'X'"}`. Swift surfaces in dev mode only.

### 13.7 Swift-side decoder shape

```swift
public enum CMInbound {
    case ready(version: Int)
    case change(text: String, version: Int, contentLength: Int)
    case incrementalChange(ranges: [CMRange], version: Int)
    case save
    case cursorPositionChanged(line: Int, column: Int, head: Int, ranges: Int)
    case selectionChanged(selection: CMSelection, hasSelection: Bool)
    case scrollChanged(top: Int, left: Int, viewportFromLine: Int, viewportToLine: Int)
    case findOpened(query: String)
    case findClosed
    case findResultChanged(matches: Int, current: Int)
    case linkClicked(href: String, line: Int, column: Int)
    case editorBlurred
    case errorOccurred(phase: String, message: String, stack: String?)
    case requestReply(replyId: String, value: Data)  // raw JSON for typed re-decode
}
```

…with a single `CodeMirrorBridge.decode(_ body: Any) -> CMInbound?`
matching today's pattern. Keep the pure-logic enum in
`ViewerCore` (or a sibling pure module) so the existing
`CodeMirrorBridgeTests` extends naturally and runs on host
without launching WKWebView.

### 13.8 Swift-side encoder shape

```swift
public enum CMOutbound {
    case setText(text: String, resetHistory: Bool, preserveSelection: Bool)
    case appendText(text: String)
    case replaceRange(from: Int, to: Int, insert: String, version: Int)
    case setLanguage(String)
    case setTheme(name: String, syntaxTheme: CMHighlightStyleJSON?)
    case setFontSize(Int)
    case setWordWrap(Bool)
    case setReadOnly(Bool)
    case setLineNumbers(Bool)
    case setShowInvisibles(Bool)
    case setIndentation(useTabs: Bool, size: Int)
    case gotoLine(line: Int, column: Int?, select: Bool)
    case setSelection(anchor: Int, head: Int, scroll: Bool)
    case openSearch(query: String?, replace: Bool)
    case closeSearch
    case findNext, findPrev, replaceNext, replaceAll
    case setDiagnostics([CMDiagnostic])
    case undo, redo, focus, flushChanges
    case getDocument(replyId: String)
    case getSelection(replyId: String)
    case getScrollPosition(replyId: String)
    case getStateSnapshot(replyId: String)
    case setStateSnapshot(Data)
}
```

Encoder is a tiny `Codable`-driven JSON serializer; pass to
`webView.evaluateJavaScript("window.cmDispatch(\(json))")`
exactly once per message. JS-side dispatcher is:

```js
window.cmDispatch = function (msg) {
  if (msg.v !== 1) { return; }
  switch (msg.type) {
    case "setText":         applySetText(msg); break;
    case "setDiagnostics":  applyDiagnostics(msg); break;
    /* ... */
  }
};
```

One global entry point, one switch — easier to keep in sync than
a dozen `window.X` functions.

---

## 14. Swift-side state management

### 14.1 The data flow

```
   ┌─────────────────┐     setText / setSelection      ┌─────────────────┐
   │ DocumentModel   │ ──────────────────────────────► │ CodeMirrorView  │
   │  ├─ Tab[]       │                                 │   Coordinator   │
   │  ├─ activeTabID │ ◄────────────────────────────── │                 │
   │  └─ savedScroll │      change / cursor / find     └────────┬────────┘
   └────────┬────────┘                                          │
            │ buffer per tab                                    │ evaluateJavaScript
            ▼                                                   ▼
   ┌─────────────────┐                                 ┌─────────────────┐
   │ EditorBuffer    │                                 │     CM6 JS      │
   │  ├─ text        │                                 │ (window.cm*)    │
   │  ├─ originalText│◄─── markSaved on disk write ────│                 │
   │  ├─ lastSavedMT │                                 │ updateListener  │
   │  └─ isDirty     │                                 │  → post(change) │
   └────────┬────────┘                                 └─────────────────┘
            │                                                   ▲
            │ saveActiveEditor                                  │
            ▼                                                   │
   ┌─────────────────┐                                          │
   │ EditorWriter    │ ──── atomic write → mtime/size ──────────┘
   │ .save(text,url) │
   └─────────────────┘
            │
            │ FileWatcher fires (mtime change)
            ▼
   ┌─────────────────┐
   │ Conflict prompt │ ──── user picks: discard buf / keep buf / merge
   │ (existing UI)   │
   └─────────────────┘
```

### 14.2 The state-vs-debounce question

CM6 is the source of truth for the *live* doc. EditorBuffer is
the source of truth for *what's-on-disk-and-is-it-dirty*. The
200 ms debounce means **EditorBuffer.text lags CM6 by ≤ 200 ms**.
Implications:

- **Save flow**: Swift menu ⌘S → JS `flushChanges()` →
  immediate `change` posted → Swift updates EditorBuffer →
  EditorWriter.save → markSaved. We already do this correctly.
- **Quit flow**: Swift `applicationShouldTerminate` →
  bridge.flushChanges (async!) → wait for `change` reply →
  decide. Must use a synchronous-ish helper. Current code
  fires-and-forgets; needs a tiny `await` shim.
- **External-edit during typing**: file watcher fires while user
  is mid-edit. Today's flow shows the conflict prompt
  immediately. With v1 protocol we want the prompt to fire only
  after the next debounced `change` post (or via explicit
  flush). Tiny addition.

### 14.3 Per-tab state — single-WebView future (feature #24)

When/if we move to a single shared WebView (Phase 4), tab
switches become `view.setState(savedSnapshot[tabId])`. The
DocumentModel stores per-tab `EditorState` snapshots (JSON
blobs) keyed by tab ID. **Cheap** — a 100 KB doc's state JSON is
~120 KB. We can keep all open tabs hot in memory; only swap on
visible-tab change.

The risk: a single WebView shares the JS heap across tabs.
Today's "one WebView per tab" partitions failure modes. The
shared-WebView win is ~50 MB per saved tab (WebContent process
memory) — significant when you have 20+ tabs open.

---

## 15. Performance plan

### 15.1 The bridge is the hot path

WKScriptMessageHandler IPC: ~3-5 ms round-trip on macOS [17].
JSContext init is the dominant cost. Implications:

- **Never fire a bridge message per keystroke.** Debounce
  `change` (200 ms — already there). Debounce `cursorPosition`
  (~50 ms — proposed). Debounce `scroll` (~100 ms).
- **Batch multi-call sequences** into one `evaluateJavaScript`.
  Instead of 5 `webView.evaluateJavaScript("X()");
  evaluateJavaScript("Y()"); ...`, ship one
  `evaluateJavaScript("X();Y();Z();...")`. Halves the IPC tax.
  The `cmDispatch` design (§13.8) makes this natural.
- **Prefer postMessage over evaluateJavaScript** when the
  message is JS→Swift only (already the case for `change`).

### 15.2 Doc-string allocation

`view.state.doc.toString()` allocates the whole string. On a
10 MB doc, that's a ~10 MB JS string per emit + a ~10 MB Swift
String when WK marshals it across. Two paths:

1. **Today**: debounce + accept the cost. 200 ms × 10 MB ≈ 50
   MB/s of allocations in the WebView process — fine for short
   editing sessions, gross for long ones.
2. **Future (v2)**: ship incremental `{from, to, insert}` triples
   per debounce window. Mirror what
   `@codemirror/lsp-client` does internally for `didChange`.
   Swift applies them to an `EditorBuffer.applyChanges(...)`
   helper. Eliminates the full-doc cost from the hot path.

### 15.3 Avoid layout thrash

- Don't `getBoundingClientRect` from inside `updateListener` —
  use `view.requestMeasure`.
- Don't call `setFontSize` per-keystroke (currently we don't,
  but the temptation will exist with a settings UI).
- When wholesale-replacing the doc, prefer `view.setState` over
  `dispatch` with a huge `changes` (less DOM patch work).

### 15.4 Memory ceiling per tab

| Component                     | Cost                              |
|-------------------------------|-----------------------------------|
| WebContent process (cold)     | ~50–80 MB                         |
| CM6 EditorState (1 MB doc)    | ~5–10 MB JS heap                  |
| EditorBuffer (Swift)          | ~2× the doc string (orig + live)  |
| LSP server (when active)      | per-language; 100 MB–1 GB         |
| Document.toString lag string  | transient, freed per debounce     |

10 open tabs × per-WebView ≈ 700 MB resident for the WebContent
processes alone. **This is the case for feature #24 (shared
WebView).** Defer until 5+ tabs is a common workflow.

### 15.5 Startup latency

Current: ~50 ms from `WKWebView` creation to `ready` post on
M1. Most of that is JS parse of the 572 KB bundle. Mitigations
if we feel it:

- Pre-warm a WebContent process at app launch (we already share
  the process pool).
- Skip bundling languages the user has never opened
  (lazy-import). Saves ~200 KB but adds complexity.

---

## 16. Testing strategy

Per CLAUDE.md: pure-logic tests on host; UI tests on the VM.

### 16.1 Pure-logic tests (host-safe, in `ViewerCoreTests` / `ViewerKitTests`)

- **`CodeMirrorBridgeTests`** (existing) — extend with the v1
  envelope: `decode` returns nil for missing `v`, returns nil
  for `v != 1`, returns the right case for each `type`, ignores
  unknown `type`.
- **`CMOutboundEncodingTests`** — round-trip every Swift→JS
  message through JSON and back, asserting we produce valid
  JSON5 that a tiny JS-side decoder fixture would parse.
- **`EditorBufferConflictTests`** (extend) — verify
  `hasExternalEdit` interplays correctly with mid-debounce
  states (mtime updated after last `change` post).
- **`CMDiagnosticMappingTests`** — Swift `LSPDiagnostic` →
  bridge `CMDiagnostic` (from/to position conversion via
  `LSPPositionConverter`).
- **`CMScrollSnapshotTests`** — JSON round-trip for the per-tab
  scroll + selection records.

### 16.2 VM live-WebView tests

Per CLAUDE.md, only on macOS15 VM via `rsync` + `swift test`.

- **`CodeMirrorReadyTests`** — open editor, await `ready`,
  assert `setText` round-trips via `getDocument`.
- **`CodeMirrorFindTests`** — scripted: open search panel,
  type query, find next, assert highlighted position.
- **`CodeMirrorBigDocTests`** — load a 10 MB markdown, assert
  first paint < 1 s and edit-latency < 50 ms.
- **`CodeMirrorVimSmokeTest`** (when vim mode lands) — assert
  `h`/`j`/`k`/`l` motions work; specifically pin the four bugs
  from §6.4 so we notice when they're fixed.
- **`CodeMirrorImeTest`** — scripted IME composition via
  `NSTextInputClient` proxy (challenging; may be a manual-test
  row instead).
- **`CodeMirrorSelectionPersistenceTest`** — close tab, reopen
  same URL, assert selection + scroll restored.

### 16.3 Scripted scenarios

A new helper `Tests/ViewerUITests/CMScript.swift` that exposes a
high-level `EditorScript` — drives the WebView via the
bridge: `script.openDocument(url)`, `script.type("hello")`,
`script.assertDocEquals(expected)`. Pattern matches the
existing `Tests/ViewerUITests/ScenarioRunner.swift` style.

### 16.4 Bundle integrity

Already in `CodeMirrorBundleTests` (host). Extend with:

- Assert the bundle exports `cmDispatch` after v1 lands.
- Assert the bundle posts `{v: 1, type: "ready"}` (parse the
  HTML string).
- Assert the bundle size hasn't ballooned past a threshold
  (e.g. 1.5 MB) — guardrail against accidentally checking in a
  non-minified build.

---

## 17. Risks & open questions

### 17.1 LSP-through-bridge latency

We have a Swift-side LSP pool with hover round-trips of ~50-200
ms on small docs. Going through the bridge adds 2× IPC round-
trips (~10 ms). Total ~210 ms — at the edge of "feels
responsive". **Open**: measure before committing the hover UX.
Fall-back: hover dwell timer goes from 300 ms to 500 ms.

### 17.2 Should we use `@codemirror/lsp-client` instead of our own pool?

Arguments **for** the official client:

- Marijn-maintained.
- Built-in handling for hover / diagnostics / completion /
  references with correct CM6 integration (tooltip placement,
  decoration remapping, etc.).
- Position-encoding-aware.
- One less Swift-side surface.

Arguments **against**:

- It runs LSP **in JS**, meaning transport must be JS-side.
  We'd have to either: (a) push our Swift-side
  sourcekit-lsp child's stdio through the bridge (silly
  marshalling), or (b) start a TCP/WebSocket-based LSP transport
  the JS can connect to.
- Our existing LSP machinery (~10 files, ~3k lines, fully
  tested) becomes a parallel path that has to stay in sync.
- Bundle delta: ~75 KB added.

**Recommendation**: stick with Swift-side LSP. Use the bridge
to push diagnostics + receive hover/definition requests. The
JS side only needs to render decorations — no LSP transport
inside the WebView. Document this decision so future-us doesn't
re-litigate.

### 17.3 Vim mode community plugin trust

`@replit/codemirror-vim` is MIT, actively maintained by Replit.
Reasonable trust. Known bug list (§6.4) is concrete. **Open**:
do we run `npm audit` on every bump? Yes — add to BUILD.md.

### 17.4 Single shared WebView (feature #24)

Big refactor of `CodeMirrorEditorView`. Today's
`NSViewRepresentable` cardinality is one-view-per-Tab. To
switch, the SwiftUI view becomes a thin slot that references a
singleton `CodeMirrorHost` actor (which owns the WebView and
the per-tab state map). **Open**: does this break SwiftUI's
diffing? Need a prototype before committing.

### 17.5 What about file > 100 MB?

Per §9, CM6 starts to feel pressure above 100 MB. Today we
already silently skip CM6 for "huge" files in some paths.
**Open**: explicit cap? Suggest 50 MB hard cap for CM6 mode,
fall back to a read-only NSTextView. The user gets degraded
edit but doesn't get a hung WebContent process.

### 17.6 Format-on-save?

Some LSP servers offer formatting. We currently reject
formatting per viewer mandate, but with editor mode landed,
this rejection is worth re-examining. **Open**: ship behind a
per-language opt-in flag if at all.

### 17.7 Per-language indent detection

Today we set `tabSize` once. Real workflows have mixed tab/space
docs. **Open**: auto-detect on `setText` (sniff first N
indented lines)? Defer to Phase 4.

---

## 18. Phased roadmap

Five phases. Each lists deliverables, rough effort, and the gate
that opens the next.

### Phase 1 — Protocol v1 + foundational UX (target ~1 week)

Goal: replace the implicit untyped bridge with the v1 spec, add
the things we should've shipped on day one.

Deliverables:

- Bridge v1 encoder/decoder on both sides (§13).
- `setText` with `resetHistory` flag (§5.3, §5.4).
- Per-tab persistent scroll + selection.
- Cursor position bridge → bottom-bar L:C readout.
- Word-wrap toggle in View menu + Settings.
- `gotoLine` + menu item / keyboard binding.
- Indent settings (tabs/spaces, size) bridge.
- Read-only bridge (already half-wired; tidy).
- Font-size: move to Compartmented theme rather than inline
  `<style>` swap (cleaner; survives across reconfigure).
- Code folding: menu items (Fold All / Unfold All).
- Find / Replace: use built-in CM panel, add Replace menu item.
- File-watcher conflict: verify with v1 protocol; add
  `Transaction.addToHistory.of(false)` on external rewrites.

Tests: extended `CodeMirrorBridgeTests`, new
`CMOutboundEncodingTests`, VM `CodeMirrorReadyTests` +
`CodeMirrorSelectionPersistenceTest`.

**Gate**: bridge v1 ships, all green on VM.

### Phase 2 — Find bar bridged + diagnostics + settings (~1 week)

Goal: integrate the find experience with our SwiftUI find bar
(don't ship two find UIs in the same app), light up LSP
diagnostics as squiggles.

Deliverables:

- SwiftUI `MarkdownFindBar` drives JS find via bridge
  (`findNext`/`findPrev`/`replaceNext`/`replaceAll`).
  CM's built-in panel hidden in editor mode. MarkEdit pattern.
- Match count / current-match readout in find bar.
- `setDiagnostics` bridge wired to `LSPDiagnosticsStore`.
  Squiggles via `@codemirror/lint`.
- Lint gutter markers.
- Symbol outline → caret-follow (uses `cursorPositionChanged`).
- Settings UI section: editor font / theme / word wrap / tab
  size / indent type / line numbers / show invisibles.

Bundle delta: `@codemirror/lint` (~18 KB minified). New total
~590 KB. Inside cap.

**Gate**: diagnostics show on a known-bad Swift file; find bar
behaves identically in source-mode and editor-mode.

### Phase 3 — LSP in editor mode (hover / jump / refs / theme) (~2 weeks)

Goal: bring everything the read-only Source view gets from LSP
into editor mode.

Deliverables:

- `requestHover` bridge round-trip. Render via existing
  `LSPMarkdownRenderer`. NSPopover anchored at
  `view.coordsAtPos(pos)`.
- `requestDefinition` bridge → `[Location]` → multi-result
  picker (matches the LSP-roadmap Phase B picker).
- References from editor selection → existing References panel.
- Per-tab editor state snapshots (preparation for feature #24).
- Theme bridge: ship `HighlightStyle.define([...])` derived
  from our `SyntaxTheme`. Compartmented; can swap at runtime.
- Save-on-blur (opt-in).
- Show invisibles (decoration plugin).

Open question: how do we want `Cmd-click → definition` to
interact with `Cmd-click` on a markdown link? Today the source
view bias is: links win in `.md`, LSP wins in code files. Same
heuristic should work here — language compartment knows what
we're in.

**Gate**: hover popover renders for Swift symbols; ⌘-click on
identifier jumps; refs panel populates from editor selection.

### Phase 4 — Polish + perf + opt-in features (~2 weeks)

Goal: ship the wishlist; address the perf items.

Deliverables:

- Vim mode (opt-in via Settings). Bundle delta +~210 KB →
  total ~826 KB. Inside cap.
- LSP `foldingRange` → CM6 fold service.
- Indent guides (community plugin or hand-rolled). Decide
  based on bundle audit at that point.
- Shared WebView refactor (feature #24) — *conditional on
  prototype validating SwiftUI diffing behavior*.
- Incremental change shipping (`v=2` protocol).
- Diff view / blame markers (gutter widgets).
- Big-file cap (50 MB → read-only NSTextView fallback).

**Gate**: bundle ≤ 1.5 MB, executable still ≤ 16 MB, all VM
smoke tests green.

### Phase 5 — Conditional (~open)

Conditional on Phase 4 outcomes and product direction:

- LSP autocompletion (would lift viewer mandate; needs
  product sign-off).
- Snippet expansion.
- Format-on-save.
- Inline LSP `inlayHint`.
- Semantic tokens.
- Custom CM6 extensions for our markdown specifics (math
  rendering inline, mermaid block previews).

---

## 19. Bundle-growth plan

Strict accounting per phase. Numbers from §10; minified, not
gzipped (we ship minified IIFE in the .app, no transport
compression).

| Phase | Adds                                                       | Bundle Δ |  Total | App total | Exec  |
|------:|------------------------------------------------------------|---------:|-------:|----------:|------:|
|     — | (today)                                                    |    —     | 572 KB |   ~25 MB? |~11 MB |
|     1 | (no new pkgs — pure protocol + Swift)                       |  +~10 KB | 582 KB |    +~0 MB |+0     |
|     2 | `@codemirror/lint`                                          |  +~18 KB | 600 KB |    +~0 MB |+0     |
|     3 | (no new pkgs — pipes existing LSP data)                     |  +~15 KB | 615 KB |    +~0 MB |+0     |
|     4 | `@replit/codemirror-vim` (opt-in still bundled)            | +~210 KB | 825 KB |   +~0.2MB |+0     |
|     4 | + `@codemirror/lang-html`, `lang-css`, `lang-xml`           | +~120 KB | 945 KB |   +~0.1MB |+0     |
|     4 | + `@codemirror/lang-rust`, `lang-cpp`, `lang-sql`            | +~250 KB | 1.20MB |   +~0.2MB |+0     |
|     5 | + `@codemirror/autocomplete` (if approved)                  |  +~38 KB | 1.24MB |    +~0 MB |+0     |

We don't hit the 37 MB app cap on the JS side any time soon.
**The binding constraint is the bundle parse time**, not size —
1.5 MB of JS is ~80 ms to parse on M1. If parse time becomes
visible, switch to lazy-import per language (Phase 4+).

Each PR that touches `scripts/codemirror-build/package.json`
must:

1. List the package + the minified size delta.
2. Run `swift test --filter CodeMirrorBundleTests` (host).
3. Update the table in BUILD.md.

---

## 20. MarkEdit reference patterns

MarkEdit is the precedent we should mine hardest. MIT, actively
maintained, the same problem space.

### 20.1 Top-level layout to copy

```
MarkEdit (repo)                            TextView analog
─────────────────                          ───────────────
CoreEditor/                       ←→   Sources/ViewerUI/Resources/codemirror/
  src/                                 + scripts/codemirror-build/
    api/                                  (we don't have an analog yet;
    bridge/  ┐                             api/ + bridge/ split is what
      native/│ ts-gyb-generated typed       our v1 protocol design becomes)
      web/   ┘ message shapes
    common/
    config.ts
    core.ts
    extensions.ts
    modules/
    styling/
  test/
  package.json   (yarn-based)
  vite.config.mts (we use esbuild instead — fine)

MarkEditCore/                     ←→   Sources/ViewerCore/EditorBuffer.swift
                                         (and the pure-logic bridge enum)

MarkEditKit/                       ←→   Sources/ViewerCore/* (LSP, watchers,
                                         workspace state, etc.)

MarkEditMac/                       ←→   Sources/ViewerUI/* + main app
  Sources/Editor/Controllers/             (EditorViewController split into
    EditorViewController.swift            ~20 +Feature.swift extensions
    EditorViewController+Completion.swift     is the pattern we copy)
    EditorViewController+TextFinder.swift
    EditorViewController+GotoLine.swift
    EditorViewController+HyperLink.swift
    ...
```

### 20.2 Specific patterns to borrow

**Bridge IDL generated from TypeScript** (their `ts-gyb` setup):
they define a TS interface, codegen produces both the JS-side
type and the Swift-side struct. We don't have to adopt ts-gyb
now, but designing v1 with codegen in mind (single source of
truth = a JSON Schema or a TS interface) means we can adopt
later without re-architecting. **Action**: in BUILD.md, sketch
where a `bridge.d.ts` would live.

**Per-feature Swift extension** (`EditorViewController+X.swift`):
each feature gets one Swift file containing the menu item, the
bridge call, the Swift state. Hugely easier to navigate than
a 2000-line `EditorViewController.swift`. **Action**: when we
add features in Phase 1, split `CodeMirrorEditorView.swift`
along similar lines as it grows past ~500 lines.

**Find bar bridged to native**: confirmed via
`EditorViewController+TextFinder.swift` — they have a
`bridge.search.updateQuery(options:)` + `findNext` / `findPrev`
JS API, drive from a native AppKit panel, and sync with the
system find pasteboard. This is exactly the design for our
Phase 2 (§13.4, feature #13).

**`api/` directory** for the public surface the bridge exposes
to native (their `setText`, `getText`, etc.) — separate from
`modules/` (the internal CM6 wiring). Useful split because the
"public API" is the contract you don't break; "modules" are
implementation details.

**`@vendor` / `@light` / `@codegen` aliases**: TypeScript
import-aliases for vendored code, light-build resources, and
generated code. Makes the source tree self-documenting. We can
mirror with esbuild `--alias` flags or just discipline the
folder names.

### 20.3 Things to *not* borrow

- **Their build is yarn + vite**; we're npm + esbuild and that's
  fine. esbuild is faster and smaller; vite's HMR doesn't
  matter for our build-once-vendor flow.
- **ts-gyb itself** until we feel the pain. Right now hand-
  rolling the v1 spec is cheaper than learning ts-gyb.
- **Their `pandoc` integration** (`EditorViewController+Pandoc.swift`) —
  out of our scope; we ship a different markdown pipeline.

### 20.4 Anti-patterns flagged in their issue tracker

(General observation, not pulled per-issue) — MarkEdit's
WKWebView focus drift bugs (e.g. clicking outside the editor
leaves caret blinking but no keystrokes registering) are the
class of bugs we'll inherit. Mitigation: explicit `focus`
bridge call on tab-switch + visibility-change.

---

# Appendices

## Appendix A — Executive summary

This doc covers ~1300 lines of CM6 deep-study + integration
design for TextView. Headline answers:

- **Top 5 features to ship next**, in order:
  1. **Bridge protocol v1** — versioned envelope, request/reply,
     12 new message types. Foundation for everything else.
     (Phase 1, ~3 days.)
  2. **Per-tab scroll + selection persistence** — biggest UX
     win for low cost; falls out of v1 trivially.
  3. **`setText` with `resetHistory` flag** — fixes the known
     "open file, then ⌘Z back to nothing" bug.
  4. **Find-bar bridged** — single find experience across
     source + editor mode. Mirrors MarkEdit's pattern.
  5. **Inline LSP diagnostics squiggles** — feeds existing
     `LSPDiagnosticsStore` (Phase E of LSP roadmap) directly
     into CM6 via `@codemirror/lint`.
- **No deal-breakers found.** All known CM6 pain points (IME,
  vim, accessibility, large-file edges, set-text/undo)
  have documented workarounds and are inside our risk tolerance.
- **Recommend bridge-protocol v1 as designed in §13** — typed,
  versioned envelope; request/reply via `replyId`; one global
  `cmDispatch` entry point; pure-logic encode/decode enums on
  the Swift side so existing test patterns apply.
- **Long-term watch items**: per-keystroke IPC cost (mitigated
  by debouncing today, eliminated by incremental change
  shipping in v2 protocol), bundle parse time at 1.5 MB
  threshold (Phase 4+), shared-WebView refactor (Phase 4,
  conditional on prototype).

---

## Appendix B — Sources

1. CodeMirror System Guide — `https://codemirror.net/docs/guide/`
2. CodeMirror Reference Manual — `https://codemirror.net/docs/ref/`
3. discuss.codemirror.net: *editor.setHistory(), clearHistory() equivalent in CodeMirror 6* — `https://discuss.codemirror.net/t/editor-sethistory-clearhistory-equivalent-in-codemirror-6/6291`; *Is there a way to customize the undo history list?* — `https://discuss.codemirror.net/t/is-there-a-way-to-customize-the-undo-history-list/7343`; *Restoring history without blowing up extensions state* — `https://discuss.codemirror.net/t/restoring-history-without-blowing-up-extensions-state/6712`
4. CodeMirror Decoration Example — `https://codemirror.net/examples/decoration/`; *atomicRange in codemirror 6* — `https://discuss.codemirror.net/t/atomicrange-in-codemirror-6/6238`; *Conditionally showing Widgets using a StateField* — `https://discuss.codemirror.net/t/conditionally-showing-widgets-using-a-statefield/6020`
5. CodeMirror Bundling Example — `https://codemirror.net/examples/bundle/`; *Bundle size* GitHub issue — `https://github.com/codemirror/dev/issues/760`; *Minimal setup (because by default v6 is +50kb)* — `https://discuss.codemirror.net/t/minimal-setup-because-by-default-v6-is-50kb-compared-to-v5/4514`
6. Bundlephobia for `@codemirror/state` — `https://bundlephobia.com/package/@codemirror/state`; for `@codemirror/view` — `https://bundlephobia.com/package/@codemirror/view`; for `@codemirror/search` — `https://bundlephobia.com/package/@codemirror/search`
7. *Update Compartment from ViewUpdate* — `https://discuss.codemirror.net/t/update-compartment-from-viewupdate/7650`; *Reconfigure doesn't re-run StateField's create* — `https://discuss.codemirror.net/t/reconfigure-doesnt-re-run-statefield-s-create/8548`; *Reconfigure EditorView.baseTheme* — `https://discuss.codemirror.net/t/reconfigure-editorview-basetheme/7276`; *Toggling Extensions* — `https://discuss.codemirror.net/t/toggling-extensions/4667`; *Change Codemirror language* — `https://discuss.codemirror.net/t/change-codemirror-language/7169`
8. CodeMirror Changelog — `https://codemirror.net/docs/changelog/`; *Composition issues in Firefox on Mac with widgets* — `https://discuss.codemirror.net/t/composition-issues-in-firefox-on-mac-with-widgets/5988`; *Clipboard is broken on Mac Catalyst WebView* (issue #977) — `https://github.com/codemirror/dev/issues/977`; *iOS IME causes app/page freeze with line wrapping* (issue #502) — `https://github.com/codemirror/dev/issues/502`; *EditorView compositionend state* (issue #1069) — `https://github.com/codemirror/dev/issues/1069`; *how to listen to changes with IME support* — `https://discuss.codemirror.net/t/how-to-listen-to-changes-with-ime-support/5737`
9. `@replit/codemirror-vim` — `https://github.com/replit/codemirror-vim`; *codemirror-vim issue 196 (`~` then undo enters visual mode)* — `https://github.com/replit/codemirror-vim/issues/196`; *CodeMirror 6 vim mode issues* on Joplin forum — `https://discourse.joplinapp.org/t/codemirror-6-vim-mode-issues/35135`; *Handling IME correctly in Vim command mode* — `https://discuss.codemirror.net/t/handling-ime-input-method-editor-correctly-in-vim-command-mode/8829`; *Vim mode* tracker issue — `https://github.com/codemirror/dev/issues/79`
10. *Accessibility: Screen Readers appear to be unaware of currently selected autocomplete candidate* (issue #1055) — `https://github.com/codemirror/dev/issues/1055`; *Code editor screen reader accessiblity survey* — `https://discuss.codemirror.net/t/code-editor-screen-reader-accessiblity-survey/1790`; *Screen reader response for backspace is flaky* (issue #563) — `https://github.com/codemirror/dev/issues/563`; *Android: Screen reader accessibility: Navigation by lines doesn't navigate by lines* (issue #1556) — `https://github.com/codemirror/dev/issues/1556`
11. CodeMirror Huge Doc Demo — `https://codemirror.net/examples/million/`; *How Does CodeMirror Calculate Line Counts So Quickly?* — `https://discuss.codemirror.net/t/how-does-codemirror-calculate-line-counts-so-quickly/2938`
12. *CM6 Performance Benchmarks* — `https://discuss.codemirror.net/t/cm6-performance-benchmarks/2471`; *Tips for improving codemirror performance* — `https://discuss.codemirror.net/t/tips-for-improving-codemirror-performance/1331`
13. *Content length limit (CodeMirror6)* — `https://discuss.codemirror.net/t/content-length-limit-codemirror6/4183`; *Noticeable lag when dealing with large files* — `https://discuss.codemirror.net/t/noticable-lag-when-dealing-with-large-files/5928`; *Is there an option to limit the number of line on CodeMirror6?* — `https://discuss.codemirror.net/t/is-there-an-option-to-limit-the-number-of-line-on-codemirror6/4000`
14. Marijn Haverbeke's blog — `https://marijnhaverbeke.nl/blog/`
15. MarkEdit repo — `https://github.com/MarkEdit-app/MarkEdit`; CoreEditor/src tree — `https://github.com/MarkEdit-app/MarkEdit/tree/main/CoreEditor/src`; MarkEditMac/Sources/Editor/Controllers — `https://github.com/MarkEdit-app/MarkEdit/tree/main/MarkEditMac/Sources/Editor/Controllers`; `EditorViewController+TextFinder.swift` — `https://github.com/MarkEdit-app/MarkEdit/blob/main/MarkEditMac/Sources/Editor/Controllers/EditorViewController%2BTextFinder.swift`; *Why MarkEdit* — `https://github.com/MarkEdit-app/MarkEdit/wiki/Why-MarkEdit`; Customization wiki — `https://github.com/MarkEdit-app/MarkEdit/wiki/Customization`
16. MarkEdit empirical 10 MB markdown claim (same Why MarkEdit page)
17. *WKWebView Communication Latency* — `https://blog.persistent.info/2015/01/wkwebview-communication-latency.html`; *WKWebView Communication Latency Revisited* — `https://blog.persistent.info/2015/08/wkwebview-communication-latency.html`; Apple Radar 17956460 — `https://openradar.appspot.com/17956460`; WebKit bug 215729 (memory leak in evaluateJavaScript) — `https://bugs.webkit.org/show_bug.cgi?id=215729`
18. `@codemirror/state` source README — `https://github.com/codemirror/state/blob/main/src/README.md`; main repo — `https://github.com/codemirror/state`
19. `@codemirror/lsp-client` repo (archived at GitHub, moved to code.haverbeke.berlin) — `https://github.com/codemirror/lsp-client`; *Announce* thread — `https://discuss.codemirror.net/t/codemirror-lsp-client/9309`; DeepWiki overview — `https://deepwiki.com/codemirror/lsp-client/2-getting-started`
20. Community LSP alternatives: `FurqanSoftware/codemirror-languageserver` — `https://github.com/FurqanSoftware/codemirror-languageserver`; `marimo-team/codemirror-languageserver` — `https://github.com/marimo-team/codemirror-languageserver`; Shopify's client — `https://www.npmjs.com/@shopify/codemirror-language-client`
21. Trevor Harmon, *Learning CodeMirror* — `https://thetrevorharmon.com/blog/learning-codemirror/`; *CodeMirror and React* — `https://thetrevorharmon.com/blog/codemirror-and-react/`
22. DataCamp Engineering, *Getting started with the new CodeMirror 6* — `https://medium.com/datacamp-engineering/codemirror-6-getting-started-7fd08f467ed2`
23. Codiga blog, *Revisiting our CodeMirror 6 implementation in React after the official release* — `https://www.codiga.io/blog/revisiting-codemirror-6-react-implementation/`
24. CodeMirror Configuration Example — `https://codemirror.net/examples/config/`
25. CodeMirror Search example (Evin Owen) — `https://evinowen.medium.com/codemirror-search-84bc73b1b1ee`; Decorations Underline example — `https://evinowen.medium.com/codemirror-decorations-underline-example-dafd4ca4bda6`
26. CodeMirror Undoable Effects Example — `https://codemirror.net/examples/inverted-effect/`
27. WordPress Trac #41872 (CodeMirror accessibility) — `https://core.trac.wordpress.org/ticket/41872`
28. CodeMirror Accessible demo (bgrins) — `https://bgrins.github.io/codemirror-accessible/`

---

*End of document. ~1320 lines.*
