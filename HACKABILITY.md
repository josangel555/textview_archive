# HACKABILITY.md

How to extend MarkdownViewer without rewriting it. Each entry below
names the file you touch + the shape of the change. Goal: someone
unfamiliar with the codebase can land a working extension in
under 30 minutes.

## Module layout

```
Sources/
  ViewerKit/    — types, no UI, no AppKit. Languages, prefs schema, primitives.
  ViewerCore/   — pure logic. Highlighters, formatters, file loaders, git, search.
                  Tree-Sitter engine lives here. No SwiftUI/AppKit imports except where unavoidable.
  ViewerUI/     — SwiftUI views + DocumentModel. AppKit bridging (NSTextView).
  MarkdownViewer/ — executable. Window, menu bar, AppDelegate. Glue.
```

Pure logic stays out of `ViewerUI`. View files stay out of `ViewerCore`.
When you add anything, pick the module by what it imports.

## Add a new file type to highlight

1. `Sources/ViewerKit/HighlightLanguage.swift`
   - Add an enum case (e.g. `.lua`)
   - Add the extension(s) to `detect(from url:)`
   - Add a display name in `displayName`
2. `Package.swift`
   - Add the tree-sitter grammar package as a dependency
   - Add the product to `ViewerCore`'s dependencies array
3. `Sources/ViewerCore/Highlight/Queries/`
   - Copy the upstream grammar's `highlights.scm` here as `<lang>-highlights.scm`
   - (Decision C in `PHASE_5B_TREESITTER.md` §12: we vendor queries.)
4. `Sources/ViewerCore/Highlight/TreeSitterEngine.swift`
   - Add a case to `tsLanguagePointer(for:)` returning `tree_sitter_<lang>()`
   - Add a case to `queryURL(for:)` returning the bundled .scm
5. `Sources/ViewerCore/Highlight/CaptureMap.swift`
   - Only edit this if the grammar emits capture names we don't yet map.
6. Add a golden test: `Tests/ViewerCoreTests/TreeSitterEngineGoldenTests.swift`
   - One snippet per language, assert canonical (substring, kind) pairs.

That's it. Five files, ~20 lines of code, one .scm vendored.

## Add a new view mode (e.g. JSON tree view, image preview, SQLite browser)

Today the mode-routing is a `switch` in `ContentView.loadedView(for:)`.
That's the bottleneck for everything-gets-Normal/HEX (#92), and it's
where any new mode plugs in.

1. `Sources/ViewerCore/FileTypeDetector.swift` — classify the file
2. `Sources/ViewerUI/<NewView>.swift` — the SwiftUI view itself
3. `Sources/ViewerUI/ContentView.swift` — add a branch to `loadedView`
4. `Sources/ViewerUI/ContentView.swift` (ModeBar) — show the toggle
5. `Sources/ViewerUI/DocumentModel.swift` — add `supportsXxxView` accessor
6. Tests: at least one DiagnosticDumpTest asserting the right view
   appears for the right URL

**Heads up:** if the new view embeds an AppKit subview via
`NSViewRepresentable` / `NSViewControllerRepresentable`, run
`scripts/visual-smoke.sh` and the visual regression tests after.
See LESSONS.md for the compositor pathology that's bitten us twice.

## Add a new sidebar section

Sidebars look like: [header / bookmarks / file tree / search].
Adding a new one:

1. Create `Sources/ViewerUI/<Section>View.swift` (model the
   `BookmarksSection` shape: header row + expandable body)
2. Edit `Sources/ViewerUI/SidebarView.swift` — insert your section
   between existing ones, gated on `if model.<dataSource>.isEmpty == false`
3. State on `DocumentModel` if persistence matters, else `@State`
   inside the section view

## Add a new menu command

1. `Sources/MarkdownViewer/main.swift`
   - Find the menu builder for the menu (App / File / Edit / View / Window / Help)
   - Add an `NSMenuItem(title:, action:, keyEquivalent:)`
   - Set `target = self`
