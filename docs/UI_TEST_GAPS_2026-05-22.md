# UI Test Coverage Audit — TextView / MarkdownViewer (UTM VM)

**Date:** 2026-05-22
**Scope:** Live-app (NSApplication) UI-test coverage gaps for recently-shipped and about-to-ship features
**Target:** Tests that must run on UTM macOS15 VM (not host)

---

## Executive Summary

The codebase has **6 major feature areas shipped in the past 3 weeks** (Sessions v1, LSP v1, Plugins v1, Code Folding, Walkthrough Player, TreeSitter lazy-load). **~150 new tests** landed on `main` but are skewed toward **model-level coverage** (Sessions, Plugins, LSP stores) with **significant VM-level UI gaps** in:

1. **Sessions outer-tab layout** — nested-tabs UI not yet rendered; only model-contract tests exist
2. **LSP hover popovers** — deferred to VM (requires live text-view mouse events + WKWebView)
3. **Code folding chevron column** — storage-swap + responder-selector deferred (host-only constraint)
4. **Walkthrough player positioning** — line-anchored popovers partially implemented; sidebar/gitTab/window anchors not positioned
5. **Right-click context menus** — all file-tree/bookmark/tab-bar menus lack live-interaction coverage
6. **Keyboard navigation** — ⌘1-9 (tab/session switching), ⌃Tab, ⌃⌘S (sidebar), keyboard shortcuts on Settings window

Below: **16 feature areas** analyzed; **23 coverage gaps** identified, grouped by VM-test necessity and shipped-vs-pending status.

---

## 1. Sessions v1 (Merged; nested-tabs layout pending)

| Feature | Surface | Scenario Type | Why VM-only | Test Status |
|---------|---------|---|---|---|
| Outer tab strip rendering | SessionTabStrip view, tab width/spacing, glyph rendering | visual regression | Window compositor, tab sizing logic | ❌ NO VM TEST |
| Session switch via click | Tab click handler + DocumentModel switch | interaction | NSApplication responder chain, view swap | ❌ NO VM TEST |
| Session switch via ⌃Tab | System-level key binding dispatch | keyboard event | macOS event loop, NSApplication.sendEvent | ❌ NO VM TEST |
| Session switch via ⌃1-9 | Similar (numeric variants) | keyboard event | ditto | ❌ NO VM TEST |
| Close session ⇧⌘W | Window close + session detach sync | keyboard + state | NSWindow lifecycle | ❌ NO VM TEST |
| "Open in New Session" (tree) | SidebarView context menu → opens new window | interaction | NSApplication.activate, drag alt-click, async window creation | ⚠️ UNIT ONLY (OpenInNewSessionTests model-only) |
| "Open in New Session" (bookmarks) | BookmarksSection context menu → same | interaction | ditto | ⚠️ UNIT ONLY |
| Session indicator dot (live-watcher) | GitPanelModel.watcherIsActive → glyph in outer tab | binding | observable state propagation + SwiftUI redraw | ⚠️ MODEL-ONLY |
| Detach-then-remount file watcher | FileWatcher pause on detach, resume on mount | state lifecycle | DispatchSourceFileSystemObject lifecycle | ✅ TESTED (SessionStateTests) |
| Workspace snapshot persistence | SessionStore write-flush on detach | persistence | GCD serialization, file I/O blocking | ✅ TESTED (SessionStoreTests) |

**Highest priority new tests:**
- `test_outerTabStripRendersVisibly` — ⌃1 switches sessions, old session hidden, new sidebar+tabs in place
- `test_controlTabSwitchesSessions` — **keyboard event chain**; requires live key dispatch
- `test_openFolderInNewSessionShowsNewWindow` — **NSApplication multi-window**; file watcher attached to new session

---

## 2. Walkthrough Player (Merged; popover positioning incomplete)

