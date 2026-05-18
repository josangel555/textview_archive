# Code folding — design

**Status:** design only. No code yet.
**Last update:** 2026-05-18.

## Goal

Collapse syntactic regions (JSON objects, XML elements, function
bodies, code-fence contents, multi-line strings, multi-line comments)
to a single line in the source view. Click the gutter chevron → toggle
fold. Cmd-Option-[ / Cmd-Option-] / Cmd-Option-Shift-[ to collapse /
expand / collapse-all at caret.

## Non-goals

- Code folding in rendered markdown view (different layout pipeline).
- Persistence of fold state across app launches (per-tab + per-session
  is enough for v1).
- Folding by indentation (e.g. for `.py`, `.yaml`) — purely
  syntax-aware. TreeSitter knows the structure; indentation-only
  folding has different semantics worth deferring.

## TreeSitter integration

TreeSitter grammars expose a `folds.scm` query file that declares which
nodes should fold:

```
(object) @fold
(array) @fold
(function_declaration body: (_) @fold)
```

The default queries in upstream grammars cover ~80% of intuitive
folding behaviour. We vendor them next to `highlights.scm` per the
existing pattern.

For grammars without an upstream `folds.scm` (currently: many of the
ones we ship), we hand-roll one based on the grammar's node-type
list. Initial languages targeted, in priority order:

1. **JSON / JSONL** — `object`, `array`. Trivial.
2. **XML / HTML** — `element` with multi-line content.
3. **Swift** — function bodies, type declarations, multi-line
   `if`/`for`/`while`, multi-line string literals.
4. **JavaScript / TypeScript** — function bodies, class bodies,
   object literals, array literals, JSX elements.
5. **Markdown** — fenced code blocks, ATX headings (fold-to-next-heading).
6. Everything else — generic "any node spanning ≥ 3 lines that has a
   typed name we recognize".

## Data model

```swift
// Sources/ViewerCore/Highlight/FoldRegion.swift

/// Folding region in a parsed document.
public struct FoldRegion: Hashable, Sendable {
    public let startLine: Int    // 1-based, inclusive
    public let endLine: Int      // 1-based, inclusive
    public let kind: Kind

    public enum Kind: String, Sendable, Hashable {
        case object        // { ... }
        case array         // [ ... ]
        case function      // function body
        case type          // class / struct / enum body
        case codeFence     // ``` … ``` in markdown
        case comment       // /* … */, // … // line block
        case stringLiteral // multi-line "..."
        case element       // XML element
        case other         // generic "node spans ≥ 3 lines"
    }
}

/// Per-document set of folds + which ones are currently collapsed.
/// Lives on `DocumentModel` alongside other per-tab state.
public struct FoldState: Sendable, Equatable {
    public var regions: [FoldRegion] = []
    public var collapsed: Set<FoldRegion> = []
}
```

## Computing regions

`TreeSitterEngine.computeFolds(text:language:) async -> [FoldRegion]`.
Runs on a background task; caches per-tab keyed on
`(url, contentHash)` like the existing highlight runs. Re-runs on
file-watcher reload (cache invalidates by hash).

For languages without TreeSitter coverage (`plainText`, etc.) we
return an empty array; folds simply don't appear in the gutter.

## Source-view integration

### Gutter chevrons

`SourceGutterView` currently renders line numbers + diff stripes +
bookmark dots. Add a 12 pt column to the left of the line number
showing a chevron for any line that starts a fold region:

```
 ▾  10  func foo() {
       11    let bar = 42
       12    return bar
       13  }
```

When the region is collapsed:

```
 ▸  10  func foo() {…}    ← visual "fold ellipsis" in the source view
       14  func next() { … }
```

Click the chevron to toggle. Hover shows the count: `Fold 3 lines`.

### Hiding folded lines

The expensive part. `NSTextView` doesn't natively support hiding line
ranges. Two implementation approaches:

1. **`NSLayoutManager.setExtraLineFragmentRect(_:)` magic** —
   technically possible, but fragile and historically the path that
   triggers the SwiftUI compositor pathology (see `LESSONS.md`).
   **Avoid.**

2. **`NSLayoutManager.setTextStorage` swap with a "displayed text"
   buffer** — maintain two parallel `NSTextStorage`s: the canonical
   one (full text, used for find/save/etc.) and a displayed one
   (collapsed). Translate caret + selection between them via a
   line-mapping table.

The mapping table is the v1 implementation: `[Int]` of N-original-line
→ M-displayed-line. Fast to compute from `FoldState.collapsed`. Update
on every toggle. NSTextView gets the collapsed buffer; the canonical
text never changes.

Find / replace / save operate on the canonical buffer. The user's
caret/selection is translated each direction:
- Caret in original → displayed: lookup in the line-map.
- Caret in displayed → original: reverse lookup (constant-time with
  a parallel array).

### Fold ellipsis

When a region is collapsed, the displayed buffer gets:

```
func foo() {…}
```

with the `{…}` rendered in `tertiaryLabelColor`. Click the `{…}`
glyph → expand. Implemented as a custom NSTextAttachment.

## Keyboard

- `⌘⌥[` collapse fold at caret (smallest enclosing)
- `⌘⌥]` expand fold at caret
- `⌘⌥⇧[` collapse all
- `⌘⌥⇧]` expand all
- Click chevron → toggle (same as `⌘⌥[/]`)

## Persistence

Per-tab in-memory only for v1. Closing the tab drops the fold state.
A future enhancement could persist `collapsed: Set<FoldRegion>`
alongside other per-tab state in the session snapshot.

## Out of scope for v1

- Fold across multiple files (no equivalent in any editor).
- Fold based on user-defined regions (`// region foo` / `#region`).
  Re-add in v1.1 after measuring the v1 surface.
- Persisted state across app launches.
- Folding in the rendered markdown view.

## Effort estimate

- 0.5d: vendor / write `folds.scm` for the 6 priority languages.
- 0.5d: `FoldRegion` + `FoldState` + `TreeSitterEngine.computeFolds`.
- 1d: line-mapping table + caret translation.
- 1d: gutter chevron rendering + click handling.
- 0.5d: fold-ellipsis NSTextAttachment.
- 0.5d: keyboard shortcuts.
- 1d: tests (region detection, line mapping, caret translation).
- 0.5d: integration testing on VM (collapse / expand / find /
  save round-trips).

**Total: ~5.5 dev days.**

## Risk

The line-mapping translation is the only piece that genuinely scares
me. NSTextView is well-known to misbehave around custom layout
managers (we already pay for one workaround per `LESSONS.md`). The
double-buffer approach side-steps that by keeping the layout manager
vanilla and only changing the storage; that's the safer choice but
adds a (cheap) per-folder array indexing step on every selection
update.
