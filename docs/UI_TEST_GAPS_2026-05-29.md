# UI Test Coverage Audit — TextView / MarkdownViewer

**Date:** 2026-05-29
**Scope:** Coverage gaps for shipped UI surfaces, refreshed against `main` after the
CM6 Phase 1-4 + coordinator-extraction + sidebar polish + security/perf landings
of the last ~140 commits.
**Replaces:** `docs/UI_TEST_GAPS_2026-05-22.md` (kept intact for delta reference).

This audit classifies every UI-visible surface as:

| Tier | Meaning |
|---|---|
| **Covered (host)** | A host-safe `@MainActor` / pure-logic test pins the contract. Runs in `swift test --filter ViewerUITests.<Suite>` or `ViewerCoreTests`. |
| **Covered (VM)** | A live-app scenario or visual test pins the contract; only runs on the UTM VM (uses `LaunchHarness` / `AppLauncher.runScript` / screencapture). |
| **GAP** | No automation; manual smoke only. |

Tier suggestions for each GAP follow the project's three-tier discipline:

1. **Host @MainActor invariant test** — when the surface boils down to model
   wiring, observation chain, or pure-logic helper. No NSApplication required.
2. **VM scenario test** — when the assertion requires the live app, real
   responder chain, real NSEvent dispatch, or compositor output.
3. **Manual smoke** — when neither tier is reasonable yet (TCC-blocked visual,
   single-shot dialog, system-modal flow).

---

## Executive summary

Since `2026-05-22` the team has shipped:

- **CM6 Phase 2-4** (find bar, diagnostics squiggles, per-tab cursor/scroll
  restore, invisibles, L:C, v2 incremental change, foldingRange via LSP,
  indent guides, diff/blame gutter API)
- **3 coordinators extracted** from DocumentModel (`FindCoordinator`,
  `TabCoordinator`, `EditorCoordinator`) with +149 host-safe tests covering
  state machine, republish invariants, per-tab cleanup, forwarders, disk
  round-trip, and interop
- **Sidebar republish chain severed** + `SidebarSectionPlanner` divider fix
  + light-grey panel chrome + recency stripe
- **Per-tab HighlightCacheActor** (replaces global `@Published` dict)
- **Sessions tab persistence bug fixed** (`SessionTabPersistenceTests` pins it)
- **Native NSMenu context menu in CM6 editor** + image zoom in `MediaPreviewView`
- **Security hardening** (URL containment, ReDoS guard, HTML sanitizer,
  symlink refuse, env-gated walkthrough drop)

**Coverage delta vs. 2026-05-22:**

- **Newly Covered (host):** EditorCoordinator (88 tests), TabCoordinator
  (61 tests), FindCoordinator (24 tests), SidebarRepublishInvariant (7),
  HighlightCacheActor (8), CM6 v1 + extended bridge tests, CodeMirror bundle
  parity, GoToPath UI, Sessions tab persistence (9 host-MainActor),
  SessionState (8), Walkthrough sample-script roundtrip, walkthrough anchor
  key (14).
- **Newly Covered (VM):** CM6 Phase 4 v2 scenarios (4), `SessionsKeyboardUI`
  via verb dispatch (5), `OpenInNewSession` tree+goto verbs (2),
  `SessionTabBarUI` (5), Editor multi-scenario (5).
- **Still GAP (carried from 2026-05-22):**
  - LSP hover popover (NSTrackingArea + WKWebView) → still no VM test
  - Code-folding **chevron** visual + click-collapse → still no VM test
  - Right-click context menu *interactions* on file tree / bookmarks /
    tab bar / CM6 editor (model wired; live dispatch unverified)
  - Settings window lifecycle, zoom slider, theme picker, invisibles toggle
  - Sidebar **drag-resize** + width persistence
  - Tab-bar horizontal scroll on overflow + drag-reorder
  - Walkthrough popover positioning for sidebar / gitTab / window anchors
  - Plugins sidebar section + install permission prompt + Settings pane
- **New GAPs introduced since 2026-05-22:**
  - **CM6 NSMenu context menu in editor** (cut/copy/paste + Go to Definition)
    — popUp blocks on a real NSWindow; no live coverage
  - **Image zoom** (`MediaPreviewView` cmd-scroll + pinch + keyboard zoom)
    — no tests at all (host or VM)
  - **CM6 indent guides, fold gutter chevrons, diff stripes** — bridge tested
    in `CMOutboundEncodingTests` but no visual proof the JS renders them
  - **CM6 push-diagnostics squiggles** — `DiagnosticDumpTests` mocks; no
    real-DOM assertion
  - **Recency stripe colors per tier** — `FileTreeRecencyTests` covers the
    pure-logic side, but no rendering / accessibility-id assertion on a
    real tree row
  - **Outer Session tab bar** has host tests now via dump pages
    (`SessionTabBarUITests`) but **no visual / compositor coverage**
  - **Find-bar in editor mode** (CM6) — JS tested; no live key-dispatch
    test that `⌘F` opens the in-editor bar