| Feature | Surface | Scenario Type | Why VM-only | Test Status |
|---------|---------|---|---|---|
| Player dock-bottom strip visible | WalkthroughPlayerView, NSRect layout | visual | SwiftUI.frame layout in NSWindow | ❌ NO VM TEST |
| Prev/Next/Pause buttons | Button tap handlers + player state | interaction | SwiftUI button tap dispatch | ⚠️ SCRIPT ONLY (ScenarioTests has 0 walkthrough steps) |
| Auto-advance dwell timer | Timer fires, next action queued | state + timing | DispatchSourceTimer lifecycle | ✅ TESTED (WalkthroughAutoAdvanceTests) |
| Line-anchored popover positioned | LSPHoverAttachment-style precision for highlight strips | visual regression | NSView frame in window coords + clipping | ⚠️ PARTIAL (Editor anchor done; sidebar/gitTab anchor not positioned) |
| Sidebar-anchored popover | Popover aligned to a tree row | visual regression | ditto | ❌ NO VM TEST |
| gitTab-anchored popover | Popover aligned to a Git panel row | visual regression | ditto | ❌ NO VM TEST |
| Window-anchored popover (floating) | Callout positioned at screen coords | visual regression | NSApplication screen info | ❌ NO VM TEST |
| Note button → Code Review | Button routes to ReviewViewController | interaction + navigation | Popover dismissal + new modal launch | ❌ NO VM TEST (blocked on integration) |
| Walkthrough script load from file | File picker + JSON decode + validation | I/O + state | file:// URL drag-drop to app | ✅ TESTED (WalkthroughFixtureFileTests) |
| Walkthrough schema version guard | Reject v2 scripts on v1 reader | compatibility | JSON schema validation | ✅ TESTED (WalkthroughScriptTests) |

**Highest priority new tests:**
- `test_popoverAutoPositionsAtLineAnchorsInEditor` — previous line + next line + horizontal bounds
- `test_popoverAutoPositionsAtSidebarRowAnchors` — tree item frame in window coords
- `test_popoverAutoPositionsAtGitTabRowAnchors` — diff/log table row frame in window coords
- `test_noteButtonOpensCodeReviewModal` — **multi-modal window orchestration**

---

## 3. LSP Integration (Merged; hover + outline UI deferred)

| Feature | Surface | Scenario Type | Why VM-only | Test Status |
|---------|---------|---|---|---|
| Outline section in sidebar | LSPOutlineSection view tree | visual + interaction | SwiftUI child disclosure, symbol click routing | ⚠️ MODEL ONLY (LSPOutlineSection.swift wired; UI tests deferred) |
| Hover popover on mouseover text | LSPHoverAttachment + NSView.tracking | interaction | NSTextView mouse tracking, async popover show | ❌ NO VM TEST |
| Hover popover dismisses on scroll | Mouse-exit tracking + fade animation | behavior | hover-tracking lifecycle | ❌ NO VM TEST |
| Diagnostics window (Settings > LSP) | LSPDiagnosticsView window + live table refresh | visual + interaction | NSPanel lifecycle, view binding to LSPPool | ⚠️ COMPONENT ONLY (DiagnosticDumpTests mock-only) |
| Diagnostic inline squiggles | Text-view attachment display (future phase) | visual regression | NSTextView attribute rendering | ❌ DESIGN-PHASE ONLY |
| Definition jump (Cmd+hover or menu) | DocumentModel + SourceTextController scroll | navigation | responder chain, coordinated scroll | ❌ NO VM TEST |
| Workspace symbol search | Cross-session symbol lookup | search + interaction | NSApplication multi-window query | ❌ NO VM TEST (future phase) |

**Highest priority new tests:**
- `test_hoverPopoverShowsOnMouseoverSymbol` — **mouse tracking + async popover**; requires real NSTextView
- `test_hoverPopoverDismissesOnMouseExit` — **tracking lifecycle**
- `test_definitionJumpScrollsToSymbolInTab` — **inter-tab navigation**

---

## 4. Code Folding (Merged; storage-swap + chevron deferred)

| Feature | Surface | Scenario Type | Why VM-only | Test Status |
|---------|---------|---|---|---|
| Fold-chevron column in gutter | SourceGutterView canvas + interactive clickable rects | visual | Canvas hit-testing, glyph rendering, layout sync | ❌ NO VM TEST |
| Collapse at caret (⌘⌥[) | Keypress dispatch + DocumentModel.collapseAtCaret | keyboard | key binding dispatch, responder chain | ⚠️ UNIT ONLY (FoldCommandsTests, model-level) |
| Expand at caret (⌘⌥]) | ditto | keyboard | ditto | ⚠️ UNIT ONLY |
| Collapse all (future keybind) | bulk fold state mutation | keyboard | ditto | ❌ NO VM TEST (future) |
| NSTextView storage-swap (deferred) | Swap attributed string, re-layout | implementation detail | NSTextView responder state invalidation | ❌ DEFERRED (host-only constraint) |
| Fold region detection per language | TreeSitter.foldRegions query result | logic | **pure logic, host-testable** | ✅ TESTED (FoldRegionTests) |
| Fold line-map (display ↔ source) | FoldLineMap display-to-original index | logic | pure logic | ✅ TESTED (FoldLineMapTests) |

