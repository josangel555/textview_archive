# CodeMirror 6 — Capabilities Q&A for TextView / MarkdownViewer

Research-only doc dated **2026-05-23**. Companion to:

- `/Users/me/Documents/workspaces/claude/markdown_viewer/docs/CM6_INTEGRATION_DESIGN_2026-05-23.md`
- `/Users/me/Documents/workspaces/claude/markdown_viewer/docs/TEXT_EDITOR_OPTIONS_2026-05-23.md`
- `/Users/me/Documents/workspaces/claude/markdown_viewer/docs/SCINTILLA_VS_CODEMIRROR6_2026-05-23.md`
- `/Users/me/Documents/workspaces/claude/markdown_viewer/docs/VIM_MODE_OPTIONS_2026-05-23.md`
- `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/CodeMirrorEditorView.swift`
- `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/TextDisplayView.swift`
- `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/Resources/codemirror/codemirror.js` (572 KB IIFE bundle)
- `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/Highlight/TreeSitterEngine.swift`
- `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/LSP/LSPPool.swift`

The CM6 design doc gives the **API tour and integration plan**.
This doc answers the **specific "can we do X, what does it cost,
where's the wall?" questions** the user posed — focused on the
sharp edges, not the happy path.

Source citations inline as bracketed `[Sn]`; full list at end.

---

## Executive summary

