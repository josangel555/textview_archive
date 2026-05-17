# Backlog

> **Update 2026-05-16 (afternoon session):** shipped the tabbed Git
> panel (Status / Log / Stash / Trees / Remotes with topological
> Canvas graph), proper DiffView for `.diff`/`.patch` tabs, Swift 6.3
> strict-concurrency migration (caught by VM build canary), and the
> JSONFileStore refactor (Batch 3 partial). Items below are what's
> left unticked after the sweep.
>
> **Previous overnight session swept:** Bug fixes, Sidebar / folder UX,
> Scaling polish, Build hygiene, CSV → tables, Accordion sidebar,
> Split view (Phase 2.5). Design docs landed for Mermaid,
> Walkthroughs, and Automation/MCP under `docs/`.

Roll-up of pending items as of 2026-05-16. Each line links to the
relevant module / file when applicable. Ordering inside each section
is rough priority — most-asked-for first.

## Bug fixes (small, urgent)

- ~~**Find mode: can't scroll past currently-selected match.**~~ DONE
  (commit `f12ee43` — `lastScrolledMatchIndex`).
- ~~**Rendered-MD find: highlights persist after dismiss.**~~ DONE
  (commit `f12ee43` — `window.__mdvFindClear` on empty query).
- **Invisible characters appear too grey.** NSLayoutManager renders
  invisibles in `tertiaryLabelColor` (very faint). No public API to
  override. Fix needs an `NSLayoutManager` subclass that overrides
  `drawGlyphs(forGlyphRange:at:)` to substitute our own color +
  glyphs. Deferred because NSLayoutManager subclassing has
  historically triggered the SwiftUI compositor bug (LESSONS.md).
  → `Sources/ViewerUI/TextDisplayView.swift` SourceTextController.

## Sidebar / folder UX

- ~~**Right-click folder → Bookmark Folder.**~~ DONE.
- ~~**Right-click folder → Set as Git Root.**~~ DONE.
- ~~**Right-click folder → Open in Terminal.**~~ DONE (commit `94e130d`).

## Scaling + chrome polish

- ~~**UI scaling audit.**~~ MOSTLY DONE. Remaining: ModeBar mode-picker
  text doesn't scale with `uiScale`.
- ~~**Left sidebar resize feels janky.**~~ DONE (commit `f12ee43` —
  `@State liveWidth` during drag).

## Build hygiene

- ~~**Bundle size guard.**~~ DONE (`scripts/check-bundle-size.sh`,
  25 MB cap, wired into `build-app.sh`).

## Larger features (named)

- ~~**Bookmark current line + gutter marks.**~~ DONE (commit `f37af90`).
- ~~**CSV → tables.**~~ DONE.
- ~~**Collapsible accordion sidebar sections.**~~ DONE.
- ~~**Split view (Phase 2.5).**~~ DONE (commit `6fdad21`).
- ~~**Tabbed Git panel.**~~ DONE (commits `b1cd878` + `bbd273b`):
  Status / Log / Stash / Trees / Remotes; topological Canvas graph;
  per-row branch chips + HEAD chip; ⌥⌘R refresh.
- ~~**Proper file diff tab.**~~ DONE (commit `c8ea29c`): structured
  DiffView with per-hunk colored rendering; default mode for
  `.diff` / `.patch`.
- **Mermaid diagram support.** Pending — design in `docs/MERMAID.md`.
  3 user decisions waiting (vendor mermaid.min.js ~2.5 MB, %% @step N
  convention, ← / → bindings).
- **Mermaid animations.** Pending — depends on above.
- **Walkthrough system.** Pending — design in `docs/WALKTHROUGH.md`.
  5 decisions waiting (JSON vs YAML, transport, step taxonomy,
  persistence, branching).
- **MCP automation surface.** Pending — design in `docs/AUTOMATION.md`.
  3 decisions waiting (swift-mcp dep, bundle ID, opt-in TCP).

## Deferred features

- **jq / JSONPath query for JSON files.** Proposed: hand-rolled
  `.users[0].name` subset, fallback to shell `/usr/bin/jq` if
  present.
- **Expanded TreeSitter language support.** Java, Kotlin, Ruby,
  PHP, C#, Lua. Each is a new SwiftPM dep; conflicts with the
  minimal-deps rule. Pick 2-3 by user demand.
- ~~**Diff +/- line coloring in diff tabs.**~~ DONE (commit `94e130d`
  for runs; `c8ea29c` for proper DiffView with row backgrounds).
- **Phase 9 distribution.** Real Developer ID + notarization. User
  said "local signing only for now"; revisit when shipping public.

## Polish backlog

- Recents section uses generic icons; switch to `FileIconView`.
- ModeBar mode-picker text doesn't scale with `uiScale`.
- ClaudeTimeline section uses generic icons.
- Recents-list could show modified-since-last-open badge.

## Architectural / tech debt

- **DocumentModel SRP split.** 41 `@Published`, ~970 lines. Split
  into `SourceViewState` + `FindState` + facade. Mechanical but
  invasive.
- **TOCTOU on bookmark symlinks.** Bookmark resolves at add time;
  attacker can swap symlink later. Architectural fix: store
  resolved-path + inode + watch.
- **Regex DoS on main thread.** `NSRegularExpression` has no
  timeout API. Right fix: run on a background actor with
  cancellation; show "regex slow" feedback after 200ms.
- **Batch 3 refactor.** PARTIAL. `JSONFileStore` extracted (commit
  `bf2f886`). `LineNumberRulerView` deletion deferred — it's still
  gated behind `MDV_ENABLE_BROKEN_RULER=1` for the meta-regression
  test that catches the compositor bug class. Shared test helpers
  not addressed.
- **`test_zoom_persistsAcrossNewTab`.** Known regression after
  view-mode normalization; guarded to not crash; not investigated.
- **TESTS_AUDIT.md deletions.** E2E dedup proposed; awaiting
  user review.

## Hard-to-test features (manual smoke only)

These shipped without automated tests because the test cost
outweighs the value. Manual checks are in `MANUAL_TESTING.md`:

- Bookmark current line (`⌘⌥D` keyboard activation)
- Sidebar bookmark row showing `:42` suffix
- Click bookmark → scroll-to-line behavior
- Gutter diff stripe colors / placement
- Gutter bookmark dot color / placement
- `xattr -dr com.apple.FinderInfo` bundle hygiene during signing
- `NSServices` "Open in TextView" in Finder context menu
- VoiceOver labels on stars, icons, gutter
- HEX mode on PDF / MIDI / PNG (visual)
- UI-scale slider's effect on all chrome
- Right-side metadata panel for preview tabs