**Highest priority new tests:**
- `test_chevronColumnRendersAtCorrectRowsForFoldRegions` — **Canvas visibility + hit detection**
- `test_collapseAtCaretHidesFollowingLines` — **text-view layout swap** (may be blocked on storage-swap deferral)
- `test_expandAtCaretShowsCollapsedLines` — ditto

---

## 5. Plugins v1 (Merged; UI gaps in sidebar + Settings)

| Feature | Surface | Scenario Type | Why VM-only | Test Status |
|---------|---------|---|---|---|
| Plugins sidebar section | PluginSidebarSections nested rows | visual | SwiftUI rendering, dynamic section list | ⚠️ NO LIVE-APP TEST (model-only PluginManifest tests) |
| Plugin install flow | NSOpenPanel + manifest validation + fs write | I/O + dialog | NSOpenPanel lifecycle, TCC file access | ❌ NO VM TEST |
| First-install permission grant | NSAlert prompt + UserDefaults write | interaction + dialog | NSAlert modal dispatch, permission contract | ❌ NO VM TEST |
| Settings > Plugins pane | PluginsSettingsView in SettingsWindow | visual + interaction | NSView/NSViewController lifecycle in modal | ⚠️ NO VM TEST |
| Tier B subprocess spawn | Process + pipe I/O + env scrub | process lifecycle | Process waitUntilExit + concurrent drain | ✅ TESTED (PluginProcessTests) |
| Plugin audit log display | JSON log file read → table view | I/O + visual | file:// watchdog + NSTableView data binding | ❌ NO VM TEST |

**Highest priority new tests:**
- `test_pluginSidebarSectionDisplaysInstalledPlugins` — **SwiftUI dynamic list visibility**
- `test_installPluginShowsPermissionPromptAndStoresGrant` — **NSAlert + permission contract**
- `test_pluginsSettingsPaneListsPluginsAndVersions` — **Settings window content**

---

## 6. File Tree Right-Click Menu (All features; no VM tests)

| Feature | Surface | Scenario Type | Why VM-only | Test Status |
|---------|---------|---|---|---|
| "Open" (in current tab) | contextMenu handler in SidebarView row | interaction + state | NSTableView context menu dispatch, tab model update | ❌ NO VM TEST |
| "Open in New Tab" | menu action → tab append | interaction | ditto + TabBar re-render | ❌ NO VM TEST |
| "Open in Split" | menu action → splitURL model update | interaction | SwiftUI SplitPaneView swap | ❌ NO VM TEST |
| "Bookmark" | menu action → BookmarksStore.add + sidebar refresh | interaction + I/O | bookmarks.json write, sidebar section re-render | ⚠️ UNIT ONLY (BookmarkIntegrationTests) |
| "Open in New Session" | SessionsCoordinator → new window | interaction + process | NSApplication.activate new window | ⚠️ UNIT ONLY (OpenInNewSessionTests closure contract) |
| "Git Root Override" | SidebarModel.gitRootOverride = url | state mutation | git panel refresh + status re-query | ⚠️ UNIT ONLY |
| "Show Folder History" | Opens git log in tab (synthetic markdown) | navigation | GitClient.log + markdown tab creation | ❌ NO VM TEST |
| "Open in Terminal" | NSWorkspace.openApplication | system integration | Launch Services + Process fork | ⚠️ NO VM TEST (one-liner) |

**Highest priority new tests:**
- `test_openCurrentTabOpensFileInActiveTab` — **context menu dispatch**
- `test_openNewTabCreatesTabAndSelectsIt` — **tab model update + visibility**
- `test_openInSplitShowsSplitViewAndTargetFile` — **split-pane visibility**
- `test_openInNewSessionOpensSecondWindow` — **multi-window coordination**

---

## 7. Bookmarks Right-Click Menu (Bookmarks sidebar section; no VM tests)