---

## 1. CM6 Editor (Phases 1-4 landed; coverage thin on UI side)

| Surface | Status | Where |
|---|---|---|
| Bridge decoder v1 + v2 (inbound) | **Covered (host)** | `CMBridgeV1Tests`, `CodeMirrorBridgeExtendedTests`, `CMV2IntegrationTests` |
| Outbound encoder (applyEdits, fold markers, gutters, indent guides) | **Covered (host)** | `CMOutboundEncodingTests` |
| Bundle parity (vendored `codemirror.js` decodes shared HTML) | **Covered (host)** | `CodeMirrorBundleTests` |
| Disk round-trip (write/edit/save persists) | **Covered (host)** | `EditorCoordinatorDiskRoundtripTests` (13) + `EditorFlowIntegrationTests` |
| Save-active-editor, dirty-flip, close-prompt | **Covered (host)** | `EditorCoordinatorInteractionTests`, `EditorCoordinatorTests` (21 + 14) |
| Editor multi-scenario VM (load, edit, save, oversize cap) | **Covered (VM)** | `EditorPhase4ScenarioTests` (4), `EditorMultiScenarioTests` |
| `evaluateJavaScript` U+2028 / U+2029 escape | **Covered (host)** | via `JSStringEmbeddingTests` (ViewerCoreTests) |
| 50 MB cap aborts editor mode | **Covered (host+VM)** | `EditorPhase4ScenarioTests.test_v2_oversizedFile_doesNotEnterEditorMode` |
| **NSMenu right-click in CM6 editor** (Cut/Copy/Paste, Go to Definition) | **GAP** | `CodeMirrorEditorView.swift:85` — `NSMenu.popUp` blocks until dismissal; needs live NSWindow. |
| **CM6 find bar via ⌘F dispatch** | **GAP** | `MarkdownFindBar` host-tested for rendered mode; editor-mode find bar relies on JS message round-trip. No VM scenario fires the key event. |
| **CM6 diagnostics squiggles render in DOM** | **GAP (DOM-only)** | Bridge tested in `DiagnosticDumpTests` (mock); no assertion that the JS actually attaches lint marks. |
| **CM6 fold chevron column** (gutter) | **GAP** | `setFoldingRanges` outbound encoded + tested; no live or visual test that the JS renders chevrons. |
| **CM6 indent guides** | **GAP** | `setIndentGuides` encoded; no DOM/visual proof. |
| **CM6 diff/blame gutter** | **GAP** | `setGutterMarkers` encoded; no Swift-side wiring or visual proof. |
| **CM6 incremental change path under heavy paste** | **Covered (host)** | `CMV2IntegrationTests` exercises length-drift fallback to v1 `flushChanges`. |

### Proposed tests

- **Host @MainActor** — `CodeMirrorEditorViewMenuTests` pinning that the
  NSMenu items the bridge installs (Cut / Copy / Paste / Go to Definition)
  match `Sources/ViewerUI/CodeMirrorEditorView.swift` menu-build code. Use
  a fake `NSMenu` builder and assert item titles, actions, and `isEnabled`
  given a selection / no-selection / Go-to-Definition response.
- **VM scenario** — `EditorContextMenuScenarioTests.test_rightClickShowsNativeMenu`
  via a new script verb `editor-right-click <line:col>` that posts a
  `contextmenu` message into the WKWebView and asserts the dump captures
  the menu's first-responder swap (or screencaptures a corner).
- **VM scenario** — `EditorFindBarScenarioTests.test_cmdF_opensInEditorFindBar`
  via low-level `CGEvent` (the harness will eventually grow key dispatch;
  for now drive via `editor-find <query>` verb).
- **Host @MainActor** — `CMOutboundDOMAssertTests`: dispatch
  `setFoldingRanges` / `setIndentGuides` / `setGutterMarkers` into a
  detached WKWebView (or `JSContext`) and assert the corresponding state
  field exists. Optional; otherwise rely on bundle parity test + a single
  VM screencap of the editor with a folded region.

---

## 2. Coordinator state-machine (Find / Tabs / Editor)

| Surface | Status | Where |
|---|---|---|
| FindCoordinator state machine + forwarders | **Covered (host)** | `FindCoordinatorTests` (14), `FindRepublishInvariantTests` (10) |
| TabCoordinator open/close/select + 6 per-tab dicts cleanup | **Covered (host)** | `TabCoordinatorTests` (27), `TabCoordinatorCleanupTests` (6), `TabRepublishInvariantTests` (8), `DocumentModelTabForwarderTests` (20) |
| EditorCoordinator state + per-tab cleanup via `addCloseHook` | **Covered (host)** | `EditorCoordinatorTests` (21), `EditorCoordinatorCleanupTests` (7), `EditorCoordinatorInteractionTests` (14), `EditorRepublishInvariantTests` (13), `EditorCoordinatorDiskRoundtripTests` (13), `DocumentModelEditorForwarderTests` (20) |
| `countDocumentRepublishes(while:)` helper (test-infra) | **Covered (host)** | `TabRepublishInvariantTests` |
| Sidebar chain severance (no DocumentModel republish) | **Covered (host)** | `SidebarRepublishInvariantTests` (7) — includes a negative-control test |

