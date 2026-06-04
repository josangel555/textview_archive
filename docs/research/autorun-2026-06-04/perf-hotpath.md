I have a complete and confident picture. The `confirmCloseIfDirty` is O(1) for clean tabs (no modal). The ~1s close is not a synchronous modal — it's the re-body cascade plus WebView teardown/re-mount of the newly-focused tab. Here is the report.

---

# DocumentModel hot-path profiling: tab SWITCH / CLOSE / OPEN

**Scope:** `Sources/ViewerUI/DocumentModel.swift` (+ `GitClient`, `RepoFocusTracker`, `ContentView`, `CodeMirrorEditorView`, `MarkdownRenderedView`). All three paths funnel through `updateDerived()` (`:3987`), which is the central re-publish + side-effect fan-out.

## The shared architecture (read this first — it explains all three symptoms)

- `model.tabs` is **computed** off `tabCoordinator.tabs` (`:60`), a `@Published` on `TabCoordinator`. **ContentView does NOT observe `tabCoordinator`** — it observes only `model`, `sidebar`, `find`, `panelLayout`, `terminalPane` (`ContentView.swift:7–33`). PERF #1 deliberately severed coordinator→model `objectWillChange` forwarding.
- Consequence: a bare `tabCoordinator.select`/`replace` does **not** re-body the content tree. So every switch/close/open path **must** call `updateDerived()` to force a republish — and `updateDerived` does so via its unconditional `windowTitle = …` `@Published` write (`:3988`) plus `sourceDiffMarks` writes. **That single republish re-evaluates the entire `ContentView.body`** including all always-on chrome (rails, status bar, mode bar, tab bar) and `loadedView`.
- `loadedView` (`ContentView.swift:490`) branches on `model.currentViewMode` with `if/else if`. **Switching tabs in the same mode keeps the same structural branch** → the WebView is reused, `updateNSView` diffs state (deduped by `lastSent*`). **Switching MODE changes the branch** → SwiftUI dismantles one WebView and `makeNSView`s the other (full JS bootstrap + reload). The content pane is **not** `.id()`-keyed per tab (only the large-editor placeholder is, `:510`), so tab switches do not force a remount. This is the one thing the code gets right.

## Per-path cost breakdown

### TAB SWITCH — `selectTab(at:)` `:3505`

| # | Suspect | file:line | Sync on main? | Triggers full republish? | Est. cost |
|---|---------|-----------|---------------|--------------------------|-----------|
| 1 | **`updateDerived()` → full `objectWillChange`** | `:3514`, `:3987` | yes | **yes (this IS the republish)** | re-body entire ContentView tree; dominant if content view is a WebView re-`updateNSView` |
| 2 | `refreshDiffMarks()` (git diff) | `:3996`→`:1046` | **spawn is async** (Task.detached, 150 ms debounce, 3 s cap) | only on completion, and only if `currentURL` unchanged-guarded | git process ~20–150 ms, **off-main**; main cost ≈0 |
| 3 | `repoFocus.recompute()` | `:4004`→RepoFocusTracker `:135` | gather is sync, store work is async `Task` | no (own `trackedRepos.version` channel) | sync part is `gatherDesiredSet` (array build + set diff) — cheap; **equality-guarded no-op within one repo** |
| 4 | `warmLSPForCurrentFile()` | `:4015`→`:4041` | spawns `Task`; deduped by `lastWarmedLSPURL` | no | main cost ≈0 (just a string copy + Task spawn); no-op for md/txt |
| 5 | `materializeIfNeeded(at:)` | `:3513`→`:3636` | file read is `Task.detached`; **completion calls `updateDerived()` again** | yes, on completion | a **second** full republish when a lazy tab lands |
| 6 | `captureScroll` + `restoreScroll` | `:3510`/`:3527`→`:1353`/`:1374` | yes | `captureScroll` does `tabCoordinator.replace` (no model republish on its own) | cheap; reads one Int from the source channel |
| 7 | `refreshDiskStateForActiveTab()` | `:3519`→`:3186` | **yes — synchronous `FileManager.fileExists` + `attributesOfItem`** | only via `setDiskState`→`objectWillChange.send()` **if state changed** (`:3233`) | 2 sync `stat`s on main; ~sub-ms local, **tens of ms on a network/slow volume** |
| 8 | `followActiveTabIfNeeded()` | `:3522`→`:476` | yes | mutates `sidebar` (separate observation) | path-split + per-segment `isExpanded`/`toggleExpansion`; cheap unless deep tree |
| 9 | `startWatchingCurrentFile()` | `:3515`→`:3258` | yes — `fileExists` + `FileWatcher` init (opens an FSEvents/kqueue fd) | no | idempotent if same URL; otherwise one syscall + fd setup |