| Feature | Surface | Scenario Type | Why VM-only | Test Status |
|---------|---------|---|---|---|
| "Remove Bookmark" | BookmarksSection menu → BookmarksStore.remove | interaction | list item removal + sidebar refresh | ⚠️ UNIT ONLY |
| "Open in New Session" | SessionsCoordinator → new window | interaction | ditto (Sessions feature) | ⚠️ UNIT ONLY |
| "Reveal in Finder" | NSWorkspace.selectFile + Finder focus | system integration | Launch Services | ❌ NO VM TEST |
| "Copy Path" | NSPasteboard write | system integration | clipboard coordination | ❌ NO VM TEST |

**Highest priority new tests:**
- `test_removeBookmarkRemovesFromListAndStores` — **list model update**
- `test_revealInFinderOpensFinderWindow` — **Launch Services focus**

---

## 8. Tab Bar (All features; some VM gaps)

| Feature | Surface | Scenario Type | Why VM-only | Test Status |
|---------|---------|---|---|---|
| Close tab (X button) | TabBar close handler | interaction | button dispatch + tab array mutation | ⚠️ UNIT ONLY (DocumentModelTests covers model) |
| Tab scroll (horizontal overflow) | NSScrollView or SwiftUI scroll wrapper | interaction + visual | horizontal scroll indicator + keyboard scroll sync | ❌ NO VM TEST |
| Drag tab to reorder | NSView drag source / drop target | interaction | NSDraggingSource lifecycle, tab array reorder | ❌ NO VM TEST |
| Right-click tab → reveal sidebar | contextMenu on tab | interaction + state | SidebarModel.revealInSidebar(url) | ⚠️ PARTIAL (SidebarRevealTests model-only) |
| Tab title update on file edit | DocumentModel.updateTabTitle | binding | SwiftUI view update on @Published change | ⚠️ UNIT ONLY |
| Tab dirty indicator (•) | Rendered on tab title when file edited | visual binding | file-watcher + title re-render | ⚠️ MODEL ONLY |

**Highest priority new tests:**
- `test_closeTabRemovesTabAndSelectsAdjacentTab` — **close handler + adjacent selection logic**
- `test_tabScrollShowsHorizontalIndicatorOnOverflow` — **NSScrollView behavior**
- `test_dragTabReordersTabList` — **NSDraggingSource + model persistence**

---

## 9. Sidebar (Mostly model-tested; UI gaps in locking + interactions)

| Feature | Surface | Scenario Type | Why VM-only | Test Status |
|---------|---------|---|---|---|
| Sidebar lock toggle | isSidebarLocked state + icon swap | interaction | SwiftUI button state binding | ⚠️ UNIT ONLY (SidebarRevealTests) |
| Sidebar resize (drag right edge) | DraggableSidebar width binding + persist | interaction | NSView drag tracking, UserDefaults write | ❌ NO VM TEST |
| Sort menu (name/date/kind) | Menu handler + sorted children | interaction | sortOrder mutation + sidebar re-render | ⚠️ NO VM TEST (SidebarModel has sort logic) |
| FSEvents auto-refresh | FolderWatcher callback → invalidateCache | background behavior | FSEvent stream + main-thread dispatch | ✅ TESTED (FileWatcherIntegrationTests) |
| Palette interactions (text search) | Command palette filtering | logic + interaction | NSTableView data source, Swift string matching | ⚠️ UNIT ONLY (CommandPaletteView has no dedicated tests) |
| Search in sidebar (future) | Text input box + live filter | interaction | unimplemented | — |

**Highest priority new tests:**
- `test_sidebarLockTogglePreventsCollapse` — **lock state binding**
- `test_dragSidebarRightEdgeResizesAndPersists` — **NSView drag tracking + NSUserDefaults**
- `test_sortMenuReordersSidebarRows` — **sortOrder mutation + list re-render**

---

## 10. Status Bar (All features; some visual gaps)

| Feature | Surface | Scenario Type | Why VM-only | Test Status |
|---------|---------|---|---|---|
| Cursor line/col display | StatusBar text binding to SourceTextController.selection | binding | source-view selection tracking | ⚠️ MODEL ONLY |
| Indent indicator (tabs/spaces) | Parsed from source file | logic | String analysis | ✅ TESTED (DocumentModelTests) |
| File size display | Text file byte count | binding | file load state | ✅ TESTED (DocumentModelTests) |
| Zoom level indicator | Zoom binding display | binding | view-level state | ❌ NO VM TEST (visual-only) |

---

## 11. View Modes (Render / Source / Hex / Formatted; mostly tested)