This area is **fully covered**. The pattern (state-machine + republish
invariant + cleanup + forwarder + disk round-trip) is now the canonical
template for any future coordinator extraction.

---

## 3. Sessions v1 (now partly Covered (host); VM gaps shrunk)

| Surface | Status | Where |
|---|---|---|
| `session-open-folder`, `-activate`, `-next`, `-prev`, `-close-active` verbs | **Covered (VM)** | `SessionsKeyboardUITests` (5) — drives coordinator via verbs, asserts on `Pages(dump:).sessionTabBar` |
| Outer pill basics (lifecycle, activate, next/prev wrap, close) | **Covered (VM)** | `SessionTabBarUITests` (5) |
| `Open in New Session` from tree | **Covered (VM)** | `OpenInNewSessionUITests.test_treeContextMenuOpensInNewSession` |
| `GoToPath` ⇧⌘↩ → new session | **Covered (VM)** | `OpenInNewSessionUITests.test_goToPathShiftEnterOpensInNewSession` |
| Session-switch preserves tabs, sidebar root, zoom, wrap, theme, per-tab view mode | **Covered (host)** | `SessionTabPersistenceTests` (9 host-MainActor) |
| `activate()` bumps `lastActiveAt` on both sessions | **Covered (host)** | `SessionsCoordinatorTests` (ViewerCoreTests) |
| SessionStore persistence (atomic write, GCD serialisation) | **Covered (host)** | `SessionStoreTests` (ViewerCoreTests) |
| `FirstPaintGoToGate` (deferred go-to until first paint) | **Covered (host)** | `FirstPaintGoToGateTests` (ViewerCoreTests) |
| **Outer pill visual chrome** (color, font, hover state) | **GAP** | No VM screencap / compositor test. |
| **⌃Tab / ⌃1-9 real key dispatch** (vs verb dispatch) | **GAP (intentional)** | `SessionsKeyboardUITests` documents this: dispatching `NSEvent.addLocalMonitorForEvents` doesn't fire under headless `Process` launch. Manual VM smoke only. |
| **⇧⌘W close-window vs close-session race** | **GAP** | Closing the *window* via NSWindow lifecycle vs. closing the *session* via shortcut — no test pins which wins when both are armed. |
| **Workspace persistence on detach** | **GAP** | `SessionStateTests.test_detachThenRemount` exists, but no test cuts power mid-detach (snapshot atomicity). |

### Proposed tests

- **Host @MainActor** — `SessionPillChromeInvariantTests`: pin that
  active-pill background + label font weight match `SessionTabBar`'s
  computed style. Cheap visual proxy without screencap.
- **VM scenario** — `SessionCloseShortcutScenarioTests.test_shiftCmdW_closesSessionNotWindow`
  once the harness grows key dispatch (defer).
- **Host @MainActor** — `SessionStoreCrashRecoveryTests`: write
  half-formed snapshot, assert SessionStore.load rejects safely.

---

## 4. LSP UI

| Surface | Status | Where |
|---|---|---|
| LSPClient transport + framing | **Covered (host)** | 15 tests via `MDVFakeLSPServer` (`LSPClientFakeServerTests`) |
| LSPDiagnosticsView dump shape | **Covered (host)** | `DiagnosticDumpTests` |
| LSPPositionConverter | **Covered (host)** | ViewerCoreTests |
| Outline section model wiring | **Covered (host)** | `DocumentModelTests` |
| ProblemsPanel model wiring | **Covered (host)** | (indirect via DocumentModelTests + sidebar planner) |
| **Hover popover on mouseover symbol** | **GAP** | `LSPHoverAttachment.swift` enum exists; no test fires mouse-entered on a real NSTextView/WKWebView and asserts popover appears. |
| **Hover popover dismisses on exit / scroll** | **GAP** | Same. |
| **Cmd-click → definition jump** | **GAP** | `LSPNavigationPanel` exists; no VM scenario for the keyboard-modifier-click path. |
| **References panel population on Find References** | **GAP** | Panel rendered; no test populates it from an LSP exchange end-to-end. |
| **Workspace symbol search** | **GAP** | Panel exists; no scenario. |
| **Push-diagnostics → Problems sidebar row** | **GAP** | LSP client pushes; ProblemsPanel renders; no test ties one to the other through DocumentModel. |
| **LSP markdown rendering** (hover body) | **GAP (design open)** | Currently plain-text; HANDOFF lists as awaiting user decision. |

### Proposed tests

- **VM scenario** — `LSPHoverPopoverScenarioTests`: open a `.swift` file
  served by `MDVFakeLSPServer` (env `hoverDelayMs=200`), drive a new
  `editor-hover <line:col>` script verb, dump asserts popover visible
  with expected body. The fake server already returns deterministic
  hover for tests.
