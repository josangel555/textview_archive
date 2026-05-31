# Triage — feat:sessions

I have everything needed. The "pin" feature is essentially the well-developed inverse of the existing `revealInSidebar` + `isSidebarLocked` machinery — `revealInSidebar` already does the reveal work; what's missing is an automatic trigger on tab-focus change. Let me write up the analysis.

---

# SESSION work — sizing & dependency analysis

**TL;DR up front:** Sessions already exist, but in a deliberately incomplete **Phase-1 façade**: a `SessionsCoordinator` (value-level, `ViewerCore`) + `SessionsAppCoordinator` (`ViewerUI`) wrap a **single shared `DocumentModel`** that every session reuses (`Sources/ViewerUI/Sessions/SessionsAppCoordinator.swift:18-23, 250-279`). Switching sessions tears down and re-hydrates tab state *on the same model*. The "session independence" item is exactly the documented Phase-2 R1–R3 refactor in `docs/SESSIONS_DESIGN.md §3.3–3.5` — it is the foundational item, and how it's modeled determines whether the other three items are trivial or blocked.

---

### Session independence (per-session state)

**Status today**
- A real session layer is landed and wired into the app: `SessionsAppCoordinator` is instantiated in `Sources/MarkdownViewer/main.swift:17`, the strip renders via `SessionTabBar` (`ContentView.swift:62-63`), and script verbs drive it (`Sources/MarkdownViewer/ScriptRunner.swift:115-209`).
- But it's **Phase-1 façade**: `SessionsAppCoordinator.model` is *one* `DocumentModel` shared across all sessions (`SessionsAppCoordinator.swift:27-28`, comment block lines 14-23). `SessionState` wraps that same instance (`SessionState.swift:38-60`); switching is implemented as "drop all tabs, re-hydrate from the incoming snapshot" against the singleton (`switchSessionFaçade`, `SessionsAppCoordinator.swift:250-279`).
- Persistence works and is non-trivially hardened (LRU, trash/recovery, downgrade guard, lazy-restore) — `SessionsCoordinator.swift` + `SessionStore.swift`. The on-disk `SessionSnapshot` (`Sources/ViewerCore/Sessions/SessionSnapshot.swift`) is the canonical schema (v2).
- **What is genuinely shared (not per-session) today:** everything `DocumentModel` owns. Specifically:
  - Tabs/per-tab caches — `tabCoordinator` (`DocumentModel.swift:22`).
  - Sidebar tree (root, `expanded`, `selectedURL`, `includeHidden`, `isVisible`) — `SidebarModel`, one instance (`DocumentModel.swift:173`, `SidebarModel.swift:9-18`).
  - **Tool-window / shoulder-rail state** — `PanelLayoutStore` (`DocumentModel.swift:180, 261`), and crucially it persists to **app-global `UserDefaults`** keys `MarkdownViewer.sidebar.panelEdges` / `…panelOverrides` (`PanelEdgeAssignment.swift:34`, `PanelVisibilityOverrides.swift:21`) — there is *no* per-session dimension at all.
  - Find/cross-search (`find` coordinator), git focus (`repoFocus`), LSP pool/diagnostics/navigation, editor coordinator, zoom/theme/word-wrap, sidebar lock.