| Feature | Surface | Scenario Type | Why VM-only | Test Status |
|---------|---------|---|---|---|
| Toggle Render ↔ Source (⇧⌘R) | Keyboard dispatch + view swap | keyboard + visual | WKWebView / NSTextView swap in SwiftUI | ⚠️ SCRIPT ONLY (InteractionScriptTests.test_toggleView_swapsRenderedAndSourceViews) |
| Mode persistence on tab switch | ViewMode stored per tab | state | @Published tab update | ✅ TESTED (DocumentModelTests) |
| Hex mode rendering | HexView data → rows | visual | Canvas rendering, memory-efficient row virtualization | ⚠️ PARTIAL (component rendered in ComponentVisualTests) |
| Formatted view (SQL/CSV/JSON) | ContentView routing to CSVTableView / SQLiteBrowserView | visual | dynamic view selection | ✅ TESTED (FormatToggleTests for model; ComponentVisualTests for view) |

---

## 12. Git Panel Sub-tabs (Status / Log / Stash / Trees / Remotes; mostly tested)

| Feature | Surface | Scenario Type | Why VM-only | Test Status |
|---------|---------|---|---|---|
| Git status table | GitStatusTab with M/A/?/D badges | visual + sorting | NSTableView data source | ⚠️ NO LIVE-APP TEST (GitStatusTabGroupingTests model-only) |
| Git log graph | GitLogTab + GraphLayout line rendering | visual | Canvas rendering of graph edges | ⚠️ PARTIAL (GraphLayoutTests model; no visual regression) |
| Switch tab via click | Tab selection handler | interaction | tab control dispatch | ⚠️ NO VM TEST |
| Git stash list | GitStashTab table | visual | table data source | ⚠️ NO VM TEST |
| Git worktrees list | GitWorktreesTab table | visual | ditto | ⚠️ NO VM TEST |
| Git remotes list | GitRemotesTab with push/pull actions | visual + interaction | ditto + button dispatch | ⚠️ NO VM TEST |
| File diff in tab | DiffView syntax coloring + line mapping | visual | DiffHighlighter + text attributes | ⚠️ PARTIAL (DiffHighlighterTests model; no visual regression) |

**Highest priority new tests:**
- `test_gitStatusTableDisplaysAndClickSelects` — **NSTableView interaction**
- `test_gitLogGraphRendersTreeStructure` — **Canvas visual regression**
- `test_switchGitTabShowsTabContent` — **tab control dispatch**

---

## 13. Settings Window (Kitchen sink; significant gaps)

| Feature | Surface | Scenario Type | Why VM-only | Test Status |
|---------|---------|---|---|---|
| Settings window open (Settings menu) | NSPanel launch | dialog | NSWindowController lifecycle, SettingsView hosting | ❌ NO VM TEST |
| Zoom slider | Slider binding → DocumentModel.zoom | interaction | NSSlider value change, zoom re-render | ❌ NO VM TEST (binding tested at model level) |
| Theme picker | Segmented control → themeOverride | interaction | PreferencesStore write, appearance change | ⚠️ NO VM TEST |
| Word wrap toggle | Toggle → sourceWordWrap | interaction | NSTextView attributes update | ⚠️ NO VM TEST |
| Invisibles toggle | Toggle → showInvisibleChars | interaction | NSTextView attribute re-apply | ❌ NO VM TEST |
| LSP Diagnostics panel (inside Settings) | Button → opens 560×420 window with live LSPPool data | dialog + data binding | NSPanel + live table refresh | ⚠️ PARTIAL (DiagnosticDumpTests mocks LSPPool) |
| Plugins pane | PluginsSettingsView list | visual + interaction | PluginManifest enumeration, uninstall handler | ⚠️ NO VM TEST |
| Sessions list (future) | List of persisted sessions + reorder/delete | visual + interaction | SessionStore persistence | ❌ NO VM TEST (future) |

**Highest priority new tests:**
- `test_settingsWindowOpensAndClosesCorrectly` — **NSPanel lifecycle**
- `test_zoomSliderChangesZoomLevelAndPersists` — **NSSlider value dispatch**
- `test_lspDiagnosticsPanelShowsLivePoolSnapshot` — **data binding to live model**
- `test_pluginsPaneListsAndUninstallsPlugins` — **plugin management UI**

---

## 14. Visual Regression (Main baseline + compositor guard)

