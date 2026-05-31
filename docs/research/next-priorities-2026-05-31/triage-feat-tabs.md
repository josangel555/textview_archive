# Triage — feat:tabs

I have all the verification I need. Here is the sizing.

---

# Tab / Tab-Bar Feature Sizing

All findings verified against current code on `main`. Key architectural fact that recurs below: **the file watcher (`FileWatcher`) watches exactly ONE file — the active tab's** (`startWatchingCurrentFile()`, `Sources/ViewerUI/DocumentModel.swift:2189-2205`, rebound on every `selectTab`/`closeTab`). Disk-change state today is only ever computed for the active tab, and only against an editor buffer's fingerprint. This is the central dependency for the red-dot and the status-bar "modified" work.

---

### 1. Tabs shrink to a MIN width (icon + close), THEN overflow/scroll

**Status today**
- Tab item frame is `.frame(minWidth: 100, idealWidth: 180, maxWidth: 240)` then `.frame(height: 28)` — `Sources/ViewerUI/TabBar.swift:180-181`.
- The strip is a plain `ScrollView(.horizontal, showsIndicators: false)` wrapping an `HStack(spacing: 0)` — `TabBar.swift:9-10`. There is no width-distribution logic; each tab takes its ideal/min width and the strip scrolls once total width exceeds the viewport.

**Root cause / gap**
- `ScrollView` gives each child its *ideal* width unconditionally and never compresses. `minWidth: 100` is a floor that's never approached because nothing ever asks the tabs to shrink. So tabs jump straight from `idealWidth: 180` to scrolling — they never collapse to an icon+close pill first. SwiftUI's `ScrollView` cannot do "shrink-to-fit-then-scroll"; it has no available-width feedback to its children.

**Fix/build sketch**
- Two viable approaches:
  1. **GeometryReader-driven width budget (pure SwiftUI):** wrap the strip in a `GeometryReader`, compute `perTabWidth = clamp(availableWidth / tabCount, minIconWidth...idealWidth)`. When `perTabWidth` hits the `minIconWidth` floor and tabs still overflow, fall back to the `ScrollView`. Drive a `TabBarItem` "compact" bool (hide title, keep icon + dirty/disk dot + close) when `perTabWidth < ~64pt`. This is the idiomatic path and keeps everything in `TabBar.swift`.
  2. **NSCollectionView/AppKit custom layout:** more control, far more code, not justified here.
- The `TabBarItem` already has the right internal structure to go compact — icon (`FileIconView`), dirty dot, bookmark star, close button are independent `HStack` children (`TabBar.swift:130-177`); you'd gate the `Text(tab.title)` and the bookmark star on `!compact`.

**Size: M.** Layout math + a compact rendering mode + the overflow→scroll handoff. No model changes, but the GeometryReader/width-budget interaction with the existing `ScrollView` and the drag-reorder hit targets (`onDrag`/`onDrop`, `TabBar.swift:23-35`) needs care — compact pills shrink the drop target.

**Dependencies** None hard. Pairs naturally with #2 (scroll-to-selected) since both touch the strip layout.

**Risk/one-way-door** Low. Watch the compositor rule called out in `ContentView.swift:80-88` (LESSONS.md) — the tab strip is above the content band so it's not in the NSScrollView/WKWebView flex path, but a `GeometryReader` that claims height could subtly shift the `.frame(height: 30)` strip; keep the GeometryReader scoped to the horizontal axis.

---

### 2. Active tab must ALWAYS be visible (scroll-to-selected)

**Status today**
- No `ScrollViewReader` / `scrollTo` anywhere in `TabBar.swift` (verified — grep returned nothing). The `ForEach` is keyed by `\.element.id` (`TabBar.swift:11`) but children have no `.id()` scroll anchors and the `ScrollView` has no programmatic scroll driver.
- Same gap in `SessionTabBar.swift:38-65`.

**Root cause / gap**
- Selection (`model.tabs.selectedIndex`) changes the visual highlight (`isSelected`, `TabBar.swift:14`) but never scrolls the strip. When the selected tab is offscreen (after overflow, or after `selectTab` from the command palette / `revealInSidebar` / keyboard ⌘1-9), it stays offscreen.

