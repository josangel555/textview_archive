# SESSIONS_DESIGN.md — sessions (tabs-within-tabs) for TextView

> Status: design-only, not yet implemented. Phase 1 is land-able from
> this document alone; phase 2 builds on phase 1.

A **session** is "a project the user has open". Each session owns its
own sidebar tree, file tabs, bookmarks-in-context, git panel state,
find state, and per-tab view modes. Multiple sessions coexist in a
single window as an **outer tab strip** above the existing file tab
bar — *tabs within tabs*. Switching the outer tab swaps the entire
inner UI (sidebar contents, file tabs, status bar, panels) as if the
user re-launched the app on a different project.

The reference mock (`/Users/me/Downloads/TextView (3)/details/sessions-tabs.html`)
nails the visual: a 34-px strip across the top of the window, one
"workspace tab" per session, with a 2-letter glyph, project name,
branch, dirty / ahead / behind counts, and a live-watcher dot. Below
it sits the existing 30-px file tab bar, scoped to whichever session
is active. The implementation here is faithful to that visual.

---

## 0. Terminology

| Term            | Meaning                                                                                  |
| --------------- | ---------------------------------------------------------------------------------------- |
| **Session**     | A directory the user has opened, plus all the per-project state attached to it.          |
| **Outer tab**   | The strip that switches sessions. One outer tab = one session.                           |
| **Inner tab**   | The existing per-file tab strip. One inner tab = one open file (or diff / sqlite / etc). |
| **Active session** | The one currently mounted into the window. Exactly one at a time.                     |
| **Detached session** | A session that exists in the registry but isn't mounted. File watchers paused.      |
| **Workspace JSON** | Existing on-disk schema (`WorkspaceSnapshot`). Re-used as the per-session payload.    |

A session is **identified** by a stable UUID generated at create time,
*not* by its directory path. Reason: a user can rename / move a project
folder out from under us; the session ID survives. The path is stored
inside the session record and resolved lazily.

---

## 1. What a session contains

Exhaustive inventory. Anything that today is "global per-window" in
`DocumentModel` needs a verdict — does it belong to the session, or
does it stay app-global? See §10 for open decisions on the gray cases.

### 1.1 Session-scoped (moves out of singleton `DocumentModel`)

- **Identity**
  - `id: UUID` — stable across renames, restarts.
  - `rootURL: URL` — the directory the session represents.
  - `displayName: String` — defaults to `rootURL.lastPathComponent`,
    user-editable.
  - `createdAt: Date`, `lastActiveAt: Date` — for LRU ordering of the
    outer strip and for the recent-sessions list.

- **Sidebar tree state** (currently `SidebarModel`)
  - `expanded: Set<URL>`
  - `selectedURL: URL?`
  - `includeHidden: Bool`
  - `isVisible: Bool`
  - `gitRootOverride: URL?`
  - The file-listing cache (`children(of:)` results) — re-buildable, so
    cleared on detach.

- **Open file tabs** (currently `DocumentModel.tabs: TabsState`)
  - The full `[Tab]` array, with each tab's `url`, `state`, `viewMode`,
    `id`.
  - `selectedTabIndex`.
  - `formattedTabIDs: Set<UUID>` (per-tab pretty-print toggle).
  - Pinned-tab flags (future — phase 3, mirrors the mock).

- **Bookmarks scoped to this session's root**
  - The global `BookmarksStore` stays global. But the UI presentation
    of bookmarks is *filtered to the active session's root* in the
    sidebar's bookmarks section. Bookmarks pointing outside the
    session's root are dimmed or hidden behind "Show all". Decision:
    keep one global store (cross-project bookmarks remain useful),
    but introduce a `BookmarksView` that knows the active session and
    filters. Net effect: no schema change to `bookmarks.json`.

- **Recents** — keep `HistoryStore` global. But the sidebar's
  "Recent Files" section filters to entries under `rootURL`, matching
  the bookmark treatment.

- **Find state** (the cluster of `*Find*` fields)
  - `isRenderedFindBarPresented`, `renderedFindQuery`,
    `renderedFindCaseSensitive`, `renderedFindMatched`,
    `renderedFindMatchSummary`, the request-nonces
    (`renderedFindNextRequest`, `…PrevRequest`, `…FocusRequest`).
  - Same set for source mode (`sourceFind*`).
  - Cross-search panel state: `isCrossSearchPresented`,
    `crossSearchQuery`, `crossSearchResults`, `crossSearchIsRunning`,
    `crossSearchCaseSensitive`, `crossSearchGeneration`.

- **Git panel state**
  - `gitPanelFocusRequest` nonce, `gitPanelDesiredTab`.
  - Per-session collapsed/expanded section flags (future).
  - The discovered `repoRoot` (cached; not authoritative).
  - `sourceDiffMarks` for the currently focused file is session-scoped
    only insofar as it depends on the session's git root — but the
    cache lives next to the focused tab, which is session-scoped.

- **Split view** — `splitURL`. Per-session.

- **Scroll telemetry** — `sourceScrollState`, `sourceSelection`,
  `sourceScrollLineTarget`, `sourceScrollLineNonce`. These describe
  the currently focused file *inside* the session, so session-scoped.

- **File watcher binding** — `fileWatcher`, `watchedURL`. The watcher
  for the active file. Paused/torn down when session is detached.

- **Caches** — `highlightCache`, `renderedHTMLCache`. These are keyed
  by URL+length so a single global cache would still be correct, but
  practically the working set is the active session's files. Keeping
  them per-session caps memory growth (close a session = drop its
  caches) and avoids cross-session contention. Decision:
  **session-scoped**.

### 1.2 Session-aware persisted state (existing JSON files, untouched)

- `bookmarks.json` — stays global. Each `BookmarkEntry` already carries
  its `url`, which implicitly belongs to one project. UI filters by
  active session root.
- `history.json` — stays global. Same logic.
- `_last.json` — replaced by `Sessions/<id>.json` files (see §5).

### 1.3 App-global (stays in a singleton, not session-scoped)

These don't differ between projects — duplicating them per-session
would be user-hostile (toggle dark mode, only the active session
gets it).

- `PreferencesStore` (UserDefaults) — zoom default, ui scale,
  word-wrap default, show-invisibles, theme override, sidebar
  visibility default, sidebar width default.
- Command palette state (`isPalettePresented`) — modal, transient,
  global.
- Settings window state.
- The recent-folders list (drives `File → Open Recent`) — same as
  `history.json`, global.

### 1.4 Decisions on ambiguous fields

| Field                            | Verdict      | Why                                                                                                         |
| -------------------------------- | ------------ | ----------------------------------------------------------------------------------------------------------- |
| `zoom`                           | **global**   | Reading is a comfort setting, not a project property. User who zooms in expects every project zoomed.       |
| `themeOverride`                  | **global**   | Same reasoning — appearance is the user, not the project.                                                   |
| `sourceWordWrap`                 | **global**   | Per-user editing convention, not per-project.                                                               |
| `showInvisibleChars`             | **global**   | Same.                                                                                                       |
| `uiScale`                        | **global**   | Display-density setting.                                                                                    |
| `sidebarWidth`                   | **global**   | Disagree-able — but mirroring Finder / VS Code, this is a window chrome preference, not project-scoped.     |
| `splitURL`                       | **session**  | Project-shaped.                                                                                             |
| `gitRootOverride`                | **session**  | Tied to the sidebar root.                                                                                   |
| `defaultModeOverrides`           | **global**   | Already persisted to prefs; cross-project "always open `.csv` as table".                                    |

Future preferences view can promote any of these to **per-session
override** with the same pattern Workspace JSON uses today
(workspace value wins if present, fall back to global).

---

## 2. Session lifecycle

### 2.1 Create

A new session is created by any of:

- **`File → Open Folder…`** (existing menu) — current behavior. Today
  this calls `model.openFolder(url)` on the singleton, which clobbers
  the sidebar root. After: routes through `SessionsCoordinator.openFolder(url)`,
  which either reveals an existing session for that path or creates a
  new one.