- **Host @MainActor** — `LSPProblemsPanelBindingTests`:
  push a `publishDiagnostics` notification into a real LSPClient (using
  fake server), tick the run loop, assert `DocumentModel.problemsByURL`
  matches the diagnostics. Avoid VM entirely.
- **Host @MainActor** — `LSPHoverAttachmentBuilderTests`: feed a
  `hover.contents.markdown` payload into the hover-attachment builder,
  assert the popover view body string. Locks the plain-text → future
  markdown migration boundary.

---

## 5. Code Folding (chevrons still GAP)

| Surface | Status | Where |
|---|---|---|
| FoldRegion detection per language | **Covered (host)** | `FoldRegionTests` |
| FoldLineMap (display ↔ source) | **Covered (host)** | `FoldLineMapTests` |
| FoldCommands (collapse-at-caret, expand-at-caret) | **Covered (host)** | `FoldCommandsTests` |
| FoldDisplay (display state) | **Covered (host)** | `FoldDisplayTests` |
| CM6 `setFoldingRanges` outbound | **Covered (host)** | `CMOutboundEncodingTests` |
| LSP `textDocument/foldingRange` integration | **Covered (host)** | Phase 4 tests |
| **`SourceGutterView` chevron column click → collapse** | **GAP** | `SourceGutterView.swift:69` `chevronOverlay` — `Button(action: { click(n) })` inside a SwiftUI overlay; no test instantiates the view and clicks. |
| **CM6 fold chevrons render in editor mode** | **GAP** | JS renders; no visual / DOM assertion. |
| **NSTextView storage-swap on collapse** (deferred per CLAUDE.md) | **GAP (deferred)** | Host-only constraint; design-phase. |

### Proposed tests

- **Host @MainActor** — `SourceGutterFoldChevronTests`: build
  `SourceGutterView` with a stub `foldState`, dispatch `click(n)` via
  the closure, assert callback fires with the expected line. No NSWindow
  needed (hosted view test).
- **VM scenario** — `EditorFoldGutterScenarioTests.test_clickFoldChevronCollapsesRegion`
  once `editor-click-gutter <line>` verb lands.

---

## 6. Sidebar (chain severed; visual + interaction gaps remain)

| Surface | Status | Where |
|---|---|---|
| Sidebar republish chain severance | **Covered (host)** | `SidebarRepublishInvariantTests` (7) |
| SidebarModel sort logic | **Covered (host)** | `SidebarModelTests` |
| SidebarSectionPlanner (divider planner) | **Covered (host)** | `SidebarSectionPlannerTests` (ViewerCoreTests) |
| Section header recipe | **Covered (host)** | `SidebarSectionHeaderRecipeTests` |
| Bookmarks empty state | **Covered (host)** | `BookmarksSectionEmptyTests` |
| `FileTreeRecency` tier + color | **Covered (host)** | `FileTreeRecencyTests` (ViewerCoreTests) |
| `SidebarPanelKind` + Registry | **Covered (host)** | `SidebarPanelKindTests` |
| RecentChanges discovery | **Covered (host)** | `RecentChangesDiscoveryTests` |
| Reveal-in-sidebar logic | **Covered (host)** | `SidebarRevealTests` |
| Bookmark integration | **Covered (host)** | `BookmarkIntegrationTests` |
| **Recency stripe rendered on file rows** | **GAP (visual)** | Stripe shape + accessibility id (`mdv.sidebar.fileRow.recencyStripe.<tier>`) wired in `SidebarView.swift:797`; no test asserts the id is in the view tree. |
| **Sidebar drag-resize + width persistence** | **GAP** | `DraggableSidebar` view; no test. |
| **Sort menu reorders rows** | **GAP** | Logic covered; UI dispatch not. |
| **Sidebar lock toggle visual swap** | **GAP** | Logic-only. |
| **Section disclosure (chevron click)** | **GAP** | No test instantiates SidebarView and asserts disclosure flipped. |
| **Tree right-click context menu items** (Open / New Tab / New Session / Bookmark / Split / Git Root / Folder History / Open in Terminal) | **GAP** | Wired via `.contextMenu { ... }` in `SidebarView.swift:747`. Per CLAUDE.md note: SwiftUI ViewInspector doesn't reach `.contextMenu`. Use accessibility-id assertions OR a manual smoke for the live dispatch. |

### Proposed tests

- **Host @MainActor** — `SidebarRecencyStripeAccessibilityTests`: render
  a SidebarView with a stub `FileTreeRecencyAttributes` per tier, assert
  the accessibility id (`mdv.sidebar.fileRow.recencyStripe.<tier>`) is
  present using a `View.inspect()`-style traversal already in
  `SidebarSectionHeaderRecipeTests`.
