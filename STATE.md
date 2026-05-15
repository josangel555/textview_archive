# STATE.md — state management audit + plan

Where state lives in MarkdownViewer today, what's persisted vs
ephemeral, and a proposed unification. The bigger fix is the
workspace/session-restore feature (Task #22).

## Current state surfaces

### 1. `DocumentModel` — `@Published` properties, in-memory only

`Sources/ViewerUI/DocumentModel.swift`. Roughly 30 published fields.
Categories:

- **Window state**: `windowTitle`, `sidebarWidth`, `zoom`, `themeOverride`,
  `sourceWordWrap`
- **Tabs**: `tabs` (TabsState — array of Tab structs with state)
- **Find bars**: `isRenderedFindBarPresented`, `renderedFindQuery`,
  `renderedFindCaseSensitive`, `renderedFindNextRequest`,
  `renderedFindPrevRequest`, `renderedFindMatched`, `renderedFindFocusRequest`,
  + the source-mode equivalents (`sourceFind*`)
- **Palette / cross-search**: `isPalettePresented`, `isCrossSearchPresented`,
  `crossSearchQuery`, `crossSearchResults`, `crossSearchIsRunning`,
  `crossSearchCaseSensitive`
- **Caches**: `highlightCache`, `renderedHTMLCache`
- **Scroll telemetry**: `sourceScrollState`
- **Computed derived**: `recents`, `bookmarks` (synced from stores)

When the app quits, ALL of this is lost.

### 2. `PreferencesStore` — UserDefaults

`Sources/ViewerCore/PreferencesStore.swift`. Persisted across launches:

- `sidebarWidth: Double`
- `sidebarVisible: Bool`
- `zoom: Double`
- `lastFolderURL: URL?`
- `sourceWordWrap: Bool`

That's it. Fewer than 10 keys. Persistence is just UserDefaults
(`com.markdownviewer.MarkdownViewer.plist`).

### 3. `BookmarksStore` — JSON file

`Sources/ViewerCore/BookmarksStore.swift`. JSON-encoded array of
`BookmarkEntry { url, addedAt, displayName }`. File path:
`~/Library/Application Support/MarkdownViewer/bookmarks.json`.

### 4. `HistoryStore` — JSON file

`Sources/ViewerCore/HistoryStore.swift`. Recent files + folders. JSON
at `~/Library/Application Support/MarkdownViewer/history.json`.

### 5. `SidebarModel` — derived + ephemeral

`Sources/ViewerUI/SidebarModel.swift`. Holds `rootURL`, `expanded`,
`selectedURL`. None persisted (only `rootURL` indirectly via
`preferences.lastFolderURL`).

### 6. Per-tab state — `Tab` struct

Each Tab has `url`, `state` (loaded/binary/error/empty), `viewMode`,
`id`. Plus `DocumentModel.formattedTabIDs: Set<UUID>` tracks
pretty-print toggle per-tab. None persisted.

### 7. View-local `@State`

Sprinkled across views. Examples:
- `ContentView.isDropTargeted`
- `TabBarItem.isHovering`
- `BookmarksSection.isExpanded`

By design ephemeral. Mostly fine.

## What's broken or limiting today

1. **Tabs vanish on quit.** Restart → empty tab bar. Annoying.
2. **Find query lost on quit.** Reasonable, but maybe not — losing a
   long search is mildly painful.
3. **Sidebar expanded/collapsed state lost.** Restart → all folders collapsed.
4. **Theme override is `@Published` but not persisted.** User picks
   dark in a session, restart, back to system-resolved. Bug-ish.
5. **No "workspace" concept.** Can't save a set of tabs + sidebar
   root + window position under a name and switch between projects.
6. **State changes don't auto-save during session.** Crash → lose
   everything. Crash recovery would need periodic snapshots.
7. **Cross-window state.** If we ever support multiple windows
   (split-view, second window from menu), there's no shared model
   pattern.

## Proposed unification

### Principle: one model, multiple persistence tiers

Every piece of state lives on `DocumentModel` (or a child
ObservableObject it owns). Each piece tags its tier explicitly:

```swift
enum PersistenceTier {
    case ephemeral       // never written to disk
    case session         // workspace JSON, restored on launch
    case userPreference  // UserDefaults
    case shared          // cross-machine sync candidate (iCloud later)
}
```

Then a `StateSnapshot` aggregator walks the model on a debounced
schedule and writes:
- Workspace JSON → `~/Library/Application Support/MarkdownViewer/Workspaces/<name>.json`
- UserDefaults → unchanged (Apple handles writes)
- Shared (iCloud) → deferred

### Session restore at launch

1. On launch, check for the most-recent workspace in
   `~/.../Workspaces/_last.json` (auto-saved on quit)
2. If found and the user opted in (default ON), restore: tabs +
   selectedIndex + sidebar root + sidebar expansion + window frame
3. Skip restore if the tab list includes files that no longer exist
   (just drop them with a notice)

### Multiple workspaces

`File → Workspaces → New / Save / Switch`. Each named workspace
captures a snapshot. Switching workspaces saves current → swaps in
target. Use case: project A vs project B with different sidebar roots
and tab sets.

### Auto-save debouncing

Workspace JSON written 500ms after the last mutation (cross-property
debounce). Crash recovery comes nearly for free.

### Migration

Existing UserDefaults keys stay. We ADD the workspace JSON layer
alongside. No breaking change. Bookmarks + history JSON files stay
where they are.

## API shape (sketch)

```swift
public struct WorkspaceSnapshot: Codable, Sendable {
    let version: Int       // schema version; bump on breaking change
    let savedAt: Date
    let windowFrame: NSRect?
    let sidebarRoot: URL?
    let sidebarExpanded: [URL]
    let tabs: [TabSnapshot]
    let selectedTabIndex: Int?
    let zoom: Double
    let viewMode: ViewMode
    let wordWrap: Bool
    let themeOverride: SyntaxTheme.Name?
    // …
}

public final class WorkspaceStore {
    public func snapshot(from model: DocumentModel) -> WorkspaceSnapshot
    public func restore(_ snap: WorkspaceSnapshot, to model: DocumentModel)
    public func save(_ name: String, _ snap: WorkspaceSnapshot) throws
    public func load(_ name: String) throws -> WorkspaceSnapshot
    public func list() -> [String]
    public func delete(_ name: String) throws
}
```

Integration in `DocumentModel`:
- Owns a `WorkspaceStore` instance
- `init` checks for `_last.json` and restores if present
- `applicationWillTerminate` writes `_last.json` (already
  partially wired in `AppDelegate.applicationWillTerminate`)
- During session, mutations to "session-tier" fields trigger a
  500ms debounced write

## Open questions

1. **Versioning** — what happens when a new MDV version adds fields?
   Workspaces should be forward-compatible (extra fields ignored on
   older versions) and backward-compatible (missing fields filled
   with defaults). The schema version field is the lever.
2. **Bookmarks vs workspaces** — bookmarks are global, workspaces are
   per-project. Keep both. The collision is "bookmarks open via a
   different workspace" — probably switch to the bookmark's
   workspace if it's tagged with one, else just open the file.
3. **What's session-tier vs user-preference?** Some things (theme,
   zoom) feel global; others (tabs) feel per-workspace. Proposed:
   - **Workspace** (per-project): tabs, sidebar root, sidebar expansion, window frame
   - **User preference**: zoom default, theme override, word-wrap default
   - When you open a workspace, it inherits user prefs unless the
     workspace overrides them.
4. **Cross-machine sync** — iCloud Documents container is the most
   straightforward path. Defer until workspaces are stable in v1.

## Implementation order (proposed)

1. **WorkspaceSnapshot type + WorkspaceStore + auto-save `_last.json`** —
   This alone restores tabs on relaunch. Most user-visible win.
2. **Named workspaces UI** — File menu entries for save/switch.
3. **Schema versioning + migration** — once we have real users.
4. **iCloud sync** — distant future.
5. **Crash recovery banner** — "MarkdownViewer crashed; restore your
   workspace?" — if `_last.json` exists but no clean shutdown marker.

## Testing strategy

- Snapshot roundtrip: model → snapshot → JSON → snapshot → model →
  equal-state assertion
- Migration: load old-version JSON, confirm new model fields default
  correctly
- Crash recovery: write `_last.json`, launch fresh model, confirm
  state matches

## Anti-goals

- CoreData. Way too heavy for this scale.
- A reactive store framework (Redux/TCA). The `@Published` pattern
  on `DocumentModel` is sufficient.
- Network sync as a first-class feature. iCloud Documents is the
  ceiling for any cross-device story.
