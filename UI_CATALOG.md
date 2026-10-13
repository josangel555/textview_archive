# UI Component Catalog

Living spec for every user-visible component in MarkdownViewer. Each
entry lists what it is, where it lives in the layout, what it should
look like, how the user interacts with it, what changes should result,
and which test(s) cover it.

The "Test" column points to tests that catch regressions in that
component. Tests live under `Tests/ViewerUITests/`:

- **L1 model:** `DocumentModelTests.swift`, `SidebarModelTests.swift`,
  `Tests/ViewerCoreTests/`, `Tests/ViewerKitTests/` — pure-logic unit tests
- **L3 hosting:** `ContentViewHostingTests.swift` —
  presence + geometry of realized NSViews
- **L3+ diagnostic:** `DiagnosticDumpTests.swift` —
  every visibility-determining property
  (color contrast, glyph generation, layer state, etc.)
- **L4 interaction:** `InteractionScriptTests.swift` — drives the real
  `.app` through scripted multi-step flows, asserts on the
  diagnostic-dump JSON written between each step

When in doubt about behavior, **the test is the spec**.

---

## Window

| Property | Expected |
| --- | --- |
| Title | Current file's basename, or "MarkdownViewer" when no tab is open |
| Style | Standard `[.titled, .closable, .miniaturizable, .resizable]` |
| Min content size | 600 × 360 pt (enforced via `window.contentMinSize`) |
| Initial size on first launch | 900 × 650 pt |
| Frame autosave | `MainWindow` — persisted via `setFrameAutosaveName` |
| Off-screen recovery | If saved frame doesn't intersect any current `NSScreen`, re-center |
| System tabbing | Disabled (`NSWindow.allowsAutomaticWindowTabbing = false`) |

Tests:
- `ContentViewHostingTests.test_openXML_hostedView_hasNonZeroOverallSize`
- `DiagnosticDumpTests.test_wholeTree_noOpacityZeroOrAncestorHidden`

---

## Top-level layout (ContentView)

```
┌─────────────────────────────────────────────────────────────┐
│  TabBar                                          [+]        │  28pt
├─────────────────────────────────────────────────────────────┤
│  ModeBar  [Rendered|Source]            /path/to/file.md     │  ~30pt
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Sidebar     │             Content (rendered / source       │
│  (optional)  │              / hex / empty / error)          │
│              │                                              │
└──────────────┴──────────────────────────────────────────────┘
```

`ContentView` is the SwiftUI root, hosted via
`NSHostingController` as the window's `contentViewController`. The
hosting controller's view installs auto-layout to track window resize.
Earlier we used a bare `NSHostingView` set on `window.contentView` and
that broke resize tracking (commit 18951b2 fixed this).

---

## TabBar

`Sources/ViewerUI/TabBar.swift`. Horizontal strip of tabs at the top.

| State | Expected |
| --- | --- |
| Empty (no tabs) | Shows only the "+" button on the right |
| One tab | Tab shows filename + × close button. Width 180pt |
| Multiple tabs | Each tab 180pt wide. Horizontally scrolls when overflowing |
| Selected tab | Light-blue background tint |

Interactions:
- **Click tab** → selects it (`model.selectTab(at:)`)
- **Click ×** → closes that tab (`model.closeTab(at:)`)
- **Click +** → opens a new empty tab (`model.newTab()`)
- **Cmd+1..9** → selects nth tab (via menu shortcut)
- **Ctrl+Tab / Cmd+Option+→** → next tab
- **Ctrl+Shift+Tab / Cmd+Option+←** → prev tab
- **Cmd+Shift+[]** → move current tab left/right
- **Cmd+W** → close current tab (or window if last tab)
- **Cmd+T** → new tab

Accessibility identifier: `mdv.tabbar`

Tests:
- `InteractionScriptTests.test_newTabAndClose_changesTabCount`
- `DiagnosticDumpTests.test_tabBar_isPresent_andHasNonZeroFrame_whenFileOpened`

---

## ModeBar

`Sources/ViewerUI/ContentView.swift` (`struct ModeBar`). Strip below
TabBar showing the rendered/source toggle and the current file path.