- **Dropping a folder onto the window** — same code path.
- **`File → Open Folder in New Session…`** (new menu item) — forces
  a new session even if the path matches an existing one. Useful with
  git worktrees that resolve to the same path under symlinks.
- **`Session → New`** (new menu) — opens the folder picker; creates a
  new session on confirm.
- **Outer "+" button** in the session strip — same as
  `Session → New`.
- **Opening a file** with no session yet — auto-creates a session
  rooted at the file's containing directory, matching today's
  behavior.

**Duplicate-path policy**: opening a directory that's already a live
session brings that session forward instead of creating a duplicate.
Worktrees that point to the same path through different symlink
chains count as distinct — we key on `URL.resolvingSymlinksInPath()`.
This matches the mock's "Two sessions, same directory — forbidden"
note.

### 2.2 Switch

Switching to session `B` while session `A` is active:

1. Snapshot `A`'s mutable state into its in-memory `Session` record
   (cheap; just pointer-equal swaps for `[Tab]`, `Set<URL>`, etc).
2. Detach `A`: stop its `FileWatcher`, cancel its in-flight
   `diffMarksTask` and `crossSearchGeneration`, drop its
   `highlightInFlight` set. Caches stay (warm-on-return).
3. Set `A.lastActiveAt = now`.
4. Mark `B` as the active session.
5. Mount `B`: start a `FileWatcher` for `B`'s currently selected tab
   URL, kick off the diff marks task.
6. Trigger `objectWillChange.send()` on whatever the views observe so
   `ContentView` re-evaluates with `B`'s data.

Animation: **0 ms** intentionally (per the mock). Snap-in feels right
when the user is the cause of the switch.

Performance budget: total switch should complete within one frame
(< 16 ms) for any session with < 50 open tabs. Cache warmth is the
only thing that takes longer than that, and it's lazy anyway.

### 2.3 Close

Closing a session:

- **`Session → Close`** menu, **outer-tab-context-menu → Close**, or
  middle-click on the outer tab.
- Default behavior: persist the session's snapshot one last time, then
  remove it from the in-memory list. The `Sessions/<id>.json` file
  stays on disk for the next 30 days so undo is trivial.
- If the closed session was the active one, switch to the most recent
  other session (by `lastActiveAt`). If it was the *last* session, the
  window shows the empty state ("Open a folder to start a session").
- No "save changes" prompt is needed — TextView is a viewer, sessions
  don't carry dirty buffers. (When scratch tabs land, this needs to be
  revisited.)

### 2.4 Restore

At launch:

1. Read `Sessions/index.json` (see §5). If absent, fall back to legacy
   `_last.json` (§8).
2. Materialize every session listed there as a detached `Session`
   record. Do **not** start watchers, do **not** load file contents,
   do **not** populate tabs' state beyond reading the snapshot.
3. Activate the session marked `lastActive` in the index. That
   activation runs §2.2's mount step, which is what triggers actual
   tab content loading (`controller.open(url:)`).
4. Reveal the window. Per-session tabs that point at now-missing files
   render as `.error` (same path as today — `controller.open(url:)`
   already produces an error state for missing files).

Result: relaunch puts the user back exactly where they left off, with
the same set of sessions, the same active one, the same tabs in each.

---

## 3. Data model

This is the meat of the design. Two options were considered.

### 3.1 Option A — `SessionsCoordinator` owns `N × DocumentModel`

```
                  ┌───────────────────────┐
                  │ SessionsCoordinator   │
                  │  - sessions: [Session]│
                  │  - activeID: UUID     │
                  └─────────┬─────────────┘
                            │ 1..N
                            ▼
                   ┌─────────────────┐
                   │ Session         │
                   │  - id           │
                   │  - rootURL      │
                   │  - displayName  │
                   │  - model: …Model│ ◀── one per session
                   └─────────────────┘
```

`Session` owns the per-project Combine-publishing model. The
coordinator publishes `activeID` and the views observe whichever
model the coordinator points at.

**Pros**: Cleanest separation. Each session is fully self-contained,
trivially testable in isolation. Detach = stop watchers; the model
keeps its `@Published` state untouched until next mount. Mirrors how
VS Code, Xcode, etc. structure their "workspace = independent state
tree" model.

**Cons**: Requires splitting today's 1145-line `DocumentModel`. Some
of it is genuinely session-scoped (tabs, find, git), but some is
genuinely app-global (zoom, theme). The split is mechanical but
touches every callsite that does `model.zoom = …` or
`model.toggleViewMode()`.

### 3.2 Option B — singleton `DocumentModel` with `currentSessionID`

`DocumentModel` keeps its identity. Internally, every session-scoped
field becomes `[SessionID: T]`. Switching session is just changing
`currentSessionID` and re-publishing.

