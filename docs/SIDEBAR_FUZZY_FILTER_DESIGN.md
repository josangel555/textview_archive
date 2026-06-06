# Sidebar fuzzy file-nav filter — execute-ready design (TSK-282)

> **Status:** design spike (no code yet). Owner ask (TSK-282): *"typing in the
> file-nav tool should fuzzy find and highlight matches."* The implementation
> touches `SidebarView` (a perf-sensitive file — see #215) and needs a live
> window to validate latency + highlight rendering, so it is **deferred to a
> screen-unlocked / live-smoke turn**. This doc makes that turn fast + safe.
>
> Authored from a headless heartbeat after confirming the SwiftUI
> headless-safe pool was drained; this is the "Spike / Task Breakdown" SDLC
> activity, mirroring the Tools-surface plan that let `7e9d78f` land in one
> pass.

## What already exists (reuse, don't rebuild)

- **`FuzzyMatcher` (`Sources/ViewerCore/FuzzyMatcher.swift`)** — pure,
  Unicode-safe, already shipped + well-tested (`FuzzyMatcherTests`, incl.
  filename/path inputs like `far/foo/readme.md`). Key API:
  - `match(_ query:against:) -> Match?` where `Match { score: Int,
    matchedIndices: [Int] }` (indices into the **original** target's
    `Character` array — safe to bold in the un-lowercased display string).
  - `filterWithMatches(_ items:query:by:) -> [(item, match)]` — ranked,
    **stable** tie-break on input order. This is the exact entry point to use.
  - Scoring already rewards word boundaries (`/ _ - . space`), consecutive
    runs, and pref/early matches — correct for path/filename ranking.
- **Highlight precedent:** `CommandPaletteView` already bolds matched glyphs
  from `Match.matchedIndices`. Lift the same `HighlightedText`-style helper
  (grep `CommandPaletteView` for the matched-index → `AttributedString`
  builder) so the sidebar rows render identically. Do **not** invent a second
  highlight path.
- **`SidebarModel.flatVisibleRows() -> [VisibleRow]`** —
  `VisibleRow { node: FileNode, depth: Int; id == node.url }`, cached in
  `cachedFlatRows`, invalidated by `invalidateFlatCache()`. **Only includes
  children of *expanded* dirs** (it walks the `expanded` set). This is the
  crux of the scope decision below.

## Scope decision: narrow-visible vs. global-find

`flatVisibleRows()` only contains rows under currently-expanded folders. So
there are two genuinely different features:

| Mode | Candidate set | Cost | Matches owner intent? |
|------|---------------|------|-----------------------|
| **(A) Narrow visible** | filter `flatVisibleRows()` | cheap (already in memory) | partial — can't find a file in a collapsed dir |
| **(B) Global find** | every file under `rootURL` | needs full-tree walk + auto-expand ancestors of matches | yes — "fuzzy **find**" implies surfacing unseen files |

**Recommendation: ship (A) first as the MVP, architect for (B).** (A) is a
1-file view change with no FS-walk risk and immediately useful; (B) adds the
descendant cache (below) and auto-reveal. Gate them as two commits so the
risky part lands separately and is individually revertible.

## The perf hazard (why this isn't a 10-minute change)

#215 was a whole-UI-lag cascade caused by `SidebarView` doing expensive work
**in `body`** (sync FS walks, sync git walks) + over-broad `@ObservedObject`
observation re-rendering the world. The naive global-find ("walk the tree in
the filter computed-property") would reintroduce exactly that. Hard rules:

1. **No filesystem walk in `body` or in any computed property read during a
   body pass.** The global candidate set must come from a **pre-built, cached**
   list, refreshed off-main.
2. **`filterQuery` is view-local `@State`, NOT a `@Published` on
   `SidebarModel`.** Widening model observation is what #215 punished. The
   pure filter function takes the query as a parameter; the view owns it.
3. **Debounce** keystrokes (~120–150 ms) before running the filter, matching
   the palette/CSV-filter cadence.
4. **Cap results** (e.g. 500 rows) and `log()` truncation — never render an
   unbounded match list.
5. Reuse the existing **lowercased-cache** pattern (see CSV filter perf win
   #155 / `feedback`) if profiling shows per-keystroke lowercasing is hot.

## Architecture

### Pure core (headless-testable, ship in any lane)
A free function — no model state, no view:
```swift
// Sources/ViewerUI/SidebarFilter.swift  (or ViewerCore if no UI types leak)
struct SidebarMatch: Equatable { let url: URL; let matchedIndices: [Int] }
enum SidebarFilter {
    /// `candidates` = (displayString, url). displayString is the filename for
    /// mode (A), or the root-relative path for mode (B) so deep matches rank
    /// by path-segment boundaries. Returns ranked matches + bold ranges.
    static func filter(_ candidates: [(text: String, url: URL)],
                       query: String) -> [SidebarMatch]
}
```
Built directly on `FuzzyMatcher.filterWithMatches`. Fully unit-testable:
ranking, match-range correctness, filename-vs-path display, empty query,
cap behavior. **This is the only piece that can land headless** (with tests)
— but it's dead until the view consumes it, so land it *in the same commit*
as the mode-(A) view wiring, not before.

### Mode-(B) descendant cache (the deferred, careful part)
Add to `SidebarModel`:
- `private var descendantsCache: [VisibleRow-like {url, relPath}]?` built by an
  **async, off-main** walk of `rootURL` (respect `includeHidden`, skip
  `.git`/`node_modules`/build dirs like the existing tree walk does), invalidated
  by the SAME signals as `cachedFlatRows` **plus** FSEvents (the sidebar already
  has an FSEvents refresh, #153 — hook the cache invalidation there).
- A read-only accessor the view calls; if the cache is still building, fall
  back to mode-(A) candidates so typing is never blocked.

### View wiring (`SidebarView`, live-validation-needed)
- A `TextField` in the Files panel header (a11y id `sidebar.filterField`),
  `@State private var filterQuery`, debounced.
- When `filterQuery.isEmpty`: render the tree exactly as today (zero behavior
  change — additive, like the `availableModes` hint in TSK-332).
- When non-empty: render a **flat** result list (filter mode drops tree
  indentation; show root-relative path as secondary text) with bolded matched
  glyphs via the palette helper. `Esc` clears + restores the tree.
- Selection/open uses the existing `node(for:)` / open path — no new open logic.
- **Auto-reveal (mode B):** on commit/click of a filtered result in a collapsed
  branch, expand ancestors via the existing `expanded` set so the file is
  visible after the filter clears.

## Validation plan
- **Headless (this lane):** `SidebarFilterTests` — ranking order, match-range
  indices map to the right glyphs, filename vs relPath display, empty-query
  passthrough, result cap. Plus a `SidebarModel` test that the descendant-cache
  builder yields the expected set + honors `includeHidden` + skip-dirs.
- **Live (deferred turn):** `bash scripts/build-app.sh debug` → open a large
  folder, type, confirm: (1) results narrow + highlight correctly, (2) no
  visible typing latency / jank (the #215 acceptance bar), (3) Esc restores
  the tree, (4) selecting a result in a collapsed dir reveals it. Capture a
  `--diagnose` dump if a layout assertion is wanted.

## Effort / files
- `Sources/ViewerUI/SidebarFilter.swift` (new, ~40 LOC) + `SidebarFilterTests`.
- `Sources/ViewerUI/SidebarView.swift` (filter field + filtered row rendering;
  the sensitive edit).
- `Sources/ViewerUI/SidebarModel.swift` (mode-B descendant cache + invalidation).
- Reuse `CommandPaletteView`'s highlight helper (extract to a shared
  `HighlightedLabel` if it isn't already shared).
- ~1 focused live turn for (A)+(B); (A) alone is ~half that.

## Open question for the owner (not blocking the design)
Mode (A) vs (B) priority — (A) is instant + safe; (B) is the fuller "find any
file" intent but carries the descendant-walk. Default plan: land (A) first,
then (B) behind the same field. If the owner only wants (A), skip the cache
entirely.