2. Define the `@objc func someAction(_ sender: Any?)` selector
   on `AppDelegate`
3. Add a case to `validateMenuItem(_:)` if it should disable when
   inapplicable
4. (Optional) Add to the script-runner step dispatch in `main.swift`
   so headless tests can drive it

## Add a new file format (loader + viewer)

1. `Sources/ViewerCore/<XxxLoader>.swift` — read bytes → typed model
2. `Sources/ViewerCore/DocumentController.swift` — extend the switch
   `case .loaded(file)` → `case .xxx(yourModel)`
3. `Sources/ViewerCore/DocumentState.swift` — add the enum case
4. `Sources/ViewerUI/ContentView.swift` — route to the new viewer
5. Info.plist (`scripts/Info.plist`) — add to `CFBundleDocumentTypes`
6. Tests: file loader unit test + ContentView routing test

## Add a new theme

`Sources/ViewerCore/Highlight/SyntaxTheme.swift`:
- Add a `Name` enum case
- Add a `static let yourTheme = SyntaxTheme(...)`
- Add a case in `named(_ name:)`
- (Optional) Add detection in `resolved(forAppearance:)` if the new
  theme should auto-activate
- Theme is consumed wholesale by `TextDisplayView` and `markdown.css`
  has a separate CSS section — keep both in sync OR add a CSS
  generator (TODO)

## Add a new pretty-print formatter

`Sources/ViewerCore/Formatter.swift`:
- Add a `SupportedFormat` case
- Add to `detect(_ url:)` UTI list
- Implement `prettyPrint(_:as:)` clause
- Test: `Tests/ViewerCoreTests/FormatterTests.swift`

## Add a new test fixture file

Drop it in `Tests/<TestTarget>/Fixtures/`. The visual regression test
points at real source files in `Sources/...` — avoid that unless the
file is stable.

## Touch the source view containment

**Read LESSONS.md first.** Then:
- DON'T attach an `NSRulerView` subclass to the scroll view
- DON'T wrap the scrollView in an intermediate NSView container
- DO use `NSViewControllerRepresentable` (NOT `NSViewRepresentable`)
- DO run `scripts/visual-smoke.sh` after the change
- DO run `SourceViewVisualRegressionTests` after the change

## Plug into the Command Palette

`Sources/ViewerUI/CommandPalette.swift` (or `UnifiedFinder.swift`):
just add to the action list. Each entry is a `(title, action)` pair.

## Plug into the Quick Open / Recents palette

`Sources/ViewerUI/CommandPalette.swift` calls into
`HistoryStore.recent()` + `BookmarksStore.all()`. To inject custom
items, modify the merge in `DocumentModel.paletteEntries`.

## Where state goes

- **Ephemeral** (lost on restart) — `@State` inside views
- **Per-tab** — fields on `Tab` in `Sources/ViewerCore/TabsState.swift`
- **Per-document** — `DocumentModel`'s `@Published` properties
- **User prefs** — `PreferencesStore` (UserDefaults backed) in
  `Sources/ViewerCore/PreferencesStore.swift`
