# Pre-launch audit — macOS UI best practices (HIG)

Dimension: HIG conformance — control sizes/spacing, sheet vs panel use, toolbar/menu
conventions, dark-mode correctness, vibrancy, SF Symbols usage.
Date: 2026-07-09 · Reviewer: agent (static code review; no UI tests were run)

---

## Executive summary

TextView is a deliberately **custom-chrome, IDE-style app** (VS Code-like: in-window tab
strip, shoulder rails, dockable panels, dense 9–12 px chrome type) rather than a stock
AppKit document app. Within that chosen idiom the codebase is unusually disciplined: a
central `Palette` of dynamic system colors, a single `.helpInfo` tooltip system with a11y
fallbacks, Reduce Motion gating, a `CommandRegistry` as single source of shortcut truth,
and a Help/Window/Edit menu skeleton that follows HIG order. Most chrome hardcodes zero
RGB values — dark mode is structurally sound in the default (no-theme) configuration.

The significant gaps are at the **platform-integration seams**, not inside the custom
chrome:

1. **Theme × system-appearance mismatch (P1)** — selecting a dark theme on a light-mode
   Mac themes only three background surfaces while every semantic color (labels,
   separators, selection) stays resolved for the *system* appearance → dark-on-dark /
   light-on-light chrome text. No `NSAppearance` sync exists anywhere.
2. **Menu-bar key-equivalent collisions (P2)** — ⌘1–⌘3 and ⌘⌥[ / ⌘⌥] are each bound to
   two *visible, simultaneously-enabled* menu items (View-mode slots vs Window-menu tab
   numbers; Fold/Unfold All vs Move Tab Left/Right). AppKit resolves by menu order, so
   the Window-menu items display shortcuts that mostly do something else.
3. **Missing document-window conventions (P2)** — no `representedURL` (titlebar proxy
   icon / ⌘-click path menu), no `isDocumentEdited` (close-button edited dot), document
   types declared `Viewer` though the app edits, recents not fed to
   `NSDocumentController` (Dock menu / Apple-menu Recent Items are empty).
4. **Nonstandard save-changes alert layout (P2)** — button order Save / Don't Save /
   Cancel diverges from the canonical Save / Cancel / Don't Save, and Don't Save carries
   no ⌘D equivalent.

Nothing found here is a ship-blocker in the crash/data-loss sense (the dirty-close prompt
itself is correctly wired through every close path). The P1 is a real, user-visible
broken state in a shipping feature combination.

---

## Methodology

Static review of the SwiftUI/AppKit UI layer, ~4 hours of targeted reading:

- **App shell / windows / menus:** `Sources/MarkdownViewer/main.swift` (4,435 lines —
  window construction, `buildMenu()` in full, Window/Help/Edit/File/View/Tools/Navigate
  menus, alert flows), `scripts/Info.plist`.
- **Chrome:** `ContentView.swift` (layout roots), `ContentToolbar.swift`, `TabBar.swift`,
  `StatusBar.swift`, `SettingsView.swift`, `ShoulderRailView`/dock containers (spot),
  `RowHoverButtonStyle.swift`, `FloatingTooltip.swift`.
- **Theming / dark mode:** `Palette.swift`, `ChromeTheme.swift`,
  `ViewerCore/Highlight/ThemeDefinition.swift`, `ThemeStore.swift`,
  `DocumentModel.swift` theme plumbing, `Resources/markdown.css` (dark block),
  `HTMLRenderedView.swift` (transparent background).
- **Shortcuts:** `ViewerCore/Commands/CommandRegistry+BuiltIn.swift` in full,
  `applyShortcut` wiring in `main.swift`.
- **Dialogs:** every `NSAlert` cluster (`EditorCoordinator.swift`, `SidebarView.swift`,
  save/open panels), `.sheet(...)` call sites (81 sheet/panel/alert usages surveyed).
- **Symbols:** exhaustive extraction of all 256 `systemName:` usages; every distinct name
  checked against the SF Symbols catalog (all valid, none version-gated past macOS 15).