| Feature | Surface | Scenario Type | Why VM-only | Test Status |
|---------|---------|---|---|---|
| Compositor: TabBar/ModeBar/StatusBar visible | Pixel sampling at 64×16 grid, ≥3 color variance per region | visual regression | screencapture against live window (macOS 15+ Screen Capture Privacy issue) | ✅ TESTED (SourceViewVisualRegressionTests; XCTSkip'd on VM due to TCC) |
| Compositor: Sidebar visible alongside source | Same visual regression check | ditto | ditto | ✅ TESTED (same file) |
| Full-window layout (all strips + sidebar + content) | End-to-end visual | visual | ditto | ⚠️ PARTIAL (vm-smoke.sh eyeball-only; automated screenshot returns blank) |

---

## 15. Focus & Responder Chain (Cross-cutting)

| Feature | Surface | Scenario Type | Why VM-only | Test Status |
|---------|---------|---|---|---|
| Focus on find bar opens automatically | NSTextView → first responder | focus | responder chain dispatch | ❌ NO VM TEST |
| Escape dismisses find bar | Key dispatch + responder resignation | keyboard | firstResponder = nil + view removal | ❌ NO VM TEST |
| Tab key cycles through controls | macOS tab-focus behavior | keyboard | NSView traversal order | ❌ NO VM TEST |
| Settings window modal focus | NSPanel.makeKey | dialog | window focus | ⚠️ NO VM TEST |

---

## 16. Keyboard Shortcuts (High-value gaps)

| Feature | Shortcut | Status |
|---------|----------|--------|
| New tab | ⌘T | ✅ UNIT (DocumentModelTests); ⚠️ NO LIVE-KEY TEST |
| Close tab | ⌘W | ⚠️ UNIT ONLY |
| Quit | ⌘Q | ❌ NO VM TEST (app lifecycle) |
| Next/Prev tab | ⌥⌘→ / ⌥⌘← | ⚠️ UNIT ONLY |
| Jump to tab N | ⌘1-9 | ⚠️ UNIT ONLY; Sessions adds ⌃1-9 (⌃Tab too) |
| Open file | ⌘O | ❌ NO LIVE-KEY TEST |
| Open folder | ⇧⌘O | ❌ NO LIVE-KEY TEST |
| Toggle sidebar | ⌃⌘S | ⚠️ UNIT ONLY |
| Toggle source/render | ⇧⌘R | ✅ SCRIPT (ScenarioTests) |
| Find | ⌘F | ⚠️ UNIT (FindBarTests) + ❌ rendered-mode broken (known Phase 4.5 gap) |
| Reload file | ⌘R | ❌ NO LIVE-KEY TEST |
| Collapse at caret | ⌘⌥[ | ⚠️ UNIT (FoldCommandsTests) |
| Expand at caret | ⌘⌥] | ⚠️ UNIT ONLY |

---

## Summary Table: Coverage by Feature Area

| Area | Recent Ship | Estimated Tests | Host-Safe? | VM-Safe? | Priority |
|------|---|---:|---|---|---|
| **Sessions v1** | ✅ Main | 47 | ⚠️ model only | ❌ 0 live-app | 🔴 CRITICAL |
| **Walkthrough UI** | ✅ Main | 22 | ⚠️ model/script | ❌ 0 anchor-position | 🔴 CRITICAL |
| **LSP v1** | ✅ Main | 52 | ⚠️ store/pool | ❌ 0 hover/outline | 🔴 CRITICAL |
| **Code Folding** | ✅ Main | 36 | ✅ logic tests | ⚠️ chevron visual only | 🟡 HIGH |
| **Plugins v1** | ✅ Main | 42 | ⚠️ manifest | ❌ 0 UI/install | 🟡 HIGH |
| **TreeSitter lazy** | ✅ Main | 55 | ✅ logic | ⚠️ first-load smoke | 🟢 MEDIUM |
| **File-tree context menu** | ✅ Main | 0 | ❌ 0 | ❌ 0 | 🔴 CRITICAL |
| **Bookmarks menu** | ✅ Main | 0 | ❌ 0 | ❌ 0 | 🟡 HIGH |
| **Tab bar** | ✅ Main | ~5 | ⚠️ model | ❌ 0 scroll/drag | 🟡 HIGH |
| **Sidebar interactions** | ✅ Main | ~3 | ⚠️ model | ❌ 0 lock/resize | 🟡 HIGH |
| **Settings window** | ✅ Main | 0 | ❌ 0 | ❌ 0 | 🟡 HIGH |
| **Git panel tabs** | ✅ Main | ~8 | ⚠️ model | ❌ 0 table-click | 🟢 MEDIUM |

---

## Highest-Priority New Tests (Ranked by Impact)

**Tier 1: Foundation features missing core UI coverage (no live-app tests at all)**

1. **`SessionsUITests::test_outerTabStripVisibleAndSwitches`** — Session v1 is the "Phase 1" feature; without live-app outer-tab coverage, the feature is ship-untested.
2. **`ContextMenuUITests::test_fileTreeRightClickOpensInCurrentTab`** — File-tree menu is the primary interaction surface for the app; 0 VM tests.
3. **`ContextMenuUITests::test_fileTreeRightClickOpenInNewSession`** — Sessions + tree context menu cross-integration.
4. **`LSPUITests::test_hoverPopoverShowsAtMouseoverSymbol`** — LSP v1 hover is a core editor feature; requires live mouse tracking.
5. **`SettingsWindowUITests::test_settingsWindowOpensAndClosesCorrectly`** — Every setting lands in a modal; no lifecycle tests.
6. **`KeyboardShortcutUITests::test_controlTabSwitchesSessions`** — Keyboard dispatch for all new sessions shortcuts (⌃Tab, ⌃1-9).

**Tier 2: Recently-shipped features with partial coverage (model-only; need UI)**

7. **`WalkthroughUITests::test_lineAnchoredPopoverAutoPositions`** — Walkthrough popovers partially implemented; line-anchor positioning ready to verify.
8. **`CodeFoldingUITests::test_chevronColumnRendersAndClickCollapses`** — Chevron UI is the entry point; no VM visual tests.
9. **`PluginsUITests::test_pluginsSidebarSectionDisplaysPlugins`** — Plugins sidebar section wired (model-level); UI never visually verified.
10. **`SidebarUITests::test_sidebarResizePersistsWidth`** — Sidebar resize is a core UX; pure interaction, no model test.

**Tier 3: Known regression vectors from LESSONS.md + historical bugs**

11. **`TabBarUITests::test_tabBarScrollShowsIndicatorOnOverflow`** — Tab bar overflow handling (related to "md-narrow-strip" regression history).
12. **`VisualRegressionUITests::test_sidebarVisibleAlongsideRenderedContent`** — Compositor-bug regression check; currently XCTSkip'd due to Screen Capture Privacy.

---

## Blockers & Constraints

| Blocker | Impact | Mitigation |
|---------|--------|-----------|
| macOS 15 Screen Capture Privacy | Visual regression tests XCTSkip on VM (TCC redacts windows launched via `sudo launchctl asuser`) | Manual eyeball via UTM display window + non-visual assertion tests (pixel sampling currently blocked) |
| NSTextView storage-swap deferred | Code folding chevron + collapse/expand UI blocked on responder-selector refactor (host-only constraint) | Implement chevron rendering first; storage-swap can land post-GA |
| Sessions nested-tabs layout not merged | Outer tab strip is design-only; no code in `main` yet | Nested-tabs UI is ~1-2 week follow-up; tests should be written when UI lands |
| LSP workspace symbol search (future phase) | Multi-window symbol queries not yet scoped | Defer cross-session tests to Phase 2 |

---

## Notes for Test Author

- All tests in `Tests/ViewerUITests/` that launch the `.app` (via `AppLauncher.runScript` or direct binary invocation) should use **`MDV_BACKGROUND=1` + `MDV_SKIP_WORKSPACE_RESTORE=1`** env vars to avoid UI focus-theft and stale workspace state.
- **Keyboard shortcut tests** must dispatch through `NSEvent.addLocalMonitorForEvents` (already used in `SidebarKeyMonitor.swift`) or low-level `CGEvent` to trigger the app's event handlers, not simulate them.
- **Right-click context menu tests** require `NSView` subclass inspection or accessibility tree traversal (no direct SwiftUI `ViewInspector` support for menus); consider using **menu-item callback mocking** at the model level where feasible (done for `OpenInNewSessionTests`).
- **Hover popover tests** need **NSTextView mouse tracking** (`NSTrackingArea`) + async popover show; best pattern is to hook `LSPHoverAttachment.mouseEntered()` and assert the popover appears in the view hierarchy.
- **Window + modal tests** (Settings, multi-window Sessions) should use **`NSWindow.orderedWindows`** to check for presence + **`NSPanel.isVisible`** to verify lifecycle.
