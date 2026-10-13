# HEX view performance — implementation + validation plan (TSK-267 / #218)

**Status:** plan only. The fix is live-validation-blocked (needs Instruments on the target macOS);
this turns the vague "1MB HEX extremely slow" complaint into an actionable, reviewed plan with a
testable seam. Author: autonomous run 2026-06-06. `main` @ `3a65759`.

## Confirmed diagnosis (from the TSK-267 spike + code read)
- **Model layer is clean.** `HexDumpBuilder.renderRows` is `withUnsafeBytes` raw-pointer iteration
  with `reserveCapacity` + amortized-O(1) append: 6 KB builds in µs, 1 MB well under 100 ms. Already
  unit-tested. **Not** the bottleneck.
- **Cost is view-layer**, two distinct problems:
  1. **1 MB killer — eager full-document layout.** `HexView` builds the ENTIRE dump as one
     `NSAttributedString` pushed into one `NSTextView` (`Sources/ViewerUI/HexView.swift`, the
     `HexTextController`). The text view is vertically resizable with an effectively-infinite
     container, so TextKit lays out the whole multi-MB monospaced grid up front to compute document
     height. Layout, not string-building, dominates.
  2. **6 KB ~1 s — fixed per-open overhead.** Too small to be dump size. It's mode-switch remount +
     async load + layout setup + the chunked-build machinery (background queue, "Building hex dump…"
     placeholder, per-chunk `DispatchQueue.main.sync` round-trips). Perf Fix#1 (TSK-108, pane
     retention) already removes the *remount* cost for revisited tabs; first-open still pays it.

## The blocking unknown: TextKit 1 vs TextKit 2
Highlights are applied via `textView.textStorage.addAttribute(.backgroundColor:)` (storage-level),
**not** `layoutManager` temporary attributes — so the code does NOT currently force a TextKit 1
downgrade. On the macOS 15 SDK, `NSTextView.scrollableTextView()` returns a **TextKit 2**
(`usesTextLayoutManager = true`) view by default. **Which engine is actually live at runtime decides
the whole approach** and can only be confirmed by inspecting `textView.textLayoutManager != nil` /
`textView.layoutManager` (the latter forces a downgrade) on the target OS:

- **If TK2 is live:** TK2 already does *viewport-based* layout (lays out only the visible region).
  Then the 1 MB slowness is likely (a) something forcing full layout — e.g. querying document
  height for `isVerticallyResizable`, or the chunked `beginEditing/endEditing` over the whole
  storage — or (b) `addAttribute` over `NSRange(0, storage.length)` in `applyHighlights`' full-paint
  path (it removes `.backgroundColor` across the ENTIRE storage on every non-fast-path update →
  O(document) attribute walk). Fix = stop touching full-document ranges; scope attribute ops to the
  matched rows only.
- **If TK1 is live (or we must downgrade):** enable `layoutManager.allowsNonContiguousLayout = true`
  — the canonical large-NSTextView fix; for a uniform monospaced grid the height estimate is exact,
  so no scroll-thumb jumpiness, and character indices (caret/click math) are unchanged.

## Proposed work (in order; each independently shippable)
1. **Instrument first (live).** Build debug, open a 1 MB binary in HEX, Time Profiler. Confirm TK1/TK2
   and where the ms go (layout vs attribute walk vs chunk round-trips). ~30 min. **Gates the rest.**
2. **Cheap, safe win regardless of engine — scope the highlight clear.** `applyHighlights` full path
   does `storage.removeAttribute(.backgroundColor, range: NSRange(0, storage.length))` every time the
   match set/width changes. Replace with: track painted ranges and clear only those (we already keep
   `lastPaintedMatches`). Removes an O(document) walk from every search edit. Headless-testable if we
   extract the "ranges to clear" computation into a free function in `ViewerCore`/`HexLayout`.
3. **Small-file fast path.** Below a threshold (e.g. ≤ 256 KB rendered), build the dump synchronously
   in one shot — skip the background queue, placeholder, and per-chunk `main.sync`. Kills the 6 KB
   ~1 s per-open overhead. Threshold decision is pure logic → headless unit test.
4. **1 MB: lazy layout.** Apply the TK1/TK2-appropriate lever from step 1's finding (non-contiguous
   layout, or stop forcing full layout / scope attribute ops). Live-validate scroll + select + search
   on a 1 MB file.

## Testability seam (so this isn't live-only forever)
`HexTextController` is `private` → not unit-testable today. To get automatic coverage, lift the pure
decisions OUT of the controller into testable units:
- `HexLayout.clearRanges(painted:patternLength:width:) -> [NSRange]` (step 2).
- `HexRenderPlan.useSyncBuild(renderedByteCount:) -> Bool` (step 3 threshold).
Then headless XCTests pin the logic; only the TextKit wiring + perf numbers need the live smoke.

## Validation
- Headless: unit tests for the extracted pure functions (steps 2–3) + the existing `HexDumpBuilder`
  golden tests; `scripts/test-headless-gate.sh` green on the committed commit.
- Live (next supervised live turn, footgun now fixed so host smoke is safe): `bash
  scripts/build-app.sh debug`, open a 1 MB binary + a 6 KB file in HEX, confirm sub-100 ms render,
  exercise scroll / drag-select / byte-search next-prev / click-highlight / (if editable) byte edit
  for no regression. Time Profiler before/after.

## Risk notes
- Do NOT blind-flip `allowsNonContiguousLayout` without step 1 — if TK2 is live, touching
  `layoutManager` *downgrades* to TK1 and could regress, not help.
- Steps 2 + 3 are engine-agnostic and low-risk → land those first.
- HEX view is a regression-prone tuned zone (edit-caret, click-highlight, chunked append,
  temporary-attribute-free highlight) — every change needs the live HEX smoke, not just the gate.