- Greps: hardcoded colors (`Color(red:` / `NSColor(red:` — only 3 hits, all
  image-editor *content* colors), `.white`/`.black` misuse, `NSVisualEffectView`,
  `representedURL|isDocumentEdited`, `noteNewRecentDocument`, `collectionBehavior`,
  `runModal` (61) vs `beginSheetModal` (1), `controlSize`, `contextMenu`.

Not executed: no app launch, no VM pixel runs — all findings are code-verifiable.

---

## Findings

### F1 (P1) — Selecting a theme that mismatches the system appearance yields illegible chrome (no NSAppearance sync)

- **Files:** `Sources/ViewerUI/ChromeTheme.swift:15-22`, `Sources/ViewerUI/Palette.swift:22-61`,
  `Sources/ViewerUI/DocumentModel.swift:1929-1938`,
  `Sources/ViewerCore/Highlight/ThemeDefinition.swift:164-183`
- **Evidence:** `ChromeTheme` deliberately themes ONLY three surfaces
  (`textBackground`, `windowBackground`, `sidebarPanelBackground`) — its own header says
  "the long tail of SEMANTIC colors (labels, separators, selection) stays system-native
  deliberately" (`ChromeTheme.swift:15-17`). `ThemeDefinition.isDark` exists
  (`ThemeDefinition.swift:16-17`) but a repo-wide grep for `NSAppearance(named`,
  `appearance =`, `NSApp.appearance` returns **zero** hits — nothing ever flips the
  window appearance to match the selected theme. The rendered-markdown page got exactly
  this fix (`pageCSS()`, `ThemeDefinition.swift:164-183`, "a selected dark theme on a
  light-mode system left the reading view LIGHT — the Dark-Mode gap"), but the chrome
  did not.
- **Impact:** Pick *Xcode Dark* while macOS is in Light Mode: sidebar/panels/bars paint
  near-black from the theme, while `labelColor` / `secondaryLabelColor` / separators /
  selection resolve for Light Mode (near-black text, light selection washes) →
  black-on-black chrome text, invisible separators. Mirror-image failure for a light
  theme on a dark-mode system. This is a shipping Settings combination, two clicks away.
- **Suggested fix:** when `selectedThemeID != nil`, set
  `window.appearance = NSAppearance(named: def.isDark ? .darkAqua : .aqua)` (and reset to
  `nil` for system-native). That makes every system dynamic color re-resolve coherently
  with the themed surfaces — the same pattern Xcode uses. Apply to all app windows
  (settings/tool windows too) or scope to the main window contentView.
- **Fix size:** M · **Fix risk:** careful (appearance flips re-resolve every dynamic
  color; needs a VM T5 sweep over theme × system-appearance matrix; watch the WKWebView
  `prefers-color-scheme` follow `NSAppearance` of the hosting view, which actually
  *improves* the story since markdown.css keys off it).

### F2 (P2) — ⌘1–⌘3 bound to two enabled menu items at once (View-mode slots shadow Window-menu tab numbers)

- **Files:** `Sources/MarkdownViewer/main.swift:2110-2119` (View ▸ "View Mode 1/2/3",
  `keyEquivalent: "1"/"2"/"3"`, ⌘), `Sources/MarkdownViewer/main.swift:1578-1585`
  (Window ▸ per-tab items, `keyEquivalent: "1"…"9"`, default ⌘ mask)
- **Evidence:** both sets are plain `NSMenuItem`s with identical key equivalents, both
  enabled whenever a file with ≥1 view mode is open. AppKit dispatches a key equivalent
  to the **first enabled item in menu order**; the View menu precedes the Window menu
  (`main.swift:2881` vs `:2927`), so ⌘1–⌘3 always fire the view-mode slots.
- **Impact:** the Window menu *displays* ⌘1/⌘2/⌘3 beside the first three tabs, but
  pressing them switches view modes instead — a visible lie in the menu bar. HIG:
  "Assign each keyboard shortcut to exactly one menu item." Tabs 1–3 have no working
  shortcut; users of the near-universal ⌘1-⌘9 = tab-N convention (Safari, Chrome,
  Terminal, VS Code) get mode flips instead.
- **Suggested fix:** pick one owner for ⌘1–⌘9. Recommended: tabs get ⌘1–⌘9 (platform
  convention), view-mode slots move to ⌃1–⌃3 or ⌘⌥1–3 (and register in
  `CommandRegistry` rather than hardcoding). At minimum stop rendering the shadowed key
  equivalents on the Window-menu items.
- **Fix size:** S · **Fix risk:** careful (shipped muscle memory + `keybinding.json`
  contract; the registry comment at `CommandRegistry+BuiltIn.swift:113` says the owner
  "reserved ⌘1-9 for tool windows" — needs an owner call, so park a ticket).

### F3 (P2) — ⌘⌥[ / ⌘⌥] double-bound: Fold All / Unfold All vs Move Tab Left / Right

- **Files:** `Sources/ViewerCore/Commands/CommandRegistry+BuiltIn.swift:157-168`
  (`view.foldAll` ⌘⌥[, `view.unfoldAll` ⌘⌥]) and `:395-404` (`tabs.moveLeft` ⌘⌥[,
  `tabs.moveRight` ⌘⌥], comment: "Collides with view.foldAll by default — intentional,
  the menu disambiguates by responder/mode"); live menu items at
  `Sources/MarkdownViewer/main.swift:2212-2228` (View ▸ Fold/Unfold All via
  `applyShortcut`) and `:1552-1567` (Window ▸ Move Tab Left/Right, hardcoded ⌘⌥[/⌘⌥]).
- **Evidence:** the "disambiguates by responder" claim is not how `NSMenu` key
  equivalents work — dispatch is menu-order + validation. In any foldable lens (the
  common case: every text/source doc) both items are enabled; View precedes Window, so
  ⌘⌥[ always folds and **Move Tab Left is keyboard-unreachable**. In a non-foldable lens
  the same chord silently changes meaning to a tab move — a modal shortcut.
- **Impact:** Window menu displays ⌘⌥[/⌘⌥] on items that usually don't respond to them;
  the same physical chord does two unrelated things depending on invisible state. HIG
  unique-shortcut rule violated.
- **Suggested fix:** rebind Move Tab Left/Right to ⌃⌘←/⌃⌘→ or ⌘⌥⇧[/] (both free in the
  registry), or drop their displayed equivalents.
- **Fix size:** S · **Fix risk:** safe (both are niche chords; registry + menu are the
  only two touch points, `ShortcutMapTests`-style coverage exists for the registry).

### F4 (P2) — Save-changes alert violates the canonical button layout; no ⌘D on "Don't Save"

- **File:** `Sources/ViewerUI/Coordinators/EditorCoordinator.swift:1197-1209`
- **Evidence:**
  ```swift
  alert.addButton(withTitle: "Save")          // rightmost, default
  alert.addButton(withTitle: "Don't Save")    // middle
  alert.addButton(withTitle: "Cancel")        // leftmost
  ```
  The macOS-standard unsaved-changes alert (TextEdit, Pages, Xcode) is: **Save**
  (default, right) · **Cancel** (middle) · **Don't Save** (far left, ⌘D). NSAlert lays
  buttons right-to-left in add order, so the current middle slot — where 30 years of
  muscle memory expects Cancel — is the destructive "Don't Save".
- **Impact:** users who reflexively click the button left of the default (Cancel
  position) discard their edits. This is the single most muscle-memory-sensitive dialog
  on the platform. Escape still maps to Cancel (AppKit auto-binds by title), which
  limits keyboard damage, but mouse users are exposed.
- **Suggested fix:** reorder to Save / Cancel / Don't Save; set
  `alert.buttons[2].keyEquivalent = "d"` with `.command` modifier (the TextEdit
  behavior), and consider `hasDestructiveAction = true` on Don't Save.
- **Fix size:** S · **Fix risk:** safe (the `DirtyClosePrompt` mapping is by
  `alertFirst/Second/ThirdButtonReturn` — update the switch in the same commit;
  `dirtyClosePromptOverride` test seam keeps host tests unaffected).

### F5 (P2) — No titlebar document proxy (`representedURL`) and no `isDocumentEdited`

- **Files:** `Sources/MarkdownViewer/main.swift:329-402` (window setup; `window.title`
  only), repo-wide grep for `representedURL|representedFilename|isDocumentEdited` = zero
  hits. Title sync exists (`main.swift:424-429`) but only for the string.
- **Evidence/Impact:** a document-centric window on macOS is expected to carry the
  file's proxy icon in the titlebar — draggable into other apps/Finder, ⌘-click for the
  enclosing-folder popup — and to show the dot-in-close-button edited state via
  `isDocumentEdited`. TextView shows a plain text title; the in-tab accent dot
  (`TabBar.swift:415-427`) is the only edited indicator, and drag-the-document workflows
  (drop the open file onto Terminal, a mail message, another editor) are impossible.
- **Suggested fix:** in the existing `model.$windowTitle`-style sink, also bind
  `window.representedURL = model.currentURL` and
  `window.isDocumentEdited = model.currentTabIsDirty` on tab switch / dirty-state change.
- **Fix size:** S–M (the plumbing exists; pick the right publishers) · **Fix risk:** safe.

### F6 (P2) — ⌘P Print is a no-op for plain-text / source / editor lenses

- **File:** `Sources/ViewerUI/DocumentModel+PrintExport.swift:15-20`
  (`canPrintRenderedPage`: rendered web pages only; "Source/editor/hex/CSV printing is
  phase 2 … deliberately out of this gate"), menu gating at
  `Sources/MarkdownViewer/main.swift:1959-1966`.
- **Impact:** in a text *editor*, File ▸ Print… is disabled for a `.txt`, `.swift`, or
  any file being edited — a table-stakes expectation (HIG lists Print among the standard
  File-menu commands users assume work everywhere). Export-as-PDF is likewise
  rendered-only.
- **Suggested fix:** ship the acknowledged phase 2: an `NSPrintOperation` over an
  `NSTextView` populated with the buffer (or print the CM6 WebView via
  `WKWebView.printOperation(with:)`).
- **Fix size:** M · **Fix risk:** safe (additive path; keep the rendered gate as-is).

### F7 (P2) — Document types declared `Viewer` although the app edits and saves

- **File:** `scripts/Info.plist:122-189` — all four `CFBundleDocumentTypes` entries have
  `CFBundleTypeRole = Viewer` (`:128, :141, :154, :180`).
- **Impact:** LaunchServices ranks the app as a viewer: Finder's "Open With" ordering
  and the default-handler UI treat it below actual editors; scripting/automation that
  queries the claimed role sees a viewer. The app has a full editor, Save (⌘S),
  autosave-adjacent local history, and file-create flows — the declaration undersells
  the product at launch.
- **Suggested fix:** `CFBundleTypeRole = Editor` for Plain Text / Markdown / Source Code
  (Folder stays Viewer). Revisit `LSHandlerRank` (Alternate is a reasonable launch
  default to avoid stealing double-click, so leave it unless product wants otherwise).
- **Fix size:** S · **Fix risk:** careful (changes LaunchServices registration behavior
  on user machines; deliberate product stance — one-line change, but confirm with owner).

### F8 (P2) — Recent files never reach the system: no Dock-menu / Apple-menu recents

- **Files:** repo-wide grep `noteNewRecentDocumentURL|NSDocumentController|applicationDockMenu`
  = zero hits; in-app recents implemented at `Sources/MarkdownViewer/main.swift:1471-1502`
  (`rebuildRecentsMenu`, custom store).
- **Impact:** right-clicking the Dock icon shows no recent documents; Apple ▸ Recent
  Items ignores TextView; Finder's "Recent" provenance misses opens. The custom File ▸
  Open Recent works, but the OS-level surfaces users actually reach for stay empty —
  a visible non-native tell for a launch.
- **Suggested fix:** call
  `NSDocumentController.shared.noteNewRecentDocumentURL(url)` at the open-file seam
  (single choke point where `recent-paths.json` is appended) — coexists fine with the
  custom menu. Optionally implement `applicationDockMenu(_:)` for sessions.
- **Fix size:** S · **Fix risk:** safe.

### F9 (P2) — Settings is a single 708-line, 12-section scroll (no panes), in a resizable+miniaturizable window

- **File:** `Sources/ViewerUI/SettingsView.swift:6-8` ("Kitchen-sink Settings page.
  Single page, no tabs … Tabs/categories can wait until we have enough settings"),
  sections listed `:33-57` (Appearance, Editor, Languages, Terminal, Viewer, File
  Associations, Audio, Privacy, Plugins, Extensions, LSP, Advanced); window at
  `:680-707`.
- **Impact:** the "can wait" threshold is long past — twelve top-level domains in one
  scroll makes ⌘, navigation a scavenger hunt and diverges from the toolbar-pane
  Settings idiom every Mac app shares (System Settings, Safari, Xcode). The window is
  also `.miniaturizable`/`.resizable` with no autosaved frame, both atypical for
  Settings.
- **Suggested fix:** SwiftUI `TabView` with `.tabViewStyle(...)` inside the existing
  hosting window, or `NSTabViewController` toolbar-style panes; group the 12 sections
  into ~6 panes (General/Appearance, Editor, Languages & LSP, Terminal, Files &
  Privacy, Extensions).
- **Fix size:** M · **Fix risk:** safe (pure re-hosting; the sections are already
  self-contained `@ViewBuilder` vars).

### F10 (P2) — File menu carries tool/browse surfaces that belong in Tools/View

- **File:** `Sources/MarkdownViewer/main.swift:1774-1852` — File ▸ Feed Reader (`:1777`),
  Dependency Graph (`:1785`), Folder Sizes (Treemap) (`:1794`), Walkthroughs (`:1816`),
  Annotations (`:1824`), Log Patterns (`:1832`), Package Dependencies (`:1840`), Local
  History (`:1848`) — plus four Export items — before Open… even appears (`:1879`).
- **Impact:** HIG: the File menu holds commands on the document/file lifecycle. Eight
  analysis/browse tools push Open…/Open Recent/Close/Save below the fold of a ~30-item
  menu; discoverability of the *standard* items suffers most. The TSK-1413 reorg
  already created a Tools menu for exactly this class (`:2434-2438`) but these stayed
  behind.
- **Suggested fix:** move the eight items to Tools (Annotations/Log Patterns/Package
  Dependencies/Dependency Graph/Folder Sizes) and View or File-bottom (Local History,
  Walkthroughs, Feed Reader); keep File to New/Open/Recent/Close/Save/Print/Export/Reset.
- **Fix size:** S · **Fix risk:** safe (selectors/targets unchanged — same move TSK-1413
  already performed for four other items; `AppMenuActionsTests` guards the actions).

### F11 (P2) — 61 app-modal `runModal` dialogs vs 1 window sheet

- **Files:** grep `runModal` = 61 hits vs `beginSheetModal` = 1; representative:
  `Sources/ViewerUI/Coordinators/EditorCoordinator.swift:1205` (dirty-close),
  `SidebarView.swift:344-368` (rename / Move-to-Trash confirms),
  `main.swift:256-269` (save-copy panel + error alert).
- **Impact:** HIG: alerts and Open/Save panels that pertain to a specific document in a
  specific window should be **sheets** on that window; app-modal alerts block the whole
  app (including unrelated tool windows: Settings, Monitor, Diagnostics, Snippets — the
  app is not single-window, see `main.swift:27-56`). Also blocks interaction with the
  MCP-automation-driven window while a stray modal sits open.
- **Suggested fix:** adopt `alert.beginSheetModal(on: window)` /
  `panel.beginSheetModal(for:)` for document-scoped prompts; keep `runModal` for truly
  app-global ones (Reset Everything, relaunch).
- **Fix size:** M (mechanical but 20+ call sites; async completion handlers) ·
  **Fix risk:** careful (several call sites return synchronously through
  `DirtyClosePrompt`-style enums; sheeting them forces an async refactor of the close
  paths — do it per-dialog, not big-bang).

### F12 (P3) — Custom find-highlight blue instead of `findHighlightColor`, fixed for both appearances

- **File:** `Sources/ViewerUI/Palette.swift:63-85` (`findHighlightBlueColor` sRGB
  #1E6FFF; inactive 0.28 alpha wash, current 0.55).
- **Impact:** the platform find-highlight is system yellow (`NSColor.findHighlightColor`)
  — Safari/TextEdit/Xcode users scan for yellow. A 0.55-alpha saturated blue over dark
  syntax-highlighted text also has worse worst-case text contrast than the system
  yellow-with-black-text treatment. The header comment shows this was tuned
  deliberately, so treat as polish, not a bug.
- **Suggested fix:** use `findHighlightColor` for the current match (with
  `.labelColor`-forcing per system behavior) or keep blue but bump differentiation via
  a border on the active match rather than alpha alone.
- **Fix size:** S · **Fix risk:** safe (pixel-test updates on the VM).

### F13 (P3) — Tab close affordance on the trailing edge (macOS-native tabs put it leading)

- **File:** `Sources/ViewerUI/TabBar.swift:464-497` (close button is the last element in
  the tab's HStack).
- **Impact:** Safari, Xcode, Terminal, Finder all place tab-close on the LEFT edge.
  Trailing-close is the VS Code convention — consistent with this app's idiom, but a
  native-feel tell. Note also `TabBar.swift:511` `.accessibilityElement(children:
  .ignore)` collapses the whole tab (including the close button and both status dots)
  into one AX element, so the close control is invisible to VoiceOver/AX-driven UAT —
  covered in the accessibility dimension but worth cross-referencing here.
- **Suggested fix:** product call — if VS Code idiom is intentional, keep; otherwise flip
  the HStack ordering. Fix the AX collapse regardless (`children: .contain` + label).
- **Fix size:** S · **Fix risk:** safe.

### F14 (P3) — Duplicate "New Image" commands with inconsistent ellipsis

- **File:** `Sources/MarkdownViewer/main.swift:1728-1733` (File ▸ New File ▸ "Image…")
  and `:1809-1813` (File ▸ "New Image", same `newImage(_:)` selector, no ellipsis).
- **Impact:** the same command appears twice in one menu at two levels with two titles;
  the standalone copy omits the ellipsis though it opens a size/color dialog (HIG:
  trailing ellipsis when further input is required).
- **Suggested fix:** delete the standalone item (the submenu copy suffices), or keep it
  and drop the submenu entry; add "…" to whichever survives.
- **Fix size:** S · **Fix risk:** safe.

### F15 (P3) — Chrome typography is hardcoded pixel sizes; some glyphs below legibility floor

- **Files:** e.g. `Sources/ViewerUI/ContentToolbar.swift:113` (breadcrumb chevron
  `size: model.uiSize(7)` — 7 pt at zoom 1.0), `TabBar.swift:444, 478` (8 pt),
  `StatusBar.swift:221` (9 pt), pervasive `.system(size: 10/11/12)` across chrome.
- **Impact:** HIG floor for legible text is ~10 pt; 7–9 pt glyphs are decorative at
  best. No semantic text styles are used anywhere in chrome, so the system Text Size
  accessibility setting has no effect — mitigated (deliberately) by the app's own
  chrome-zoom (`uiSize` = base × zoom), which is a reasonable substitute but is
  buffer-zoom-coupled.
- **Suggested fix:** raise the sub-10 pt glyphs to ≥10 pt equivalents; longer term
  consider mapping chrome fonts through `.caption`/`.footnote` relative styles.
- **Fix size:** S (glyph bumps) / L (text-style migration — not recommended pre-launch) ·
  **Fix risk:** safe.

### F16 (P3) — Destructive confirms don't mark the destructive button; "&" in button title

- **Files:** `Sources/ViewerUI/SidebarView.swift:362-368` (Move to Trash confirm — no
  `hasDestructiveAction`, first/default button IS the destructive one),
  `Sources/ViewerUI/Coordinators/EditorCoordinator.swift:1233-1234` ("Discard & Reload"
  — HIG spells out "and"; also the destructive choice, unmarked).
- **Impact:** since macOS 11 `NSButton.hasDestructiveAction` renders destructive alert
  buttons red and keyboard-guards them; without it, Return confirms trash/discard as the
  default action with no visual weight.
- **Suggested fix:** set `hasDestructiveAction = true` on Move to Trash / Discard
  buttons; retitle "Discard and Reload"; consider making Cancel the default for the
  trash confirm.
- **Fix size:** S · **Fix risk:** safe.

### F17 (P3) — `NSApp.activate(ignoringOtherApps: true)` (deprecated, focus-stealing) at 9+ sites

- **Files:** `Sources/MarkdownViewer/main.swift:3511, 3540, 3849, 3859, 3869, 3881,
  3901, 3912`, `Sources/MarkdownViewer/ScriptRunner.swift:56`,
  `Sources/ViewerUI/SettingsView.swift:689, 705`.
- **Impact:** deprecated since macOS 14; the modern cooperative-activation API is
  `NSApp.activate()` / `yieldActivation(to:)`. `ignoringOtherApps: true` is also the
  focus-stealing pattern HIG warns against — several of these fire from background/
  automation paths (walkthrough start, tool-window opens) where yanking focus from
  another app is hostile.
- **Suggested fix:** replace with `NSApp.activate()`; audit which call sites even need
  activation (window `makeKeyAndOrderFront` inside an already-active app doesn't).
- **Fix size:** S · **Fix risk:** safe.

### F18 (P3) — `applicationSupportsSecureRestorableState` not implemented

- **File:** `Sources/MarkdownViewer/main.swift` (AppDelegate at `:12`; grep = no
  override).
- **Impact:** macOS 14+ logs a restorable-state warning at every launch and, with
  NSCoder secure-coding enforcement tightening, unsecured state restoration is on
  Apple's deprecation path. The app does its own frame/session persistence, so the
  effective risk is console noise + future-proofing.
- **Suggested fix:** `func applicationSupportsSecureRestorableState(_ app: NSApplication)
  -> Bool { true }`.
- **Fix size:** S · **Fix risk:** safe.

### F19 (P3) — Full-screen support unverified; no explicit `collectionBehavior`

- **File:** `Sources/MarkdownViewer/main.swift:329-338` (styleMask `[.titled, .closable,
  .miniaturizable, .resizable]`; no `collectionBehavior` set; repo grep `fullScreen` in
  UI code = no hits).
- **Impact:** best guess: AppKit gives resizable windows implicit full-screen and
  auto-inserts View ▸ Enter Full Screen — but nothing in-code guarantees it, and the
  custom-built View menu makes the auto-insertion worth confirming (a primary window
  without ⌃⌘F / green-button full screen would be a visible launch gap). Flagged as
  VERIFY on the VM rather than a confirmed defect.
- **Suggested fix:** verify on the VM; if absent, set
  `window.collectionBehavior.insert(.fullScreenPrimary)`.
- **Fix size:** S · **Fix risk:** safe.

### F20 (P3) — Session shortcuts collide with platform tab-switch muscle memory

- **File:** `Sources/ViewerCore/Commands/CommandRegistry+BuiltIn.swift:541-556`
  (`session.next` ⌃Tab, `session.previous` ⌃⇧Tab, `session.close` ⌘⇧W).
- **Impact:** in every tabbed Mac app ⌃Tab cycles *tabs* and ⌘⇧W closes the *window*;
  here ⌃Tab jumps sessions (a much bigger context switch — the tab set swaps out) and
  ⌘⇧W destroys a whole session's tab set (behind its own confirm, per the dirty-drain
  design). Deliberate design, but the mismatch between chord "size" and action "size"
  will surprise switchers.
- **Suggested fix:** owner judgment call; at minimum ensure the ⌘⇧W path always confirms.
- **Fix size:** S · **Fix risk:** careful (shipped muscle memory either way).

---

## Positive observations

- **`Palette` (Palette.swift) is the right pattern:** all chrome colors are AppKit
  dynamic system colors cached once; the only custom dynamic color
  (`systemSidebarPanelBackground:56-61`) is built with `NSColor(name:)` and an
  appearance-aware resolver, including the high-contrast appearances. Grep found only
  3 hardcoded-RGB call sites in ViewerUI, all image-editor *content* colors.
- **Default (no-theme) dark mode is structurally sound** — chrome from system colors,
  `markdown.css:158` carries a real `prefers-color-scheme: dark` block, the rendered
  WebView is transparent (`HTMLRenderedView.swift:161`) over themed backgrounds.
- **Reduce Motion is honored** via `@Environment(\.accessibilityReduceMotion)` +
  `MotionGate` in the tooltip overlay (`FloatingTooltip.swift:249-284`) and hover
  styles (`RowHoverButtonStyle.swift:170`).
- **The `.helpInfo` tooltip system** (`FloatingTooltip.swift:308-411`) keeps native
  `.help` as fallback, feeds the status bar, and sets a11y label/hint — a genuinely
  additive custom control, correctly `accessibilityHidden` and hit-test-transparent.
- **Shortcut governance:** `CommandRegistry` as single source of truth with user
  overrides (`~/.textview/keybinding.json`), and HIG-literate decisions on record —
  ⌘= zoom-in rationale (`main.swift:2270-2279`), ⌘P deliberately reserved for Print
  vs VS Code's palette (`CommandRegistry+BuiltIn.swift:410-414`), fold shortcuts moved
  off legacy conflicts with comments explaining each move.
- **Menu skeleton:** correct top-level order (App/File/Edit/Format/View/Tools/Navigate/
  Session/Window/Help — `main.swift:2875-2928`), standard App-menu block (Hide/Hide
  Others ⌥⌘H/Show All/Quit), `NSApp.helpMenu` set for searchable help, Window menu with
  Minimize/Zoom/Bring All to Front, Services provider registered, About via the standard
  panel, Settings… on ⌘,.
- **Window geometry hygiene:** frame autosave + first-run centering + off-screen /
  under-minimum clamping through a host-tested model (`WindowGeometry`,
  `main.swift:343-389`), AppKit-level `contentMinSize`, and window-tabbing opt-out with
  a written rationale (`main.swift:227-229`).
- **All 256 SF Symbol usages resolve to valid catalog names** (no typos, no
  macOS-16-only symbols); symbols in menus get `accessibilityDescription`
  (`main.swift:1751-1752`).
- **Dialogs know their idiom:** overlays (palette, Go-to) use `.keyboardShortcut(
  .defaultAction/.cancelAction)`; scoped tasks use `.sheet`; save panels set
  `allowedContentTypes` / `canCreateDirectories`.
- **The dirty-close prompt is wired through every close path** (`DocumentModel.swift:
  3151-3178` — close, close-others, close-to-right, window close) while session
  switches correctly bypass it by snapshotting buffers (TSK-733).

---

## Coverage gaps (not examined)

- **No runtime/VM verification** — everything here is static. Pixel-level issues
  (actual contrast of the theme mismatch, focus rings, vibrancy interactions,
  full-screen behavior F19) need the VM T5 lane to confirm.
- **CodeMirror/WebView interior UX** (editor context menus, CM6 find panel, selection
  colors inside the WebView) — only the native chrome around it was reviewed.
- **Canvas, Claude Monitor, Walkthrough, Audio/Image editor deep interiors** — spot
  checks only.
- **Localization/RTL:** all UI strings are hardcoded English (no `NSLocalizedString` /
  String Catalogs); not assessed as a finding since launch scope appears en-only, but
  it is a structural cost if that changes.
- **Drag-and-drop matrix** (sidebar ↔ Finder, tab tearing) beyond confirming the
  file-URL drop target and exported drag UTIs exist.
- **Accessibility beyond HIG overlap** — VoiceOver traversal, Full Keyboard Access
  tab-order — covered by the separate accessibility dimension
  (`accessibility.md` in this audit folder).
- **Menu item validation matrix** (`validateMenuItem`, ~4,000 lines of main.swift not
  read line-by-line) — enable/disable correctness per state was sampled, not swept.