- **Host @MainActor** — `SidebarContextMenuActionTests`: model the
  context-menu **actions** as a pure list (action name → closure firing),
  assert each closure mutates DocumentModel as expected. Mirrors the
  `OpenInNewSessionTests` pattern.
- **VM scenario** — `SidebarDragResizeScenarioTests.test_dragRightEdgeResizesAndPersists`
  (defer until harness grows mouse-drag).
- **Manual smoke** — sort menu, lock toggle, disclosure visual.

---

## 7. Tab Bar

| Surface | Status | Where |
|---|---|---|
| Tab open / close / select / split (model) | **Covered (host)** | `TabCoordinatorTests` (27) |
| Session-tab persistence on switch | **Covered (host)** | `SessionTabPersistenceTests` (9) |
| Reveal-tab-in-sidebar context-menu action | **Covered (host)** | `SidebarRevealTests` |
| Tab label / dirty dot logic | **Covered (host)** | `SessionTabLabelTests`, `EditorCoordinatorInteractionTests` |
| **Close button visual + click** | **GAP** | Logic covered, click dispatch not. |
| **Horizontal scroll on overflow** | **GAP** | No scroll-indicator test. |
| **Drag-reorder tab** | **GAP** | No NSDraggingSource lifecycle test. |
| **Right-click tab → Reveal in Sidebar / Close Other** | **GAP** | Wired in `TabBar.swift:20`; no test. |

### Proposed tests

- **VM scenario** — `TabBarOverflowScenarioTests` once a `tab-bar-scroll`
  verb lands.
- **Manual smoke** — drag-reorder.

---

## 8. Walkthrough Player

| Surface | Status | Where |
|---|---|---|
| Sample script round-trip + player walk + pause-resume + jump-to-step | **Covered (host)** | `WalkthroughSampleScriptTests` (4) |
| Anchor key reduce + popover position math | **Covered (host)** | `WalkthroughAnchorKeyTests` (14) |
| Auto-advance dwell + speed scaling | **Covered (host)** | `WalkthroughAutoAdvanceTests` (9) |
| Bridge (request highlight / popover / note) | **Covered (host)** | `WalkthroughBridgeTests` (6) |
| Fixture file + schema versioning | **Covered (host)** | `WalkthroughFixtureFileTests`, `WalkthroughScriptTests` |
| **Player dock-bottom strip visible** | **GAP (visual)** | No screencap. |
| **Line-anchored popover positions correctly in editor** | **GAP** | Math covered; live placement on `NSTextView` / WKWebView not. |
| **Sidebar / gitTab / window-anchored popover positioning** | **GAP** | Math covered; live anchors not tested. |
| **Note button → Code Review modal launch** | **GAP** | No scenario for cross-modal navigation. |
| **Drop-transport env-gate** (`TV_WALKTHROUGH_DROP=1`) | **Covered (host)** | `WalkthroughDropTransportTests` (ViewerCoreTests) |

### Proposed tests

- **VM scenario** — `WalkthroughLineAnchorScenarioTests`: load a sample
  script that targets `editor:line:N`, dump asserts popover frame within
  expected px of the line baseline.
- **Manual smoke** — sidebar/gitTab/window anchors until anchor
  registration is exercised in a verb script.

---

## 9. Image / Media Preview (new GAP since 2026-05-22)

| Surface | Status | Where |
|---|---|---|
| Image render + overlay zoom controls | **GAP** | `MediaPreviewView.swift` lines 56-160; no test. |
| Keyboard zoom (↑/↓/⌘+/⌘-/1) | **GAP** | `.onKeyPress(.upArrow)` etc. wired; no test. |
| Pinch / magnification gesture | **GAP** | `MagnificationGesture` (best guess from view body); no test. |
| Cmd-scroll zoom | **GAP** | No test. |
| Fit-to-window (1:1 button + magnification = 0) | **GAP** | No test. |

### Proposed tests

- **Host @MainActor** — `MediaPreviewZoomStateTests`: build
  `MediaPreviewView`, drive `zoom(by:)` via a `@Binding` shim, assert
  magnification clamps to `0.05...16`. Stays host-safe because
  `MagnificationGesture` is SwiftUI value-level.
- **VM scenario** — `MediaPreviewKeyboardZoomScenarioTests`: needs
  key-event harness; defer.

---

## 10. Settings Window (still 0 VM tests; some host-safe wins possible)

| Surface | Status | Where |
|---|---|---|
| Settings window open / close | **GAP** | No test. |
| Zoom slider binding | **Covered (host, model only)** | `DocumentModelTests` |
| Theme picker → `themeOverride` write | **GAP** | No test. |
| Word wrap toggle → `sourceWordWrap` | **GAP** | No test. |
| Invisibles toggle | **GAP** | No test. |
| LSP Diagnostics window (in Settings) | **Covered (host)** | `DiagnosticDumpTests` (mock LSPPool) |
| Plugins pane | **GAP** | No test. |

### Proposed tests