**Switch verdict:** the switch itself is cheap *except* the `updateDerived()` full republish (#1). If the destination tab renders through a **WebView** (markdown `.rendered` or `.editor`), the republish forces `updateNSView`; that's deduped, so it's cheap **if state is identical**, but the republish re-evaluates ContentView's *entire* body (rails, status bar, all chrome) every time. Switching tabs of *different modes* (#1 + branch change) additionally tears down + remounts a WebView. The synchronous `stat`s (#7) are the only main-thread I/O.

### TAB CLOSE — `closeTab(at:)` `:3308` → `purgeCaches` `:3440`

| # | Suspect | file:line | Sync on main? | Republish? | Est. cost |
|---|---------|-----------|---------------|------------|-----------|
| 1 | `confirmCloseIfDirty(at:)` | `:3314`→`:2036` | yes | no | **O(1) for a clean tab** — no modal, no text compare (`EditorCoordinator.swift:238,252`). Not the culprit. |
| 2 | `purgeCaches` rebuilds `renderedHTMLCache` | `:3448` | yes | no | `.filter` rebuilds the whole dict + order list each close; cache cap is only 4 → negligible |
| 3 | `purgeCaches` hosted-view + LSP-diag sweep | `:3465`, `:3482` | yes | no | linear over surviving tabs; cheap |
| 4 | **`updateDerived()`** | `:3347` | yes | **yes — full republish** | re-bodies ContentView; **the newly-focused tab's content view mounts** → if it's a WebView, **`makeNSView` + JS bootstrap + `loadHTMLString`/`loadFileURL`** |
| 5 | WebView **dismantle** of the closed tab | (SwiftUI, `dismantleNSView`) | yes (on the run loop) | — | removeScriptMessageHandler + WKWebView teardown; WebContent process churn |
| 6 | `startWatchingCurrentFile()` | `:3348` | yes | no | rebinds FileWatcher to the new current URL |

**Close verdict — the ~1s:** closing the active tab does two expensive things back-to-back on the main actor: (a) **dismantles the closing tab's WKWebView** and (b) `updateDerived()` republishes, which **mounts the now-focused neighbor tab's content view from scratch** — a fresh `makeNSView` + CodeMirror/markdown WKWebView bootstrap (load the bundled HTML, wait for `ready`, then push text). A cold WKWebView mount + JS bootstrap is exactly the ~0.3–1 s range, especially if the WebContent process has to spin up. This is *not* a git/LSP/modal stall — it's **WebView remount of the revealed tab**, plus the full-tree republish amplifying it. (Background tabs are lazy/`.empty`, so the revealed tab may *also* trigger `materializeIfNeeded`→file read→a **second** `updateDerived` republish, `:3699`.)

### OPEN — `openResolved` `:2835` → `materializeIfNeeded` `:3636`

| # | Suspect | file:line | Sync on main? | Republish? | Est. cost |
|---|---------|-----------|---------------|------------|-----------|
| 1 | `controller.open(url:)` synchronous read | `:2893` | **yes for files ≤ softWarnBytes** | — | full file read + encoding detect **on main** for small/medium files; large files defer off-main (`:2888`) |
| 2 | `shouldDeferOpenOffMain` stat | `:2934`→`:2941` | yes | no | one `attributesOfItem` syscall |
| 3 | **`updateDerived()`** | `:2920` | yes | **yes — full republish** | re-body + content-view mount (WebView bootstrap on first markdown/editor open) |
| 4 | `recordOpenedFile` | `:2921` | yes | writes `recents` (`@Published`) → another republish-ish | history append + persist |
| 5 | `startWatchingCurrentFile` + `followActiveTabIfNeeded` | `:2922`,`:2925` | yes | sidebar mutate | as above |
| 6 | `materializeIfNeeded` completion | `:3699` | async, hops to main | **yes — full republish on land** | second republish + WebView content push |

**Open verdict:** "delayed" open = synchronous file read on main (#1) for small files, **plus** the first WebView mount/bootstrap for markdown/editor (#3). The off-main deferral only kicks in above `loader.softWarnBytes`, so medium files still read on main.

## Root causes, ranked

1. **Every switch/close/open forces a *whole-tree* republish** (`updateDerived`'s unconditional `windowTitle` write → `DocumentModel.objectWillChange`). Because ContentView observes the god-object, one focus change re-evaluates all chrome + the content pane. This is the structural amplifier behind all three symptoms.
2. **WebView mount/teardown on close (and first open).** Closing the active tab dismantles its WKWebView and remounts the revealed neighbor's WKWebView from cold (JS bootstrap). This is the ~1s.
3. **Double republish on lazy materialize.** Switching to / opening an `.empty` tab fires `updateDerived` once immediately and again at read-completion (`:3699`), each a full-tree re-body.
4. **Synchronous main-thread `stat`s** in `refreshDiskStateForActiveTab` (`:3186`) and `startWatchingCurrentFile` — fine locally, a stall on slow/network volumes.
5. Git and LSP are **already well-behaved**: `refreshDiffMarks` is debounced+async+cancellable+timed-out; `repoFocus.recompute` is equality-guarded and offloads to a `Task`; `warmLSPForCurrentFile` is deduped + spawns. None of these block the main actor meaningfully. *(If the symptom predates the PERF #1 era, these were likely the old cause; in current code they are not.)*

## Proposed fixes, ranked by impact / risk

| Rank | Fix | Targets | Impact | Risk |
|------|-----|---------|--------|------|
| 1 | **Pool / cache WebViews per tab instead of mounting on reveal.** Keep the closing tab's neighbor WebView warm (a small LRU of `WKWebView`s keyed by tabID, or keep inactive tabs' panes alive behind a `ZStack`+`.opacity`/`.hidden` instead of tearing the branch down). Kills the cold-bootstrap on close. | Close #2, Open #2 | **High** (directly removes the ~1s) | Med — memory (WebContent ~50 MB each; bound the pool), and find/scroll state must survive |
| 2 | **Narrow ContentView observation.** Stop routing focus changes through a god-object republish: have ContentView observe `tabCoordinator` directly (like it already does `sidebar`/`find`/`panelLayout`) for `tabs`/selection, and drop `updateDerived`'s reliance on `windowTitle` as the republish trigger. Then a switch re-bodies only the content subtree, not all chrome. | Switch #1, Close #4, Open #3 | **High** | Med — must re-audit which chrome genuinely needs the tick (the PERF #1 note lists the sites); risk of a "dead toggle" like the `setCurrentViewMode` one |
| 3 | **Collapse the double republish on materialize.** Have the materialize completion (`:3699`) and the `selectTab` immediate call coalesce to a single `objectWillChange` (e.g. skip the immediate `updateDerived` for an `.empty` tab and let the completion do it). | Switch #5, Open #6 | Med-High | Low-Med |
| 4 | **Move `refreshDiskStateForActiveTab` stats off-main.** Wrap the `fileExists`/`attributesOfItem` in the same `Task.detached`+main-hop pattern as `refreshDiffMarks`; it's a *signal*, not a blocking dependency. Same for the `fileExists` in `startWatchingCurrentFile`. | Switch #7, #9 | Med (only on slow volumes) | Low |
| 5 | **Cache per-tab derived state.** `windowTitle`, disk-state baseline, resolved gutter root, relPath are recomputed every focus change. Memoize the gutter-root/relPath per (tabID, url) so `refreshDiffMarks`' `resolveGutterRoot`/`relativePath` (the `.git` walk fallback, `GitClient.discoverRoot` up to 32 levels) don't re-walk on every switch within a repo. | Switch #2 setup | Low-Med | Low |
| 6 | **Lower `softWarnBytes` / always defer the read off-main** in `openResolved`, so even medium files don't read on the main actor (`:2893`). | Open #1 | Med | Low — adds a brief `.loading` flash for medium files |

**Key correction to the brief's hypotheses:** the git-diff shell, `repoFocus.recompute`, and LSP warm are **already async/debounced/guarded** and are *not* the main-thread stall in current code. The real cost is (1) the whole-tree republish via the god-object and (2) **WKWebView teardown+cold-remount when the close reveals a neighbor tab** — fixes #1 and #2 above are where the ~1s actually lives.

Relevant locations: `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DocumentModel.swift:3987` (`updateDerived`), `:3308` (`closeTab`), `:3505` (`selectTab`), `:3636` (`materializeIfNeeded`), `:3186` (`refreshDiskState`), `:1046` (`refreshDiffMarks`); `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/ContentView.swift:490` (`loadedView` mode branch), `:7-33` (observation set); `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/CodeMirrorEditorView.swift:164` (`makeNSView`), `:196` (`dismantleNSView`); `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/Coordinators/TabCoordinator.swift:49` (`@Published tabs`).