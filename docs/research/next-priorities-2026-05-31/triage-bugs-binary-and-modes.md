# Triage — bugs:binary-and-modes

I now have a complete, verified picture of all three bugs. Let me compile the findings.

---

### Bug 1 — SQLite table UI does not honor the UI-scale (zoom) preference

**Status today** — Confirmed. The SQLite browser is reached only via the `.preview(url, .sqlite)` state → `MediaPreviewView` (`ContentView.swift:317-326`, `MediaPreviewView.swift:47-48` → `SQLiteBrowserView(url:)`). `SQLiteBrowserView` and its `ResultTableView` are constructed with **only a URL** — no `DocumentModel`, no `zoom`, no `uiSize` closure (`SQLiteBrowserView.swift:12-19`, `MediaPreviewView.swift:17-29`). Every font and metric in the browser is a hardcoded literal:
- Sidebar group titles `size: 10` (`SQLiteBrowserView.swift:72`), table rows `size: 12` and fixed `height: 22` (`:85, :91`).
- Query label `size: 11` (`:114`), editor `size: 12` fixed `height: 110` (`:137-138`).
- `ResultTableView`: header `size: 11` (`:344`), cells `size: 11` (`:376`), `rowHeight: CGFloat = 22` (`:338`), column-width math in points (`computeWidths`/`approxTextWidth`, `:446-462`).

`SQLiteBrowserView` is correctly **absent** from the `grep uiSize` file list, whereas every other panel (ShoulderRail, StatusBar, Git panels, LSP panels, the ModeBar picker at `ContentView.swift:771`) routes sizes through `model.uiSize(_:)`, defined as `base * CGFloat(zoom)` (`DocumentModel.swift:146`).

**Root cause / gap** — The view is structurally cut off from the scale signal. `MediaPreviewView` takes `(url, category, onOpenSibling)` and never receives `model` or `zoom`, so there is no value to multiply against. Unlike `HexView` — which the `content` switch hands `fontSize: 12 * model.zoom` directly (`ContentView.swift:311-314`) — the sqlite path was built as a self-contained URL-only view. SwiftUI's `zoom` is not an environment value either, so nothing flows in implicitly.