**Pros**: Minimal refactor in views. `model.tabs` still works (returns
the active session's tabs).

**Cons**: The model gets *worse*: every accessor needs a switch on
`currentSessionID`, every mutation needs the same. `[UUID: TabsState]`,
`[UUID: SidebarModel]`, `[UUID: Set<URL>]`… SRP is destroyed; the
class is now a glorified `[UUID: ProjectState]` dictionary in a coat.
Tests become harder because every scenario needs a session ID prefix.

### 3.3 Recommendation: **Option A** with a staged refactor

Reasons:

1. `DocumentModel` already needs an SRP split — 1145 lines / 41
   `@Published` is a smell, and the find-bar cluster, the git panel
   cluster, the tabs cluster, and the cross-search cluster are
   already conceptually separate.
2. Per-session models map directly to the mental model in the mock
   ("each session is its own little app").
3. Option B makes the model dictionary-of-everything-keyed-by-session,
   which is the worst of both worlds — neither a clean session
   abstraction nor a clean single-model abstraction.

The staged refactor:

**Stage R1**: extract pure types and stores that are already
session-scoped today.

- `SidebarModel` stays as-is (already an `ObservableObject`).
- `TabsState`, `Tab` stay as value types in `ViewerCore`.
- `Find` cluster → new `FindModel` `ObservableObject` (owns the
  rendered-find and source-find fields and their nonces).
- `CrossSearchModel` → new `ObservableObject`.
- `GitPanelModel` → new `ObservableObject` (nonces + desired tab +
  per-section flags).

**Stage R2**: introduce `SessionState`.

```swift
@MainActor
public final class SessionState: ObservableObject {
    public let id: UUID
    @Published public var rootURL: URL
    @Published public var displayName: String
    public let createdAt: Date
    @Published public var lastActiveAt: Date

    // Per-session children. Each is an ObservableObject; SessionState
    // forwards their objectWillChange so a single observer of
    // SessionState reacts to nested mutations.
    public let sidebar: SidebarModel
    public let tabs: TabsModel          // wraps TabsState + formatted IDs
    public let find: FindModel
    public let crossSearch: CrossSearchModel
    public let git: GitPanelModel
    public let split: SplitViewModel

    // File-watch lifecycle. Active only when this session is mounted.
    fileprivate var fileWatcher: FileWatcher?
    fileprivate var watchedURL: URL?
    fileprivate var diffMarksTask: Task<Void, Never>?

    // Caches scoped to this session (see §1.1).
    @Published public private(set) var highlightCache: [DocumentModel.HighlightCacheKey: [HighlightRun]] = [:]
    var renderedHTMLCache: [DocumentModel.RenderedHTMLKey: String] = [:]

    public init(id: UUID = UUID(), rootURL: URL, displayName: String? = nil) {
        self.id = id
        self.rootURL = rootURL
        self.displayName = displayName ?? rootURL.lastPathComponent
        let now = Date()
        self.createdAt = now
        self.lastActiveAt = now
        self.sidebar = SidebarModel()
        self.tabs = TabsModel()
        self.find = FindModel()
        self.crossSearch = CrossSearchModel()
        self.git = GitPanelModel()
        self.split = SplitViewModel()
        self.sidebar.setRoot(rootURL)
        wireForwarding()
    }

    private var cancellables: Set<AnyCancellable> = []
    private func wireForwarding() {
        for child in [sidebar.objectWillChange,
                      tabs.objectWillChange,
                      find.objectWillChange,
                      crossSearch.objectWillChange,
                      git.objectWillChange,
                      split.objectWillChange] {
            child.sink { [weak self] _ in self?.objectWillChange.send() }
                 .store(in: &cancellables)
        }
    }

    public func mount() { /* attach file watcher, kick diff marks */ }
    public func detach() { /* stop watcher, cancel tasks */ }
}
```

**Stage R3**: introduce `SessionsCoordinator`.

```swift
@MainActor
public final class SessionsCoordinator: ObservableObject {
    @Published public private(set) var sessions: [SessionState] = []
    @Published public private(set) var activeID: UUID?

    private let store: SessionStore
    private let preferences: PreferencesStore
    private let history: HistoryStore
    private let bookmarks: BookmarksStore

    public var active: SessionState? {
        guard let id = activeID else { return nil }
        return sessions.first { $0.id == id }
    }

    public init(store: SessionStore = SessionStore(),
                preferences: PreferencesStore = PreferencesStore(),
                history: HistoryStore = HistoryStore(storeURL: HistoryStore.defaultStoreURL()),
                bookmarks: BookmarksStore = BookmarksStore(storeURL: BookmarksStore.defaultStoreURL())) {
        self.store = store
        self.preferences = preferences
        self.history = history
        self.bookmarks = bookmarks
    }

    // Lifecycle ---------------------------------------------------------

    public func restoreOrBootstrap() {
        let index = store.loadIndex() ?? SessionIndex(version: 1, sessions: [], lastActiveID: nil)
        for entry in index.sessions {
            guard let snap = store.load(id: entry.id) else { continue }
            let session = makeSession(from: snap)
            sessions.append(session)
        }
        if let lastID = index.lastActiveID, sessions.contains(where: { $0.id == lastID }) {
            activate(id: lastID)
        } else if let first = sessions.first {
            activate(id: first.id)
        }
    }

    @discardableResult
    public func openFolder(_ url: URL, forceNew: Bool = false) -> SessionState {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if !forceNew, let existing = sessions.first(where: { $0.rootURL == resolved }) {
            activate(id: existing.id)
            return existing
        }
        let s = SessionState(rootURL: resolved)
        sessions.append(s)
        persistIndex()
        activate(id: s.id)
        return s
    }

    public func activate(id: UUID) {
        guard activeID != id else { return }
        if let prev = active { prev.detach(); prev.lastActiveAt = Date() }
        activeID = id
        active?.mount()
        persistIndex()
    }

    public func close(id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let s = sessions[idx]
        store.save(snapshot(of: s))   // last-known-state on disk
        s.detach()
        sessions.remove(at: idx)
        if activeID == id {
            activeID = sessions.sorted(by: { $0.lastActiveAt > $1.lastActiveAt }).first?.id
            active?.mount()
        }
        persistIndex()
    }

    public func nextSession() {
        guard let id = activeID,
              let idx = sessions.firstIndex(where: { $0.id == id }),
              !sessions.isEmpty else { return }
        let next = sessions[(idx + 1) % sessions.count].id
        activate(id: next)
    }
    public func previousSession() { /* mirror */ }
    public func activate(index n: Int) {
        guard sessions.indices.contains(n) else { return }
        activate(id: sessions[n].id)
    }

    // Persistence -------------------------------------------------------

    private func persistIndex() {
        let entries = sessions.map { s in
            SessionIndex.Entry(id: s.id,
                               rootPath: s.rootURL.path,
                               displayName: s.displayName,
                               lastActiveAt: s.lastActiveAt)
        }
        let idx = SessionIndex(version: 1, sessions: entries, lastActiveID: activeID)
        store.saveIndex(idx)
        for s in sessions { store.save(snapshot(of: s)) }
    }

    private func snapshot(of s: SessionState) -> SessionSnapshot { /* see §5 */ fatalError() }
    private func makeSession(from snap: SessionSnapshot) -> SessionState { /* see §5 */ fatalError() }
}
```

### 3.4 What's left of `DocumentModel`?

After R1–R3, `DocumentModel` becomes thin. Two viable end-states:

**Option α**: rename `DocumentModel` → `AppModel`, and it owns
*global* state only — `PreferencesStore` mirror, the `SessionsCoordinator`,
the `BookmarksStore` and `HistoryStore` (still global), the
`isPalettePresented` flag. ~150 lines.

**Option β**: drop the class entirely. Views observe
`SessionsCoordinator` and `PreferencesStore` directly via environment
objects.

Recommendation: **α**. The bridging methods (`openPath`, `openInNewTab`)
naturally hang off an `AppModel` that knows about both the
coordinator and the global stores. β leaks coordinator-knowledge into
every view that today says `@ObservedObject var model: DocumentModel`.

### 3.5 The migration trick — keep `DocumentModel` as a façade

Phase 1 (§4, §11) does **not** require completing R1–R3. The phase-1
trick: introduce `SessionsCoordinator` with a single session whose
`SessionState` is just a thin wrapper around the *existing*
`DocumentModel`. The outer tab strip shows one tab. Behavior is
identical to today.

Phase 2 then begins the R1–R3 split, one cluster at a time, with the
coordinator already in place. Each cluster extracted from
`DocumentModel` becomes session-scoped without touching the rest.

This is what makes the refactor incremental.

---

## 4. UI design

Tabs within tabs. The user said it, the mock confirms it.

### 4.1 Layout

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ ●●● MarkdownViewer / TextView                                                │  ← titlebar (system)
├──────────────────────────────────────────────────────────────────────────────┤
│ ┌──────────────┐ ┌──────────┐ ┌─────────────┐ ┌─────┐                      + │  ← outer tabs (34 px)
│ │ TV  textview │ │ MO mono… │ │ SQ sqlite-… │ │NO no│                        │
│ │  feat/hex *7 │ │  main ↓2 │ │  wip/wal-r… │ │tes  │                        │
│ └──────╤═══════┘ └──────────┘ └─────────────┘ └─────┘                        │
│        │ active                                                              │
├────────┴─────────────────────────────────────────────────────────────────────┤
│ ┌──────────┐┌────────┐┌───────────┐┌──────────┐                              │  ← inner tabs (30 px)
│ │ README.md││ DOCS.md││ Sources/M…││ +        │                              │     (existing TabBar)
│ └──────────┘└────────┘└───────────┘└──────────┘                              │
├────────────────────────┬─────────────────────────────────────────────────────┤
│ Sidebar                │ Document body                                       │
│ ├ Bookmarks            │                                                     │
│ ├ Recent               │   # README                                          │
│ ├ Files                │                                                     │
│ │  └ Sources/          │   Lorem ipsum…                                      │
│ │     └ ViewerUI/      │                                                     │
│ └ Git                  │                                                     │
│   └ status (4)         │                                                     │
│   └ log                │                                                     │
└────────────────────────┴─────────────────────────────────────────────────────┘
│ Ln 12, Col 4   UTF-8   Swift   ●  feat/hex-editor   *7  ↑3                   │  ← status bar
└──────────────────────────────────────────────────────────────────────────────┘
```

**Outer tab anatomy** (from the mock):

```
 ┌────────────────────────────────────────────────┐
 │ TV  textview    feat/hex-editor    *7 ↑3   ●   │
 │ │   │          │                  │      │     │
 │ │   │          │                  │      └ live-watcher dot (green = active, grey = paused)
 │ │   │          │                  └ dirty/ahead/behind (mono, color-coded)
 │ │   │          └ current branch (mono, italic, ellipsis after 14 chars)
 │ │   └ project display name (semibold)
 │ └ 2-letter glyph (first two letters of root.lastPathComponent, uppercased)
 │
 │ Top-edge 2 px accent strip when active.
 └────────────────────────────────────────────────┘
```

### 4.2 Where the strip lives

Two viable spots:

1. **Inside the window's content view**, just above the existing
   `TabBar`. This is what the mock shows. Pure SwiftUI. Easy to
   theme. Phase 1 picks this.

2. **In the title bar** (Safari-style tabs). Uses
   `NSWindow.titlebarAppearsTransparent = true` and a custom
   `NSTitlebarAccessoryViewController`. More polished but more
   AppKit-fiddly. Defer to phase 3.

Phase 1: in-content strip. Phase 3: optional title-bar version
behind a setting.

### 4.3 Inactive / active / detached states

The mock lists six states. Phase 1 ships **active** + **inactive**.
The rest are progressively wired:

| State           | Phase | Indicator                                                 |
| --------------- | ----- | --------------------------------------------------------- |
| active          | 1     | Accent top stripe + tinted glyph + brighter text          |
| inactive        | 1     | Dim text, no accent                                       |
| running task    | 4     | Spinner replaces live dot (when long task attached)       |
| conflict        | 4     | Warn border, "MERGING — N conflicts" replaces branch+stat |
| detached HEAD   | 3     | Short SHA in branch slot, hover tooltip warns             |
| stale watcher   | 3     | "⚠ watcher" in branch slot, click to reattach             |

### 4.4 Drag, reorder, drop

- **Reorder**: within the strip, AppKit drag → swap indices in
  `sessions`. Phase 2.
- **Drag folder onto strip**: opens as a new session. Phase 1
  (trivial: the strip is just a SwiftUI `HStack` with a drop
  delegate).
- **Drag a file tab from inner strip onto an outer tab**: moves the
  file tab to that session. Phase 3 (cross-session tab move).
- **Tear off**: drag an outer tab out of the window → new window
  with just that session. Phase 4 (multi-window).

### 4.5 The "+" button

Right-most cell of the outer strip. Click → folder picker (same as
`Session → New`). Long-press / right-click → submenu listing the last
16 recent folders for quick re-open (mock spec).

### 4.6 Empty state

When zero sessions exist:

```
┌──────────────────────────────────────────────────────────────────┐
│                                                              +   │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│                  TextView                                        │
│                                                                  │
│        Open a folder to start a session                          │
│                                                                  │
│        [ Open Folder…    ⌘⇧O ]                                   │
│                                                                  │
│        Recent:                                                   │
│          • ~/Documents/workspaces/textview                       │
│          • ~/Documents/workspaces/markdown_viewer                │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### 4.7 SwiftUI sketch

```swift
public struct WindowRoot: View {
    @ObservedObject var coordinator: SessionsCoordinator
    @ObservedObject var app: AppModel  // global state

    public var body: some View {
        VStack(spacing: 0) {
            SessionStrip(coordinator: coordinator)
                .frame(height: 34)
                .background(Color(NSColor.windowBackgroundColor))
            Divider()
            if let active = coordinator.active {
                SessionRoot(session: active, app: app)
                    .id(active.id)  // forces a clean re-mount on switch
            } else {
                EmptySessionView(coordinator: coordinator)
            }
        }
    }
}

struct SessionStrip: View {
    @ObservedObject var coordinator: SessionsCoordinator

    var body: some View {
        HStack(spacing: 0) {
            ForEach(coordinator.sessions, id: \.id) { s in
                SessionTab(session: s,
                           isActive: coordinator.activeID == s.id,
                           onActivate: { coordinator.activate(id: s.id) },
                           onClose: { coordinator.close(id: s.id) })
                Divider()
            }
            AddSessionButton(coordinator: coordinator)
            Spacer()
        }
    }
}

struct SessionTab: View {
    @ObservedObject var session: SessionState
    let isActive: Bool
    let onActivate: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            GlyphView(name: session.displayName, accent: isActive)
            Text(session.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
            if let branch = session.git.branchName {
                BranchView(branch: branch, accent: isActive)
            }
            DirtyAheadBehindView(stats: session.git.statusSummary)
            LiveDotView(isActive: session.fileWatcherIsLive)
        }
        .padding(.horizontal, 12)
        .overlay(alignment: .top) {
            if isActive {
                Color.accentColor.frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .contextMenu {
            Button("Close Session", action: onClose)
            Button("Rename…") { /* phase 2 */ }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([session.rootURL])
            }
        }
    }
}

struct SessionRoot: View {
    @ObservedObject var session: SessionState
    @ObservedObject var app: AppModel

    var body: some View {
        // This is roughly today's ContentView body but parameterized on
        // `session` instead of pulling everything from `model`.
        ContentView(session: session, app: app)
    }
}
```

`SessionRoot` is intentionally just a re-parameterized `ContentView`.
Phase 1's diff against today is mostly: every place `ContentView`
reads `model.tabs` becomes `session.tabs`; every place it reads
`model.zoom` becomes `app.zoom`. Mechanical.

The `.id(active.id)` modifier is the key SwiftUI trick: when the
active session changes, SwiftUI tears down the entire subtree and
rebuilds. That's exactly the snap-in semantic we want and it sidesteps
any chance of stale state leaking between sessions through view
identity.

---

## 5. Persistence

### 5.1 Layout on disk

```
~/Library/Application Support/MarkdownViewer/
├── bookmarks.json                  ← unchanged, global
├── history.json                    ← unchanged, global
├── Workspaces/
│   └── _last.json                  ← legacy; read once for migration
└── Sessions/
    ├── index.json                  ← list of sessions, last-active ID
    ├── <uuid-1>.json               ← per-session snapshot
    ├── <uuid-2>.json
    └── trash/
        └── <uuid-3>.json           ← closed within last 30 days
```

### 5.2 Index format

```swift
public struct SessionIndex: Codable, Sendable {
    public let version: Int   // 1
    public let sessions: [Entry]
    public let lastActiveID: UUID?

    public struct Entry: Codable, Sendable {
        public let id: UUID
        public let rootPath: String
        public let displayName: String
        public let lastActiveAt: Date
    }
}
```

Keeping the index separate from per-session files means:
- Activating a session at launch only requires reading
  `index.json` + the active session's `<uuid>.json`. Other sessions
  load lazily on first activation.
- Renaming / closing / reordering doesn't rewrite every snapshot.

### 5.3 Per-session snapshot

`SessionSnapshot` extends today's `WorkspaceSnapshot` with the
session-identity fields. The existing JSON shape stays compatible —
we add optional fields, old `WorkspaceSnapshot` files load as v1
sessions with a fresh UUID.

```swift
public struct SessionSnapshot: Codable, Sendable {
    public static let currentSchema = 2
    public let schemaVersion: Int
    public let savedAt: Date

    // Identity (new in v2; absent in v1 = legacy WorkspaceSnapshot)
    public let id: UUID?
    public let displayName: String?
    public let createdAt: Date?
    public let lastActiveAt: Date?

    // Same as WorkspaceSnapshot v1:
    public let sidebarRootPath: String?
    public let openTabs: [TabSnapshot]
    public let selectedTabIndex: Int?
    public let zoom: Double?           // kept for backward-compat read; not written in v2
    public let wordWrap: Bool?         // ditto
    public let themeOverride: String?  // ditto

    // New session-scoped fields:
    public let sidebarExpandedPaths: [String]?
    public let sidebarIncludeHidden: Bool?
    public let gitPanelDesiredTab: String?
    public let splitURL: String?
    public let findQueries: SavedFindState?

    public struct SavedFindState: Codable, Sendable {
        public let renderedQuery: String?
        public let renderedCaseSensitive: Bool?
        public let sourceQuery: String?
        public let sourceCaseSensitive: Bool?
        public let sourceIsRegex: Bool?
    }
}
```

**Backward-compatibility rule**: when reading a snapshot with
`schemaVersion == 1` (the existing `WorkspaceSnapshot`), the loader
fills in defaults (`id = UUID()`, `displayName = root.lastPathComponent`,
`createdAt = savedAt`, etc).

### 5.4 Auto-save cadence

- Every state mutation on a `SessionState` triggers a **500 ms
  debounced** write of its own snapshot file. Same cadence STATE.md
  proposes for workspaces.
- The index file is written on session-list mutations (create / close /
  reorder / activate-change). Activations write `lastActiveID`
  immediately (no debounce) — these are user-initiated, infrequent,
  and a crash within the 500 ms window would otherwise lose the
  active-session pointer.
- On `applicationWillTerminate`: synchronous flush of the active
  session + index.

### 5.5 Reusing `JSONFileStore`

The existing `JSONFileStore.write(_:to:)` / `JSONFileStore.read(_:from:)`
handle atomic writes. `SessionStore` is just a wrapper:

```swift
public final class SessionStore: Sendable {
    public let directory: URL

    public static func defaultDirectory() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)) ??
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("MarkdownViewer/Sessions")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("trash"),
            withIntermediateDirectories: true)
        return dir
    }

    public init(directory: URL = SessionStore.defaultDirectory()) {
        self.directory = directory
    }

    public func loadIndex() -> SessionIndex? {
        JSONFileStore.read(SessionIndex.self,
                           from: directory.appendingPathComponent("index.json"))
    }

    public func saveIndex(_ idx: SessionIndex) {
        JSONFileStore.write(idx, to: directory.appendingPathComponent("index.json"))
    }

    public func load(id: UUID) -> SessionSnapshot? {
        JSONFileStore.read(SessionSnapshot.self, from: fileURL(for: id))
    }

    public func save(_ snap: SessionSnapshot) {
        guard let id = snap.id else { return }  // v1 legacy reads only
        JSONFileStore.write(snap, to: fileURL(for: id))
    }

    public func moveToTrash(id: UUID) {
        let src = fileURL(for: id)
        let dst = directory.appendingPathComponent("trash")
            .appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.moveItem(at: src, to: dst)
    }

    public func emptyTrashOlderThan(_ days: Int) { /* … */ }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
```

### 5.6 Trash + recovery

Closed sessions move to `Sessions/trash/<uuid>.json` and stay for 30
days. `Session → Reopen Closed` (⌘⇧T at session scope) restores the
most recent. After 30 days, `emptyTrashOlderThan(30)` deletes them on
next launch.

---

## 6. Concurrent state

Exactly one session is **mounted** at a time. Others are **detached**.

### 6.1 What "mounted" means

A mounted session has:

- A live `FileWatcher` on its currently-focused tab's URL.
- Eligible to launch `diffMarksTask` for the current tab.
- Eligible to populate `highlightInFlight` / `highlightCache` via
  TreeSitter tasks.
- Eligible to run cross-search.
- Owns the SwiftUI view subtree.

A detached session has none of those active. Its in-memory
`@Published` state stays intact (so reactivation is instant), but no
background work is happening on its behalf.

### 6.2 State transition: detach

```
mount-state of A   detach()         mount-state of A
─────────────────  ──────────────►  ──────────────────
fileWatcher ≠ nil   stop()           fileWatcher == nil
watchedURL  ≠ nil   nil              watchedURL  == nil
diffMarksTask       cancel()         nil
crossSearch         gen +=1          generation invalidates pending
highlightInFlight   (left as-is;     same — Tasks check
                     Tasks check
                     mount + cancel)
caches              kept             kept
@Published fields   unchanged        unchanged
```

```swift
extension SessionState {
    public func detach() {
        fileWatcher?.stop()
        fileWatcher = nil
        watchedURL = nil
        diffMarksTask?.cancel()
        diffMarksTask = nil
        crossSearch.invalidateInflight()
        // caches stay warm; objectWillChange not fired —
        // the coordinator drives the view swap.
    }
}
```

### 6.3 State transition: mount

```swift
extension SessionState {
    public func mount() {
        attachFileWatcher()
        refreshDiffMarks()
        git.refreshStatusSummary()   // updates branch / ahead / behind for the strip
    }
}
```

### 6.4 In-flight Task discipline

Already true today in `DocumentModel`: every background `Task.detached`
re-checks the model's identity (e.g. `self.currentURL == token`)
before publishing. With sessions, the check has to include
*identity-of-session* too. A simple pattern:

```swift
diffMarksTask = Task.detached { [weak self, sessionID = self.id] in
    // …
    await MainActor.run { [weak self] in
        guard let self,
              self.id == sessionID,        // not yet swapped out from under us
              self.isMounted,              // and still mounted
              self.tabs.currentURL == token
        else { return }
        self.sourceDiffMarks = marks
    }
}
```

`isMounted` is a derived bool: `coordinator.activeID == self.id`.

### 6.5 Cross-session background work

A few things might legitimately run for detached sessions:

- **Git status polling for the outer strip** (branch name, dirty
  count, ahead / behind, watcher live-dot). The strip wants this for
  *every* session, not just the active one. Run on a 10-second
  background poll per session, cheap shell-out to `git status -sb`.
  Cancel on session close. Throttle aggressively if any session is
  on a network mount (mock notes 5 s polling fallback for SSHFS).

- **FS-watcher for cross-strip "dirty file" badges**. Phase 4. Until
  then the periodic git poll is sufficient.

- **Activity-monitor "all sessions" mode** (mock §Behaviors). Defer.

---

## 7. Menus & keyboard shortcuts

### 7.1 Existing shortcut audit

| Combo             | Today's binding                       | Future binding                                            |
| ----------------- | ------------------------------------- | --------------------------------------------------------- |
| `⌘1`…`⌘9`         | Select **inner** file tab N           | **unchanged** — still selects file tab                    |
| `⌘O`              | Open File…                            | unchanged                                                 |
| `⌘⇧O`             | Open Folder…                          | **Open Folder in New Session…** (creates a new session)   |
| `⌃⇥` / `⌃⇧⇥`      | (unbound)                             | **Next / Previous session**                               |
| `⌃1`…`⌃9`         | (unbound)                             | **Jump to session N**                                     |
| `⌘W`              | Close tab                             | unchanged (file-tab; **never** closes a session)          |
| `⌘⇧W`             | (unbound)                             | **Close Session**                                         |
| `⌘N`              | (unbound; new tab is `⌘T`)            | **New Session** (`File → Open Folder for New Session…`)   |
| `⌘⇧T`             | (planned: reopen-closed-tab)          | scope-sensitive: reopen-tab if active session, else reopen-session |
| `⌘⌥→` / `⌘⌥←`     | (unbound)                             | (from mock) Next / Previous tab                           |
| `⌘\`              | (unbound)                             | (from mock) Split editor right                            |

Rationale for `⌃Tab` over `⌥⌘1`: the user's draft says "⌥⌘1 / ⌥⌘2",
but the mock's `⌃⇥` / `⌃1…9` is more consistent with macOS conventions
(Safari uses `⌘⌥→` to switch tabs, `⌃⇥` to switch tabs in some apps;
VS Code uses `⌃⇥` to switch editors). `⌃1…9` doesn't collide with
anything in the current bindings and leaves `⌘1…9` for the inner
file tabs, which the user already trained their fingers on.

If the user insists on `⌥⌘N`-style: the binding live in one place
(the `Session` menu builder) and can be re-keyed cheaply.

### 7.2 New "Session" menu

Insert between `File` and `Edit`:

```
Session
├── New Session…                 ⌘⇧O      → coordinator.openFolder via picker (forceNew = true)
├── Open Folder…                 ⌘O … ?   → existing semantics; reveals existing session if path matches
├── ────────
├── Next Session                 ⌃⇥
├── Previous Session             ⌃⇧⇥
├── Jump to Session    ►
│   ├── 1. textview              ⌃1
│   ├── 2. monorepo              ⌃2
│   ├── 3. sqlite-tools          ⌃3
│   └── …
├── ────────
├── Rename Session…
├── Reveal in Finder
├── ────────
├── Close Session                ⌘⇧W
└── Reopen Closed Session        ⌘⇧⌃T      → recovers from trash/
```

Implementation note: the "Jump to Session" submenu is rebuilt on
demand (`NSMenuDelegate.menuNeedsUpdate`) so it reflects current
session order — same pattern the existing `Window` menu uses to list
file tabs.

### 7.3 `⌘1…9` scoping clarification

`⌘1`…`⌘9` stays bound to "select inner tab N of the active session".
The selector (`selectTabByNumber(_:)`) targets the active session's
`SessionState.tabs` instead of the singleton `model.tabs`. Phase 1
wires this; mechanical change.

---

## 8. Migration

Zero data loss. Two surfaces to migrate:

### 8.1 `Workspaces/_last.json` → first session

On launch, if `Sessions/index.json` does **not** exist:

1. Read `Workspaces/_last.json` (existing `WorkspaceSnapshot`).
2. If found, build a fresh `SessionState` from it: new UUID,
   `displayName = sidebarRootPath?.lastPathComponent ?? "Untitled"`,
   tabs / sidebar / etc copied across.
3. Write that as the first entry in a new `Sessions/index.json` and
   `Sessions/<new-uuid>.json`.
4. Leave `_last.json` in place. (`Workspaces/` becomes vestigial but
   harmless; a follow-up cleanup PR can delete it after a release
   cycle.)

If neither exists, the launch path falls back to today's
"restorePreviousFolderIfAvailable" reading `preferences.lastFolderURL`,
and that becomes the first session.

### 8.2 In-place fields

- `bookmarks.json` and `history.json` are untouched — they already
  store URLs, and the session-aware sidebar UI is purely a *view*
  filter over them.
- `PreferencesStore` keys are untouched — they remain global (§1.3).

### 8.3 Reverse compatibility

If a user downgrades to a pre-sessions build, the worst case is:
- The new build's `Sessions/` directory is ignored.
- The old build keeps reading `Workspaces/_last.json` (which we never
  deleted), so the user sees "the last state I was in before
  upgrading". Stale, but no crash, no data loss.

We can also write a bridge `Workspaces/_last.json` from the active
session's snapshot at quit time, for the first release-cycle, so a
downgrade keeps the active session's tabs.

---

## 9. Test strategy

### 9.1 Pure-model tests (no SwiftUI, no AppKit)

**`SessionsCoordinatorTests`**

- `test_openFolder_createsSession_whenNoMatch`
- `test_openFolder_revealsExistingSession_whenPathMatches`
- `test_openFolder_forceNew_alwaysCreatesNewSession`
- `test_activate_swapsActiveID_andCallsMountDetach`
- `test_close_removesSession_andActivatesMostRecent`
- `test_close_lastSession_clearsActiveID`
- `test_nextSession_wrapsAtEnd`
- `test_restore_loadsSessionsFromIndex`
- `test_restore_missingIndex_fallsBackToLegacyWorkspaceJSON`
- `test_restore_brokenSnapshotFile_skipsThatSessionLogsError`

Test doubles: `SessionStore` is initted with a temp directory; no
filesystem mocking needed beyond a `tempDir` helper. `FileWatcher`,
`GitClient`, `DocumentController` get test-doubles or are simply not
exercised in coordinator tests (mount() is observable as side effects,
and we can assert via spy hooks).

**`SessionStateTests`**

- `test_init_seedsSidebarRoot`
- `test_mount_attachesWatcher`
- `test_detach_stopsWatcher_andCancelsInflightTasks`
- `test_objectWillChange_firesForNestedMutations` (sidebar, tabs, find)

**`SessionSnapshotTests`**

- Roundtrip: `session → snapshot → JSON → snapshot → session`,
  assert tab list, selected index, sidebar root, sidebar expanded set,
  find queries.
- Forward-compat: snapshot with v1 schema (no UUID) decodes into
  `SessionSnapshot` with synthesized ID.
- Backward-compat: future v3 fields are dropped gracefully when
  encoded as v2.

### 9.2 Persistence tests

- Write index + 3 session files, re-open, verify same sessions /
  active ID.
- Delete the active-session file out from under the index → restore
  should fall back to next session by `lastActiveAt`.
- Truncated JSON file → graceful skip + log; index unchanged.
- Trash retention: write a file dated 31 days ago into
  `Sessions/trash/`, call `emptyTrashOlderThan(30)`, verify removal.

### 9.3 Mount lifecycle tests

A `SpyFileWatcher` that records `start()` / `stop()` calls feeds
through to assertions:

- Switching A → B calls `A.fileWatcher.stop()` and starts a new
  watcher for B's current tab.
- Closing B (mounted) re-activates the most recent other session,
  which starts its watcher.
- All in-flight Tasks check session-ID + mount-state; a test that
  swaps the active session mid-Task asserts the late callback is a
  no-op (no published mutation).

### 9.4 UI-level smoke (XCUI / scripts/visual-smoke.sh)

Phase 1 ships a minimal screenshot diff:
- Launch app with two sessions in the index.
- Capture screenshot; assert the strip shows both glyphs.
- Click outer tab 2; capture; assert sidebar contents differ from
  outer tab 1's.

### 9.5 Anti-regressions for the rest of the app

The R1–R3 refactor needs the existing test suite to stay green.
Specifically:
- `TabsStateTests` — unchanged.
- `BookmarksStoreTests` — unchanged.
- `WorkspaceSnapshotTests` (existing) — repurposed to test
  `SessionSnapshot.decode(legacyWorkspaceJSON)` path.
- Anything that constructs `DocumentModel()` keeps working through
  the façade pattern in §3.5.

---

## 10. Open decisions

Captured for the implementer (or a follow-up design pass). Defaults
chosen are listed; they are reversible.

### 10.1 What's session-scoped vs app-global, the gray cases

Already addressed in §1.4. The defaults are listed there. Anything
in that "global" column that the user later wants per-project becomes
a `SessionOverride<T>` field — present = use it, nil = inherit
global.

### 10.2 Outer tab visual height

Phase 1 picks **34 px** matching the mock. Reconsider after dogfooding
— may want **30 px** to match the inner tab bar exactly, but the
distinction is what makes the hierarchy readable.

### 10.3 Maximum sessions

No hard cap. The mock says "first 6 visible" with horizontal scroll
after. Phase 1: render all in a scrollable HStack; assume nobody
opens > 24 sessions in practice. Add a soft warning at 32.

### 10.4 Strip orientation

Could be vertical along the left edge ("Workspace switcher" rail like
Slack). Defer. The mock is horizontal, the user request says "tabs
within tabs" implying horizontal.

### 10.5 Two-finger swipe between sessions

`NSEvent.scrollWheel` with `phase == .began && hasPreciseScrollingDeltas`
on the outer strip could cycle sessions. Defer to phase 3.

### 10.6 Should the **same file** appear in two sessions' tabs?

Yes. Each session has its own `Tab` instances. The underlying
`controller.open(url:)` call is idempotent for a clean read, so there's
no state corruption. The two tabs each have their own scroll position,
find state, view mode. Matches Xcode / VS Code behavior.

### 10.7 Cross-session pinned tabs (mock: "Pin to all sessions")

Punt. Mock-spec'd, useful for a `CLAUDE.md` or daily-notes file.
Implementation: a small `[URL]` in `AppModel.crossSessionPinnedTabs`
that every `SessionState.tabs` auto-prepends. Phase 4.

### 10.8 What happens when the session's root directory disappears?

The mock doesn't address this. Proposal:

- On mount, check `FileManager.fileExists(atPath: rootURL.path)`. If
  false, the session enters a **broken** state: outer tab shows a
  warning glyph, sidebar shows "Root directory not found — relocate /
  remove session". Tabs that point at still-existing files (e.g. a
  user navigated to an absolute path outside the original root)
  remain usable.
- Provide `Session → Relocate…` to pick a new root.

---

## 11. Implementation plan — phase 1 (land-able from this doc)

Goal: introduce the outer tab strip with a single session that wraps
today's `DocumentModel`. No multi-session yet. Zero behavior change
for the user except a new ribbon at the top of the window showing
"TV  textview" (or whatever the open folder's name is).

### 11.1 New files

```
Sources/ViewerCore/Session/SessionIdentity.swift   ← UUID + name + dates
Sources/ViewerCore/Session/SessionSnapshot.swift   ← Codable, replaces WorkspaceSnapshot
Sources/ViewerCore/Session/SessionStore.swift      ← JSONFileStore wrapper
Sources/ViewerCore/Session/SessionIndex.swift      ← index.json type
Sources/ViewerUI/Sessions/SessionsCoordinator.swift
Sources/ViewerUI/Sessions/SessionState.swift       ← phase-1: façade over DocumentModel
Sources/ViewerUI/Sessions/SessionStripView.swift
Sources/ViewerUI/Sessions/SessionTabView.swift
Sources/ViewerUI/Sessions/AddSessionButton.swift
Sources/ViewerUI/Sessions/EmptySessionView.swift
Tests/ViewerCoreTests/Session/SessionSnapshotTests.swift
Tests/ViewerCoreTests/Session/SessionStoreTests.swift
Tests/ViewerUITests/Sessions/SessionsCoordinatorTests.swift
```

### 11.2 Phase-1 `SessionState` (façade variant)

In phase 1, a `SessionState` *wraps* the singleton `DocumentModel`
rather than splitting it. This is the trick that makes phase 1
small.

```swift
@MainActor
public final class SessionState: ObservableObject {
    public let id: UUID
    @Published public var rootURL: URL
    @Published public var displayName: String
    public let createdAt: Date
    @Published public var lastActiveAt: Date

    // Phase 1: one DocumentModel per session.
    // Phase 2: replace this with extracted child models.
    public let model: DocumentModel

    public init(id: UUID = UUID(),
                rootURL: URL,
                displayName: String? = nil,
                model: DocumentModel = DocumentModel()) {
        self.id = id
        self.rootURL = rootURL
        self.displayName = displayName ?? rootURL.lastPathComponent
        let now = Date()
        self.createdAt = now
        self.lastActiveAt = now
        self.model = model
        self.model.openFolder(rootURL)
        wireForwarding()
    }

    private var cancellables: Set<AnyCancellable> = []
    private func wireForwarding() {
        model.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    public func detach() {
        // Phase 1: stop the file watcher via a new DocumentModel hook.
        model.pauseFileWatcher()
    }

    public func mount() {
        model.resumeFileWatcher()
    }
}
```

Two tiny additions to today's `DocumentModel`:

```swift
extension DocumentModel {
    public func pauseFileWatcher() {
        fileWatcher?.stop()
        fileWatcher = nil
        watchedURL = nil
    }
    public func resumeFileWatcher() { startWatchingCurrentFile() }
}
```

That's the entire DocumentModel touch for phase 1.

### 11.3 Phase-1 `SessionsCoordinator`

Single-session variant lives next to the more-general version
sketched in §3.3, but the only methods that actually do something
useful in phase 1 are:

```swift
@MainActor
public final class SessionsCoordinator: ObservableObject {
    @Published public private(set) var sessions: [SessionState] = []
    @Published public private(set) var activeID: UUID?

    private let store: SessionStore

    public var active: SessionState? {
        sessions.first { $0.id == activeID }
    }

    public init(store: SessionStore = SessionStore()) {
        self.store = store
    }

    public func bootstrap(initialRoot: URL?) {
        // Phase-1: migrate or create exactly one session.
        if let idx = store.loadIndex(), let entry = idx.sessions.first {
            let snap = store.load(id: entry.id)
            let model = DocumentModel()
            // Use existing restore code path:
            model.restoreWorkspaceAutoSlot()
            let session = SessionState(id: entry.id,
                                       rootURL: URL(fileURLWithPath: entry.rootPath),
                                       displayName: entry.displayName,
                                       model: model)
            sessions = [session]
            activeID = session.id
            return
        }
        // Migration from Workspaces/_last.json:
        let model = DocumentModel()
        if let root = initialRoot {
            let session = SessionState(rootURL: root, model: model)
            sessions = [session]
            activeID = session.id
            persistIndex()
            return
        }
        // No prior state. Empty.
    }

    public func openFolder(_ url: URL, forceNew: Bool = false) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        if !forceNew, let s = sessions.first(where: { $0.rootURL == resolved }) {
            activate(id: s.id)
            return
        }
        // Phase-1: replace the (single) session. Phase-2 adds N sessions.
        let model = DocumentModel()
        let s = SessionState(rootURL: resolved, model: model)
        sessions = [s]
        activeID = s.id
        persistIndex()
    }

    public func activate(id: UUID) {
        guard activeID != id else { return }
        active?.detach()
        active?.lastActiveAt = Date()
        activeID = id
        active?.mount()
        persistIndex()
    }

    public func close(id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let s = sessions[idx]
        store.moveToTrash(id: s.id)
        s.detach()
        sessions.remove(at: idx)
        activeID = sessions.first?.id
        persistIndex()
    }

    private func persistIndex() {
        let entries = sessions.map {
            SessionIndex.Entry(id: $0.id,
                               rootPath: $0.rootURL.path,
                               displayName: $0.displayName,
                               lastActiveAt: $0.lastActiveAt)
        }
        store.saveIndex(SessionIndex(version: 1,
                                     sessions: entries,
                                     lastActiveID: activeID))
        // Per-session snapshots reuse today's WorkspaceSnapshot writes
        // via DocumentModel.saveWorkspaceAutoSlot() for phase 1.
        for s in sessions {
            s.model.saveWorkspaceAutoSlot()
        }
    }
}
```

### 11.4 Phase-1 `SessionStripView`

```swift
struct SessionStripView: View {
    @ObservedObject var coordinator: SessionsCoordinator

    var body: some View {
        HStack(spacing: 0) {
            ForEach(coordinator.sessions, id: \.id) { session in
                SessionTabView(
                    session: session,
                    isActive: coordinator.activeID == session.id,
                    onActivate: { coordinator.activate(id: session.id) },
                    onClose: { coordinator.close(id: session.id) }
                )
                Divider().frame(width: 1)
            }
            AddSessionButton(coordinator: coordinator)
            Spacer()
        }
        .frame(height: 34)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

struct SessionTabView: View {
    @ObservedObject var session: SessionState
    let isActive: Bool
    let onActivate: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            glyph
            Text(session.displayName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(isActive ? Color(NSColor.controlBackgroundColor) : Color.clear)
        .overlay(alignment: .top) {
            if isActive {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .contextMenu {
            Button("Close Session", action: onClose)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([session.rootURL])
            }
        }
    }

    private var glyph: some View {
        let letters = String(session.displayName.prefix(2)).uppercased()
        return Text(letters)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .frame(width: 20, height: 20)
            .background(isActive
                ? Color.accentColor.opacity(0.16)
                : Color(NSColor.controlColor))
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
```

### 11.5 Wiring into `main.swift`

```swift
// Replace:
let model = DocumentModel()
// With:
let coordinator = SessionsCoordinator()
coordinator.bootstrap(initialRoot: PreferencesStore().lastFolderURL)

// Replace the hosting controller's root view:
let hostingController = NSHostingController(
    rootView: WindowRoot(coordinator: coordinator)
)
```

And update `applicationWillTerminate` to drive
`coordinator.persistIndex()` (which already saves each session's
`WorkspaceSnapshot`).

`AppDelegate` references to `model.xyz` (e.g. `selectTabByNumber`)
become `coordinator.active?.model.xyz`. Mechanical edit.

### 11.6 Phase-1 acceptance criteria

- App launches; the new strip shows one session named after the open
  folder (or "Untitled" with no folder).
- Opening another folder via `File → Open Folder…` replaces the
  session (phase-1 has only one slot). The strip updates.
- The `+` button opens a folder picker; selecting a folder yields the
  same as "Open Folder" (still one slot in phase 1).
- Right-clicking the outer tab shows "Close Session" / "Reveal in
  Finder". Close clears the strip and shows the empty state.
- `applicationWillTerminate` writes `Sessions/index.json` and the
  session snapshot file. Relaunch restores them.
- Existing `_last.json` files are read on first launch of the new
  build (§8.1) and migrated to a session.

### 11.7 Out of scope for phase 1

- Multi-session — there's only ever one entry in
  `coordinator.sessions`. Phase 2 removes that constraint.
- Branch / dirty / live-dot indicators in the outer tab. Phase 2.
- Drag-reorder of outer tabs. Phase 2.
- The `Session` menu. Phase 2 (a minimal "Close Session" item
  can be wired earlier; the rest depends on phase 2's multi-session).
- Cross-session anything (pin, tab move, search). Phase 3+.
- Title-bar variant of the strip. Phase 3.

---

## 12. Phase 2 — multi-session

Once phase 1 is in:

1. **Remove the "one session at a time" constraint** in
   `SessionsCoordinator.openFolder` — append instead of replace.
2. **Wire the `Session` menu** (§7.2). New / Next / Previous /
   Jump to N / Close / Reopen Closed.
3. **Per-session keyboard shortcuts**: `⌃⇥` cycles forward,
   `⌃⇧⇥` backward, `⌃1`…`⌃9` jumps.
4. **Live branch / dirty / ahead-behind in the outer tab**. Add
   `GitStatusPoller` that, for every session, runs `git status -sb`
   on a 10 s interval and publishes the result via the session's
   `GitPanelModel`. Cancel on session close. The mock's "live dot"
   reflects whether the file watcher is currently attached to *some*
   file in that session.
5. **Per-session caches**: extract `highlightCache` and
   `renderedHTMLCache` from `DocumentModel` into `SessionState`.
   Views look them up through `session.model.highlightRuns(…)`.
6. **Begin SRP split of DocumentModel** (stage R1 from §3.3). Pull
   the find cluster into `FindModel`, hold it on `SessionState`,
   forward `objectWillChange`. Mechanical.

Estimate: a focused day of work per cluster (find, cross-search, git,
split). Four clusters → roughly a week of work for one engineer.

---

## 13. Phase 3 — polish

- Outer tab states: detached HEAD, conflict, stale watcher.
- Drag-reorder outer tabs.
- Outer tab drag-tear-off → new window. Requires multi-window support.
- Title-bar variant of the outer strip.
- Two-finger-swipe gesture for session cycling.
- Cross-session pinned tabs (mock's "Pin to all sessions").
- Reopen-closed-session with full state.

---

## 14. Risks & known footguns

### 14.1 SwiftUI view identity across session swap

The `.id(active.id)` modifier on `SessionRoot` is load-bearing.
Without it, SwiftUI may reuse the same view instances and you can
get stale `@State` carrying over (e.g. a `@State var isHovering`
in a tab item that thinks it's still hovered on the new session).
**Test**: swap sessions while hovering an inner tab; verify no stray
hover state.

### 14.2 `DocumentModel.cancellables` lifecycle in phase 1

In phase-1's façade variant, each `SessionState` creates its own
`DocumentModel`. When a session is closed, its `DocumentModel`
deallocates — but only if no view subtree still holds a reference.
The `.id(active.id)` tear-down releases the views; the coordinator
removing the session from its array releases the rest. Watch for
retain cycles in `model.cancellables` (it uses `[weak self]` — good).

### 14.3 BookmarksStore concurrency

It's a single file on disk read by every session's sidebar. Multiple
sessions all reading on launch is fine (read-mostly). Multiple
sessions all writing concurrently would race — but writes only
happen from the active session (user action). No new lock needed.

### 14.4 File watcher fd budget

macOS FSEvents is cheap, but per-file `kqueue`-based watchers
aren't. Today there's one watcher (the active file). With N sessions
all watching their respective active files, that's N fds. Cap with
"only the active session's file watcher runs" (already the design).
**Don't** be tempted to keep all watchers live for cross-session
"file changed elsewhere" badges — use periodic polling for that.

### 14.5 Git poll thundering herd

Phase-2's per-session git poll on a 10 s interval × N sessions × a
spike of network round-trips on SSHFS = a real problem. Stagger the
polls (each session gets a phase offset of `id.hashValue % 10_000ms`),
and bail out early if `repoRoot` discovery returns nil.

### 14.6 Schema-version bumps

`SessionSnapshot.currentSchema = 2`. Any future field addition that
*requires* a value on read = bump to 3 and provide a v2→v3 migration
function. The "additive, optional, default-filled" pattern handles
99% of changes without bumping. Hard-bump only for semantic changes
(e.g. tabs become a tree instead of an array).

---

## 15. ASCII summary of the full design

```
                          USER ACTION                                APP STATE EFFECT
                          ───────────                                ────────────────
        Open Folder…    ─────────────────────────►  coordinator.openFolder(url)
                                                    │
                                                    ├─► matches existing session? activate it
                                                    └─► else: new SessionState(rootURL=url),
                                                              append, activate

        Click outer tab  ─────────────────────────►  coordinator.activate(id)
                                                    │
                                                    ├─► old.detach() — stop watcher, cancel tasks
                                                    ├─► activeID = id
                                                    └─► new.mount() — start watcher, refresh diff

        Close outer tab  ─────────────────────────►  coordinator.close(id)
                                                    │
                                                    ├─► snapshot → trash/<id>.json
                                                    ├─► remove from sessions[]
                                                    └─► activate most-recent other (or empty)

        ⌃Tab / ⌃⇧Tab    ─────────────────────────►  coordinator.next/previous

        ⌃1…9             ─────────────────────────►  coordinator.activate(index: n-1)

        ⌘1…9             ─────────────────────────►  active.model.selectTab(at: n-1)
                                                       (inner-tab scope, unchanged from today)

        Quit             ─────────────────────────►  for s in sessions: store.save(snapshot(s))
                                                    store.saveIndex(index)


                                       ┌──────────────────────────────┐
                                       │ Sessions/                    │
                                       │   index.json   ←── coord     │
                                       │   <uuid-1>.json ←── session  │
                                       │   <uuid-2>.json ←── session  │
                                       │   trash/                     │
                                       │     <uuid-3>.json (30d ttl)  │
                                       └──────────────────────────────┘


    SwiftUI tree:

       WindowRoot
         ├── SessionStripView  ── observes coordinator
         │     ├── SessionTabView (×N)  ── observes individual SessionState
         │     └── AddSessionButton
         └── SessionRoot      .id(active.id)   ── observes active SessionState
              │                                  (full tear-down on switch)
              └── ContentView (today's)
                   ├── SidebarView ── session.sidebar
                   ├── TabBar     ── session.tabs   (inner tabs)
                   └── DocumentBody
```

---

## 16. References

- The mock: `/Users/me/Downloads/TextView (3)/details/sessions-tabs.html`
- Existing state audit: `/Users/me/Documents/workspaces/claude/markdown_viewer/STATE.md`
- Today's session-shaped state: `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/Workspace/WorkspaceStore.swift`
- The model to be split: `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DocumentModel.swift` (1145 lines, 41 `@Published`)
- App entry point to be re-wired: `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/MarkdownViewer/main.swift`
- Sidebar already an `ObservableObject` ready to be session-scoped: `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/SidebarModel.swift`
- The global stores that stay global: `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/BookmarksStore.swift`, `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/HistoryStore.swift`, `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/PreferencesStore.swift`
