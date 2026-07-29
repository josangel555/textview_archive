# Pre-launch product review — UI consistency

Date: 2026-07-09 (re-verified 2026-07-10: every finding's file:line evidence re-checked against the live tree)
Dimension: inconsistent naming, icons, notations, animations, interactions, sizes, spacing, capitalization across panels/menus/views.
Scope reviewed: `Sources/ViewerUI` (~71k LOC SwiftUI), `Sources/MarkdownViewer/main.swift` (menu bar), with spot checks into `Sources/ViewerCore` (Commands, Git, ByteSize, ClaudeMonitorLog).

## Executive summary

The app has a real (and clearly deliberate) design-system nucleus — `Palette`, `SidebarConstants` / `SidebarSectionHeaderLabel` / `SidebarEmptyPlaceholder`, `RowHoverButtonStyle` / `IconHoverButtonStyle`, `FloatingTooltip` (`.helpInfo`), a shared `MarkdownFindBar`, a shared `ByteSize` helper — but **adoption of each of these systems stopped partway**, so the shipping UI presents two (sometimes five) dialects of the same idiom side by side:

- **Find/search is the core flow with the most fragmentation**: five separate find-bar implementations disagree on match-count notation (`2/14`, `2 of 14`, `1 / 14`, `N matches`), empty-state wording (`No results` / `0 matches` / `No matches`), stepper glyphs (`chevron.left/right` vs `chevron.up/down`), button styles, keyboard shortcuts (Return/Shift+Return vs ⌘G/⇧⌘G), and which options (case, regex) exist at all.
- **One action, many names**: reload-file-from-disk is "Reload" (View menu), "Refresh" (tab context menu), and "Reload from Disk" (sidebar context menu); the cross-file search panel is reachable as "Find in Folder…", "Search in Folder", "Search Files", and lives under a sidebar section titled "Search".
- **Numbers disagree with themselves**: five byte-size formatters (mixed 1000- vs 1024-based) can show the same file as "1.5 MB" in the metadata panel and "1.4 MB" in the status bar; two zoom-percent readouts truncate vs round; three relative-time dialects ("5m ago" / "5 min ago" / RelativeDateTimeFormatter) live in adjacent sidebar sections.
- **Two tooltip systems ship simultaneously** (123 native `.help()` sites in 50 files vs 75 custom `.helpInfo()` bubbles in 18) with different visuals and delays.
- **UI zoom applies unevenly**: find bars, sidebar, CSV, diff scale with `model.uiSize`/`zoom`; the cross-search panel, command palette, terminal chrome, snippet manager, and observability views do not scale at all.
- A grab-bag of P3 polish items: mixed keyboard-shortcut notation (`⇧⌘G` vs `Shift+Return` vs `Cmd-F` — two styles within one file), placeholder-text capitalization/ellipsis drift, `Done` vs `Close` dismissal verbs, error-toast colored as a warning, a duplicated File-menu item with inconsistent ellipsis.

Nothing here is a ship-blocker (no P0/P1): core flows work; these are quality/polish findings (P2/P3). But the find-bar fragmentation and naming drift are the kind of thing reviewers and discerning users notice in the first hour.

## Methodology

- Enumerated all SF Symbol usage (`systemName:`/`systemImage:`) and cross-referenced same-concept glyph choices.
- Extracted every `Button("…")`, `TextField("…")` placeholder (full sweep, 35+ distinct strings), `.help("…")`, `Text("No …")` empty state (29 distinct strings), and `NSMenuItem(title:)` string; audited capitalization, ellipsis usage, and duplicates.
- Read in full: `MarkdownFindBar.swift`, the find bars in `CSVTableView.swift`, `Git/DiffView.swift`, `HexView.swift`, `SidebarConstants.swift`, `FloatingTooltip.swift`, `ToastOverlayView.swift`, context menus in `TabBar.swift` and `SidebarView.swift`, `SessionTabBar.swift` action row, the File/View/Find menu construction in `main.swift`, all byte-size and relative-time formatters.
- Quantified: animation durations (grep tally), corner radii (9 distinct values, 93 sites), hardcoded font sizes (15 distinct values, 240+ sites), `buttonStyle` variants, `.help` vs `.helpInfo` counts, `uiSize`/`zoom` adoption per panel.
- **Re-verification pass (2026-07-10):** every file:line citation below was re-read/grepped in the current working tree; one stale path was corrected (`WalkthroughPlayerView.swift` → `Walkthrough/WalkthroughPlayerView.swift`) and two findings added (F18 byte-size, F19 relative-time).
- Static analysis only; no UI tests were run, no windows opened, no repo files modified other than this report.

---

## Findings

### F1 — Five find-bar implementations, four count notations, three stepper styles (P2)

**Severity:** P2 · **Fix size:** M · **Fix risk:** careful (shared-component migration touches 4 surfaces + their tests)

**Evidence (all re-verified):**

| Surface | Count format | Empty state | Prev/Next | Shortcuts | Case/regex toggles | Dismiss |
|---|---|---|---|---|---|---|
| Shared `MarkdownFindBar` (rendered/editor/source/PDF) — `Sources/ViewerUI/MarkdownFindBar.swift:219-268`, fed `"3/12"` per `MarkdownFindBar.swift:32` | `2/14` | `No results` (orange) | `chevron.left/right`, `.bordered` stepper | Return / Shift+Return | Aa + .* | `Done` (Esc) |
| CSV table — `Sources/ViewerUI/CSVTableView.swift:735-804` (`findCountLabel` at 797-810) | `2 of 14`, plus `1 match`/`N matches` | `No results` (orange) | `chevron.left/right`, `.bordered` | Return / Shift+Return | none | `Done` (Esc) |
| Diff view — `Sources/ViewerUI/Git/DiffView.swift:128-173` | `2 of 14` | `0 matches` (secondary gray) | `chevron.up/down`, `.plain` | none shown | none | clear-only `xmark.circle.fill` |
| Hex view — `Sources/ViewerUI/HexView.swift:130-208` (`matchCountLabel` at 199-208) | `1 / 14` (spaces), `1 / 50+` capped | `0 matches`; invalid query = lowercase `invalid` | `chevron.up/down`, `.borderless` | ⌘G / ⇧⌘G | Hex/ASCII segmented | none |
| Cross-file search — `Sources/ViewerUI/CrossSearchPanel.swift:175` | `N scanned · N found` | `No matches` | n/a (result list) | n/a | Aa + .* (`CrossSearchPanel.swift:94,102`) | panel close |

Leading glyph also varies for the same "find text" concept: `magnifyingglass` (MarkdownFindBar:176, DiffView:130), `text.magnifyingglass` (CSVTableView:737).

**Impact:** The single most-used utility in a viewer/editor behaves and reads differently on every surface. Users carry no learning from one view to the next; the same state ("2nd of 14 matches") renders three different ways.

**Suggested fix:** Extract the count/empty-state formatting into one shared helper (`FindCountFormat.label(current:count:capped:)`) and standardize on one notation (recommend `2 of 14` — matches Safari/Xcode) + one empty-state string (`No results`); align stepper glyphs (`chevron.up/down` is native macOS find-bar convention — pick one and apply to all five) and add Esc-dismiss to the diff bar. The CSV comment at `CSVTableView.swift:730-733` already acknowledges it "mirrors" the shared bar — finish the mirroring.

---

### F2 — Same command, three names: "Reload" vs "Refresh" vs "Reload from Disk" (P2)

**Severity:** P2 · **Fix size:** S · **Fix risk:** safe (string changes; update any AX/UAT tests that match titles)

**Evidence — all reload the current/target file from disk (re-verified):**
- View menu: `title: "Reload"` — `Sources/MarkdownViewer/main.swift:2241`
- Command palette: `id: "file.reload", title: "Reload"` — `Sources/ViewerCore/Commands/CommandRegistry+BuiltIn.swift:95`
- Tab context menu: `Button("Refresh") { model.refreshTab(at: tabIndex) }` — `Sources/ViewerUI/TabBar.swift:309`
- Sidebar file context menu: `Button("Reload from Disk")` — `Sources/ViewerUI/SidebarView.swift:1105`
- Disk-conflict banner action: `title = "Reload from Disk"` — `Sources/ViewerUI/Coordinators/EditorCoordinator.swift:1114`
- Sidebar *folder* context menu uses `"Refresh"` for re-listing — `Sources/ViewerUI/SidebarView.swift:1221` (a different operation, sharing a name with the tab item above).

**Impact:** Users cannot tell whether "Refresh" (tab) and "Reload" (menu) are different operations; the folder "Refresh" genuinely IS different, which makes the collision worse.

**Suggested fix:** One verb for file-from-disk everywhere (recommend "Reload from Disk" in context menus, "Reload" in the View menu — or simply "Reload" everywhere); keep "Refresh" exclusively for the folder re-list.

---

### F3 — The cross-file search feature has four user-facing names (P2)

**Severity:** P2 · **Fix size:** S · **Fix risk:** safe

**Evidence — all invoke the same `CrossSearchPanel` (re-verified):**
- Edit ▸ Find menu: `"Find in Folder…"` — `Sources/MarkdownViewer/main.swift:2622`
- Sidebar folder context menu: `"Search in Folder"` — `Sources/ViewerUI/SidebarView.swift:1227`
- Session-bar pinned button: `title: "Search Files"`, help "Search across files in this session" — `Sources/ViewerUI/Sessions/SessionTabBar.swift:139-140`
- Sidebar accordion section title: `"Search"` — `Sources/ViewerUI/SearchAnywhereSection.swift:74`
- The panel's own field placeholder: `"Search across folder…"` / `"Search file names…"` — `Sources/ViewerUI/CrossSearchPanel.swift:87`

Meanwhile in-document search is "Find" (`main.swift:2595-2646`). The Find/Search boundary is not the discriminator here — the *same* feature is "Find in Folder" in one place and "Search…" in three others.

**Impact:** Discoverability: a user who saw "Find in Folder…" in the menu won't recognize "Search Files" in the session bar as the same feature (and vice versa).

**Suggested fix:** Pick one axis: "Find" = in the current document, "Search" = across files — then rename the menu item to "Search in Folder…" (or rename the others to "Find in Folder"). One term, everywhere, including the section header and placeholder.

---

### F4 — Two tooltip systems ship at once: native `.help()` vs custom `.helpInfo()` (P2)

**Severity:** P2 · **Fix size:** M · **Fix risk:** safe (mechanical, but 123 sites)

**Evidence (re-counted 2026-07-10):**
- `FloatingTooltip.swift:4-15` documents the intent: "The native macOS `.help(...)` tooltip is slow (~1.5–2s system delay), tiny, and unstyled. UX-H replaces it" — appear delay ≈ 0.6 s, styled bubble, title+description.
- Actual adoption: **123 `.help(` sites across 50 files** vs **75 `.helpInfo(` sites across 18 files** (grep counts, `Sources/ViewerUI`). Files still on native `.help`: `SettingsView.swift`, `TabBar.swift`, `SidebarView.swift`, `CrossSearchPanel.swift`, `CommandPaletteView.swift`, `SnippetManagerView.swift`, `Terminal/TerminalView.swift:306`, `PluginsSettingsView.swift:124,127`, `Git/DiffView.swift:573`, `Git/FileHistoryView.swift:124`, LSP panels, Observability views, etc. Some files mix both.

**Impact:** Hovering different toolbars yields visibly different tooltip chrome and a 0.6 s vs ~1.5-2 s delay — the exact inconsistency UX-H set out to kill, now shipping as a split-brain.

**Suggested fix:** Finish the migration (mechanical `.help("x")` → `.helpInfo(title: "x")`), or scope a rule ("chrome buttons use helpInfo; long prose explanations stay native") and apply it consistently. Consider a lint/grep test that fails on new `.help(` in ViewerUI.

---

### F5 — UI zoom (`uiSize`) applies to some panels and not others (P2)

**Severity:** P2 · **Fix size:** M · **Fix risk:** careful (layout re-verification per panel; T5 pixel checks ideally)

**Evidence (re-verified):** `DocumentModel.uiSize(_:)` multiplies by `zoom`, and is threaded through `MarkdownFindBar` (every font/padding takes `uiSize(…)`), `SidebarView`/`SidebarConstants` (header recipe scales, `SidebarConstants.swift:125-146`), `DiffView` (`doc.uiSize(...)` at 131-166), `TabBar`, CSV (`cellFontSize = 11 * model.zoom`, `CSVTableView.swift:609-611`), `StatusBar` (`model.uiSize(10)` throughout). But these panels contain **zero** references to `uiSize`/`model.zoom` (grep = 0 hits per file): `CrossSearchPanel.swift` (hardcoded `size: 11`/`16` at lines 87-102), `CommandPaletteView.swift`, `SnippetManagerView.swift`, `Observability/LogsView.swift`, terminal chrome. Even inside the sidebar design system, `SidebarEmptyPlaceholder` hardcodes `size: 11` (`SidebarConstants.swift:186-190`) while the section header directly above it scales via `uiSize` (`SidebarConstants.swift:133-143`).

**Impact:** A user who raises UI zoom gets larger tabs, sidebar headers, and find bars — while the command palette, search panel, and terminal chrome stay small. The mixed result reads as broken zoom rather than a deliberate boundary.

**Suggested fix:** Sweep the non-scaling panels through the existing `uiSize` idiom (the pattern is established and cheap); at minimum fix the intra-sidebar mismatch (`SidebarEmptyPlaceholder`).

---

### F6 — Hover/click affordance differs between adjacent sidebar rows (P2)

**Severity:** P2 · **Fix size:** S-M · **Fix risk:** safe

**Evidence (re-verified):** `RowHoverButtonStyle.swift` exists precisely to fix visually-inert `.plain` rows. Adopted: `BookmarksSection.swift:303`, `SidebarView.swift:1413`, `CrossSearchPanel.swift:586,616`, `CommandPaletteView.swift:690,756`. Still inert `.plain` rows in sibling sections of the same accordion: `MarkdownOutlineSection.swift:56`, `LSP/LSPOutlineSection.swift:169`, `RecentlyOpenedSection.swift:51,116`, `ClaudeTimelineSection.swift:96,148`, `Git/GitLogTab.swift:59,66,99,185`. App-wide: ~84 `.plain` vs ~35 `.borderless` vs 17 `IconHoverButtonStyle` vs 12 `RowHoverButtonStyle`.

**Impact:** In one sidebar, hovering a bookmark row highlights + shows a pointing hand; hovering an outline heading row directly below gives no feedback — clickability is ambiguous exactly where the shared style was meant to remove ambiguity.

**Suggested fix:** Apply `RowHoverButtonStyle` to the remaining list-row surfaces (outline, LSP outline, recently-opened, Claude timeline, git log). Icon buttons: converge `.plain`/`.borderless` icon buttons onto `IconHoverButtonStyle` case by case.

---

### F7 — Error toasts are colored/iconed as warnings (P2)

**Severity:** P2 · **Fix size:** S · **Fix risk:** safe

**Evidence (re-verified):** `ToastOverlayView.swift:104-118` — `case .error: return "exclamationmark.triangle"` and `case .error: return .orange`. Elsewhere the app's severity language is orange=warning, red=error: `ToolResultsPanel.swift:110-114` (`.warning: .orange`, `.error: .red`), LSP diagnostics red/orange split, `SidebarView.swift` orange=modified.

**Impact:** A failed operation surfaces in the same color+glyph as a mere warning; severity is under-communicated and inconsistent with the app's own panels.

**Suggested fix:** Toast `.error` → red + `xmark.octagon`/`exclamationmark.octagon` (or add a distinct `.warning` kind and keep orange there).

---

### F8 — File menu contains the same action twice with inconsistent naming/ellipsis (P2)

**Severity:** P2 · **Fix size:** S · **Fix risk:** safe

**Evidence (re-verified):** `Sources/MarkdownViewer/main.swift:1730-1733` — File ▸ New File ▸ `"Image…"` → `#selector(newImage(_:))`; `main.swift:1809-1811` — File ▸ `"New Image"` (no ellipsis) → the **same** `#selector(newImage(_:))`. Both open the size/color dialog (`main.swift:1217-1222`, TSK-1054/1208), so per HIG both need "…"; and the same command appears at two menu depths with two names. (The sidebar context menu's `New File ▸ "Image"` — `SidebarView.swift:1206` — creates a blank image directly via `createNewBlankImage` with no dialog, so its lack of "…" is correct but means "Image" behaves differently by entry point.)

**Impact:** Menu clutter + a HIG ellipsis violation; users can reasonably think the two items differ.

**Suggested fix:** Drop the top-level "New Image" (the TSK-1167 submenu entry supersedes the TSK-1054 item) or make it the single "New Image…"; ensure it carries "…".

---

### F9 — Keyboard-shortcut notation is mixed, sometimes within one file (P3)

**Severity:** P3 · **Fix size:** S · **Fix risk:** safe

**Evidence (re-verified):**
- Symbol style: `"…(⇧⌘G)"` `HexView.swift:168`, `"Close Tab (⌘W)"` `TabBar.swift:496`, `"(⌘S)"` `CSVTableView.swift:690`.
- Word style: `"…(Shift+Return)"` `MarkdownFindBar.swift:252`, `CSVTableView.swift:763`; `"(Cmd-F)"` `CSVTableView.swift:671` — the same file writes `(⌘S)`, `(Cmd-F)`, and `(Shift+Return)` in three different notations.
- Hyphenated click modifiers: `"Cmd-click"` `Git/FileHistoryView.swift:124,147`, `Git/UnifiedHistoryView.swift`; `"Shift-click"` `Git/DiffView.swift:573`.
- Modifier order deviation: `"(⌘⇧\\)"` `SplitPaneView.swift:125` vs Apple-canonical ⇧⌘ (`HexView.swift:168` gets it right).

**Suggested fix:** Standardize on symbol notation (⌘F, ⇧⌘G, ⌘-click) in tooltips/help text; one pass over the ~30 strings.

---

### F10 — Empty-state strings drift in punctuation and wording (P3)

**Severity:** P3 · **Fix size:** S · **Fix risk:** safe

**Evidence (full `Text("No …")` sweep, 29 distinct strings; re-verified):** `"No matching commands."` (`TerminalCommandPaletteView.swift:42`) vs `"No matching commands"` (`CommandPaletteView.swift:532`) — identical string, one has a period. Family variants: `No results` (`MarkdownFindBar.swift`), `No matches` (`SidebarView.swift`, `CrossSearchPanel.swift:175`), `0 matches` (`DiffView.swift:139`, `HexView.swift:201`), `No matches in this file`. Terminal-period mixing across one-liners: `"No open tabs."` / `"No comments yet."` / `"No statistics available."` vs `"No results"` / `"No local branches"` / `"No folder open"`.

**Suggested fix:** House style: sentence case, no trailing period for one-line empty states; one canonical no-match string (pairs with F1).

---

### F11 — TextField placeholder style drift: capitalization + ellipsis (P3)

**Severity:** P3 · **Fix size:** S · **Fix risk:** safe

**Evidence (full placeholder sweep, 35+ strings; re-verified):** lowercase outliers `"filter…"`, `"branch name"`, `"search bytes…"` (`HexView.swift:143`), `"auto-detect"`, `"=formula"` vs capitalized norm (`"Filter rows…"`, `"Find in table…"`). Ellipsis presence is arbitrary: `"Search files…"` / `"Search commands…"` / `"Find in table…"` / `"Add feed URL…"` vs `"Find in diff"` (`DiffView.swift:133`), `"Search messages"`, `"Search transcript content"`, `"Filter shortcuts"`, `"Filter files"`, `"Filter favorites"`, `"Filter headings"`, `"Filter by title or path"`.

**Suggested fix:** Sentence-case + trailing "…" for all search/filter placeholders; ~15 strings.

---

### F12 — Dismiss verb: "Done" vs "Close" chosen arbitrarily (P3)

**Severity:** P3 · **Fix size:** S · **Fix risk:** safe

**Evidence (re-verified):** `Done`: `CSVTableView.swift:783`, `RecoverDeletedFileView.swift:45`, `ContentView.swift:481`, `MarkdownFindBar.swift:159`. `Close`: `StructuralSearchView.swift:58`, `TerminalCommandPaletteView.swift:34`, `SnippetManagerView.swift:261`, `ScriptConsoleView.swift:57`, `TaskRunnerView.swift:37`. None of these carry state to confirm (HIG: "Done" = completes a task; "Close" = plain dismiss), and near-identical tool panels (Task Runner vs Recover Deleted File) disagree.

**Suggested fix:** "Close" (or the xmark affordance) for plain-dismiss panels; reserve "Done" for editors that commit.

---

### F13 — Zoom percent computed differently in Settings vs status bar (P3)

**Severity:** P3 · **Fix size:** S · **Fix risk:** safe

**Evidence (re-verified):** `SettingsView.swift:263` — `Text("\(Int(model.zoom * 100))%")` (truncates); `StatusBar.swift:451` — `Text("\(Int((model.zoom * 100).rounded()))%")` (rounds; same rounded form again at 456, 460). For zoom values whose ×100 lands just under an integer (float repr of 0.9 → 89.999…), Settings shows 89% while the status bar shows 90% for the same live value.

**Suggested fix:** One shared formatter (rounded); two lines.

---

### F14 — Terminal feature represented by two different glyphs; back-chevron drift (P3)

**Severity:** P3 · **Fix size:** S · **Fix risk:** safe

**Evidence (re-verified):** dock/shoulder rail uses `apple.terminal` (`ShoulderRailView.swift:289,301`); the terminal panel's own tabs/dock button use `terminal` (`Terminal/TerminalView.swift:226,244,326`). Back-navigation glyphs differ: `chevron.backward` (`SettingsView.swift:663`) vs `chevron.left` (`Review/ReviewIndexTab.swift:27`, `Walkthrough/WalkthroughPlayerView.swift:162`) for the same "back to list" affordance.

**Suggested fix:** Pick one glyph per concept (`terminal`; `chevron.backward` is the RTL-aware choice for back).

---

### F15 — Title-case drift in buttons/labels for the same command (P3)

**Severity:** P3 · **Fix size:** S · **Fix risk:** safe

**Evidence (re-verified):** `"Open in Default App"` (`TabBar.swift:341`, `StatusBar.swift:198`, `SidebarView.swift:1185`) vs `"Open in default app"` (`MediaPreviewView.swift:829` — a visible button Label, not a tooltip). `"Restart shell"` button (`Terminal/TerminalView.swift:396`) vs Title-Case norm for buttons (`"Restart"`, `"Reload from Disk"`, etc.). Menu bar itself is consistently Title Case; these are SwiftUI-surface stragglers.

**Suggested fix:** Title Case for button/menu labels (HIG); sentence case stays for tooltips/descriptions. 2-3 strings.

---

### F16 — "Settings" vs "Preferences" terminology mix (P3)

**Severity:** P3 · **Fix size:** S · **Fix risk:** safe

**Evidence (re-verified):** App menu: `"Settings…"`, `"Export Settings…"`, `"Import Settings…"` (`main.swift:1656,1664,1668`). File ▸ Reset: `"Reset Preferences (zoom, theme, window)…"` (`main.swift:1993`) and the reset-scope label `"Reset Preferences"` (`main.swift:907`).

**Suggested fix:** "Reset Settings (zoom, theme, window)…" (both sites) to match the macOS-13+ vocabulary used everywhere else.

---

### F17 — No typography/spacing scale: 15 distinct hardcoded font sizes, 9 corner radii (P3, systemic)

**Severity:** P3 · **Fix size:** L (opportunistic) · **Fix risk:** careful

**Evidence (re-tallied 2026-07-10):** 240+ `.font(.system(size: N))` literals across ViewerUI spanning 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 22, 28, 32, 40, 48 (top: 86×11pt, 58×10pt, 41×12pt, 20×9pt); explicit `cornerRadius:` values 0, 2, 3, 4, 5, 6, 7, 8, 10 (93 sites; top: 20×4, 19×6, 13×10, 11×0, 11×3). The sidebar header recipe (`SidebarSectionHeaderMetrics`, `SidebarConstants.swift:82-95`) proves the token approach works where applied — nothing equivalent exists app-wide.

**Impact:** Same-role text (row labels, counts, captions) lands at 9/10/11 pt depending on the file it was written in; radii on similar chips vary 3-6. This is the root enabler of F1/F5-class drift.

**Suggested fix:** Not a pre-launch rewrite. Introduce a small token enum (e.g. `UIFont.row = 11`, `.caption = 10`, `.chrome = 12`; `Radius.control = 5`, `.panel = 8`) and adopt opportunistically on every touched file; lint new literal sizes.

---

### F18 — Five byte-size formatters, mixed 1000/1024 bases: the same file size renders differently across panels (P2) *(new in re-verify pass)*

**Severity:** P2 · **Fix size:** S-M · **Fix risk:** safe (pick one helper; update string-pinning tests)

**Evidence:**
- `Sources/ViewerCore/ByteSize.swift:8-12` — the *shared* helper (`mbString`, 1,048,576-based "%.1f MB"), whose doc comment says it exists because "previously this was a private `byteString` duplicated in three views". Yet:
- `Sources/ViewerUI/StatusBar.swift:799-803` — private `formatBytes`, **1024-based** ("1.4 MB" for 1.5e6 bytes), shown as the Size metric (`StatusBar.swift:357`).
- `Sources/ViewerCore/ClaudeMonitorLog.swift:97-104` — another private `formatBytes`, 1024-based.
- `Sources/ViewerUI/Git/UnifiedHistoryViewModel.swift:251-265` — `byteLabel`, **1000-based**, different rounding rule ("one decimal below 10, whole numbers above").
- `ByteCountFormatter` (`countStyle: .file`, **1000-based**, locale-dependent): `ArchiveBrowserView.swift:96-97,201`, `RecoverDeletedFileView.swift:107`, `MetadataPanel.swift:238-239`, `FolderTreemapView.swift:173`.

**Impact:** A 1,500,000-byte file shows "1.5 MB" in the metadata panel/archive browser but "1.4 MB" in the status-bar Size metric — two numbers for the same file, simultaneously visible. The unit notation ("1.2 KB" vs system-localized "1.2 MB" vs "±0 B" deltas) also drifts.

**Suggested fix:** One shared, deterministic byte formatter in ViewerCore (the locale-independence rationale in `UnifiedHistoryViewModel.byteLabel` is sound — promote that one, pick one base, and route StatusBar/monitor/treemap/metadata through it; keep `ByteSize.mbString` only if its cap-banner fixed-MB rendering is genuinely wanted).

---

### F19 — Three relative-time dialects in adjacent sidebar sections (P3) *(new in re-verify pass)*

**Severity:** P3 · **Fix size:** S · **Fix risk:** safe

**Evidence:**
- `Sources/ViewerUI/BookmarksSection.swift:363-370` — hand-rolled `"5m ago"` / `"3h ago"` / `"2d ago"` (no space), falling back to `DisplayDateFormatter` ("Mar 12").
- `Sources/ViewerCore/Git/GitRelativeTime.swift:13-16` — `"5 min ago"` / `"3 h ago"` / `"2 d ago"` / `"1 wk ago"` (spaced, different unit abbreviations), rendered in `Git/GitLogRowLabel.swift:41` and `Git/GitStashTab.swift:47`.
- `Sources/ViewerUI/Git/GitRemotesTab.swift:68-71` — a third hand-rolled variant `"fetched 5m ago"` (unspaced, w for weeks).
- `Sources/ViewerUI/ClaudeMonitor/ClaudeMonitorView.swift:858-859` — `RelativeDateTimeFormatter` (locale-styled, e.g. "2 min. ago").

The Bookmarks section, Git log tab, and Git remotes tab are sibling sections of the same sidebar accordion; the same 5-minute-old timestamp renders "5m ago", "5 min ago", and "fetched 5m ago" depending on which section it's in.

**Suggested fix:** Promote `GitRelativeTime` (already in ViewerCore, deterministic, tested) to the single relative-time helper and route BookmarksSection/GitRemotesTab through it; pick one abbreviation style.

---

## Positive observations

- **Sidebar design system is genuinely good**: `SidebarSectionContainer`, `SidebarSectionHeaderLabel` (one header recipe, uppercase, shared metrics, uiSize-scaled), `SidebarEmptyPlaceholder` (17 adopters incl. all Git tabs) — `SidebarConstants.swift`. New sections opt in with one line.
- **Menu bar is clean**: consistently Title Case, correct "…" on dialog-opening items (no three-dot `...` found anywhere in UI strings — the ellipsis character is used throughout), standard Window/App menu structure, `"Settings…"` matches macOS 13+.
- **`Palette`/`ChromeTheme` discipline**: only one file (`FolderTreemapView.swift`) uses raw RGB/white color literals outside `Palette.swift` itself; 50 files consume `Palette`.
- **Case/regex toggles are consistent where shared**: `Aa` / `.*` mini-toggles with matching fonts and accessibility labels in both `MarkdownFindBar.swift:125-152` and `CrossSearchPanel.swift:94-102`.
- **Accessibility identifiers follow one scheme** (`mdv.<surface>.<element>`) across all surfaces sampled, incl. bespoke find bars (`mdv.csvFind.*`, `mdv.hex.search.*`, `mdv.diff.find*`).
- **Destructive actions** almost universally carry `role: .destructive` (11+ sites; only `PluginsSettingsView.swift:125` "Remove" misses it despite trashing a plugin).
- **Animation usage is restrained and clustered** (re-tallied: 0.12 s ×5, 0.15 s ×4, 0.18 s ×2, plus one each of 0.08/0.10/0.20 — no rogue long/springy outliers).
- **"Reveal in Finder" and "Copy Path"** are identically named and Title-Cased at all sites — the context-menu vocabulary is mostly disciplined.
- **Deterministic-formatting rationale is written down** where formatters were hand-rolled (`UnifiedHistoryViewModel.byteLabel`, `ClaudeMonitorLog.formatBytes` doc comments) — the F18 fragmentation is an integration gap, not carelessness.

## Coverage gaps (not examined)

- **On-screen rendering**: this is a static-code audit; no VM/T5 pixel verification of any finding (per constraints). Visual spacing/alignment issues that only show at runtime are out of scope.
- **WebView-hosted surfaces**: CodeMirror find/replace UI, rendered-markdown HTML/CSS, Mermaid/Canvas internals (`Sources/ViewerUI/Resources/codemirror`, JS/CSS) — their internal consistency with the native chrome (fonts, selection colors, find-bar behavior inside CM6 vs the native bar) was not audited.
- **The other two front-ends** (`mdv-tui`, `mdv-web`) — cross-front-end naming consistency unchecked.
- **Settings panes content** (each sub-page's control layout/labels) — only spot-checked.
- **Localization readiness** (string catalogs, plural rules) — out of scope for this lens.
- **Dark/light theme parity** — `Palette` centralization noted, but per-theme rendering not verified.
- **Keyboard shortcut *assignments*** (conflicts/overlaps) — only the notation in help text was audited, not the actual key map.
- **Alert/dialog chrome** (NSAlert in the app shell vs SwiftUI `.alert` in panels) — button ordering/default-button conventions not audited.