**Fix / build sketch** — Plumb the scale through `MediaPreviewView` to `SQLiteBrowserView`:
1. Add a `uiScale: CGFloat` (or pass the `uiSize` closure) param to `MediaPreviewView.init` and forward it from the `.preview` arm in `ContentView.swift:317-326` (`model.zoom` is already in scope there, same as the HexView arm).
2. Thread it into `SQLiteBrowserView.init(url:uiScale:)` and `ResultTableView`.
3. Replace the literal sizes with `size * uiScale` and `rowHeight * uiScale`; scale the column-width constants (`approxTextWidth`'s `* 7`, the `80/220/320` clamps) too or they desync from the larger text. `computeWidths`/`approxTextWidth` are `internal static` and unit-tested — keep them pure by taking `uiScale` as a parameter rather than reading global state.
- Lower-effort alternative: wrap `SQLiteBrowserView` in `.environment(\.dynamicTypeSize, …)` — but its fonts are `.system(size:)` fixed-point, which ignore Dynamic Type, so this won't work without also converting fonts to text styles. The explicit-multiply approach matches the rest of the codebase and is the right call.

**Size** — **M.** Mechanically simple (multiply ~10 literals) but touches three files across two modules, the unit-tested width helpers, and the other preview arms share the same `MediaPreviewView.init` (image/audio/video/pdf) so the new param must be optional or all call sites updated. Manual VM verification needed (UI test, host-forbidden per `CLAUDE.md`).

**Dependencies** — None hard. `model.zoom`/`uiSize` already exist and are in scope at the `.preview` call site.

**Risk / one-way-door** — None. Additive param with a default keeps other previews compiling. No persistence or state-machine impact.

---

### Bug 2 — Misnamed binary (e.g. `mydb.db.bak`) can't be opened in the SQLite UI; type picker is locked out

**Status today** — Confirmed, with a nuance. Routing is **purely extension-driven**. `FileTypeDetector.category` keys off `url.pathExtension.lowercased()` against `sqliteExtensions = ["sqlite","sqlite3","db","db3"]` (`FileCategory.swift:55-71`). `mydb.db.bak` has extension `bak`, so it is **not** `.sqlite`; it falls through to UTI checks and lands as `.unknown` (`FileCategory.swift:86`). `DocumentController.open` then runs the text loader, which throws `binaryFile` on NUL bytes, producing `.binary(BinaryFile)` (`DocumentController.swift:91-103`) → `HexView` (`ContentView.swift:307-314`).

The picker for such a file is `ViewModeOptions.availableModes` = `[.source, .hex]` (`ViewMode.swift:21-49`; no rendered/format/table/diff/editor apply, and `supportsEditor` returns `false` for `.binary`/`.unknown`, `:93-101`). There is **no `.sqlite` ViewMode at all** — the `ViewMode` enum (`ViewMode.swift:7-15`) has no sqlite case, and sqlite is rendered via the `.preview` *state*, not a view mode. So today there is genuinely no UI affordance to say "treat this file as SQLite."

**Root cause / gap** — Two coupled gaps:
1. File-type identification is extension-only — no content sniffing. A SQLite DB has a fixed 16-byte magic header `"SQLite format 3\0"`; nothing reads it.
2. The user-facing "type" concept is split: `ViewMode` (Source/HEX/Format/…) is per-file in the picker, but `FileCategory` (which selects sqlite/image/preview) is **not** user-overridable anywhere. There is no "open as type X" menu. So even a correctly-detected-but-wrong case can't be forced.

**Fix / build sketch** — Two independent layers; do the override first (it subsumes the auto-detection need and is the actual ask):
1. **Add a SQLite affordance to the type picker.** Cleanest is a new `ViewMode.sqlite` (or `.database`) case, conditionally offered in `availableModes` and dispatched in `ContentView.loadedView`/`content`. But sqlite currently lives in *state*, not *mode* — so simpler: add a per-tab `categoryOverride: FileCategory?` on `Tab`, consulted by `FileTypeDetector`-aware call sites (`DocumentController.open`, `MediaPreviewView` routing, `availableModes`). When the user picks "Open as SQLite," set the override → re-run `controller.open` → `.preview(url, .sqlite)`. A "View as…" menu in the `ModeBar` (next to the language badge at `ContentView.swift:801-846`, which is the existing precedent for per-tab overrides) is the natural home.
2. **Add content sniffing (optional, makes it automatic).** In the `binaryFile` fallback of `DocumentController.open` (`:94`), before committing to `.binary`, read the first 16 bytes; if they equal `SQLite format 3\0`, return `.preview(url, .sqlite)`. This auto-fixes `mydb.db.bak` without any user action and is low-risk (a 16-byte read).

**Size** — **M** for sniffing-only (one focused change in `DocumentController.open` + a test). **L** for the full per-tab category-override + picker UI (touches `Tab`, `TabsState`/`TabCoordinator` persistence, `availableModes`, `MediaPreviewView` routing, `ModeBar`, and session/workspace serialization so the override survives restore).

**Dependencies** — The override approach depends on per-tab override plumbing (the language-override pattern at `DocumentModel.setCurrentLanguage` is a working template). Sniffing depends on nothing. Note **Bug 3 interacts**: if Source is removed for binaries (Bug 3), the type-affordance must live somewhere other than the mode segmented control — a separate "Open as…" menu — which argues for doing them together.

**Risk / one-way-door** — Persisting a `categoryOverride` in the workspace JSON is a schema addition; make it optional/forward-compatible (the codebase already guards against stale persisted modes — see the `appendLazyTab` clamp at `DocumentModel.swift:2405-2408`). Sniffing on the binary-fallback path runs for *every* binary open; cap it to a fixed 16-byte read so it can't regress large-binary open latency. No irreversible decisions.

---

### Bug 3 — "Source" mode should not be offered for binary files (only HEX, plus SQLite/preview where applicable)

**Status today** — Confirmed. For a binary file (category `.binary` or `.unknown`), `ViewModeOptions.availableModes` returns `[.source, .hex]` (`ViewMode.swift:23-47`: starts with `[.source]`, no special category matches, appends `.hex`). The picker renders both because `modes.count > 1` (`ContentView.swift:763-784`) and labels Source/HEX (`:860-870`). So **"Source" is shown for binaries.**

Worse, it's a dead/misleading control: the `content` switch renders `.binary` → `HexView` **unconditionally**, ignoring `viewMode` entirely (`ContentView.swift:307-314`). Selecting "Source" calls `setCurrentViewMode(.source)`, which for a `.binary` state whose category is `.binary`/`.unknown` runs `loadTextAsync` (`DocumentModel.swift:2585-2587`) — re-reading a file the loader already rejected as binary, which silently fails and leaves the tab in `.binary`/HexView while the picker now says "Source." A confusing no-op.

**Where mode buttons are chosen per file type** — Single source of truth: `ViewModeOptions.availableModes(for:)` (`Sources/ViewerKit/ViewMode.swift:21-49`). The picker iterates its result (`ContentView.swift:762-773`). Per-category branching also lives in `defaultMode` (`:54-61`) and `supportsEditor` (`:93-101`).

**Root cause / gap** — `availableModes` unconditionally seeds `[.source]` for **every** URL (`ViewMode.swift:23`). There is no "this file has no text representation" branch, so binaries inherit Source. The actual content renderer already knows binaries are HEX-only, but the picker's mode list and the renderer disagree.

**Fix / build sketch** — Gate `.source` (and `.editor`, already excluded) out for non-text categories in `availableModes`:
```swift
let cat = FileTypeDetector.category(for: url)
let isBinaryShaped = (cat == .binary || cat == .unknown)
var modes: [ViewMode] = isBinaryShaped ? [] : [.source]
// … existing rendered/table/diff/editor/formatted inserts (all already
//    skip binary categories) …
modes.append(.hex)
```
For `.image/.audio/.video/.pdf/.sqlite` the file is `.preview` state, not `.loaded`, and the picker mode list is already largely cosmetic there — but to match the ask ("only HEX, plus SQLite/preview where applicable"), those should also drop `.source`. Cleanest: drive off a single `FileCategory.hasTextRepresentation`-style predicate so `availableModes`, the `content`/`loadedView` dispatch, and `setCurrentViewMode` all agree. Also fix `defaultMode` to return `.hex` (not `.source`) for binary-shaped files so a binary opens straight into HEX. Verify the `availableModes(for: nil)` baseline (`:22`, returns `[.source, .hex]`) — the empty-tab placeholder relies on it; keep that as-is.

**Size** — **S/M.** Core change is a few lines in `ViewMode.swift` (`ViewModeOptions`), which has direct unit-test coverage (it's pure ViewerKit logic, host-testable per `CLAUDE.md`). M-leaning because: (a) `defaultMode` must change in lockstep or binaries default to a now-unavailable Source; (b) the persisted-mode clamp (`DocumentModel.swift:2405-2408`) already handles a saved `.source` against a file that no longer offers it, but verify restore of an old workspace with a `.source` binary tab lands on HEX cleanly; (c) the dead `setCurrentViewMode(.source)` re-load branch for binaries (`:2585-2587`) should be cleaned up since Source is no longer reachable.

**Dependencies** — Coordinate with **Bug 2**: removing Source from binaries removes the only non-HEX picker slot, so any "open as SQLite" affordance (Bug 2) must be a *separate* menu, not a mode segment. Decide Bug 2's UI shape before finalizing Bug 3's picker.

**Risk / one-way-door** — None irreversible. Pure presentation logic. Main regression surface is workspace restore of pre-change tabs (already guarded) and any UI test asserting Source is present for a binary fixture — those tests (VM-only) would need updating.

---

**Cross-cutting note:** All three converge on the same two files — `Sources/ViewerKit/ViewMode.swift` (the mode-availability policy) and `Sources/ViewerUI/MediaPreviewView.swift` + `ContentView.swift` (the state→view dispatch). The cleanest sequencing is **Bug 3 → Bug 2 → Bug 1**: settle the picker's mode policy first, add the SQLite-override affordance against that settled picker, then do the orthogonal scale-plumbing. Bugs 2 and 3 share the "binary files and the type/mode UI" decision space and should be designed as one change.