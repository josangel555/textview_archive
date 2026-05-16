# Backlog

Roll-up of pending items as of 2026-05-16. Each line links to the
relevant module / file when applicable. Ordering inside each section
is rough priority — most-asked-for first.

## Bug fixes (small, urgent)

- **Find mode: can't scroll past currently-selected match.** When the
  find bar is active, scrolling stalls at the current match. Probably
  `scrollRangeToVisible` recentering on every redraw.
  → `Sources/ViewerUI/TextDisplayView.swift`, find application path.
- **Rendered-MD find: highlights persist after dismiss.** Closing the
  find bar doesn't clear the `<mark>` overlay in the WKWebView.
  → `Sources/ViewerUI/MarkdownRenderedView.swift` + injected JS.
- **Invisible characters appear too grey.** Toggle works but the
  rendering is so faint many users can't see it.
  → `Sources/ViewerCore/Highlight/SyntaxTheme.swift` (no theme hook
  for invisibles color) + NSLayoutManager default.

## Sidebar / folder UX

- **Right-click folder in sidebar → "Bookmark Folder".** `⌘D` only
  bookmarks files. Folders need explicit context-menu entry.
  → `Sources/ViewerUI/SidebarView.swift` `FileRowContextMenu`.
- **Right-click folder → "Set as Git Root".** Currently the repo is
  auto-discovered from the open folder via `.git` walk. User wants to
  override for nested repos / submodules.
  → `Sources/ViewerCore/Git/GitClient.swift` + `SidebarModel`.

## Scaling + chrome polish

- **UI scaling audit.** `model.uiScale` reaches sidebar / tabs / mode
  bar / status bar; needs sweep for missed surfaces: footer /
  status-bar metrics, mode picker text, settings labels, bookmark
  row line suffix, etc.
- **Left sidebar resize feels janky.** Investigate
  `DraggableSidebar.swift` — likely a layout pass thrash during
  drag.

## Build hygiene

- **Bundle size guard.** Add a `scripts/check-bundle-size.sh` that
  fails if `dist/TextView.app` exceeds 25 MB. Wire into build-app.sh.

## Larger features (named)

- **Bookmark current line: scroll-to-line plumbing** — DONE (commit
  `f37af90`); ⌘⌥D wired. Manual-test only; tracked here so the test
  gap is visible.
- **Source-view git gutter marks** — DONE (commit `f37af90`).
- **CSV rendering as tables.** Detect `.csv` / `.tsv`, render as a
  proper grid view with the existing SQLite-style ResultTableView.
  Per-cell text selection.
- **Collapsible accordion sidebar sections.** Each panel
  (BOOKMARKS / SEARCH / CHANGED / CLAUDE / files) gets a header
  with chevron, click to collapse. Persist state.
- **Split view.** Phase 2.5 — biggest unstarted feature. Side-by-side
  two files in one window. Needs `WindowState` with primary +
  secondary editor.
- **Mermaid diagram support.** Render fenced ```mermaid blocks
  inline. Pluggable so users can disable.
- **Mermaid animations.** Step-through rendering — multiple frames,
  controllable.
- **Walkthrough system.** Predefined scripts Claude can send via
  MCP; play/pause/skip/rewind; checkpoints to ask user questions.
  See design doc `docs/WALKTHROUGH.md` (subagent-generated).
- **Hackability / extensibility / automation.** Plugin surface,
  IPC, scripting. See design doc `docs/HACKABILITY.md`
  (subagent-generated).

## Deferred features

- **jq / JSONPath query for JSON files.** Proposed: hand-rolled
  `.users[0].name` subset, fallback to shell `/usr/bin/jq` if
  present.
- **Expanded TreeSitter language support.** Java, Kotlin, Ruby,
  PHP, C#, Lua. Each is a new SwiftPM dep; conflicts with the
  minimal-deps rule. Pick 2-3 by user demand.
- **Diff +/- line coloring in diff tabs.** Diff tab opens as plain
  text right now. Color `+` lines green, `-` lines red via a custom
  `HighlightRun` generator.
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
- **Batch 3 refactor.** Extract `JSONFileStore`, delete
  `LineNumberRulerView`, shared test helpers.
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
