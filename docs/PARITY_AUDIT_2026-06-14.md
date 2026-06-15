# Feature-Surface Parity Audit — 2026-06-14 (TSK-939)

How each user-facing feature is reachable across surfaces — **Capability-exists**,
**Menu bar**, **⌘K palette** (command mode), **Source** (read-only NSTextView),
**Editor** (CM6/WebView) — plus the **Viewer-vs-Editor deprecation** assessment the
owner asked for. All claims are `file:line`-cited in the body. No code was changed by
this audit; the actionable findings are filed as follow-up tickets (bottom).

## How the surfaces relate (load-bearing facts)
- **One registry, three consumers.** `CommandRegistry+BuiltIn.swift` is the canonical
  command list (74 commands); each carries an optional `scriptVerb` (`nil` = window/NSApp-
  coupled, not headlessly invokable — `CommandRegistry.swift:62-94`).
- **Palette command mode is `>`-prefixed + verb-gated.** ⌘K opens in file-finder mode;
  commands show only under a `>` query (`CommandPaletteView.swift:27,382-387`). It lists
  all registry commands but `invokeCommand` no-ops any `scriptVerb == nil` (dimmed/disabled
  rows — `DocumentModel.swift:960-972`, `CommandPaletteView.swift:623-628`). "In palette" =
  "has a scriptVerb."
- **Menu binds nil-verb commands directly** (`@objc`), so menu coverage ⊋ palette coverage.
- **~25 menu actions have NO registry entry at all** — menu-bar-only, invisible to the palette.
- **Context menus are a large separate surface** (16 menus); many features are right-click-only.

## A. Parity matrix (condensed)
Full per-row matrix with file:line in the audit working notes; the headline shape:
- **File ops:** Open/Open-Folder/Open-Recent/New-File/New-Tab-from-Clipboard/Save-a-Copy/
  Print/Export-PDF/Reset/Settings-Export — **menu (some palette), but several have NO palette command.**
- **Edit/text tools:** Insert Date, Align Tables, Convert Encoding/Line-Endings/Indentation,
  Trim/Final-Newline, Insert TOC, Promote/Demote, Lines, Minify JSON, Insert Snippet — **menu-only,
  no palette.** The 16 clipboard `tools.*` (UUID/SHA-256/base64/case/url/html/trim/checksum) are
  **palette-only, no menu.**
- **View:** Toggle Rendered/Source, Sidebar, Zoom, Pretty-Print, Bookmarks, Split — menu+palette.
  Wrap/Invisibles/Fold/Unfold/Go-to-Line/Apply-jq — **menu-only (nil verb).** Document Statistics,
  Language Mode, Select-View-Mode-slot — **menu-only, no registry entry.**
- **Git:** Show Panel/File-History/Blame — menu and/or palette. Review Commit, Reviews submenu,
  status-row Open/Diff, Copy Diff/Hunk — **context-menu only.**
- **LSP:** Go-to Definition/Declaration/Type/Impl + Format/Rename/CodeActions — menu+palette.
  **Find References — context-menu only (no menu, no palette).**
- **Tabs/Sessions:** Next/Prev/Move + session lifecycle — menu+palette. Close-Others/Close-to-Right,
  move-to-session, Rename Session (palette) — **context-only or no palette.**
- **Filesystem ops** (Reveal in Finder, Copy Path/Relative, Open in Default App, Reveal in Sidebar)
  — **entirely context-menu only.**