- **Host @MainActor** — `SettingsViewBindingTests`: instantiate
  `SettingsView` with a stub `PreferencesStore`, dispatch each toggle,
  assert the corresponding `UserDefaults` key writes and DocumentModel
  republishes. No window required.
- **Manual smoke** — window lifecycle.

---

## 11. Plugins v1

| Surface | Status | Where |
|---|---|---|
| Plugin subprocess host (Tier B spawn + drain + env scrub) | **Covered (host)** | `PluginProcessTests` (ViewerCoreTests) |
| Manifest validation | **Covered (host)** | `PluginManifestTests` (ViewerCoreTests) |
| **Plugins sidebar section** (`PluginSidebarSections`) | **GAP** | No test. |
| **Settings → Plugins pane** | **GAP** | No test. |
| **Install / permission prompt** | **GAP** | NSAlert / NSOpenPanel — manual only. |
| **Audit log display + dir 0o700** | **Covered (host, perms)** | Security test pins perms; UI table not tested. |

### Proposed tests

- **Host @MainActor** — `PluginSidebarSectionRenderTests`: build
  `PluginSidebarSections` with a stub registry, assert visible rows
  match installed plugins via accessibility ids.
- **Manual smoke** — install flow + permission prompt.

---

## 12. Git Panel + Sub-tabs

| Surface | Status | Where |
|---|---|---|
| GraphLayout | **Covered (host)** | `GraphLayoutTests` |
| DiffHighlighter | **Covered (host)** | `DiffHighlighterTests` |
| GitClient status / log parsing | **Covered (host)** | `GitClientStatusTests` |
| GitStatusTab grouping | **Covered (host)** | `GitStatusTabGroupingTests` |
| DocumentModel git-panel wiring | **Covered (host)** | `DocumentModelGitPanelTests` |
| **Switching sub-tabs (Status / Log / Stash / Worktrees / Remotes)** | **GAP** | No test for tab-control dispatch. |
| **GitLogTab graph canvas rendering** | **GAP (visual)** | Model covered; no compositor test. |
| **Push / pull buttons in Remotes** | **GAP** | No test. |
| **Stash apply / drop** | **GAP** | No test. |

### Proposed tests

- **Host @MainActor** — `GitPanelTabSwitchTests`: model-level assertion
  that selecting a sub-tab updates `GitPanelModel.activeTab` and the
  child view body switches. Cheap.
- **VM scenario** — `GitLogGraphVisualScenarioTests` (visual, TCC-blocked
  on automated screencap; manual VM eyeball).

---

## 13. Right-click context menus (cross-cutting)

| Surface | Status |
|---|---|
| File tree → Open / New Tab / New Session / Bookmark / Split / Git Root / Folder History / Open in Terminal | **GAP (live dispatch)**; **Covered (host)** for `Open in New Session` closure |
| Bookmarks → Remove / Open in New Session / Reveal in Finder / Copy Path | **GAP (live dispatch)** |
| Tab bar → Reveal in Sidebar / Close Other / Close Right | **GAP (live dispatch)** |
| CM6 editor → Cut / Copy / Paste / Go to Definition | **GAP (live dispatch)** |

### Recommended approach (cross-cutting)

Model **each menu item as a named closure on a struct** so the closure
firing can be host-tested without `.contextMenu` introspection:

```swift
struct SidebarRowMenu {
    let open: (URL) -> Void
    let openInNewTab: (URL) -> Void
    let openInSplit: (URL) -> Void
    let openInNewSession: (URL) -> Void
    let bookmark: (URL) -> Void
    let revealInFinder: (URL) -> Void
    // ...
}
```

Then a `SidebarRowMenuActionTests` suite asserts each closure mutates
the model correctly. Live dispatch (does the NSMenu show? does the click
fire the closure?) stays a manual VM smoke until ViewInspector gains
`.contextMenu` support.

---

## 14. Visual Regression / Compositor

