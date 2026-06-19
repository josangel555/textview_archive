# TSK-889 — Warm-reopen lag: view-preservation fix design

**Status:** design (root cause confirmed; implementation deferred to a focused effort).
**Owner P0.** Board: TSK-889 (full trace evidence in its comments). Tooling: TSK-961 (`vm-profile.sh reopen`).

## Problem
Re-opening / switching back to an already-open large file (e.g. a ~699 KB JSON) is laggy
(~20 ms+ stutter), even though the file's content + highlight are already computed.

## Root cause (confirmed by VM os_signpost + symbolicated traces)
- `open()` **de-dups** to the existing tab (DocumentModel.swift:3611) — re-open is a tab *switch*.
- But switching **away** dismantles the inactive tab's source view: SwiftUI removes it from the
  hierarchy → `dismantleNSViewController` → `SourceTextController.teardownStorage()`
  (TextDisplayView.swift:170) frees the heavy `NSTextStorage`/`NSLayoutManager` glyph store
  (a deliberate memory bound for large files).
- Switching **back** re-creates a fresh, **empty-storage** controller → `apply()` can't hit its
  existing skips (the `AttrKey` early-return at :995 and the in-place recolor at :1017 both need
  the text already laid out) → it runs the full `setAttributedString` + **O(N) glyph
  layout/typesetting** (debug trace: dominated by `NSATSTypesetter`/`NSLayoutManager`/`TGlyphEncoder`/
  font shaping — NOT `buildAttributed`). Cold open is fast because it paints plain→recolor, reusing
  the first layout.

So 889 is a **memory-vs-speed consequence**: inactive large-file views are torn down for memory,
and re-activation re-typesets. A cheap per-URL *attributed-string* cache would NOT help — the cost
is the per-`NSLayoutManager` layout, rebuilt on a fresh view.

## Fix: LRU view-preservation
Keep the laid-out `SourceTextController` (its `NSTextView` + `NSTextStorage` + `NSLayoutManager`)
alive for the **N most-recently-active tabs** (small LRU, N≈4); `teardownStorage` only on **close**
or **LRU eviction**. On switch-back the controller is reused → `apply()` early-returns on the
`AttrKey` match → only AppKit's cheap viewport re-layout runs.

### Implementation sketch
- A shared, main-actor `SourceControllerCache` keyed by tab/URL identity, LRU-bounded (N≈4),
  holding strong refs to preserved `SourceTextController`s.
- `makeNSViewController`: look up the cache by the tab's stable id; **reuse** the cached controller
  if present, else create + insert (evicting + `teardownStorage`-ing the LRU tail).
- `dismantleNSViewController`: do **not** `teardownStorage` if the controller is still cache-resident
  (tab merely deactivated); only teardown on actual close (tab removed) or eviction.
- The cache key must be the **tab identity**, not just URL (two tabs, same URL edge cases), and must
  be purged when a tab closes (hook the existing close path that maintains `tabCoordinator.openTabURLs`).

### Risks (why this is not a blind autonomous edit)
- Touches the **core tab-switch lifecycle** — a bug = broken tab switching / stale content / a view
  shown in the wrong tab. High blast radius.
- Reusing an `NSViewController` across SwiftUI representable instances is non-idiomatic; SwiftUI's
  expectations around make/dismantle must be respected (detached-then-re-added must be clean).
- Memory: N preserved large-file glyph stores. Keep N small; consider a byte-budget cap (evict by
  total retained storage, not just count) so N huge files don't blow the budget.

### Safe rollout
Land behind a default-OFF flag (e.g. `MDV_PRESERVE_RECENT_SOURCE_VIEWS`), enable + validate on the
VM, then flip the default. Keeps `main` safe while the lifecycle change bakes.

### Validation pyramid
1. **Host:** unit-test `SourceControllerCache` (LRU insert/reuse/evict/purge-on-close) — pure logic.
2. **VM reopen trace:** `vm-profile.sh <bigjson> 18 reopen` — confirm `SourceTextController.apply`
   drops from ~20 ms to a cheap re-attach on the switch-back (the teeth: it must measurably improve).
3. **VM UI:** a tab-switch correctness test — switch among ≥N+1 tabs, confirm each shows the right
   content (no stale/wrong-tab view), and that the evicted tail re-renders correctly.

### Value caveat
The fixture that surfaced this is `indent=1` (tens of thousands of lines) — a typesetting worst case.
A more compact real 699 KB JSON may re-layout faster; the **owner's actual laggy file** would size the
real win and set N / the byte budget. Worth confirming before investing in the full lifecycle change.