**Fix/build sketch**
- Wrap the inner `HStack` in `ScrollViewReader`, tag each item with `.id(tab.id)`, and add `.onChange(of: model.tabs.selectedIndex)` (and `initial: true` for first paint) that calls `proxy.scrollTo(selectedID, anchor: .center)`. ~8 lines.
- Apply the identical change to `SessionTabBar` for the active session pill.

**Size: S.** Textbook `ScrollViewReader` usage. The only subtlety is animating it without fighting the drag-reorder, and making sure the scroll fires after a programmatic `selectTab` (use `.onChange` on `selectedIndex`, not on a tap closure).

**Dependencies** None. Strictly better if #1 lands first (so there's something to scroll), but independently shippable.

**Risk/one-way-door** None.

---

### 3. Blue dot = changed/dirty in the editor

**Status today — ALREADY IMPLEMENTED.**
- `Tab.isDirty` exists (`Sources/ViewerCore/Tab.swift:9-15`), is part of `Tab`'s cheap Equatable (`Tab.swift:62`), and the dot is rendered: `Circle().fill(Color.accentColor)` gated on `tab.isDirty` — `TabBar.swift:143-153`. It carries the a11y id `mdv.tab.dirtyDot`.
- It's `Color.accentColor` (system accent, typically blue), not a literal blue. Set/cleared by `updateEditorText` and the save path (`EditorCoordinator.saveEditor`, `EditorCoordinator.swift:382-388`).

**Root cause / gap**
- Only gap vs. the ask: it's accent-colored, not guaranteed blue, and it shares the visual column with the close button (`TabBar.swift:146-147` comment). If you want a literal blue regardless of accent, swap `Color.accentColor` → `Color.blue`. If a red disk-dot (#4) is added, you need both to coexist — decide layout (two dots, or one dot whose color encodes priority: red-on-disk > blue-dirty).

**Fix/build sketch** Trivial color pin if literal blue is required; otherwise nothing.