| Surface | Status |
|---|---|
| Sidebar + source view compositor (pixel sampling) | **Covered (VM, XCTSkip'd on TCC)** | `SourceViewVisualRegressionTests` |
| **Editor mode (CM6) compositor** | **GAP** | New since 2026-05-22; no visual test. |
| **Image preview compositor** | **GAP** | No visual test. |
| **Outer session tab strip visible alongside content** | **GAP** | No screencap. |

**Constraint persists:** macOS 15 Screen Capture Privacy redacts windows
launched via `sudo launchctl asuser`. Tests `XCTSkip` automatically.
Manual eyeball via UTM display window remains the fallback.

---

## 15. Keyboard shortcuts — coverage matrix

| Shortcut | Action | Status |
|---|---|---|
| ⌘T | New tab | Model **Covered (host)**; live key **GAP** |
| ⌘W | Close tab | Model **Covered (host)** |
| ⌘Q | Quit | **GAP** (app lifecycle) |
| ⌥⌘→ / ⌥⌘← | Next/prev tab | Model **Covered (host)** |
| ⌘1-9 | Jump to tab N | Model **Covered (host)** |
| ⌃Tab / ⌃1-9 | Jump to session N | Verb **Covered (VM)**; raw NSEvent **GAP** (intentional) |
| ⇧⌘W | Close session | **GAP** |
| ⌘O / ⇧⌘O | Open file / folder | **GAP** |
| ⇧⌘G | GoToPath prompt | **Covered (host)** `GoToPathUITests` + **Covered (VM)** verb |
| ⇧⌘G + ⇧↩ | GoToPath → new session | **Covered (VM)** |
| ⌃⌘S | Toggle sidebar | Model **Covered (host)** |
| ⇧⌘R | Toggle source/render | **Covered (VM)** `InteractionScriptTests` |
| ⌘F | Find (rendered) | **Covered (host)** `FindBarTests`, `RenderedFindBarTests` |
| ⌘F | Find (editor mode, CM6) | **GAP** |
| ⌘R | Reload file | **GAP** |
| ⌘+/⌘− | Zoom | **Covered (VM)** `InteractionScriptTests` |
| ⌘⌥[ / ⌘⌥] | Fold collapse / expand | Model **Covered (host)**; live key **GAP** |
| ⌘S | Save (editor mode) | **Covered (host)** `EditorCoordinatorDiskRoundtripTests` |

The **live-key-dispatch gap** is structural: `LaunchHarness` runs the
app under `Process`, no `XCUIApplication`, no `NSEvent` injection.
Until the harness grows real key support (either via `XCUIApplication`
on the VM or a low-level `CGEvent` injector), every "⌘X works" line
above remains model-only.

---

## 2026-05-22 → 2026-05-29 delta

### Newly covered

| Area | Tests landed |
|---|---|
| EditorCoordinator | `EditorCoordinatorTests` (21), `EditorCoordinatorInteractionTests` (14), `EditorCoordinatorCleanupTests` (7), `EditorCoordinatorDiskRoundtripTests` (13), `EditorRepublishInvariantTests` (13), `DocumentModelEditorForwarderTests` (20) — total 88 |
| TabCoordinator | `TabCoordinatorTests` (27), `TabCoordinatorCleanupTests` (6), `TabRepublishInvariantTests` (8), `DocumentModelTabForwarderTests` (20) — total 61 |
| FindCoordinator | `FindCoordinatorTests` (14), `FindRepublishInvariantTests` (10) |
| SidebarRepublishInvariant | `SidebarRepublishInvariantTests` (7) |
| HighlightCacheActor | `HighlightCacheActorTests` (8) |
| Sessions tab persistence | `SessionTabPersistenceTests` (9 host-MainActor) |
| GoToPath UI | `GoToPathUITests` |
| Outer Session pill flow | `SessionTabBarUITests` (5), `SessionsKeyboardUITests` (5), `OpenInNewSessionUITests` (2) |
| Walkthrough sample-script round-trip + anchor + bridge | `WalkthroughSampleScriptTests` (4), `WalkthroughAnchorKeyTests` (14), `WalkthroughBridgeTests` (6) |
| CM6 bridge v1 + v2 + bundle parity + extended decoder | `CMBridgeV1Tests`, `CMV2IntegrationTests`, `CMOutboundEncodingTests`, `CodeMirrorBundleTests`, `CodeMirrorBridgeExtendedTests` |
| LSP host-runnable transport (FakeLSPServer) | 15 `LSPClientFakeServerTests` (unblocked from env-gated smoke) |
| CM6 Phase 4 VM scenarios | `EditorPhase4ScenarioTests` (4) |
| Per-tab Highlight actor | `HighlightCacheActorTests` (8) |

### New uncovered code (introduced since 2026-05-22)

| Area | Why now |
|---|---|
| **CM6 editor NSMenu context menu** | Landed in `CodeMirrorEditorView.swift:85`; no live or DOM test. |
| **CM6 indent guides + fold chevrons + diff stripes** | Outbound encoder tested; rendering side not. |
| **CM6 push-diagnostics squiggles** | Bridge + outbound tested; DOM render not. |
| **CM6 editor find bar via ⌘F** | New since Phase 2; no key-dispatch test. |
| **Image zoom (`MediaPreviewView`)** | New surface; zero tests. |
| **Sidebar recency stripe accessibility-id rendering** | New UI surface; logic covered, view assertion missing. |
| **Sidebar light-grey card chrome + planner divider** | Logic covered (`SidebarSectionPlannerTests`); visual not. |
| **CodeMirror bundle dedup** (`@codemirror/state`) | Caught manually; no automated check that bundle is single-state. (LESSONS captures the bug shape.) |
| **JS U+2028 / U+2029 escape** | Pure-logic tests cover it; no end-to-end DOM proof a real WebView ingests sanitised source. |

### Still uncovered (no progress since 2026-05-22)

- Right-click context menu live dispatch (file tree, bookmarks, tab bar)
- Sidebar drag-resize + width persistence
- Tab-bar horizontal scroll on overflow + drag-reorder
- Walkthrough popover sidebar/gitTab/window anchors (live)
- Settings window lifecycle + zoom slider / theme picker / invisibles toggle
- Plugins sidebar + install / permission prompt + Settings pane
- LSP hover popover, definition jump, references panel, push-diagnostics → Problems tie-in
- Code-folding chevron click → collapse on Source view
- Visual compositor for editor mode / image preview / outer session strip
  (blocked on Screen Capture Privacy)

---

## Highest-priority new tests (ranked)

**Tier 1 — host @MainActor, low effort, high contract-value:**

1. **`SidebarContextMenuActionTests`** — model file-tree menu items as
   named closures, assert each fires the expected DocumentModel
   mutation. Pattern: `OpenInNewSessionTests`. Closes 80% of the
   right-click "live dispatch" gap without VM.
2. **`SourceGutterFoldChevronTests`** — assert the chevron-overlay
   button's `click(n)` closure fires with the expected line. Catches
   the collapse path without storage-swap.
3. **`MediaPreviewZoomStateTests`** — drive `zoom(by:)` and `1` reset,
   assert magnification clamping. Closes the image-zoom gap.
4. **`SettingsViewBindingTests`** — toggle invisibles / word-wrap /
   theme override against a stub PreferencesStore; assert writes.
5. **`SidebarRecencyStripeAccessibilityTests`** — assert each tier
   renders with `mdv.sidebar.fileRow.recencyStripe.<tier>` id.
6. **`LSPProblemsPanelBindingTests`** — push diagnostics via
   `MDVFakeLSPServer`, assert ProblemsPanel rows populate. Reuses the
   fake-server infra to close a known UI gap without going to VM.
7. **`LSPHoverAttachmentBuilderTests`** — pin the popover body string
   from a typed hover payload. Locks the plain-text → future markdown
   migration boundary.

**Tier 2 — VM scenario, needs new script verbs:**

8. **`EditorContextMenuScenarioTests`** — post `contextmenu` into
   WKWebView, assert dump captures menu presence (new verb
   `editor-right-click <line:col>`).
9. **`EditorFoldGutterScenarioTests`** — new verb
   `editor-click-gutter <line>`, assert region collapses.
10. **`LSPHoverPopoverScenarioTests`** — new verb
    `editor-hover <line:col>`, fake server returns deterministic hover.
11. **`WalkthroughLineAnchorScenarioTests`** — load sample script,
    assert line-anchored popover frame.

**Tier 3 — defer (harness gaps or TCC-blocked):**

12. Real `⌃Tab` / `⇧⌘W` / `⌘O` key dispatch
13. Tab drag-reorder / scroll-overflow
14. Sidebar drag-resize
15. Compositor screencap for CM6 / image preview / outer session strip
16. NSAlert / NSOpenPanel install flow for plugins

---

## Blockers (carried forward)

| Blocker | Impact | Mitigation |
|---|---|---|
| macOS 15+ Screen Capture Privacy | All compositor / visual regression tests `XCTSkip` under VM `sudo launchctl asuser` | Manual eyeball; pixel-sampling pending TCC bypass |
| `LaunchHarness` lacks real NSEvent dispatch | "live-key" tests degrade to verb-dispatch | Add `CGEvent` injector or migrate to `XCUIApplication` on VM (large lift) |
| SwiftUI `.contextMenu { ... }` not introspectable | Right-click menus only testable via closure-mocking | Refactor each menu's items into a named closure struct (see §13) |
| WKWebView DOM not directly inspectable from Swift | CM6 chevrons / squiggles / indent guides depend on bundle behaviour | Add a `cmDispatch({type:"dumpState"})` outbound that mirrors live state; assert against that |
| NSTextView storage-swap deferred | Source-view fold collapse blocked | Implement on CM6 first; NSTextView path can drop |

---

## Notes for test author

- Pattern for republish-invariant tests:
  `Tests/ViewerUITests/TabRepublishInvariantTests.swift` —
  `countDocumentRepublishes(while:)` helper. Adopt for any new coordinator
  / observation-chain change.
- Pattern for VM scenario tests: subclass `MultiScenarioTestCase`,
  override `harnessLabel`, list scenarios via `runScenarios([...])`. Each
  scenario is a script string + dump assertion. The harness auto-skips
  when `dist/TextView.app` isn't built — keeps host CI green.
- Pattern for closure-driven menu tests: see `OpenInNewSessionTests`.
- Page Object usage: `Pages(dump:).sessionTabBar.assertActiveSessionName(...)`.
  Add page objects under `Tests/ViewerUITests/PageObjects/` when new
  dump surfaces are introduced; keeps assertion sites typo-free.
- Always set `MDV_BACKGROUND=1` + `MDV_SKIP_WORKSPACE_RESTORE=1` env
  vars when launching the `.app` in tests to avoid focus theft + stale
  workspace state.
- Use `FileManager.default.temporaryDirectory` (not `~/Documents`) for
  all test scratch. Project rule.