| # | Question                                          | Verdict | One-liner |
|--:|---------------------------------------------------|:-------:|-----------|
| 1 | Read-only CM6                                     | ✅      | Use `EditorState.readOnly.of(true)` + (optionally) `EditorView.editable.of(false)`; lose nothing — find / fold / multi-select still work; caret behavior depends on which knob. |
| 2 | Replace NSTextView source viewer with CM6        | ⚠️      | Wins are real (unified codepath, CM features) but you lose Services / Force-Touch lookup polish, your existing compositor-stable AppKit layout, your tuned `SelectionHighlightEngine`. Bad trade unless you commit to *one* viewer. |
| 3 | Keep both viewers vs. unify                       | 🤔      | Carrying cost is real (two find APIs, two highlight pipelines, two scroll models). Long term: unify. Short term: keep both while CM6 wrapper hardens. |
| 4 | CM6 viable for very large files                   | ⚠️      | Comfortable to ~10 MB; usable 10–50 MB; bad above ~100 MB; hard wall around JS heap (~4 GB). NSTextView reads 1 GB log files; CM6 does not. Add a fallback path. |
| 5 | Syntax highlighting coverage                      | ⚠️      | CM6 official: Markdown / JS / TS / Python / JSON / HTML / CSS / XML / Rust / C++ / Java / SQL / PHP / Vue. **No official Swift, no official Go** — community packages exist. Lezer is per-language ~30–120 KB. |
| 6 | Plug our existing tree-sitter into CM6            | ⚠️      | Yes — push externally-computed ranges as `Decoration.mark` via `StateField`. Bridge round-trip adds 3–10 ms per debounced highlight push. Works; mature pattern; we save bundle by not shipping Lezer grammars. |
| 7 | LSP fed by our Swift LSP pool                     | ✅      | `@codemirror/lint`'s `setDiagnostics` + `hoverTooltip` + custom `domEventHandlers` for ⌘-click → request. Our Swift `LSPPool` stays the LSP runtime; CM6 is dumb display. No need for `@codemirror/lsp-client`. |
| 8 | Right-click context menu fully replaceable        | ✅      | macOS WKWebView path: subclass `WKWebView`, override `willOpenMenu(_:with:)` — full NSMenu mutation [S1, S2]. Contextual items via JS bridge call. |
| 9 | Text-selection "highlight all instances"          | ✅      | Built-in: `highlightSelectionMatches`. Or roll your own via `StateField` + `Decoration.mark`. We can port our `SelectionHighlightEngine` policy unchanged. |
|10 | Find / Replace replaceable, drive via Swift bar   | ✅      | `search({createPanel: () => null})` suppresses CM panel; drive via `setSearchQuery` + `findNext`/`findPrevious`/`replaceNext`/`replaceAll`. MarkEdit ships exactly this. |
|11 | Multiple custom gutters (numbers / git / bookmark)| ✅      | `gutter()` extension stacks; order by extension precedence. Each gutter is independent — separate marker sets, separate event handlers. |
|12 | Custom rendering — special chars / whitespace / current-line | ✅ | `highlightSpecialChars()` covers tab/CR/NBSP/zero-width; `highlightActiveLine()` covers current-line backdrop. Whitespace dots: custom `ViewPlugin` + `Decoration.mark`. Word-wrap indicator: line decoration. |
|13 | History — observable / taggable / arbitrary rewind | ⚠️    | History is a `StateField` you *can read* (`done` + `undone` branches; both serializable to JSON). Tag via `Annotation`s (e.g. `Transaction.userEvent`). **No event** fires per history entry — you'd watch it via `updateListener`. Time-travel to arbitrary point: feasible via JSON snapshot + `fromJSON`; not via the history stack itself. Persistable. |
|14 | Bus-factor / fork cost                            | ⚠️      | Marijn Haverbeke is the keystone but **OpenAI now sponsors him** (2025) [S3] — funding stable. Lezer parser + view (~290 KB minified) is the bulk; forkable in a quarter by a small team. Less risky than NSTextView TextKit 2 path, more risky than vanilla NSTextView TK1. |
|15 | Keyboard shortcut precedence                      | ✅      | `Prec.highest` + `keymap.of([...])` order = first-wins. Cmd-keys pass through to macOS menus by default (CM doesn't bind Cmd-*). Adding our own ⇧⌘F: trivial — wrap in `Prec.highest`. |
|16 | Paste interception / transform / suppress         | ✅      | `EditorView.clipboardInputFilter` — runs on every paste/drop, returns transformed string. Suppress via `domEventHandlers.paste = e => true`. Per-region read-only via `EditorState.changeFilter`. |

Inline labels follow: ✅ fully possible · ⚠️ possible with caveats · ❌ not possible / requires fork · 🤔 depends.

---

## Question 1 — Read-only CM6: what it does, what it loses

**Verdict: ✅ Trivial. Two different knobs, two different behaviors.**

CM6 ships **two distinct facets** that look similar but mean
different things [S4, S5]:

```ts
// from @codemirror/view editorview.ts:
/// Facet that controls whether the editor content DOM is editable.
/// When its highest-precedence value is `false`, the element will
/// not have its `contenteditable` attribute set.
EditorView.editable: Facet<boolean>

// from @codemirror/state:
/// readOnly: consulted by commands and extensions that implement
/// editing functionality to determine whether they should apply.
EditorState.readOnly: Facet<boolean>
```

What that actually means:

| Knob                          | DOM `contenteditable` | Caret visible | Selection works | Find works | Fold works | Commands (e.g. `indentMore`) |
|-------------------------------|-----------------------|---------------|-----------------|------------|------------|------------------------------|
| Default                       | `"true"`              | yes           | yes             | yes        | yes        | yes                          |
| `readOnly.of(true)` only      | `"true"`              | yes           | yes             | yes        | yes        | **silently no-op**           |
| `editable.of(false)` only     | `"false"`             | yes (drawn by `drawSelection`) | yes | yes        | yes        | yes (but no IME, no clipboard input filter triggers) |
| both                          | `"false"`             | yes           | yes             | yes        | yes        | no-op                        |

Source: `EditorView` sets `contenteditable: !state.facet(editable) ? "false" : "true"` and `aria-readonly: "true"` when `state.readOnly` [S4].

**What's lost in read-only mode:**

- *Nothing structural.* All gutter, find, fold, syntax-highlight,
  decoration, selection-highlight, scroll, multi-cursor, ⌘-arrow
  motion, and even `drawSelection` continue to work.
- IME composition is disabled when `editable = false` (no
  `contenteditable` → no `compositionstart`).
- The native browser context menu changes (no Cut/Paste/Spell
  items). Right-click still fires — you can replace the menu (Q8).
- `clipboardInputFilter` is not invoked because there's no paste
  target. `clipboardOutputFilter` *is* invoked on copy.

**Recommended pattern for our use case** (read-only source viewer that
still wants selection, find, fold):

```ts
const ext = [
  EditorState.readOnly.of(true),       // disables editing commands
  EditorView.editable.of(false),        // contentEditable=false
  drawSelection(),                      // we draw the caret ourselves
  highlightSelectionMatches(),          // selection-driven highlights
  // … syntax + fold + gutter as usual
]
```

**Perf profile:** Read-only is *no faster* than read-write for the
same doc. The expensive paths (line virtualization, syntax
re-highlight on edit, decoration recomputation, layout) are
identical. The only saving is no event dispatch on
keystroke-that-would-edit (negligible).

---

## Question 2 — Could CM6 replace our native NSTextView source viewer?

**Verdict: ⚠️ Possible, but the trade is asymmetric.**

### Real losses if we switch

Looking at `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/TextDisplayView.swift` — that file embodies a *lot* of tuned work the CM6 path would discard or have to reimplement:

| Feature today (in `TextDisplayView`)                                       | Where it lives                          | CM6 equivalent                              | Effort to re-do |
|----------------------------------------------------------------------------|-----------------------------------------|---------------------------------------------|-----------------|
| Compositor-stable layout (controller-rep, not view-rep — sibling SwiftUI doesn't blank) | `NSViewControllerRepresentable`       | n/a — WKWebView has different failure modes | rewrite         |
| Tuned `SelectionHighlightEngine` w/ throttle + size cap                    | `SelectionHighlightEngine.swift`        | `highlightSelectionMatches` (built-in)      | port policy     |
| Newline-offset binary-search index (O(log n) line lookup)                  | `newlineOffsetsRefreshed()`             | `state.doc.lineAt()` (free)                 | delete          |
| Current-line backdrop via NSLayoutManager temp attrs                       | `applyCurrentLineHighlight()`           | `highlightActiveLine()` (built-in)          | delete          |
| Find highlights via temp attrs + scroll-to-match                            | `applyFindHighlights()`                 | `setSearchQuery` + decorations              | rewrite         |
| Find match-set minimap (line numbers → SwiftUI render)                     | `FindMatchSet` publish                  | iterate `cm-searchMatch` decorations        | rewrite         |
| Cached compiled regex                                                       | `cachedRegex(...)`                     | n/a — done in JS                            | delete          |
| 256 KB+ attributed-string fast path (no allocation when runs empty)        | `applyAttributedString(...)` fast path  | CM6 doesn't allocate per-string anyway      | delete          |
| Services menu (Look Up, Translate, Share, Speech)                          | NSTextView default                       | WKWebView default has Look Up only          | partial loss    |
| Force-Touch lookup on selected word                                         | NSTextView default                       | WebKit handles it (works)                   | wash            |
| `NSSpellChecker` integration                                                | NSTextView default                       | WebKit handles it (works) — different surface | wash         |
| `NSTextFinder` (system pasteboard sync)                                    | NSTextView via `NSScrollView`            | DIY bridge to `find` pasteboard              | rewrite         |
| Bookmark / fold gutter dots (custom NSRulerView avoided)                   | SwiftUI sibling, clipView-bounds-driven | `gutter()` extension                         | rewrite (cleaner) |

The TextDisplayView file is ~1100 LOC of *finely-tuned* AppKit. A
CM6 cutover deletes ~40% of that as redundant — but **forces a
rewrite of the other ~60%** in JS + bridge, and you eat the
compositor-pathology section's reasoning all over again from scratch
with WebKit's failure modes.

### Real wins if we switch

- **One viewer instead of two.** Today: source view (NSTextView)
  and editor view (CM6). One scroll model, one find model, one
  selection-highlight, one gutter system.
- **Multi-cursor** in read-only mode (alt-click to drop secondary
  carets to copy multiple disjoint ranges).
- **Fold UI parity** — fold gutter in source view today is a
  separate codepath; in CM6 it's free.
- **Bookmark dots / git diff stripes can be one gutter extension**
  shared between source + editor.
- **Selection-highlight + find minimap can be one CM6 plugin**
  rather than one Swift `SelectionHighlightEngine` + one
  `FindMatchSet` publisher.
- **Whitespace dots / current-line backdrop / show-invisibles**
  are CM6 built-ins, not hand-rolled.

### Real-world perf comparison

These are *informed estimates* — there is no published head-to-head benchmark of NSTextView TK2 vs CM6-in-WKWebView at multi-MB sizes; the published CM6 numbers are MarkEdit's empirical reports [S6, S7] and discuss.codemirror.net forum threads [S8, S9] which contain anecdotes but no measured table.

| Doc size  | NSTextView (TK1) read-only                          | CM6-in-WKWebView read-only                       | Winner |
|-----------|-----------------------------------------------------|--------------------------------------------------|--------|
| 1 MB      | <50 ms first paint; instant scroll; ~3 MB RAM       | <50 ms first paint after `ready`; ~10 MB JS heap on top of ~80 MB WebContent process | NSTextView on memory, wash on perceived perf |
| 10 MB     | ~300 ms first paint; scroll smooth; ~30 MB RAM      | "eye-blinking" per MarkEdit [S6]; ~50 MB JS heap; ~130 MB process | CM6 closes the gap; NSTextView still cheaper |
| 100 MB    | ~3 s first paint; scroll fine; ~300 MB RAM          | Marijn: "no documented ceiling" but expect lag [S10]; ~500 MB+ heap pressure | NSTextView wins clearly |
| 1 GB      | ~30 s first paint; scroll fine if `usesFontPanel = false` [S11]; ~3 GB RAM (TK1's `NSTextStorage` is contiguous) | Out of CM6's designed range; will hit JS heap ceiling (~4 GB Safari default) | NSTextView wins |
| Single line > 5 KB | Fine                                       | Wrap layout O(n) on line length [S8]              | NSTextView wins |

**Bigger files favor NSTextView** — JS-heap pressure is the
binding constraint for CM6; AppKit's `NSTextStorage` is a single
contiguous string with attribute runs (cheap), and TK2's viewport-
based layout means scroll is decoupled from doc size [S12].

**One caveat**: NSTextView TK1 is "soft-deprecated" — the
maintenance signal is that Apple is investing in TK2. TK2 is
significantly more bug-prone (per the TEXT_EDITOR_OPTIONS doc's
exhaustive citation list). If we stay on NSTextView for huge
files but switch to CM6 for ≤ 50 MB, we get the best of both —
but we ship two viewers permanently.

### Memory footprint per open file (rule of thumb)

| Component                                       | Cost                              |
|-------------------------------------------------|-----------------------------------|
| NSTextView read-only (1 MB file)                | ~3 MB (storage + glyph cache)     |
| WKWebView WebContent process (cold)             | ~80–140 MB [S13]                  |
| WKWebView + CM6 + 1 MB doc                      | ~130–180 MB total (process + heap)|
| Extra NSTextView per tab                        | ~3 MB                             |
| Extra WKWebView per tab (today)                  | ~80–140 MB                        |
| Shared WebView host (one process, N tabs)        | ~80 MB + ~10 MB/MB doc per tab    |

**At 10+ open tabs, the single-shared-WebView refactor (feature
#24 in the CM6 design doc) is mandatory** if every tab is CM6 —
otherwise you're at >1 GB resident just for editor processes.
TextDisplayView/NSTextView is constant ~3 MB per tab regardless.

### Cold-start time per tab switch

- **NSTextView**: ~1 ms — `NSViewController` swap, no IPC.
- **CM6 same-WebView, `view.setState(...)`**: ~5–20 ms depending
  on doc size (re-build syntax tree + decoration set).
- **CM6 new-WebView**: ~80–120 ms cold (HTML load + bundle parse +
  state build) on M1; ~200 ms on a 2017 Intel MBP.

### Startup time for first WKWebView in a session

- **WebContent process spin-up**: ~30–60 ms cold (system caches
  WebContent processes; warm in second session of the app).
- **Bundle parse** (our 572 KB IIFE): ~25–50 ms on M1, ~80 ms on
  Intel. Linear with bundle size — keep an eye on this if we
  approach 1.5 MB.
- **Total to first `ready`**: ~80–150 ms on M1; ~250 ms on Intel.

Our existing `CodeMirrorEditorView` already shares a `WKProcessPool`
across tabs to keep this warm — good move. The first tab still
pays the cold cost.

### Verdict

**Don't replace the source viewer wholesale.** The TextDisplayView
file is doing too much that's already-tuned-and-working. *Possible*
incremental path:

1. Phase A: ship CM6 in **editor** mode only (today's plan). Stay
   on NSTextView for **source viewer**.
2. Phase B: Add an A/B opt-in flag (`useCodeMirrorForSourceViewer`)
   for early adopters. Measure on real files.
3. Phase C: If A/B is positive AND we've shipped the shared-
   WebView refactor, retire TextDisplayView for sub-50 MB files.
   Keep an NSTextView fallback for huge files.

---

## Question 3 — Keep both viewers or unify?

**Verdict: 🤔 Depends on willingness to maintain two paths.**

### Cost of two viewers (concrete)

Each feature lands twice unless explicitly shared:

| Feature                | NSTextView path                        | CM6 path                       | Shareable? |
|------------------------|----------------------------------------|--------------------------------|------------|
| Find / Replace         | `MarkdownFindBar` + temp attrs         | `@codemirror/search`           | Bridge layer can unify |
| Selection highlight     | `SelectionHighlightEngine`            | `highlightSelectionMatches`    | Policy yes; render no |
| Syntax highlighting    | `TreeSitterEngine` → `HighlightRun[]` | `@codemirror/lang-*` or bridge | Yes via Q6 |
| Gutter / line numbers  | `LineNumberRulerView` (avoided!)      | `lineNumbers()` + `gutter()`   | No |
| Code folding           | `FoldDisplay` / `FoldRegion`          | `foldGutter()` + `foldService` | No (different render) |
| Diff stripes           | TreeSitter-derived overlay             | `gutter()` + decoration         | No |
| Bookmark dots          | SwiftUI sibling overlay                | `gutter()`                      | No |
| Current-line backdrop  | NSLayoutManager temp attrs             | `highlightActiveLine()`         | No |
| Show invisibles        | `layoutManager.showsInvisibleChars`    | `highlightSpecialChars`         | No |
| Scroll position persistence | `SourceScrollState`                | `view.scrollDOM.scrollTop`      | Yes via DocumentModel |
| Word wrap toggle       | `applyWrap()`                          | `EditorView.lineWrapping`       | No |
| Goto line              | `scroll(toLine:)`                      | `scrollIntoView` effect         | No |
| Cursor (line:col)      | `publishSelection()`                   | `updateListener` selection       | No |

**Carrying cost (rough)**: every new visual feature is ~1.5–2× the work
to land. Every find bug is two bugs to fix. The bridge protocol
becomes the boundary you have to keep test-covered.

### Arguments for unifying (CM6 wins)

- Every feature lands once.
- Find / select / highlight UX is *identical* across modes — no
  "why does find behave differently in editor mode" surprises.
- LSP wiring (Q7) lights up in both views from one codepath.
- The shared bridge protocol becomes the single API surface for
  future scripting / plugins.

### Arguments for keeping both

- NSTextView is **6× lighter** per tab (~3 MB vs ~130 MB resident
  with a fresh WebContent process).
- For huge files (>100 MB) CM6 is unviable; NSTextView reads them.
- Compositor pathology in NSTextView is *known and worked around*
  (see TextDisplayView's docstring); WebKit pathologies are
  different and unsolved.
- Faster cold-start path for "click a file, glance at it, close".
- Services menu / Force-Touch / spell-check integration is
  *better* on NSTextView in some areas (system services menu
  contributions, dictation, Speech). WKWebView is comparable for
  the common cases but loses some chrome features.

### My read

**Short term (next 6 months)**: keep both. CM6 is in flight; let it
mature in editor mode where the new features (LSP, vim, diagnostics,
multi-cursor) actually matter. The NSTextView source viewer is your
fallback for "I just want to read a file fast" and for huge files.

**Long term (12–18 months)**: revisit. If CM6 editor mode is solid
+ the shared-WebView refactor lands + a "fall back to NSTextView at
>50 MB" path exists, then retiring TextDisplayView for the normal
case removes a real maintenance burden. Until then, the bridge
layer (find-bar shared, scroll position shared, bookmark store
shared) is the right unification target — not the rendering layer.

---

## Question 4 — Large file viability

**Verdict: ⚠️ Comfortable to ~10 MB; practical ceiling ~50–100 MB; hard wall ~JS heap.**

### What CM6 was designed for

CM6's design [S14] avoids linear-in-doc-size cost throughout:

- **Piece-tree doc storage** — O(log n) `lineAt`, `slice`, etc.
- **Viewport rendering** — only visible lines hit the DOM;
  off-screen regions are `cm-gap` placeholders [S15].
- **Lazy-on-edit highlighter** — pauses with a work budget.
- **Million-line demo** runs in-browser at 60 fps [S16].

### Where it falls over

- **Single-line length** — long minified lines blow up wrap
  recalculation. 5 KB+ on one line with `lineWrapping` on is
  visibly slow [S8]. Workaround: auto-disable wrap for files with
  any line > 5 KB. Detect on `setText`.
- **`getDocument` cost** — `state.doc.toString()` allocates the
  full string. On 10 MB: ~5 ms allocation + ~5 ms bridge marshal
  + ~5 ms Swift-side String construction. Fine for save/format;
  bad for per-keystroke (we don't do that — debounced).
- **JS heap ceiling** — Safari WebContent has a soft cap around
  4 GB. A 1 GB file with even minimal overhead (doc + viewport +
  highlighter state) is near the limit.
- **Forum reports** [S9] mention >1.6 M lines causing GC
  pressure in the WebContent process — not CM6's fault per se,
  but the practical effect.
- **Marijn on >100 MB** [S10]: "You could probably hack something
  on top of the editor, for example by putting a DOM widget with
  the approximate height of the unloaded content below the loaded
  document." Translation: **no native lazy-load**; you build it.

### Comparison with NSTextView for very large files

NSTextView (TK1) with `usesFontPanel = false` [S11] is the
documented win for plain-text logs at 100+ MB. Documents have
been edited at 1 GB+ in apps like BBEdit (which uses heavily-
customized AppKit). Our TextDisplayView's `allowsNonContiguousLayout
= true` is the same optimization — only the visible region is
glyph-cached, the rest sits in the storage as a string + attribute
runs.

For huge files, **NSTextView wins**. CM6 is *fine* up to 10 MB,
*okay* to ~50 MB, *suspect* above 100 MB.

### Recommended product policy (from CM6 design doc §17.5, doubled down here)

```
opening a file:
  size < 50 MB     → CM6 (editor or source mode per user pref)
  50 MB ≤ size     → NSTextView read-only, with a banner:
                       "Large file — read-only mode. Find works.
                        Editor mode disabled."
  size > 500 MB    → confirm before opening; consider
                       streaming-only viewer
```

This caps the worst case. The "huge file" path keeps the existing
TextDisplayView around as a *feature*, not as legacy.

---

## Question 5 — Syntax highlighting story

**Verdict: ⚠️ Excellent coverage with gaps in our exact set; bundle cost is real per language.**

### CM6 official Lezer language packages

From npm `@codemirror/lang-*` [S17, S18]:

| Language    | Package                          | Min size | Quality   |
|-------------|----------------------------------|---------:|-----------|
| Markdown    | `@codemirror/lang-markdown`      |   ~70 KB | excellent (GFM, embedded code-block) |
| JavaScript  | `@codemirror/lang-javascript`    |  ~110 KB | excellent (TS via `{typescript: true}`, JSX) |
| TypeScript  | (same as JS)                     |     ↑    | excellent |
| Python      | `@codemirror/lang-python`        |   ~50 KB | excellent |
| Java        | `@codemirror/lang-java`          |   ~40 KB | excellent |
| Rust        | `@codemirror/lang-rust`          |  ~110 KB | excellent |
| C / C++     | `@codemirror/lang-cpp`           |   ~80 KB | excellent |
| JSON        | `@codemirror/lang-json`          |   ~10 KB | excellent |
| HTML        | `@codemirror/lang-html`          |  ~120 KB | excellent (composes css + js) |
| CSS         | `@codemirror/lang-css`           |   ~30 KB | excellent |
| XML         | `@codemirror/lang-xml`           |   ~15 KB | excellent |
| SQL         | `@codemirror/lang-sql`           |   ~60 KB | excellent (multiple dialects) |
| PHP         | `@codemirror/lang-php`           |   ~50 KB | good      |
| YAML        | `@codemirror/lang-yaml`          |   ~20 KB | good      |
| Vue         | `@codemirror/lang-vue`           |   ~25 KB | good (composes html+js) |
| **Swift**   | **none official**                |        — | community via `lezer-swift` packages, varying quality |
| **Go**      | **none official**                |        — | community `codemirror-lang-go` exists |

### Our current tree-sitter set (14 langs lazy-loaded)

From `Sources/ViewerCore/Highlight/TreeSitterEngine.swift` + `GrammarLoader.swift`:

Tree-sitter ships **150+ grammars** total upstream; we lazy-load
our subset on demand. The `.dylib` model loads only the grammar
the user opens. CM6 by contrast bundles every language we declare
at build time (no dynamic `import()` in our IIFE today).

### Coverage gap analysis

Languages we'd lose / weaken if we cut tree-sitter for CM6 Lezer:

- **Swift** — no official CM6 package; community ones are
  incomplete (no protocols, no result builders).
- **Go** — community only; would need vetting.
- **Anything tree-sitter has that CM6 doesn't** (Zig, Nim, Lua, Bash,
  Ruby, Elixir, Erlang, R, Julia, Haskell, OCaml, Scala, Kotlin,
  Dart, …). Some have community Lezer packages of variable quality.

### Quality / accuracy differences

For shared languages, Lezer is **AST-aware** (parser-based) and
tree-sitter is also **AST-aware** (error-recovering GLR parser).
Both produce reasonable token classifications. Real differences:

- **Tree-sitter has bigger community** — more grammars, more
  exotic edge cases tested.
- **Lezer is JS-native** — no FFI marshalling, no dylib loading,
  parses incrementally on every keystroke without dropping out
  to a worker.
- **Tree-sitter error recovery is more aggressive** — better at
  partial-document highlighting during typing.
- **Embedded languages** — Lezer's nested parsing (markdown code
  blocks getting JS highlighting) is *better integrated* than
  most tree-sitter-injection setups.

### Theme integration

CM6 themes are `HighlightStyle.define([{tag: tags.X, color: '#...'}, …])`.
Mapping our `SyntaxTheme.colors` → a CM6 `HighlightStyle` is
~50 LOC of straightforward translation. The CM6 design doc
Phase 3 plans this.

### Bundle cost — Lezer vs tree-sitter

| Approach                                     | Cost                                    |
|----------------------------------------------|-----------------------------------------|
| Lezer in CM6 bundle, all 14 langs            | ~700 KB minified on top of 572 KB core → ~1.3 MB |
| Lezer lazy-loaded via `import()` per language | ~50 KB + per-lang only when needed     |
| Tree-sitter dylibs (current)                  | ~150 KB Swift glue + ~50–200 KB per lang dylib lazy-loaded |
| Tree-sitter run in Swift, push ranges to CM6 | ~0 added to JS bundle; bridge cost (Q6) |

**The Q6 path (tree-sitter in Swift → decorations to CM6) saves
~700 KB of bundle in exchange for 3–10 ms bridge latency per
debounced highlight push.** Cheap; recommended.

---

## Question 6 — Plug our tree-sitter into CM6

**Verdict: ⚠️ Works; pattern is well-established; one round-trip lag per highlight push.**

### The pattern

This is the classic "externally-computed decorations via
`StateField`" pattern that CM6 explicitly supports [S19, S20]:

```ts
// 1. Effect that carries highlight ranges from Swift.
const setHighlightRanges = StateEffect.define<{from: number, to: number, cls: string}[]>({
  map: (ranges, change) => ranges.map(r => ({
    from: change.mapPos(r.from),
    to: change.mapPos(r.to),
    cls: r.cls,
  })),
})

// 2. StateField stores the decorations + auto-remaps them across edits.
const highlightField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(decos, tr) {
    decos = decos.map(tr.changes)
    for (const e of tr.effects) if (e.is(setHighlightRanges)) {
      decos = Decoration.set(
        e.value.map(r => Decoration.mark({class: r.cls}).range(r.from, r.to)),
        /*sort=*/true
      )
    }
    return decos
  },
  provide: f => EditorView.decorations.from(f),
})

// 3. Swift bridge → JS dispatcher
window.cmDispatch.setHighlights = (msg) => {
  view.dispatch({
    effects: setHighlightRanges.of(msg.ranges),
    annotations: [Transaction.addToHistory.of(false)],
  })
}
```

That's the whole thing. ~30 LOC.

### Latency budget

Per Swift-side highlight push (a typical full-file re-highlight):

```
swift: TreeSitter.parse()                   ~5–50 ms (depending on file size)
swift: convert byte ranges → UTF-16         ~1–10 ms (LSPPositionConverter)
swift: encode JSON ranges                   ~1–5 ms (10K ranges = ~200 KB JSON)
bridge: evaluateJavaScript IPC              ~3–5 ms [S21]
js: dispatch effect + build DecorationSet   ~5–15 ms
total                                       ~15–85 ms per push
```

Debounced to ~150–200 ms — invisible to the user.

### Mature bridge patterns

There **is no official "tree-sitter inside CM6"** bridge (the
`mapping-tree-sitter-trees-to-lezer-trees` thread [S22] discusses
the *other* direction: feeding a tree-sitter parse back into a
Lezer `Tree` for use by CM6's `syntaxTree()` consumers — overkill
for our use case).

Community precedent:

- **`urbit-pilled/hoon-codemirror`** — runs tree-sitter via
  WASM in the page, feeds the parse as decorations. Shows the
  WASM-in-browser path works; not what we want (we have Swift-
  side tree-sitter already).
- **Joel Gustafson's "Syntax highlighting on the web"** [S23] —
  exact pattern for pushing externally-computed decorations.
- **MarkEdit's bridge layer** [S24] — `bridge.api.X` calls drive
  decorations the same way (they push markdown-specific block
  decorations from their core/api layer).

### Pros vs cons of this path

**Pros:**
- Keep our existing `TreeSitterEngine` + grammar `.dylib`s — no
  rewrite, no new bundle.
- Keep the tree-sitter language set we have (Swift, Go, Zig, …).
- One highlight pipeline across NSTextView and CM6.
- CM6 bundle stays small (no `@codemirror/lang-*` per language).

**Cons:**
- Tree-sitter parse is *not* incremental into CM6 — we re-push
  the full decoration set on each debounced change. CM6's
  Lezer-based highlighter is genuinely incremental.
- Round-trip cost on every push. Mitigation: ship range diffs
  not full sets in v2 of the bridge.
- Two truths if you're not careful — the language compartment
  swaps must coordinate with tree-sitter language switch.

### Recommendation

**Use Q6 path for the editor mode.** Saves ~700 KB bundle, keeps
the language set we have, unifies highlight pipeline across both
viewers. The 50–100 ms debounced repush is invisible at our edit
rates.

---

## Question 7 — LSP fed by our Swift LSP pool

**Verdict: ✅ Straightforward via `@codemirror/lint` + `hoverTooltip`. No need to adopt `@codemirror/lsp-client`.**

### Why not `@codemirror/lsp-client`?

The official package [S25, S26] expects:

- A `Transport` object (`send` / `subscribe` / `unsubscribe`).
- The transport speaks LSP wire-protocol over its channel.
- The LSP server lives "somewhere" — the package abstracts the
  channel but assumes one server per language.

We could implement a custom `Transport` that proxies through
WKScriptMessage to our Swift-side `LSPPool`, but that means
**LSP wire-format messages serialized over the bridge twice**
(Swift → JS → out to server → in to JS → Swift). The Swift-
side pool is the authority; pushing it behind a bridge is
silly marshalling for no win.

Per the CM6 design doc §17.2, **stick with Swift-side LSP**,
push *results* (not protocol) over the bridge.

### Diagnostics (push from Swift)

`@codemirror/lint` exports a `setDiagnostics(state, diagnostics)`
function that *takes diagnostics directly* — no lint source
needed [S27]:

```ts
// from @codemirror/lint/src/lint.ts:
export function setDiagnostics(
  state: EditorState, diagnostics: readonly Diagnostic[]
): TransactionSpec

interface Diagnostic {
  from: number; to: number;
  severity: "hint" | "info" | "warning" | "error";
  message: string;
  source?: string;
  markClass?: string;
  renderMessage?: (view: EditorView) => Node;
  actions?: readonly { name: string; apply(view: EditorView, from: number, to: number): void }[];
}
```

Bridge wiring:

```ts
// Swift sends:
{ type: "setDiagnostics", diagnostics: [...] }

// JS:
window.cmDispatch.setDiagnostics = (msg) => {
  view.dispatch(setDiagnostics(view.state, msg.diagnostics))
}
```

This is the **canonical pattern**; the package was explicitly
designed to support it. Bundle cost: ~18 KB (`@codemirror/lint`).

### Hover

CM6 provides `hoverTooltip` in `@codemirror/view` [S28]:

```ts
import { hoverTooltip } from "@codemirror/view"

const lspHover = hoverTooltip(async (view, pos, side) => {
  const replyId = nextReplyId()
  const result = await bridgeRequest("requestHover", { pos, replyId })
  if (!result) return null
  return {
    pos: result.from,
    end: result.to,
    above: true,
    create() {
      const dom = document.createElement("div")
      dom.className = "cm-tooltip-hover-lsp"
      dom.innerHTML = renderMarkdownToHtml(result.markdown)  // we ship this; see LSPMarkdownRenderer
      return { dom }
    },
  }
})
```

`hoverTooltip` handles dwell timing (default 300 ms), positioning,
dismissal on edit / scroll / blur, and viewport clipping. We
just provide the source-of-truth callback.

### Completion / Definition / References

Same pattern — `@codemirror/autocomplete` accepts a custom
`CompletionSource` (async function); custom `domEventHandlers` for
⌘-click → request:

```ts
EditorView.domEventHandlers({
  mousedown(e, view) {
    if (e.metaKey) {
      const pos = view.posAtCoords({ x: e.clientX, y: e.clientY })
      if (pos != null) {
        bridgeRequest("requestDefinition", { pos })
        e.preventDefault()
        return true
      }
    }
    return false
  },
})
```

### Latency through the bridge

Per CM6 design doc §17.1 — hover round-trip through our existing
LSP pool is ~50–200 ms; bridge adds 2× ~5 ms = ~10 ms. Total
~60–210 ms. At the *edge* of "feels responsive" but well within
the dwell budget (300 ms default; can stretch to 500 ms).

### Verdict

**Trivially possible. Recommended path:** keep Swift-side
`LSPPool` as authority; push diagnostics via `setDiagnostics`;
register `hoverTooltip` with bridge round-trip; ⌘-click via
`domEventHandlers`. Bundle cost: ~18 KB lint extension.
Latency: well within budget.

---

## Question 8 — Right-click context menu replaceable?

**Verdict: ✅ Fully replaceable on macOS. Standard pattern.**

WKWebView on macOS does NOT expose a `WKUIDelegate` method for
context-menu mutation (that's iOS-only). The accepted workaround
[S1, S2] is to **subclass `WKWebView` and override `NSView`'s
`willOpenMenu(_:with:)`**:

```swift
final class MarkdownEditorWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        // Mutate `menu` in place: remove items by identifier,
        // add our own NSMenuItems, separators, etc.
        for item in menu.items where item.identifier == nil { continue }
        // Example: drop browser-y items
        menu.items.removeAll { item in
            guard let id = item.identifier?.rawValue else { return false }
            return id.hasPrefix("WKMenuItemIdentifierReload")
                || id == "WKMenuItemIdentifierOpenLink"
                || id == "WKMenuItemIdentifierGoBack"
        }
        // Append our own.
        menu.addItem(NSMenuItem.separator())
        let copyPath = NSMenuItem(title: "Copy as Markdown Link", action: #selector(copyAsMdLink(_:)), keyEquivalent: "")
        copyPath.target = self
        menu.addItem(copyPath)
        super.willOpenMenu(menu, with: event)
    }
}
```

WebKit menu-item identifiers are documented at
`WKMenuItemIdentifier*` (e.g. `WKMenuItemIdentifierCopy`,
`WKMenuItemIdentifierPaste`, `WKMenuItemIdentifierLookUp`, etc.).
Filter by identifier is the safe API.

### Contextual items (e.g. "Open in New Tab" on a path)

Pattern:

1. On right-click, JS-side intercept via `EditorView.domEventHandlers`:
   ```ts
   domEventHandlers({
     contextmenu(e, view) {
       const pos = view.posAtCoords({x: e.clientX, y: e.clientY})
       const selection = view.state.selection.main
       const text = selection.empty
         ? wordAt(view.state.doc, pos)
         : view.state.sliceDoc(selection.from, selection.to)
       bridge.send({type: "contextMenuRequested", text, pos, hasSelection: !selection.empty})
       e.preventDefault()
       return true  // suppress browser menu
     }
   })
   ```
2. Swift side builds the menu based on `text` shape (path? URL?
   identifier?), pops it via `NSMenu.popUp(positioning:at:in:)`.

This is **cleaner** than browser-menu-mutation — gives us
arbitrary native items, full NSMenuItem styling (icons, sub-
menus, alternates), and no fight with WebKit's defaults.

### Suppress entirely + render our own

```ts
domEventHandlers({
  contextmenu(e) { e.preventDefault(); return true }
})
```

Then handle via Swift (above). MarkEdit uses a similar pattern.

---

## Question 9 — Selection-highlight "all instances" behavior

**Verdict: ✅ Two ways: built-in `highlightSelectionMatches` or roll-your-own with `StateField`.**

### Built-in: `highlightSelectionMatches`

From `@codemirror/search` [S29]:

```ts
import { highlightSelectionMatches } from "@codemirror/search"

// options:
highlightSelectionMatches({
  minSelectionLength: 1,        // default
  maxMatches: 100,              // default
  highlightWordAroundCursor: false,
  wholeWords: false,
})
```

Decoration classes: `cm-selectionMatch`, `cm-selectionMatch-main`
[S29]. Style via theme:

```ts
EditorView.theme({
  ".cm-selectionMatch": { backgroundColor: "#fff39933" },
  ".cm-selectionMatch-main": { backgroundColor: "#fff39966" },
})
```

### Roll-your-own (for our `SelectionHighlightEngine` policy)

Our existing policy is more nuanced than the built-in:

- Throttle to 150 ms.
- Bail for short / long / multi-line selections.
- Bail for huge files (`cachedTextByteCount` check).

We can port the policy unchanged to a CM6 `ViewPlugin`:

```ts
const policyPlugin = ViewPlugin.fromClass(class {
  decorations = Decoration.none
  pending: number | null = null

  update(u: ViewUpdate) {
    if (!u.selectionSet && !u.docChanged) return
    if (this.pending) clearTimeout(this.pending)
    this.pending = setTimeout(() => this.compute(u.view), 150)
  }

  compute(view: EditorView) {
    const sel = view.state.selection.main
    if (sel.empty || sel.to - sel.from < 2 || sel.to - sel.from > 200) {
      this.decorations = Decoration.none
      view.dispatch({})  // trigger rerender
      return
    }
    const text = view.state.doc.toString()  // O(n); cap by doc size
    if (text.length > 5_000_000) return
    const needle = view.state.sliceDoc(sel.from, sel.to)
    const ranges: Range<Decoration>[] = []
    let i = 0
    while ((i = text.indexOf(needle, i)) >= 0) {
      if (i !== sel.from) ranges.push(highlightMark.range(i, i + needle.length))
      i += needle.length
    }
    this.decorations = Decoration.set(ranges)
    view.requestMeasure()
  }
}, {
  decorations: v => v.decorations,
})
```

`ViewPlugin` rather than `StateField` because the policy is
viewport- and DOM-derived, not state-derived. CM6's `StateField`
pattern would also work if we want the decoration to persist
across tab-state swaps.

### Decoration API summary [S30]

| Decoration             | Use                                                   |
|------------------------|-------------------------------------------------------|
| `Decoration.mark(spec)`  | Inline style on a range. Use for selection-highlight, search hits, syntax tokens. |
| `Decoration.line(spec)`  | Line-level attributes (CSS class on the line element). Use for breakpoint backdrop, current line. |
| `Decoration.widget({widget, side})` | Inline DOM widget at a position. Use for inline color swatches, type hints. |
| `Decoration.replace({widget})` | Replace a range with a widget (or hide). Use for fold-collapsed regions. |

---

## Question 10 — Find / Replace replaceable

**Verdict: ✅ Cleanly replaceable. MarkEdit shows the production pattern.**

### Suppress CM6's panel

`@codemirror/search`'s `search()` extension accepts a
`createPanel` option [S31]:

```ts
import { search, openSearchPanel } from "@codemirror/search"

search({
  createPanel: () => null,  // ← suppresses the built-in panel entirely
  top: false,
})
```

`createPanel: () => null` means CM6's `togglePanel` effect dispatches
but no DOM panel mounts. The search state still updates, decorations
still apply — just no built-in UI.

### Drive search from our `MarkdownFindBar`

Programmatic API [S31]:

```ts
import {
  setSearchQuery, getSearchQuery, SearchQuery,
  findNext, findPrevious, replaceNext, replaceAll,
} from "@codemirror/search"

// Swift → JS dispatch:
window.cmDispatch.setFindQuery = (msg) => {
  const q = new SearchQuery({
    search: msg.query,
    caseSensitive: msg.caseSensitive,
    regexp: msg.isRegex,
    replace: msg.replace ?? "",
    wholeWord: msg.wholeWord ?? false,
  })
  view.dispatch({ effects: setSearchQuery.of(q) })
}
window.cmDispatch.findNext  = () => findNext(view)
window.cmDispatch.findPrev  = () => findPrevious(view)
window.cmDispatch.replaceN  = () => replaceNext(view)
window.cmDispatch.replaceAll= () => replaceAll(view)
```

### Bring our own match decorations + minimap

If we want the SwiftUI find-minimap (currently in
`FindMatchMinimapView`) to keep working in CM6 mode:

1. Iterate the search-match `RangeSet` after each query change
   (CM6 exposes via `getSearchQuery(view.state).create().getCursor(...)`).
2. Convert positions → 1-based line numbers via `doc.lineAt`.
3. Post back over the bridge as `findMatchSetChanged`.
4. Existing SwiftUI `FindMatchMinimapView` consumes unchanged.

Total bridge call cost per query: ~5 ms (compute) + ~3 ms (post)
+ ~5 ms (Swift decode + republish). Add a 100 ms debounce on
match-set publication — same approach as `TextDisplayView.lastPublishedFindMatchSet`.

### MarkEdit reference [S24]

MarkEdit's `EditorViewController+TextFinder.swift` is exactly
this pattern. Quoted essence:

- `bridge.search.updateQuery(options:)` — push SearchOptions struct.
- `bridge.search.findNext` / `findPrev` — navigate.
- `bridge.search.replaceNext` / `replaceAll()` — execute.
- `await bridge.search.getCounterInfo()` — async match count.
- Syncs with `NSPasteboard.find.string` via `nativeSearchQuerySync`
  flag.

We can mirror this almost line-for-line.

---

## Question 11 — Gutter: line numbers, fold, diff, bookmarks, recency

**Verdict: ✅ Multiple `gutter()` extensions stack independently.**

From `@codemirror/view/src/gutter.ts` [S32]:

```ts
export function gutter(config: GutterConfig): Extension

interface GutterConfig {
  class?: string
  renderEmptyElements?: boolean
  markers?: (view: EditorView) => RangeSet<GutterMarker> | readonly RangeSet<GutterMarker>[]
  lineMarker?: (view: EditorView, line: BlockInfo, otherMarkers: readonly GutterMarker[]) => GutterMarker | null
  widgetMarker?: (view: EditorView, widget: WidgetType, block: BlockInfo) => GutterMarker | null
  lineMarkerChange?: null | ((update: ViewUpdate) => boolean)
  initialSpacer?: null | ((view: EditorView) => GutterMarker)
  updateSpacer?: null | ((spacer: GutterMarker, update: ViewUpdate) => GutterMarker)
  domEventHandlers?: { [event: string]: (view: EditorView, line: BlockInfo, event: Event) => boolean }
  side?: "before" | "after"
}

abstract class GutterMarker extends RangeValue {
  compare(other: GutterMarker): boolean
  eq(other: GutterMarker): boolean
  toDOM?(view: EditorView): Node
  elementClass: string
  destroy(dom: Node): void
}
```

> "The order in which the gutters appear is determined by their
> extension priority." [S32]

### Per-feature wiring

| Our feature              | CM6 piece                                      | Code shape |
|--------------------------|------------------------------------------------|------------|
| Line numbers             | `lineNumbers()` extension                       | drop-in    |
| Fold chevrons             | `foldGutter()` extension                        | drop-in    |
| Git-diff stripes (add/del/mod) | `gutter({class: "cm-diff", markers: () => diffMarkers, lineMarkerChange: u => u.docChanged})` | StateField holds `RangeSet<GutterMarker>`; Swift pushes via setEffect |
| Bookmark dots             | `gutter({class: "cm-bookmark", lineMarker: (v, line) => bookmarks.has(line.from) ? new BookmarkMarker() : null})` | Same pattern |
| Recency stripe            | `gutter({class: "cm-recency", lineMarker: ...})` | Same |
| Diagnostic squiggles      | `lintGutter()` (built-in)                       | drop-in    |

Each is one `gutter()` extension call in the extensions array.

### Perf cost of many gutters

Per `lineMarker` callback fires per line per render. Cost
characteristic:

- `lineMarker` is called for every visible line. Cheap (~µs each)
  when it just does a `Set.has(line.from)`.
- `markers` callback returns a `RangeSet` — `RangeSet` is the
  same data structure CM6 uses internally for decorations;
  scaling is O(log n) for lookups.
- `lineMarkerChange` is the perf hook — return `false` to skip
  re-running `lineMarker` when nothing changed for that gutter.
  Critical for static gutters like bookmarks.

At our scale (visible lines ≤ ~80, gutters ≤ 5), perf is *not*
a concern. 1000-line viewports are fine. The real concern is
**gutter width thrash** — line numbers gutter resizes on doc
length changes; using `initialSpacer` keyed to a 9-digit width
pre-sizes the gutter so width stays stable.

### Custom gutter for in-document recency stripe

Today the recency stripe is file-tree only. If we want it in-
document, the pattern:

1. `StateField<RangeSet<GutterMarker>>` holds a `recencyStripeMarker`
   per recently-edited line range.
2. Swift pushes updates via bridge effect.
3. `gutter({markers: v => v.state.field(recencyField), class: "cm-recency"})`.
4. CSS sets a colored left border on the gutter element.

---

## Question 12 — Custom text rendering (specials, whitespace, current line)

**Verdict: ✅ Mostly built-in; the rest is decorations.**

### Built-ins

| Feature                             | Extension                             |
|-------------------------------------|---------------------------------------|
| Special chars (tab, CR, NBSP, ZWJ, …) | `highlightSpecialChars()`            |
| Current-line backdrop                | `highlightActiveLine()`               |
| Current-line gutter highlight         | `highlightActiveLineGutter()`         |
| Trailing whitespace warning           | community plugins; or custom `ViewPlugin` |
| Show-invisibles dots / arrows         | `highlightSpecialChars` covers some; full "show whitespace" needs custom |

`highlightSpecialChars()` is the canonical CM6 way to render
tab markers / NBSP / Unicode zero-width / control chars. It uses
`Decoration.replace` to swap a special char for a visible glyph
widget.

### Whitespace dots

Custom `ViewPlugin` over visible ranges:

```ts
const showWhitespacePlugin = ViewPlugin.fromClass(class {
  decorations: DecorationSet
  constructor(view: EditorView) { this.decorations = this.build(view) }
  update(u: ViewUpdate) {
    if (u.docChanged || u.viewportChanged) this.decorations = this.build(u.view)
  }
  build(view: EditorView) {
    const ranges: Range<Decoration>[] = []
    for (const {from, to} of view.visibleRanges) {
      const text = view.state.sliceDoc(from, to)
      for (let i = 0; i < text.length; i++) {
        const c = text[i]
        if (c === ' ' || c === '\t') {
          ranges.push(Decoration.mark({class: c === ' ' ? "cm-ws-space" : "cm-ws-tab"}).range(from + i, from + i + 1))
        }
      }
    }
    return Decoration.set(ranges, true)
  }
}, { decorations: v => v.decorations })
```

CSS draws the dot via `::after`:

```css
.cm-ws-space::after { content: "·"; opacity: 0.3; position: absolute; pointer-events: none; }
.cm-ws-tab::after   { content: "→"; opacity: 0.3; position: absolute; pointer-events: none; }
```

### Word-wrap indicator

The little "↵" at wrap points isn't built-in. Workaround: don't
do per-wrap glyphs (expensive — wraps recompute on every resize);
instead, use CSS to put a soft-wrap symbol on the wrap line via
the gutter — there's no widget per visual sub-line in CM6 because
the doc is logical lines only, not visual lines.

### Current-line backdrop

`highlightActiveLine()` does the standard one. To match our
`TextDisplayView` policy (theme-aware: 12% on dark, 8% on light):

```ts
EditorView.theme({
  ".cm-activeLine": { backgroundColor: "rgba(0,0,0,0.08)" },
  "&dark .cm-activeLine": { backgroundColor: "rgba(255,255,255,0.12)" },
})
```

### Where CM6 doesn't let you reach

- **Per-glyph rendering** — no hook to "draw this glyph differently".
  All rendering is via DOM nodes per token-cluster.
- **Sub-pixel font tweaks** — set via CSS only; no programmatic
  Core Text equivalent.
- **Horizontal padding inside a token** — limited; you can only
  style the wrapping element, not paint inside it.
- **Custom caret shapes other than line / block** — `drawSelection`
  draws a `<div>`; restyle via CSS but no per-frame animation hook.

For our use case (markdown / source editor) — nothing on this
list matters.

---

## Question 13 — History / undo

**Verdict: ⚠️ Powerful but with one real gap (no per-step event).**

From `@codemirror/commands/src/history.ts` [S33]:

### 13a — Is history a black box?

No. The `historyField` is exported as `StateField<unknown>` and
its value is **introspectable**:

```ts
const historyState = view.state.field(historyField, false)
// historyState has .done and .undone branches.
// Each branch is a list of history events with their effects + change ranges.
```

You can walk `done` to enumerate every reversible step. The
items are CM6-internal types — not pretty — but readable.

### 13b — Tag transactions with metadata

Annotations are the canonical mechanism [S34]:

```ts
// Define a custom annotation type.
const SavePoint = Annotation.define<{ id: string; mtime: Date }>()
const AutoFormat = Annotation.define<boolean>()

// Tag a transaction.
view.dispatch({
  changes: { from: 0, to: state.doc.length, insert: formattedText },
  annotations: [
    Transaction.userEvent.of("format"),
    AutoFormat.of(true),
    SavePoint.of({ id: "post-format", mtime: new Date() }),
  ],
})

// Read later from history walk:
historyState.done[i].annotations  // your custom annotations here
```

`Transaction.userEvent` is the official tagging scheme; values
like `"input.type"`, `"input.paste"`, `"delete"`, `"undo"`,
`"select"` are convention. Use dot-separated for sub-types.

### 13c — Per-history-step event?

**No.** [S33] confirms: "No dedicated event listener exists in
this code. History additions occur silently through state field
updates."

Workaround — `updateListener` + diff:

```ts
let lastDone: number = 0
EditorView.updateListener.of(update => {
  if (!update.docChanged) return
  const h = update.state.field(historyField, false) as any
  if (h.done.length > lastDone) {
    // New history entry added.
    const newEntries = h.done.slice(lastDone)
    bridge.send({type: "historyEntriesAdded", entries: newEntries.map(serialize)})
    lastDone = h.done.length
  }
})
```

For a "time-travel" pane this works, but you're guessing at
CM6 internal types. Pin to a CM6 version and add a test that
asserts the shape.

### 13d — Rewind to arbitrary point?

Two approaches:

1. **Step-by-step undo** — call `undo(view)` N times. Lossy on
   history-relative state (timestamps, etc.).
2. **Snapshot restore** — `EditorState.toJSON()` / `fromJSON()`.
   Capture a snapshot per "interesting" point; restore via
   `view.setState(EditorState.fromJSON(snapshot, config, fields))`.
   `historyField`'s `toJSON` / `fromJSON` are implemented [S33].

The "snapshot per save point" pattern is the practical one. Cost:
~size-of-doc per snapshot in memory. For a 100 KB doc, 50 saved
points = 5 MB JS heap. Cheap.

### 13e — Persistence

`historyField` serializes via JSON [S33]:

```ts
historyField.spec.toJSON   // (value) => { done, undone }
historyField.spec.fromJSON // (json) => HistoryState
```

So undo history survives:

- **Tab switches**: ✅ via `view.state.toJSON({history: historyField})`
  then `EditorState.fromJSON(snapshot, config, {history: historyField})`.
- **App restarts**: ✅ same — persist the JSON to disk per tab.
  Watch the size: 100 KB doc + 100 undo entries = ~5 MB JSON
  per tab. Don't persist on every keystroke (debounce).

### 13f — Tag user actions

Already covered in 13b. We'd want:

```ts
// In our keymap:
[
  { key: "Mod-s", run: v => { v.dispatch({annotations: [SavePoint.of(...)]}); save(); return true } },
  // … etc.
]

// On paste:
EditorView.clipboardInputFilter.of((text, state) => {
  // ... transform ...
  return text
})
// — paste already gets userEvent: "input.paste" automatically.
```

### Verdict

History is **observable** (post-hoc via `historyField`), **taggable**
(via annotations), **serializable** (per-state JSON), **rewindable**
(via snapshot restore). The one gap is **no per-step event** —
mitigated by watching `done.length` in `updateListener`.

For a "time-travel" pane: feasible. Roll our own thin layer:

- Per save / autoformat / explicit-checkpoint, snapshot state to
  JSON + persist to disk + index in a side store.
- UI shows the snapshot timeline; click → `view.setState(fromJSON(...))`.
- For granular undo *between* checkpoints, the existing `undo` /
  `redo` commands cover it.

---

## Question 14 — Bus-factor risk if CM6 becomes unmaintained

**Verdict: ⚠️ Lower risk than it was a year ago. Bus-factor mitigated by sponsorship + ecosystem.**

### The maintainer

CodeMirror has a clear keystone person: **Marijn Haverbeke**. He
also wrote ProseMirror, Lezer, and *Eloquent JavaScript*. Single
primary author for ~10 years.

**Important update from 2025** [S3]:

> "OpenAI will be sponsoring Marijn Haverbeke, the creator and
> maintainer of the two open source libraries used in making
> ChatGPT canvas, ProseMirror and CodeMirror."

His funding page [S35]:

> "Both ProseMirror and CodeMirror have a bunch of serious
> sponsors, which help him pay his bills. His sponsorship is
> mostly from corporations who have his projects as an essential
> part of their systems and are interested enough to keep them
> healthy."

He also signed the Open Source Pledge — actively engaged with
the funding ecosystem. **The bus factor is real but the funding
is stable.**

No foundation, no formal maintainer roster — Marijn is the
keystone, contributions accepted via mailing list / PRs.

### Fork cost — what's involved

If we had to fork-and-maintain ourselves:

| Component                 | LOC (minified KB → est. source KB)   | Complexity |
|---------------------------|--------------------------------------|------------|
| `@codemirror/state`       | ~80 KB min → ~5K LOC src             | medium — immutable data structures, transactions |
| `@codemirror/view`        | ~290 KB min → ~15K LOC src           | **high** — DOM management, viewport, IME, drawSelection, gestures |
| `@codemirror/commands`    | ~38 KB min → ~3K LOC src             | low — mostly individual keybinding handlers |
| `@codemirror/search`      | ~30 KB min → ~2K LOC src             | low — search panel + state field |
| `@codemirror/language`    | ~80 KB min → ~6K LOC src             | medium — Lezer tree adapter + fold + indent infra |
| `@codemirror/lang-*` each | 10–120 KB min → 1–10K LOC src        | low (per-language) — handwritten Lezer grammars |
| `@lezer/common`           | ~10 KB min → ~1.5K LOC src           | medium — incremental parser runtime |
| `@lezer/lr`               | ~25 KB min → ~3K LOC src             | high — LR parser engine |
| `@lezer/highlight`        | ~10 KB min → ~1K LOC src             | low — tag → style map |

**Total non-language source: ~40K LOC TypeScript.** That's
~3–6 month-equivalents of work for one engineer to deeply
understand, ~1 quarter for a small team to feel competent
maintaining (vs. building).

Compare:

| Stack                     | Fork-feasibility for a small team |
|---------------------------|-----------------------------------|
| CM6                       | feasible — ~40K LOC TS, MIT, monorepo |
| Lezer                     | feasible — ~5K LOC TS, MIT       |
| Scintilla                 | feasible — ~100K LOC C++, HPND   |
| NSTextView (TK1 / TK2)    | **impossible** — Apple-private; can't fork; can only wait or roll your own (~50K LOC of careful AppKit) |
| Custom CoreText           | "fork" = build from scratch       |

### Are there mature forks already?

- **`@replit/codemirror-vim`** — Replit forked + extended the
  CM5 vim addon for CM6. **Marijn himself is the #3 contributor**
  to that fork (CM6 design doc §1.2). Demonstrates the fork
  pattern works *and* upstream sees forks as collaborative.
- **`code.haverbeke.berlin/codemirror/*`** — Marijn moved
  primary hosting off GitHub to his self-hosted Gitea instance
  in 2024; GitHub is now a mirror. Some forks might lag if they
  point only at GitHub.

### Relative-risk comparison

| Editor stack                        | Risk of "stuck" today | Risk of "stuck" in 5 yr |
|-------------------------------------|------------------------|--------------------------|
| CM6                                  | low (active dev, OpenAI sponsors) | medium |
| Scintilla                            | very low (27 yr track) | medium (Neil Hodgson keystone) |
| NSTextView TK1                       | medium (soft-deprecated; works) | medium-high (Apple may drop) |
| NSTextView TK2                       | medium-high (bug-prone now; needs Apple attention) | medium (might mature) |
| Custom CoreText / Metal              | n/a — you ARE the maintainer | n/a |

Verdict: **CM6's bus-factor risk is real but not the highest in
the relevant set.** The funding signal (OpenAI sponsorship 2025)
is a recent strong positive. Mitigation: pin exact versions; if
CM6 stops getting updates we can fork what we have without too
much LOC pain.

---

## Question 15 — Keyboard shortcuts

**Verdict: ✅ Full control via `keymap.of(...)` + `Prec.highest`.**

### Does CM6 take over keystrokes?

When the editor is focused, CM6 receives keystrokes via the
content DOM's `keydown` listener. The dispatch order:

1. Per-keymap `run` handlers (in extension precedence order).
2. If no handler returns `true`, the event bubbles up to the
   browser → which respects `contenteditable` defaults → which
   in WKWebView is mostly suppressed for editing-like keystrokes.

For **Cmd-modified** keystrokes specifically: **CM6's built-in
keymaps DO NOT bind Cmd-keys**. The `defaultKeymap` uses Mac-
appropriate `Mod-` (which maps to ⌘ on Mac) for things like
`Mod-z` (undo), `Mod-a` (select all), `Mod-Enter` (insert above).
That means **most ⌘-keys naturally fall through to the AppKit
menu system** unless you explicitly bind them in CM6.

But once you bind something via `keymap`, that handler runs
*before* the menu sees the event. Example: if you bind
`Mod-s` in CM6, the system's File → Save menu item's
`⌘S` won't fire (the menu key equivalent check happens after
the responder chain, which the WKWebView consumes first).

### Make ALL `Cmd-*` macOS-system-handled

Goal: every ⌘-key bubbles up to NSApp menu, never CM6.

Strategy: register an "absorb everything Cmd-*" filter in
`Prec.highest` that returns `false` (didn't handle) so the
event bubbles — but explicitly prevents the default-keymap from
seeing it:

```ts
import { Prec } from "@codemirror/state"
import { keymap } from "@codemirror/view"

const releaseAllCmdToHost = Prec.highest(
  keymap.of([{
    // 'any' catches every key
    any: (view, event) => {
      // On Mac, metaKey === Cmd. We want CM6 to NOT handle this.
      // Returning false from 'any' continues to lower-precedence
      // keymaps. To suppress them entirely, we'd return true AND
      // not preventDefault the underlying event — but that's the
      // tricky bit.
      if (event.metaKey) {
        // Don't preventDefault — let bubble continue.
        // Return true so lower-precedence keymaps (defaultKeymap)
        // don't claim this event.
        return true
      }
      return false
    },
  }])
)
```

The subtle problem: returning `true` from a CM6 key handler
**stops dispatch within CM6** but also calls `event.preventDefault()`
internally for some shapes — which would then stop the menu from
seeing the event. The accurate way is to register a `domEventHandlers`
keydown filter that selectively un-preventDefaults:

```ts
EditorView.domEventHandlers({
  keydown(event, view) {
    if (event.metaKey && !event.altKey) {
      // Let macOS handle it. Don't preventDefault.
      // Return true so CM6's internal keymap dispatch doesn't fire.
      return true
    }
    return false
  }
})
```

Whether the macOS menu still picks it up depends on WKWebView's
responder chain. In practice, **AppKit menu items with key
equivalents see the event before the WKWebView's keydown handler
fires**, so as long as the AppKit menu item is registered, ⌘S /
⌘W / ⌘N / ⌘T etc. all work normally. CM6 just doesn't bind
those by default.

For the cases CM6 *does* bind (⌘Z, ⌘Y, ⌘A, ⌘Enter), the path is:

```ts
// Remove from defaultKeymap (or override with Prec.highest):
const overrideCmdShortcuts = Prec.highest(keymap.of([
  { key: "Mod-z", preventDefault: false, run: () => false },  // explicitly don't handle
  { key: "Mod-Shift-z", preventDefault: false, run: () => false },
  { key: "Mod-a", preventDefault: false, run: () => false },
]))
```

This makes our AppKit menu Undo/Redo/Select-All work uniformly
across NSTextView and CM6.

### Add our own shortcuts CM6 won't shadow

Easy — add to `keymap.of([...])` in `Prec.highest`:

```ts
Prec.highest(keymap.of([
  { key: "Mod-Shift-f", run: () => { bridge.send({type: "openUnifiedSearch"}); return true } },
  { key: "Mod-Shift-p", run: () => { bridge.send({type: "openCommandPalette"}); return true } },
]))
```

First entry wins; `Prec.highest` ensures it beats any community
extension that might claim the same key later.

### Precedence model

From `@codemirror/state` Prec docs [S36]:

> "Extensions that do not have a precedence set get the
> precedence of the nearest parent with a precedence, or
> `default` if there is no such parent. The final ordering of
> extensions is determined by first sorting by precedence and
> then by order within each precedence."

Levels (highest → lowest): `highest`, `high`, `default`, `low`, `lowest`.

For keybindings specifically, **earlier entries in the same
`keymap.of([...])` array win**. Combined with `Prec.highest`,
this is full control.

---

## Question 16 — Paste interception / transform / suppress

**Verdict: ✅ Comprehensive. `clipboardInputFilter` is the headline API.**

### Observe paste

```ts
EditorView.domEventHandlers({
  paste(event, view) {
    const text = event.clipboardData?.getData("text/plain") ?? ""
    const html = event.clipboardData?.getData("text/html") ?? ""
    bridge.send({type: "pasteObserved", textLength: text.length, hasHtml: !!html})
    return false  // continue normal paste
  }
})
```

### Transform pasted content before it lands

The official mechanism from `@codemirror/view` [S37]:

```ts
// "Functions provided in this facet will be used to transform text
//  pasted or dropped into the editor."
EditorView.clipboardInputFilter.of((text, state) => {
  // Strip HTML from a clipboard copy:
  // (clipboardInputFilter only sees text/plain; HTML stripping
  //  happens before this — but other normalizations apply here.)

  // Normalize CRLF → LF:
  text = text.replace(/\r\n/g, "\n")

  // Convert tabs → spaces if our doc is space-indented:
  if (state.facet(EditorState.tabSize) && !useTabs) {
    const indent = " ".repeat(state.facet(EditorState.tabSize))
    text = text.replace(/\t/g, indent)
  }

  return text
})
```

Returning a different string is the transformation. Multiple
filters chain by extension order.

### Route through a Swift-side prompt ("you're pasting 50 lines, confirm?")

Async confirmation interleaved with paste is *trickier* because
`clipboardInputFilter` is synchronous. Pattern:

```ts
// Suppress the auto-paste in a domEventHandler:
EditorView.domEventHandlers({
  paste(event, view) {
    const text = event.clipboardData?.getData("text/plain") ?? ""
    if (text.split("\n").length > 50) {
      event.preventDefault()  // suppress the default paste
      // Ask Swift; Swift will dispatch a `replaceRange` if confirmed:
      bridge.send({
        type: "confirmLargePaste",
        text,
        pos: view.state.selection.main.from,
        to: view.state.selection.main.to,
      })
      return true  // we handled it
    }
    return false  // continue default paste
  }
})
```

Swift shows the confirm sheet, then on confirm dispatches a
`replaceRange` over the bridge. The paste round-trips through
Swift but the UX is "click confirm → text appears" with no
visual artifact.

### Suppress paste entirely

```ts
EditorView.domEventHandlers({
  paste(event) { event.preventDefault(); return true },
  drop(event)  { event.preventDefault(); return true },
})
```

### Per-region read-only

If we want paste suppressed *only* in certain ranges (e.g.
read-only frontmatter), use `EditorState.changeFilter`:

```ts
EditorState.changeFilter.of(tr => {
  if (!tr.docChanged) return true
  let allow = true
  tr.changes.iterChangedRanges((from, to) => {
    if (intersectsReadOnlyRegion(from, to)) allow = false
  })
  return allow  // false → reject entire transaction
})
```

Or rewrite the change to skip the read-only region by returning
a numeric array of allowed change ranges (advanced).

### Verdict

Full control on paste — observe, transform, gate via Swift prompt,
or suppress. `clipboardInputFilter` is the right primitive for
synchronous transformation; `domEventHandlers.paste` is the
escape hatch for async / gated flows.

---

## Cross-cutting takeaways

### What the answers add up to

1. **CM6's extension model wins**. Every "can we…" question has
   a yes-with-API. The pain points are bridge IPC cost (mitigated
   by debouncing), JS heap for huge files (mitigated by keeping
   NSTextView as fallback), and the absence of a few niche
   per-step hooks (history events).
2. **The biggest decision is not technical — it's "one viewer or
   two"**. The CM6 path is *technically* full-featured; the
   question is whether we want to maintain both NSTextView and
   CM6 paths long-term. My read: keep both for now, plan to
   retire NSTextView for ≤ 50 MB files after CM6 editor mode
   matures, keep NSTextView as the huge-file fallback indefinitely.
3. **The Q6 tree-sitter-via-bridge path** is the surprise win.
   Saves ~700 KB bundle, keeps our language set, unifies the
   highlight pipeline. Recommend doing this from Phase 1.
4. **`@codemirror/lsp-client` is the wrong abstraction for us**
   (per CM6 design doc §17.2 and confirmed by Q7). Use
   `@codemirror/lint` + `hoverTooltip` + `domEventHandlers` to
   inject Swift-side LSP results directly. Saves ~75 KB and
   keeps the LSP pool as authority.
5. **Bus factor is mitigated** by OpenAI sponsorship (2025).
   Lower-risk than NSTextView TK2's documented bugginess.

### What we should add to the CM6 design doc (BACKLOG)

The integration design doc (§12 feature table) doesn't currently
break out:

- ✏️ **Q6 tree-sitter bridge** — add as Phase 2 feature
  "decoration-bridge highlight pipeline" with explicit decision
  to *not* bundle `@codemirror/lang-*` packages for languages
  tree-sitter covers.
- ✏️ **Q8 right-click context menu** — add a Phase 1 / 2 line
  for "subclass `WKWebView` + override `willOpenMenu`" + JS
  `contextmenu` event filter.
- ✏️ **Q13 time-travel pane** — add as Phase 5 "snapshot-per-
  save-point" feature with the JSON-serialize-historyField trick.
- ✏️ **Q16 paste gating** — add a Phase 3 row "large-paste
  confirm prompt" using the `preventDefault` + Swift-route pattern.
- ✏️ **Q4 huge-file fallback** — make explicit: 50 MB cutover
  from CM6 → NSTextView read-only; add to §17.5 as a closed
  question.
- ✏️ **Q3 unification roadmap** — long-term plan to retire
  TextDisplayView for normal-size files once the shared-WebView
  refactor (feature #24) lands.

---

## Sources

- [S1] iCab Blog, *Customize the contextual menu of WKWebView on macOS* (2022) — `https://icab.de/blog/2022/06/12/customize-the-contextual-menu-of-wkwebview-on-macos/`
- [S2] Michael Tsai, *Customize the Contextual Menu of a Mac WKWebView* (2022) — `https://mjtsai.com/blog/2022/06/24/customize-the-contextual-menu-of-a-mac-wkwebview/`
- [S3] Romain Huet (OpenAI), tweet announcing OpenAI sponsorship of Marijn Haverbeke (Oct 2024) — `https://x.com/romainhuet/status/1841889813105971646`
- [S4] `@codemirror/view` source: `editorview.ts` (EditorView.editable, EditorView.clipboardInputFilter, EditorView.domEventHandlers definitions) — `https://github.com/codemirror/view/blob/main/src/editorview.ts`
- [S5] `@codemirror/state` source: EditorState.readOnly facet — `https://github.com/codemirror/state/blob/main/src/state.ts`
- [S6] MarkEdit, *Why MarkEdit* wiki (10 MB markdown claim, TextKit rejection) — `https://github.com/MarkEdit-app/MarkEdit/wiki/Why-MarkEdit`
- [S7] MarkEdit repo (CodeMirror 6 in WKWebView precedent) — `https://github.com/MarkEdit-app/MarkEdit`
- [S8] *Noticeable lag when dealing with large files* — `https://discuss.codemirror.net/t/noticable-lag-when-dealing-with-large-files/5928`
- [S9] *Content length limit (CodeMirror6)* — `https://discuss.codemirror.net/t/content-length-limit-codemirror6/4183`
- [S10] *Lazy-loading data for very large files (>100MB)* — `https://discuss.codemirror.net/t/lazy-loading-data-for-very-large-files-100mb/1263`
- [S11] Christian Tietze, *NSTextView Performance May Degrade for Large Plain Text Documents When usesFontPanel Is Active* (2021) — `https://christiantietze.de/posts/2021/09/nstextview-fontpanel-slowness/`
- [S12] Apple, *Meet TextKit 2* (WWDC21) — `https://developer.apple.com/videos/play/wwdc2021/10061/`; ChimeHQ, *TextViewBenchmark* — `https://github.com/ChimeHQ/TextViewBenchmark`
- [S13] WebKit docs, *Memory Inspection* — `https://docs.webkit.org/Infrastructure/MemoryInspection.html`; Embrace blog, *Why Is WKWebView So Heavy and Why Is Leaking It So Bad?* — `https://embrace.io/blog/wkwebview-memory-leaks/`
- [S14] CodeMirror System Guide — `https://codemirror.net/docs/guide/`
- [S15] *Improve Scroll / Performance tradeoff* — `https://discuss.codemirror.net/t/improve-scroll-performance-tradeoff/8825`
- [S16] CodeMirror million-line demo — `https://codemirror.net/examples/million/`
- [S17] npm `@codemirror` org — `https://www.npmjs.com/org/codemirror`
- [S18] CodeMirror community / language pages — `https://codemirror.net/docs/community/`
- [S19] CodeMirror Decoration Example — `https://codemirror.net/examples/decoration/`
- [S20] CodeMirror Inverted Effect Example — `https://codemirror.net/examples/inverted-effect/`
- [S21] *WKWebView Communication Latency* — `https://blog.persistent.info/2015/01/wkwebview-communication-latency.html`
- [S22] *Mapping Tree-Sitter trees to Lezer trees* — `https://discuss.codemirror.net/t/mapping-tree-sitter-trees-to-lezer-trees/2362`
- [S23] Joel Gustafson, *Syntax highlighting on the web* (2022) — `https://joelgustafson.com/posts/2022-05-31/syntax-highlighting-on-the-web/`
- [S24] MarkEdit `EditorViewController+TextFinder.swift` — `https://github.com/MarkEdit-app/MarkEdit/blob/main/MarkEditMac/Sources/Editor/Controllers/EditorViewController%2BTextFinder.swift`
- [S25] `@codemirror/lsp-client` repo — `https://github.com/codemirror/lsp-client`
- [S26] `@codemirror/lsp-client` announce thread — `https://discuss.codemirror.net/t/codemirror-lsp-client/9309`; DeepWiki overview — `https://deepwiki.com/codemirror/lsp-client/2-getting-started`
- [S27] `@codemirror/lint` source: `lint.ts` (Diagnostic, setDiagnostics, linter) — `https://github.com/codemirror/lint/blob/main/src/lint.ts`
- [S28] `@codemirror/view` hoverTooltip reference — `https://codemirror.net/docs/ref/#view.hoverTooltip`
- [S29] `@codemirror/search` selection-match — `https://github.com/codemirror/search/blob/main/src/selection-match.ts`
- [S30] `@codemirror/view` decoration source — `https://github.com/codemirror/view/blob/main/src/decoration.ts`
- [S31] `@codemirror/search` source: `search.ts` (search, createPanel, setSearchQuery, findNext etc.) — `https://github.com/codemirror/search/blob/main/src/search.ts`
- [S32] `@codemirror/view` gutter source — `https://github.com/codemirror/view/blob/main/src/gutter.ts`
- [S33] `@codemirror/commands` history source — `https://github.com/codemirror/commands/blob/main/src/history.ts`
- [S34] CM6 manual on Annotations + Transaction.userEvent — `https://codemirror.net/docs/ref/#state.Annotation`
- [S35] Marijn Haverbeke, *Funding Marijn* — `https://marijnhaverbeke.nl/fund/`
- [S36] CM6 reference for Prec — `https://codemirror.net/docs/ref/#state.Prec`
- [S37] `@codemirror/view` clipboardInputFilter + clipboardOutputFilter — `https://github.com/codemirror/view/blob/main/src/editorview.ts`

---

*End of document.*