**Root cause / gap**
The Phase-1 trick (`SESSIONS_DESIGN.md §3.5`) intentionally deferred the `DocumentModel` split. So "each session owns its own tabs/selections/tool-window/scroll state" is false today: there is exactly one of each. Snapshots paper over tabs + sidebar root + zoom/wrap/theme on *switch* (`SessionState.makeSnapshot()`/`hydrate()`, `SessionState.swift:104-189`), but:
- Tool-window (panel visibility/edge) state is **not** in the snapshot and is global UserDefaults — toggling Git panel off in one session toggles it everywhere.
- `makeSnapshot()` hard-codes `sidebarExpandedPaths: nil`, `sidebarIncludeHidden: nil`, `splitURL: nil` (`SessionState.swift:121-123`) — so sidebar expansion, hidden-toggle, and split are lost across switches even though the schema has fields for them.
- Scroll/selection/find/git-panel state is not snapshotted at all (it's transient on the shared model, and gets clobbered on switch).

**Fix/build sketch** (this *is* the documented R1→R3, `SESSIONS_DESIGN.md §3.3`):
1. **R1 — extract session-scoped clusters off `DocumentModel`** into observable children (find already done as `FindCoordinator`; tabs as `TabCoordinator`; sidebar already standalone). Remaining: a `CrossSearchModel`, `GitPanelModel`, `SplitViewModel`, and decide caches (`highlightCache`/`renderedHTMLCache`).
2. **R2 — make `SessionState` own real per-session children** instead of wrapping the shared model (`SESSIONS_DESIGN.md §3.3` R2 sketch, lines 334-397): `sidebar`, `tabs`, `find`, `crossSearch`, `git`, `split`, plus per-session `panelLayout` and watcher/diff-task lifecycle.
3. **R3 — `SessionsCoordinator` owns `N × SessionState`** (Option A, `§3.1`), each fully self-contained; `DocumentModel` → thin `AppModel` holding only *global* state (zoom, theme, prefs, `HistoryStore`, `BookmarksStore`, palette flag) per `§3.4` Option α.
4. **The expensive part is the view layer:** ~**40+ `@ObservedObject var model: DocumentModel`** call sites across `ContentView.swift`, `SidebarView.swift`, `StatusBar.swift`, etc. must re-point at either `AppModel` (global) or `sessionsApp.active.<child>` (session). The active-session swap must re-publish so the whole content tree re-binds to the new model graph — today the façade specifically *avoids* re-mounting because the `DocumentModel` reference never changes (`SessionsAppCoordinator.swift:18-23`). Option A inverts that.

**Verdicts to honor from the design** (so the split doesn't drift): `§1.1` lists session-scoped (tabs, sidebar tree, find, cross-search, git-panel nonces, split, scroll telemetry, watcher, caches); `§1.3`/`§1.4` keep zoom/theme/word-wrap/show-invisibles/uiScale/`sidebarWidth`/`defaultModeOverrides` **global**. Note: the current `SessionSnapshot` persists `zoom`/`wordWrap`/`themeOverride` per-session (`SessionSnapshot.swift:56-58`) as a Phase-1 carry-over that **contradicts** the `§1.4` "these are global" verdict — that conflict needs an explicit resolution (keep as per-session override with global fallback, or drop from the snapshot).

**Size: L** (multi-week, multi-agent). R1+R2 are mechanical-but-broad; R3 + the view re-point is the bulk. The coordinator/persistence/lifecycle scaffolding is *already built and hardened*, which removes maybe a third of the original L estimate — but the `DocumentModel` cluster split + 40-site view rebind is irreducibly large. Recommend the documented "one cluster at a time behind the existing façade" staging so it lands incrementally rather than as one big-bang.

**Dependencies** — none; this is the floor everything else stands on.

**Risk / one-way-door**
- **Snapshot schema is the one-way door.** `SessionSnapshot` is v2 with a forward-compat (additive-optional) contract and a downgrade guard (`SessionsCoordinator.swift:110-121`, `indexWriteBlocked`). Any new session-scoped field (panel layout, expansion, scroll, pin) must be **additive + optional** or older builds truncate newer files. Get the field set right *before* shipping per-session panel state, because users will accrue `Sessions/<uuid>.json` files immediately.
- **Republish storms.** The codebase has scar tissue here (PERF #1; the `REPUB-1` note in `SessionState.swift:62-78` explicitly refuses to forward `model.objectWillChange`). The R2 sketch's `wireForwarding()` (`§3.3` lines 382-392) forwards *every* child's `objectWillChange` into `SessionState` — that's precisely the anti-pattern `LESSONS.md` warns against. The split must preserve **direct observation** of leaf models by views (the established `FindCoordinator`/`PanelLayoutStore`/`SidebarModel` pattern), not funnel through `SessionState`. This is a real design tension between the doc's R2 sketch and the current observation discipline; resolve it toward direct observation.
- **TCC/file-watcher lifecycle per session** (multiple live watchers) — the `mount`/`detach` seam exists and is detach-before-mount-correct (`SessionsCoordinator.swift:82-90, 217-242`), but N live sessions means N watchers; only the active one should be mounted (already the design).

---

### "Recently opened files" as a new tool window

**Status today**
- The data exists and is global: `HistoryStore` (`Sources/ViewerCore/HistoryStore.swift`), surfaced as `DocumentModel.recents: [HistoryEntry]` (`DocumentModel.swift:110, 262`), capped at 100, newest-first (`HistoryStore.swift:102-104`).
- The tool-window framework exists: `SidebarPanelKind` enum is the single source of truth for panels (`Sources/ViewerCore/SidebarPanelKind.swift:16-92`) with `displayName`/`systemImage`/`appStorageKey`/`defaultHeight` per case; rails render one button per kind (`ShoulderRailView.swift:51-95`); visibility resolves through `PanelLayoutStore` + `SidebarDataPresence`.
- There is **no** `recents`/`recentlyOpened` case in `SidebarPanelKind`. There's a `RecentChangesSection` (`Sources/ViewerUI/RecentChangesSection.swift`) but that's git/FS *recency* (modified-since), not "recently opened files" — different feature, and its own comment flags it as slated for deletion (line 112-115).

**Root cause / gap** — just not built as a panel. Pure additive work.

**Fix/build sketch**
1. Add `case recentlyOpened` to `SidebarPanelKind` (+ `displayName`/`systemImage`/`appStorageKey` — note `appStorageKey` is pinned by a stability test, so add a new stable key, don't derive). Add to `SidebarPanelRegistry.defaultOrder`.
2. Build a `RecentlyOpenedSection` SwiftUI view reading `model.recents` (or the per-session-filtered slice; see below), each row → `model.openPath`. Mirror `BookmarksSection`.
3. Wire into the accordion (`SidebarView`) + the rail button automatically picks it up.
4. Data-presence predicate in `SidebarDataPresence` (`recents.isEmpty == false`).

**Size: S** (≈half a day). The panel framework does all the heavy lifting.

**Dependencies** — none to ship a *global* recents panel. **But** `§1.1`/`§1.2` of the design says the sidebar's recents should be **filtered to the active session's root** (store stays global, UI filters). That filtering is trivial *after* session independence (just filter by `session.rootURL`); before it, "recently opened in this project" has no project to scope to. So: global version is independent-S now; the session-scoped version is gated on session independence.

**Risk** — none material. `appStorageKey` stability test is the only gotcha (use a fresh stable key string).

---

### File-nav "pin" button (auto-reveal focused tab's file)

**Status today**
- The *reveal mechanism* is fully built: `DocumentModel.revealInSidebar(_:)` (`DocumentModel.swift:395-432`) sets root if needed, expands ancestors without IO, and selects the file.
- The *inverse* control already ships: a **lock** toggle (`isSidebarLocked` / `toggleSidebarLock`, `DocumentModel.swift:436-438`; UI at `SidebarView.swift:479-493`) that *suppresses* auto-navigation. The header comment even says "auto-reveal-on-click + tab-reveal won't change the sidebar root."
- **Missing:** an automatic trigger that calls `revealInSidebar(currentURL)` whenever the focused tab changes. `currentURL` is `tabs.selected?.url` (`DocumentModel.swift:1888`).

**Root cause / gap** — there's no observer on tab-selection change that fires `revealInSidebar`, and no per-state "follow mode" flag. The reveal happens today only on explicit user action (open/click), not on tab focus switches.

**Fix/build sketch**
1. Add a `@Published var sidebarFollowsActiveTab: Bool` (the "pin" state) — conceptually the *positive* counterpart to `isSidebarLocked`. (Worth reconciling the two into one tri-state or clearly orthogonal pair to avoid a confusing "locked + pinned" combination.)
2. On tab-selection change (a sink on `tabCoordinator.tabs.selectedIndex`, or in `selectTab(at:)`), if pinned, call `revealInSidebar(currentURL)`.
3. Pin toggle button in the Files panel header next to the existing lock button (`SidebarView.swift:478-494`).

**Size: S** (≈half a day). All primitives exist; it's a flag + a hook + a button.

**Dependencies** — none to build it. **Per-session question:** is "pinned" a per-session preference or global? Design `§1.4` would lean global-ish (a UI behavior), but it's genuinely project-shaped (you pin in a code-review session, not a notes session). If you want it per-session it rides on session independence; global it can ship now.

**Risk** — minor: auto-reveal that *re-roots* the sidebar on every tab switch (the `needsRoot` branch, `DocumentModel.swift:400-413`) can be jarring when tabs span multiple roots. Pin should probably only *select+expand within the current root* and not re-root (i.e. behave like locked-for-root, follow-for-selection). One-way-door: none.

---

### Session TYPES (Project / Code Review / Pipeline-CICD / Metrics-Prod presets)

**Status today** — does not exist. Sessions are untyped: `SessionSnapshot`/`SessionIndex.Entry` carry only `id`/`rootPath`/`displayName`/timestamps + tab/sidebar payload (`SessionSnapshot.swift:28-58`, `:116-131`). Panel layout is **global UserDefaults**, not per-session, so there's nowhere for a "type" to express a default tool-window set.

**Root cause / gap** — no `sessionType` field, and (more fundamentally) no per-session panel-layout storage for a type to seed. A "type" abstraction is *meaningless* until panel/tool-window state is per-session.

**Fix/build sketch**
1. **`SessionType` enum** in `ViewerCore` (e.g. `project`, `codeReview`, `pipeline`, `metrics`), each mapping to a *default* `PanelEdgeAssignment` + `PanelVisibilityOverrides` + initial tab/layout (e.g. Code Review → Git + Claude + Problems panels shown, diff-first; Pipeline → logs/CI-oriented; Metrics → SQLite/CSV-oriented).
2. Add **optional** `sessionType: String?` to `SessionSnapshot` (additive, forward-compat).
3. On session create, seed the session's **per-session** `PanelLayoutStore` from the type's defaults (user can then diverge; divergence persists per-session).
4. UI: type picker on the `+`/new-session flow; a badge in `SessionTabBar`.

This is essentially "Workspaces with presets" — note `DESIGN.md §13` already has a Phase 8.5 "Workspaces" L-item; session types are the preset layer on top.

**Size: M** for the type→default-layout mapping + picker UI + schema field **on top of** session independence. **L** if you (incorrectly) try to build it before per-session panel state — you'd have to build that first.

**Dependencies** — **hard-blocked on two things:** (a) session independence (R1–R3) so each session has its own state, and specifically (b) **per-session panel-layout storage**, which today does not exist (it's global UserDefaults — `PanelLayoutStore.swift:42-46`). A type can't set "different default tool windows per type" if panel layout is one global blob.

**Risk / one-way-door** — schema: `sessionType` must be additive-optional (same downgrade-guard concern as above). Product risk: presets that *re-seed* layout on every open vs. *seed-once-then-respect-user-edits* — pick seed-once (store the resolved per-session layout, treat type as the initializer, not a live override) or users lose their tweaks.

---

## Cross-cutting: what session-state modeling makes trivial vs. blocked

```
                          session independence (R1–R3, per-session PanelLayoutStore)
                                              │
        ┌─────────────────────────────────────┼──────────────────────────────────┐
        │                                      │                                  │
   Recently-Opened panel              Pin / follow button                 Session TYPES
   - GLOBAL version: trivial NOW (S)  - GLOBAL version: trivial NOW (S)   - HARD BLOCKED.
     (panel framework exists)           (reveal + lock already built)       Needs per-session panel
   - PER-SESSION (root-filtered):     - PER-SESSION pin pref:               state to even be meaningful.
     trivial AFTER (just filter)        rides on session independence       Then M.
```

**The single highest-leverage decision:** whether per-session **tool-window / panel-layout state** becomes a real per-session `PanelLayoutStore` (vs. staying global UserDefaults).
- Do it as part of R2/R3 → **session types become a clean M** (just a default-layout map), per-session recents filtering is a one-liner, and per-session pin is free.
- Skip it / leave panel layout global → **session types are blocked** (nothing for a type to vary), and the whole "each session = its own little app" promise (`§3.3` reason 2) is unmet.

**Two latent gaps to fix while you're in there** (both are in `SessionState.makeSnapshot`, `SessionState.swift:121-123`): `sidebarExpandedPaths`, `sidebarIncludeHidden`, and `splitURL` are hard-coded `nil` despite having schema slots — sidebar expansion and split currently *do not* survive a session switch. Folding those into the per-session sidebar snapshot is part of the same R2 work.

**Doc/decision conflict to resolve before R3:** `SessionSnapshot` persists `zoom`/`wordWrap`/`themeOverride` per-session (`SessionSnapshot.swift:56-58`) but `§1.4` rules them **global**. Pick one (global, or per-session-override-with-global-fallback) — it changes whether those fields stay in the snapshot.

**Files that anchor the work:** `Sources/ViewerUI/Sessions/SessionsAppCoordinator.swift` (the façade to dismantle), `Sources/ViewerUI/Sessions/SessionState.swift` (R2 target), `Sources/ViewerUI/DocumentModel.swift` (the 31-`@Published`, 2731-line god object to split, `§3.4`), `Sources/ViewerCore/Sessions/SessionSnapshot.swift` (schema — one-way door), `Sources/ViewerUI/PanelLayoutStore.swift` + `Sources/ViewerCore/PanelEdge.swift` + `PanelVisibilityOverrides.swift` (global→per-session pivot for types), `Sources/ViewerCore/SidebarPanelKind.swift` (add `recentlyOpened`), `Sources/ViewerUI/DocumentModel.swift:395-438` (reveal+lock primitives for the pin button). Full intended architecture: `docs/SESSIONS_DESIGN.md §1, §3.3–3.5, §4.7`.