- **Workspace** (multi-tab session) — Not implemented yet (#22 + STATE.md)
- **Bookmarks / history** — JSON files in `~/Library/Application Support/MarkdownViewer/`

See `STATE.md` for the audit + the longer-term plan.

## How to add a UTI / file-association

Edit `scripts/Info.plist` under `CFBundleDocumentTypes`. Run
`scripts/install-app.sh` to re-register with LaunchServices.

## Code style conventions

- No third-party packages without a discussion (TreeSitter was the
  exception; PHASE_5B_TREESITTER.md documents the bar)
- Avoid AppKit in `ViewerCore` (mocking gets hard)
- Avoid SwiftUI in `ViewerCore` (same)
- Tests: prefer focused unit tests over E2E. Visual regression tests
  ARE necessary for view-tree-containment bugs (see LESSONS.md).

## Quick checklist before opening a PR

- [ ] `swift build` clean
- [ ] `swift test` green
- [ ] `bash scripts/visual-smoke.sh` shows TabBar / ModeBar / Sidebar /
      StatusBar all rendered if you touched source-view containment
- [ ] Updated LESSONS.md if you hit a quirk
- [ ] Updated DESIGN.md §6 (roadmap) if you closed a phase

## Things that intentionally aren't pluggable yet

We have ideas for a plugin system (`PLUGINS.md`). Until it lands,
extending the app means forking + writing Swift. That's the pragmatic
shape for now — see PLUGINS.md for what we'd want and what we're
deliberately deferring.

---

## Where features live (the file map)

When something visibly broken needs fixing, this is which file to open.
Organized by *plane* of the app rather than alphabetically.

| Plane | Owner files |
|---|---|
| Document lifecycle | `ViewerUI/DocumentModel.swift`, `ViewerCore/DocumentState.swift`, `ViewerCore/DocumentController.swift` |
| Tabs / workspace | `ViewerCore/TabsState.swift`, `ViewerUI/TabBarView.swift` |
| Sidebar | `ViewerUI/SidebarView.swift`, `ViewerUI/SidebarModel.swift`, `ViewerUI/DraggableSidebar.swift` |
| Source view (text/code) | `ViewerUI/TextDisplayView.swift`, `ViewerCore/Highlight/*` |
| Rendered Markdown | `ViewerUI/MarkdownRenderedView.swift`, `Resources/markdown.css`, `Resources/markdown.js` |
| HEX view | `ViewerUI/HexView.swift`, `ViewerCore/HexFormatter.swift` |
| CSV / TSV table | `ViewerUI/CSVTableView.swift`, `ViewerCore/CSVParser.swift` |
| SQLite browser | `ViewerUI/SQLiteBrowserView.swift`, `ViewerUI/ResultTableView.swift`, `ViewerCore/SQLite/*` |
| Media (image/audio/video/PDF) | `ViewerUI/MediaPreviewView.swift` |
| Split view | `ViewerUI/SplitPaneView.swift` (right pane router) |
| Search (find in document) | `TextDisplayView.findRanges`, `MarkdownRenderedView` (`window.__mdvFind*` JS bridge) |
| Command palette / quick open | `ViewerUI/CommandPaletteView.swift`, `ViewerUI/UnifiedFinder.swift` |
| Git integration | `ViewerCore/Git/*`, `DocumentModel.showGitLog(forPath:scope:)`, `SidebarModel.refreshGitStatus` |
| Status / chrome | `ViewerUI/StatusBarView.swift`, `ViewerUI/ModeBarView.swift` |
| Menu bar / keyboard shortcuts | `MarkdownViewer/main.swift` (`AppDelegate` + selectors) |
| App icon | `Resources/Assets.xcassets/AppIcon.appiconset/`, `scripts/pack-icns.swift` |
| Build & packaging | `scripts/build-app.sh`, `scripts/check-bundle-size.sh`, `scripts/install-app.sh`, `scripts/Info.plist` |
| Tests (visual) | `scripts/visual-smoke.sh`, `Tests/ViewerUITests/SourceViewVisualRegressionTests.swift` |

## DocumentModel `@Published` surface inventory

`DocumentModel` carries 41 `@Published` properties across ~970 lines.
That's why it's flagged as a SRP-split candidate in BACKLOG.md (`Architectural tech debt`).
The clusters:

- **Document content**: `currentURL`, `currentText`, `currentData`, `currentImage`, `loadState`, `loadError`
- **View mode**: `currentViewMode`, `defaultModeOverrides` (per-extension), `supportsRendered`, `supportsHex`, `supportsTable`
- **Highlight pipeline**: `highlightRuns`, `highlightLanguage`, `themeName`
- **Find state**: `findQuery`, `findMatches`, `currentMatchIndex`, `lastScrolledMatchIndex`, `findIsActive`, `findOptions`
- **Split**: `splitURL` (right pane), `splitIsOpen` (derived)
- **Tabs**: `tabsState` (a value-type owned object, not @Published directly — observed via Combine on changes)
- **Sidebar**: not on DocumentModel — owned by `SidebarModel`
- **Workspace restore**: `restoredFromWorkspace`, `pendingRestoreURL`

When you add a new piece of state, before reaching for `@Published`:

1. Can it be **derived** from existing state? (e.g. `splitIsOpen` is `splitURL != nil`)
2. Is it really **per-document**, or per-tab, or per-app? (Per-tab → `Tab`; per-app → `PreferencesStore`)
3. Will it fire on every keystroke? (If yes, debounce or move to local `@State` in the view.)

The 60Hz sidebar-resize jank fix is the warning here: `@Published` setters
are value-blind (writing the same value re-fires), and downstream
`.onChange` handlers can cascade. See LESSONS.md.

## The request-nonce pattern

SwiftUI ↔ NSViewRepresentable commands (scroll-to-match, focus-find,
trigger-find-from-menu) flow through a `@Published` *nonce* + payload,
not direct method calls — because `NSViewRepresentable` only sees
`updateNSView`, not your custom selectors.

Shape:

```swift
// On the model:
@Published var scrollToMatchRequest: (nonce: Int, range: NSRange)? = nil

func requestScrollTo(_ r: NSRange) {
    scrollToMatchRequest = (nonce: (scrollToMatchRequest?.nonce ?? 0) + 1, range: r)
}

// In NSViewRepresentable.updateNSView:
if let req = model.scrollToMatchRequest,
   req.nonce != coordinator.lastHandledNonce {
    coordinator.lastHandledNonce = req.nonce
    nsView.scrollRangeToVisible(req.range)
}
```

The nonce is the transport; it carries "this is a new request" past
SwiftUI's diff-the-value optimization. Without it, identical payloads
silently no-op.

Use it for: commands (action signals), not state (the value itself).
A typed enum payload + nonce is fine. Don't pattern-match the value to
decide if it's "new" — that's what the nonce is for.

## Module boundaries (hard rules)

```
┌──────────────────────────────────────────────────┐
│ MarkdownViewer (exe)                             │
│   AppDelegate, menu bar, window, NSApp lifecycle │
└─────────────┬────────────────────────────────────┘
              ↓ imports
┌──────────────────────────────────────────────────┐
│ ViewerUI                                         │
│   SwiftUI views, NSViewRepresentable, DocumentModel
└─────────────┬────────────────────────────────────┘
              ↓ imports
┌──────────────────────────────────────────────────┐
│ ViewerCore                                       │
│   Logic: highlight, format, load, search, git    │
│   NO SwiftUI. NO AppKit (with rare exceptions).  │
└─────────────┬────────────────────────────────────┘
              ↓ imports
┌──────────────────────────────────────────────────┐
│ ViewerKit                                        │
│   Types only: enums, structs, prefs schema.      │
│   No logic. No I/O. No AppKit. No SwiftUI.       │
└──────────────────────────────────────────────────┘
```

Why this is load-bearing:

- `ViewerKit` can be imported anywhere — including from tests, scripts,
  and headless tooling. Keeping it logic-free means importing it never
  drags in NSApp init or main-actor isolation.
- `ViewerCore` is testable without a running app. The TreeSitter actor,
  diff highlighter, CSV parser, git wrappers all unit-test on CI without
  a WindowServer.
- `ViewerUI` is where SwiftUI lives. The instant you `import SwiftUI`
  in `ViewerCore`, the test target needs main-actor wiring and stops
  running in parallel. Don't.
- `MarkdownViewer` is the glue. Everything app-level (AppDelegate,
  selectors, `@main`) lives here. No business logic — it should be
  almost entirely menu construction + selector forwarding.

If you're tempted to add `import SwiftUI` to `ViewerCore`, the answer
is almost always: move the type to `ViewerKit` instead, or expose it
via a value-typed boundary that `ViewerUI` consumes.