**Size: S** (effectively zero unless you want literal-blue + coexistence rules with #4).

**Dependencies** Coordinate with #4 for the shared dot column.

**Risk/one-way-door** None.

---

### 4. Red dot = file changed on DISK (external edit) vs loaded copy

**Status today**
- The *detection primitive* exists but is **scoped to the active editor tab only and is event-driven, not a persistent per-tab flag.**
  - `EditorBuffer.hasExternalEdit(currentMTime:currentSize:)` compares against `lastSavedMTime/lastSavedSize` — `Sources/ViewerCore/EditorBuffer.swift:102-106`.
  - It's consulted only inside `reloadCurrentFile(matching:)` for the *active* tab when a watcher tick fires (`DocumentModel.swift:2107-2120`), and only when the buffer is dirty — clean tabs reload silently (`DocumentModel.swift:2121`).
  - `FileWatcher` watches exactly one path; it's torn down/rebound on every tab switch (`startWatchingCurrentFile`, `DocumentModel.swift:2192-2204`). **Background tabs are not watched at all.**
- `TextFile.modifiedTime` is captured at load (`TextFileLoader.swift:33,198`) and threaded through caches, so each loaded tab *does* carry the disk mtime it was read at.

**Root cause / gap**
- There is no per-tab "disk diverged" boolean and no mechanism to detect divergence for **non-active** tabs. To show a red dot on *any* tab whose file changed on disk, you need either (a) a watcher per open file, or (b) a cheap re-stat sweep that compares each tab's `TextFile.modifiedTime`/byteCount against current disk attrs.

**Fix/build sketch**
- Add `Tab.isModifiedOnDisk: Bool` (mirror the `isDirty` pattern — extend `Tab.swift`, include in Equatable). Render a second dot (`Color.red`) in `TabBarItem` next to / instead of the blue one with a priority rule.
- Populating it — two designs:
  1. **Multi-watcher (accurate, more state):** maintain a `[URL: FileWatcher]` (or `[tabID: FileWatcher]`) for all open tabs. On any tick, re-stat and set `isModifiedOnDisk` on the matching tab if `(mtime,size)` diverges from its loaded `TextFile` fingerprint (use the existing `EditorBuffer.hasExternalEdit` logic, generalized to compare against `TextFile.modifiedTime`/`byteCount` when no buffer exists). Cleared on reload/refresh/save. Cost: N file descriptors (`O_EVTONLY|O_CLOEXEC`, already used — `FileWatcher.swift:113`); the watcher is already correct and reattaches on atomic writes.
  2. **On-demand stat sweep (cheaper, slightly stale):** keep the single active-tab watcher; on window-focus / tab-switch / a coarse timer, re-stat every open tab's URL and update flags. Lower fd pressure, but misses changes while unfocused until the next sweep.
- Either way the comparison must reuse the **mtime + byteCount** identity already standardized across the cache layer (`DocumentModel.swift:1782-1815`, `EditorBuffer.swift:102-106`) — do not introduce a content hash.

**Size: M-L.** M if you accept the on-demand-stat-sweep design and reuse `hasExternalEdit`. L if you go multi-watcher (lifecycle: bind on tab open, drop in `cleanupAfterClose` — `TabCoordinator.swift:291-309` is the natural hook via `addCloseHook`, `TabCoordinator.swift:143`), plus pause/resume integration with the session detach path (`pauseFileWatcher`, `DocumentModel.swift:2217`).

**Dependencies**
- **This is the keystone for the status-bar 'modified in red'.** The status bar (`StatusBar.swift`) shows zero disk-change info today — adding a red "modified" indicator there is the *same* per-tab divergence signal surfaced in a second place. Build the per-tab `isModifiedOnDisk` once; both the tab dot and the status-bar indicator consume it.
- Overlaps #3 (shared dot column / priority) and #5 (Refresh clears the flag).
- Overlaps the **session-independence** work: a multi-watcher fleet must respect session pause/detach (`SessionsAppCoordinator` detach → `pauseFileWatcher`) or background-session tabs will hold fds and fire spurious ticks.

**Risk/one-way-door**
- fd exhaustion / event storm if multi-watcher is unbounded across many sessions × many tabs. The existing single watcher already handles atomic-write reattach + debounce (`FileWatcher.swift:157-235`); reuse it, don't reinvent.
- Correctness trap: `hasExternalEdit` returns `false` for "can't tell" (nil operands) — see the decision table at `EditorBuffer.swift:122-138`. For a *display* dot, false-negative ("no dot when actually changed") is acceptable; do **not** wire this into any silent-reload path without `hasUnknownDiskState`.

---

### 5. Right-click tab → "Refresh" (force reload regardless of detected change)

**Status today**
- `TabContextMenu` exists with Close/Close Others/Close to Right/Copy Path/Reveal in Finder/Reveal in Sidebar — `TabBar.swift:93-113`. **No Refresh.**
- The reload machinery exists: `reload(url:at:)` (`DocumentModel.swift:2149`) and `applyReload(url:at:)` (`DocumentModel.swift:2164-2187`) re-`controller.open()` the file and rebase a clean editor buffer. `reloadCurrentFile()` (`DocumentModel.swift:2086`) does it for the active tab. But all current entry points are the active tab + watcher-driven.

**Root cause / gap**
- No public method to force-reload an *arbitrary* tab by index, and no menu item. `reload(url:at:)` is `fileprivate` (`DocumentModel.swift:2149`).

**Fix/build sketch**
- Add `public func refreshTab(at index: Int)` on `DocumentModel`: resolve the tab's URL, run the dirty-buffer guard (if dirty, route through the existing `presentExternalEditConflict` prompt at `EditorCoordinator.swift:534` — "Keep My Edits / Discard & Reload"; "force regardless" should still protect unsaved edits unless you explicitly want destructive force), else call `applyReload`. Clear any `isModifiedOnDisk` flag (#4).
- Add `Button("Refresh") { model.refreshTab(at: tabIndex) }` to `TabContextMenu` (`TabBar.swift:104-111`, after the Divider).

**Size: S.** Reuses `applyReload`. Mostly a public wrapper + one menu item. The only decision is dirty-buffer behavior (prompt vs. truly-force-discard) — recommend prompt, reusing the existing conflict UI.

**Dependencies** Builds on the existing reload path (no new infra). Clears #4's flag, so nicer after #4 but independent.

**Risk/one-way-door** Low. If "force regardless" means discard-without-prompt, that's destructive of unsaved edits — gate it behind the existing prompt or a modifier key.

---

### 6. Right-click tab → "Open file in new session" & "Move file to new session"

**Status today**
- Session creation exists: `openFolderInNewSession: ((URL) -> Void)?` on `DocumentModel` (`DocumentModel.swift:237`), wired in `main.swift:202-204` to `sessions.openFolder(url, forceNew: true)`. But this is **folder-only** — `SessionsCoordinator.openFolder` resolves the URL as a *sidebar root* (`SessionsCoordinator.swift:184-204`, sets `sidebarRootPath`), it does not open a file into a tab.
- A new session's tabs come from `SessionSnapshot.openTabs: [TabSnapshot]` (`SessionSnapshot.swift:43`), hydrated on mount. `openFolder` creates a snapshot with **empty** `openTabs` (`SessionSnapshot.swift:68`).
- No tab context-menu items for either action (`TabBar.swift:93-113`).

**Root cause / gap**
- There is no "create a session AND open this specific file in it" path. `openFolder(forceNew:)` only sets a root folder. "Move" additionally needs to *close* the file's tab in the current session after handing it off — and the Phase-1 session model shares a single `DocumentModel` across sessions via the façade trick (`SessionsAppCoordinator.swift:14-23, 250-279`), with `switchSessionFaçade` *dropping* old tabs (`SessionsAppCoordinator.swift:254-257`). So "open file in new session" then switching back must not lose the original.

**Fix/build sketch**
- **Open file in new session:** add a coordinator entry point, e.g. `SessionsAppCoordinator.openFileInNewSession(_ fileURL: URL)`:
  - Create a session rooted at the file's parent dir (so the sidebar has context), then inject the file as the session's open tab. Cleanest: build a `SessionSnapshot` with `openTabs: [TabSnapshot(url: fileURL, …)]` + `selectedTabIndex: 0` instead of going through the empty-root `openFolder`. Hydrate-on-mount already opens snapshot tabs.
  - Expose via a new `DocumentModel` closure (mirror `openFolderInNewSession`, e.g. `openFileInNewSession: ((URL) -> Void)?`) wired in `main.swift` so `ViewerUI` doesn't import `SessionsAppCoordinator`.
- **Move file to new session:** same as above, then `model.closeTab(at:)` for the source tab in the current session (with the existing dirty-confirm guard, `DocumentModel.swift:2245-2252`). Caveat: under the Phase-1 single-`DocumentModel` façade, the "new session" doesn't actually run concurrently with the old one — switching activates it and `switchSessionFaçade` drops the prior session's live tabs (persisted via `makeSnapshot` on detach, `SessionsAppCoordinator.swift:319-321`). So "move" works through the persist/hydrate round-trip, not a live in-memory hand-off. Verify the source session's snapshot is persisted before the switch so the moved file is gone from it.
- Add both `Button`s to `TabContextMenu`, gated on `tab.url != nil` (`TabBar.swift:105`).

**Size: M** for "open file in new session" (new snapshot-with-tab path + closure plumbing). **M-L** for "move" because of the Phase-1 façade's tab-dropping semantics and the persist-ordering correctness around the source session.

**Dependencies**
- **Heavily overlaps the session-independence work.** The clean version of both features (especially "move") really wants **Phase 2's per-session `DocumentModel`** (called out as the seam in `SessionsAppCoordinator.swift:21-23, 246-249`). On Phase-1's shared-model façade you *can* implement it via snapshot injection, but the semantics are "round-trip through persistence," and "move" is fragile until per-session models exist.
- Needs `SessionSnapshot`/`TabSnapshot` to carry the injected tab — the shape already supports it (`SessionSnapshot.swift:7, 43-44`).

**Risk/one-way-door**
- Medium. The Phase-1 façade drops live tabs on session switch (`SessionsAppCoordinator.swift:254-257`). If "move" hands off via in-memory state instead of persisted snapshot, the file is silently lost. Build it on the persist/hydrate path, and ideally defer the polished version to Phase 2.

---

### 7. Move the Source|Editor|HEX mode picker WITHIN the file-content window

**Status today**
- `ModeBar` (the segmented `Picker`, `pickerStyle(.segmented)`) lives in the **outer** `VStack`, above the shoulder rails and sidebars — `ContentView.swift:69-72`, directly under the `TabBar`. So it spans the full window width including over the side panels. The picker itself is `ModeBar.swift` at `ContentView.swift:754-852` (the file is `ContentView.swift`).
- The content pane is `content` → `loadedView(for:)` (`ContentView.swift:298-330`), nested inside `bodyRow` (`ContentView.swift:196-238`), which is *inside* the rails `HStack` (`ContentView.swift:89-126`). The ModeBar is a sibling **above** that whole band.

**Root cause / gap**
- ModeBar is positioned at the window-chrome level, not the content level. To move it "within the file content window," it must become a sibling *inside* the center `VStack` of `bodyRow` (above `content`, `ContentView.swift:203-204`), so it sits over only the file pane and not over the sidebar/rails.

**Fix/build sketch**
- Remove `ModeBar(model:)` + its divider from the outer `VStack` (`ContentView.swift:69-73`).
- Insert it at the top of the center column in `bodyRow` — inside the `VStack(spacing: 0)` at `ContentView.swift:203`, *before* `content`. Keep the same `.padding`/a11y id.
- Decision: should the split pane (`SplitPaneView`, `ContentView.swift:225-235`) get its own mode picker? Today the split is read-only/stateless (`TabCoordinator.swift:148-154`), so likely no — but placing ModeBar inside the center `VStack` (not the `bodyRow` HStack) keeps it scoped to the primary pane only, which is correct.

**Size: S-M.** Mechanically a node move. M-leaning because of the **compositor rule** (`ContentView.swift:74-127`, `LESSONS.md`): every wrapper around `content` must keep `.frame(maxWidth:.infinity, maxHeight:.infinity)` or the NSScrollView/WKWebView collapses. Adding a fixed-height ModeBar as a sibling above `content` inside the center `VStack` is the same shape as the existing bottom `ShoulderRailView` sibling (`ContentView.swift:109-114`), which is known-safe — so the pattern is proven, but it must be done exactly that way (fixed-height bar + flex content).

**Dependencies** None.

**Risk/one-way-door**
- Medium *only* because of the compositor fragility. Per `LESSONS.md`, restructuring around `content` has historically caused the content pane to collapse. The bottom-rail sibling precedent (`ContentView.swift:103-115`) is the safe template — follow it (fixed-height picker bar, `content` stays `.frame(maxWidth:.infinity, maxHeight:.infinity)`). Test on the VM (UI test), not host.

---

### 8. Double-click a SESSION tab → open a new tab (default ~); session-tab open menu prefills ~

**Status today**
- `SessionTabBarItem` is a `Button(action: onSelect)` (`SessionTabBar.swift:109`) — single-click activates the session. **No double-click handler** (verified — grep found no `TapGesture(count:)`/`onTapGesture` in the file).
- The `+` button calls `openNewSession()` → `sessionsApp.requestNewSessionViaGoTo()` (`SessionTabBar.swift:88-90`), which arms the first-paint GoTo gate (`SessionsAppCoordinator.swift:130-133`) → presents `GoToPathPrompt`.
- `GoToPathPrompt` opens with an **empty** field and explicitly *chooses not to prefill* — see the `onAppear` comment "match Finder, which opens empty" (`GoToPathPrompt.swift:96-101`). Placeholder is a generic `/Users/you/path/...` (`GoToPathPrompt.swift:53`).

**Root cause / gap**
- No gesture wired for double-click on a session pill.
- The "open menu" (GoToPathPrompt) deliberately starts empty; the ask is to prefill `~` (home) for the session-tab-triggered case.

**Fix/build sketch**
- **Double-click → new tab defaulting to ~:** add a double-click recognizer to `SessionTabBarItem`. SwiftUI's `Button` + `.onTapGesture(count: 2)` is unreliable on macOS; the robust path is `.simultaneousGesture(TapGesture(count: 2).onEnded { … })` or a `.gesture` with a count-2 `TapGesture` that takes priority over the single-tap select. On double-click, call a new closure that does `sessionsApp.activate(id:)` (ensure the session is active) then `model.newTab()` — but the ask says "default to ~". `newTab()` currently appends a blank `Tab()` (`DocumentModel.swift:2234-2236`), which is empty/Untitled, not rooted at ~. If "default to ~" means open the home dir, route to `model.openPath(URL(fileURLWithPath: NSHomeDirectory()))` or open the GoTo prompt prefilled with `~` (see below). Clarify intent: blank tab vs. home-rooted.
- **Prefill ~ in the session-tab open menu:** add an optional seed to `GoToPathPrompt` (e.g. `initialPath: String?`) and set `path = "~"` in `onAppear` when invoked from the session-tab path. The expansion layer already handles `~` (`GoToPathExpansion.expand`, used at `GoToPathPrompt.swift:180`; `~` is explicitly accepted per the error message at `GoToPathPrompt.swift:245`). The first-paint GoTo bridge (`ContentView.swift:280-285`, `FirstPaintGoToBridge`) is where you'd thread the "prefill ~" signal.

**Size: S-M.** S for the prefill (one `onAppear` seed + a flag through the GoTo gate). M-leaning for the double-click because macOS double-click-vs-single-click gesture arbitration on a SwiftUI `Button` is finicky and needs VM testing.

**Dependencies**
- Touches the session GoTo gate (`FirstPaintGoToGate`, `SessionsAppCoordinator.swift:52-53, 130-139`) and `FirstPaintGoToBridge`. Mild overlap with #2 (both touch `SessionTabBar`).
- Slight semantic dependency on session-independence: "open a new tab" on a session you double-clicked implies that session becomes/already-is active (Phase-1 single model means it operates on the shared `DocumentModel`).

**Risk/one-way-door**
- Low logic risk; **gesture-arbitration risk is the real cost** — a count-2 tap that also fires the count-1 select would activate-then-also-open. Use `highPriorityGesture`/`simultaneousGesture` carefully and verify on the VM. Also confirm double-click doesn't collide with the inline-rename flow (`SessionTabBar.swift:117-126, 164-173`).

---

## Cross-cutting summary

| # | Feature | Size | Hard dependency |
|---|---------|------|-----------------|
| 1 | Shrink-then-scroll tabs | M | — |
| 2 | Scroll-to-selected | S | — |
| 3 | Blue dirty dot | S (done) | — |
| 4 | Red disk-change dot | M–L | per-tab disk-divergence infra (multi-watcher or stat-sweep) |
| 5 | Right-click Refresh | S | reuses `applyReload` |
| 6 | Open/Move file → new session | M / M–L | session-independence (clean form wants Phase-2 per-session model) |
| 7 | Move ModeBar into content pane | S–M | — (compositor-rule care) |
| 8 | Double-click session tab + ~ prefill | S–M | GoTo gate |

**The two load-bearing shared substrates:**
1. **Per-tab disk-divergence signal** (#4) — the single source of truth for both the red tab-dot *and* the status-bar "modified in red." Build it once (`Tab.isModifiedOnDisk` mirroring `Tab.isDirty`, fed by a generalized `hasExternalEdit` over `TextFile.modifiedTime`/`byteCount`), reuse the existing `FileWatcher`. Today disk-change detection is active-tab-only and event-scoped — that's the core gap. #5 (Refresh) clears this flag; #3 (blue dot) shares the dot column.
2. **Session-independence / Phase-2 per-session `DocumentModel`** (#6, partly #8) — the current Phase-1 façade shares one `DocumentModel` and drops live tabs on session switch (`SessionsAppCoordinator.swift:250-279`), so "move file to new session" is only cleanly correct once per-session models exist; on Phase-1 it must round-trip through persisted snapshots.

Highest-risk one-way-door: **#7** (compositor collapse around `content`, per `LESSONS.md`) — mechanically trivial but must follow the proven bottom-rail sibling pattern and be VM-tested.