| State | Expected |
| --- | --- |
| Markdown file | Shows segmented control `[Rendered | Source]` + filename right-aligned |
| Non-markdown text file | No segmented control (source mode only); filename right-aligned |
| No file open | Shows "MarkdownViewer" filename label |

Interactions:
- **Click Rendered/Source** → flips `model.currentViewMode`
- **Cmd+Shift+R** → toggle (menu shortcut)

Accessibility identifier: `mdv.modebar`

Tests:
- `InteractionScriptTests.test_toggleView_swapsRenderedAndSourceViews`

---

## Sidebar (file tree)

`Sources/ViewerUI/DraggableSidebar.swift`,
`Sources/ViewerUI/SidebarView.swift`. Vertical column on the left,
shown when a folder is open and `model.sidebar.isVisible` is true.

| State | Expected |
| --- | --- |
| No folder open | Hidden entirely |
| Folder open, visible=true | Shows tree; root is the chosen folder; ".." entry walks up |
| Drag handle | Right edge — drag to resize, persists to PreferencesStore |
| Background | Solid white (matches content) — never gray; gray looks "out of focus" |
| Width | Persisted as `sidebarWidth` preference |

Interactions:
- **Click row** → opens file in new tab or selects existing tab
- **Double-click folder row** → enters that folder as root
- **Click ".."** → walks up one level
- **Cmd+Ctrl+S** → toggle visibility
- **Drag right edge** → resize width

Accessibility identifier: `mdv.sidebar`

Tests:
- `SidebarModelTests` (full unit coverage of state changes)

---

## Content area

`ContentView.content` switches on `model.currentState`:

### .empty (no file)

`EmptyStateView`. Document icon, "No file open" text, two buttons
("Open File…", "Open Folder…"), and "Or press ⌘K to search recents."

Tests:
- `DiagnosticDumpTests.test_emptyState_renders_buttonsAndNonZeroContent`

### .loaded — markdown rendered

`MarkdownRenderedView` (`MarkdownRenderedView.swift`).
WKWebView with the rendered HTML. CSP-locked, JS-disabled. Loads
`Resources/markdown.css` for styling.

Tests:
- `MarkdownRenderedViewTests`
- `DiagnosticDumpTests.test_markdownRenderedView_hasWKWebView_withNonZeroSize`
- `ContentViewHostingTests.test_openMarkdown_hostedView_containsWebView`

### .loaded — source / non-markdown text

`TextDisplayView` (`TextDisplayView.swift`) returning
`GutterScrollContainerView`. Layout:
```
┌──────┬─────────────────────┐
│ gut  │   NSTextView        │  full height
│ ter  │   (read-only,       │
│ 40pt │   horizontal scroll)│
└──────┴─────────────────────┘
```

`GutterScrollContainerView` (`GutterScrollView.swift`) lays out a custom
`LineNumberGutterView` (40pt wide) alongside the `NSScrollView`. The
old `NSRulerView` approach is **forbidden** — it triggered a macOS-14+
SwiftUI compositing pathology where the whole window's SwiftUI tree
stopped committing layer contents (see FINDINGS.md, commit 5fdac1c).

Source NSTextView config:
- TextKit 1 stack (not the `scrollableTextView()` factory)
- Not editable, selectable, read-only
- Monospaced font, sized by `model.zoom * 13pt`
- `textContainerInset` of (10, 10)
- Find bar enabled (`usesFindBar = true`)
- Horizontal scroll, never wraps long lines

Interactions:
- **Cmd+F / Cmd+G / Cmd+Shift+G** → find / next / prev
- **Cmd+A** → select all
- **Cmd+C** → copy

Tests:
- `DiagnosticDumpTests.test_sourceView_noZeroSizedViews`
- `DiagnosticDumpTests.test_sourceView_nsTextViewHasGeneratedGlyphs`
- `DiagnosticDumpTests.test_sourceView_nsTextViewContrastsWithBackground`
- `DiagnosticDumpTests.test_sourceView_gutterPresent_and_distinctFromTextScrollView`
- `DiagnosticDumpTests.test_sourceView_nsScrollViewDoesNotHaveVerticalRulerView` ← regression
- `ContentViewHostingTests.test_openXML_*` (4 tests)