## B. Gap list (actionable)
- **B1** ~25 menu actions have NO palette command (can't even show dimmed). Many are pure model
  methods (`canExportActiveAsHTML`, `activeCSVAsJSON`, …) → trivial `scriptVerb` additions.
- **B2** ~18 registry commands are menu-only (nil verb → dimmed in palette): open/openFolder,
  wordWrap, invisibles, foldAll/unfoldAll, goToLine, applyJQ, undo/redo, find/replace, repoHistory,
  session.new, window.minimize/zoom. Most are backed by reachable methods → low-effort verb adds.
- **B3** Palette/sidebar-only with no menu: folderStats, toggleBlame, renderedShow, sidebar.*; the
  16 `tools.*` clipboard commands. A "Text Tools" menu would aid discovery.
- **B4 (BUG)** **Find Next / Find Previous (⌘G/⌥⌘G) are inert** — they target
  `NSTextView.performFindPanelAction` (NSTextFinder), but no view sets `usesFindBar`; Source uses a
  custom `FindState`. Working next/prev is only Return/Shift-Return inside the open bar
  (`MarkdownFindBar.swift:228-237`). The CLAUDE.md `usesFindBar` note is stale.
- **B5 (BUG)** **⌘F in HTML-rendered mode toggles an invisible find bar** — `findInPage` flips
  `isRenderedBarPresented`, but the HTML rendered branch (`ContentView.swift:748-774`) mounts no
  `MarkdownFindBar` (markdown/mermaid do, `811-813`). ⌘F over the 50 MiB editor size-cap
  (`LargeEditorPlaceholderView`) is likewise enabled-but-dead.
- **B6 (UX bug)** **Find&Replace (⌥⌘F) isn't disabled outside the editor** — `replaceInPage` only
  opens a replace row in `.editor` (`main.swift:2896-2902`); elsewhere it silently degrades to find.
- **B7 (gap)** **LSP "Find References" has no menu/palette** — only the Source right-click
  (`LSPHoverAttachment.swift:263`); also absent from the CM6 context menu.
- **B8 (gap)** Filesystem ops (Reveal/Copy-Path/Open-in-Default-App) are context-only — invisible to
  keyboard/palette-first users.
- **B9 (gap)** Close-Others / Close-to-Right / move-to-session are context-only (`TabBar.swift:294,296`).
- **B10 (BUG)** **Source code folding is dead-wired** — Fold/Unfold menu (`view.foldAll/unfoldAll`)
  + `FoldState`/`SourceGutterView` exist, but `SourceModeView` builds the gutter without `foldState`
  (`ContentView.swift:938`) and the NSTextView has no collapse logic → folding silently does nothing
  in Source (works only in CM6 Editor).

## C. Viewer-deprecation assessment — can the Editor replace the read-only Source view?
Not a drop-in swap. **What blocks retiring Source:**
1. **File size: Editor caps at 50 MiB (`HighlightRun.swift:70` → `LargeEditorPlaceholderView`,
   `ContentView.swift:616`); Source goes to 512 MiB** with a 64 MiB soft-watermark that drops O(N)
   overlays (`TextFileLoader.swift:154-219`, "~1 GB logs at constant RAM"). **The single hardest blocker.**
2. **Source highlights ~9 more languages** (~15 TreeSitter vs the Editor's 6; others → `"plain"`,
   `CodeMirrorEditorView.swift:1024-1033`).
3. **`.diff`/`.patch` deliberately exclude the Editor** (`ViewMode.swift:117-118`) — a read-only/diff
   inspection lens is a real affordance.
4. **Source-only UI** to port first: find-match **minimap** (`FindMatchMinimapView`), SwiftUI
   diff/bookmark **gutter** (`SourceGutterView`), **selection-instance highlight**
   (`SelectionHighlightEngine`).
5. No cross-surface scroll-unit translation (line-center vs caret-offset vs pixel-Y).

**Verdict:** keep Source for files >50 MiB and for `.diff`; expand the Editor's language map toward
TreeSitter parity; port minimap/gutter/selection-highlight; only then retire Source elsewhere. Filed
as the deprecation roadmap on TSK-939.

## Follow-up tickets filed from this audit
- Bugs: Find-Next/Prev inert (B4), ⌘F-dead-in-HTML + over-size-cap (B5), Source-folding dead (B10),
  ⌥⌘F-not-disabled-outside-editor (B6).
- Gaps: palette-parity for menu-only commands (B1+B2 umbrella), LSP Find-References menu/palette (B7).
- (B3/B8/B9 noted as lower-priority discoverability gaps.)