### .binary (hex view)

`HexView` (`HexView.swift`). Three-column layout: offset (8-digit hex),
hex bytes (grouped), ASCII. Width-quantized to {8, 16, 24, 32, 48, 64}
bytes per row.

Tests:
- `BinaryFileLoaderTests`
- `HexView` itself doesn't yet have a dedicated diagnostic test —
  TODO add to `DiagnosticDumpTests`

### .error

`ErrorView`. Triangle icon, filename, error message, "Reload" + "Reveal
in Finder" buttons.

---

## Zoom

| Bind | Action |
| --- | --- |
| `Cmd+=` | `model.zoomIn()` — +10%, max 3.0 |
| `Cmd+-` | `model.zoomOut()` — -10%, min 0.5 |
| `Cmd+0` | `model.zoomReset()` — back to 1.0 |

Affects:
- WKWebView via `pageZoom`
- NSTextView via `13 * model.zoom` font size

Persisted as `model.zoom`.

Tests:
- `InteractionScriptTests.test_zoom_changesFontSize`

---

## Command palette (Cmd+K)

`CommandPaletteView`. Modal overlay with search-as-you-type filter
across recents and open tabs. Click any row to open.

Interactions:
- **Cmd+K** → show
- **Esc / tap dim layer** → dismiss
- **Up/Down** → navigate
- **Return** → select

Tests:
- TODO add diagnostic + interaction tests

---

## Drag & drop

`ContentView` accepts `.fileURL` drops. While dragging, shows a
rounded-rectangle accent overlay around the window edge.

Tests:
- TODO

---

## Menu bar

Built in `AppDelegate.buildMenu()`. Standard items:

- **MarkdownViewer**: About, Hide, Quit
- **File**: New Tab (Cmd+T), Open… (Cmd+O), Open Folder… (Cmd+Shift+O),
  Open Recent (autobuilt), Close Tab (Cmd+W)
- **Edit**: Copy, Select All, Find > Find… (Cmd+F), Find Next, Find Previous
- **View**: Toggle Rendered/Source (Cmd+Shift+R), Toggle Sidebar
  (Cmd+Ctrl+S), Reload (Cmd+R), Quick Open… (Cmd+K), Zoom In/Out/Reset
- **Window**: Minimize, Zoom, Bring All to Front, Next/Prev Tab,
  Move Tab Left/Right, list of open tabs
- **Help**

---

## Find bar (in source view)

NSTextView's native find bar (`usesFindBar = true`,
`isIncrementalSearchingEnabled = true`). Routed via the standard menu
items. Find bar appears just under the NSTextView when activated.

Tests:
- TODO add interaction test

---

## File watcher / change-flash

`FileWatcher` watches the currently-loaded file. On change:
- Reload contents
- Briefly flash a tint behind the content (TBD)

Tests:
- `FileWatcherTests` (pure logic)

---

## Git status

`GitService` shells out to `/usr/bin/git`. Sidebar rows show
`GitStatusBadge` (M/A/D/?/etc) when status is known.

Tests:
- `GitServiceTests`

---

## Diagnostic affordances

(Not user-facing, but documented here for completeness.)

| Mode | What it does |
| --- | --- |
| `--diagnose [--source] FILE` | Print JSON view-tree to stdout, exit 0 |
| `--auto-snapshot SECS FILE` | Wait SECS, write `/tmp/mdv-auto.{json,png}`, exit |
| `--script PATH FILE` | Run command-list script, write `/tmp/mdv-step-NN.{json,png}` between steps, exit |
| `SIGUSR1` | Write `/tmp/mdv-diagnostic-PID.{json,png}` of live state |

The JSON dump (`DiagnosticDump.swift`) is the assertable artifact —
every visibility-determining property is captured (frame, alpha,
isHidden, layer state, NSTextView color contrast + glyph counts, etc.).

PNG dump uses `CGWindowListCreateImage` against own window — no
Screen Recording permission required.
