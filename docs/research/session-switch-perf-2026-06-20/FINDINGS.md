# Session-switch latency — spike findings + ranked proposals (TSK-1040)

**Date:** 2026-06-20 · **Type:** SPIKE (read-only audit + report; NO production
code changed) · **Author:** `claude-mdv`

> Measure-don't-guess discipline (CLAUDE.md / `docs/PERFORMANCE_PROFILING.md`):
> this report **audits the code path factually**, then forms **ranked
> hypotheses** about where the cost lands per bucket, then proposes the
> **measurement plan** (signpost points + VM capture recipe) to confirm. The
> VM lane could not be run in this session, so every quantitative cost is
> labelled **hypothesis** or **needs-measurement** unless it cites a
> prior-measured result (TSK-598/889). Architectural facts (what executes, in
> what order, sync/async, which thread) are labelled **grounded** with
> `file:line`.

A concurrent agent is editing this exact path — `DocumentModel.swift`,
`Coordinators/EditorCoordinator.swift`, and a session test were uncommitted
during this audit. All line numbers below are against the **committed** tree
(HEAD `a10669de`); confirm offsets before acting.

---

## TL;DR — the headline

**The TSK-108/621 WebView pane-retention (`MountedPanesLRU`) is DEFEATED by a
session switch.** Pane retention is keyed by `Tab.id` (a `UUID` minted at tab
creation) and lives on the **single shared `DocumentModel`**. A session switch
calls `model.closeAllTabsPreservingDirty()` which closes *every* outgoing tab
-> `MountedPanesLRU.retainOnly(openIDs)` drops *all* retained panes, then
rebuilds the incoming session's tabs via `appendLazyTab` with **brand-new
`Tab.id`s** (the persisted `TabSnapshot` stores the file *path*, not the id).
So the incoming focused tab's WKWebView (rendered-Markdown **or** CM6 editor)
is built **from scratch** and re-pays the full WebKit first-open cost that
TSK-598 measured as **~94% of a rendered-Markdown open** (`loadHTMLString` ->
`didFinish`). The "instant tab switch" win does **not** extend across session
switches — by construction. **This is the single biggest felt cost and the
top-ranked fix.** (Grounded: see step 2 + 6 below.)

---

## The switch sequence (grounded, end-to-end)

Two entry points reach the same façade swap. The common case — clicking a
different session pill — is `activate(id:)`.

```
User clicks session pill  (or Cmd-}/Cmd-{, or "Open in New Session")
  |
  v
SessionsAppCoordinator.activate(id:)                         [coordinator]
  +- core.activate(id:)   SessionsCoordinator.activate       SessionsCoordinator.swift:262
       +- guard activeID != id                               (no-op if same)  :263
       +- touched(outgoing) + touched(incoming)  LRU bumps   :273-283  (value copies)
       +- activeID = id                                      :284
       +- lifecycle?.detach(prev)  --+                       :265
       +- lifecycle?.mount(nowActive)|                       :285
       +- persist()  -- enqueue snapshot+index writes (async, off-main)  :286
                       |
   +-------------------+  (LifecycleBridge, SessionsAppCoordinator.swift:687)
   v
A. detach(prev)                                              SessionsAppCoordinator.swift:714
   +- disarmAutosave()           drop Combine subs + timer   :727
   +- active.model.captureScrollForActiveTab()               :731   (main thread)
   +- active.model.captureUnsavedTextForAllTabs()            :734   (main thread, reads buffers)
   +- snap = active.makeSnapshot()   SessionState.makeSnapshot  :735 -> SessionState.swift:136
   |     +- dedupedSnapshotTabs(...) linear over live tabs   SessionState.swift:147
   |     +- sidebar.expanded.map{ }.sorted()                 SessionState.swift:154
   |     +- panelLayout.snapshot()                           SessionState.swift:192
   +- core.replaceSnapshot(id, snap) -> persist() (async I/O) :737
   +- active.detach()  -> model.pauseFileWatcher()            :738 -> DocumentModel.swift:6239
                                       (fileWatcher.stop(); nil out)

B. mount(nowActive)                                          SessionsAppCoordinator.swift:692
   +- owner.active != nil  =>  switchSessionFaçade(to: snap) :710 -> :639
        +- active?.detach()   (idempotent; already detached) :640
        +- model.closeAllTabsPreservingDirty()               :654 -> DocumentModel.swift:6349
        |     +- captureUnsavedTextForAllTabs()  (again)     :6356
        |     +- while tabs not empty: closeTabUnconditionally(at:0)  :6357-6360
        |           per tab: capture scroll, tabCoordinator.closeTab (6 per-tab dict cleanups),
        |           purgeCaches (highlight actor + rendered-HTML drop),
        |           settleSelectionAfterClose -> materializeIfNeeded + refreshDiskState,
        |           updateDerived(), startWatchingCurrentFile()
        |     =>  noteActiveTabForRetention -> mountedPanes.retainOnly({}) DROPS EVERY PANE
        +- state = SessionState(... model: model)  (same shared model)  :661
        +- state.hydrate(from: snap)                         :677 -> SessionState.swift:274
        |     +- sidebar.setRoot(url)  if root changed:      SessionState.swift:291 -> SidebarModel.swift:229
        |     |     expanded.removeAll; clearCache; invalidateDescendantsCache;
        |     |     folderWatcher.stop()+nil; ClaudeLogParser.hasTranscripts (FS);
        |     |     GitClient.discoverRoot (shells/FS walk); ensureLoaded(root) (readdir);
        |     |     new FolderWatcher (FSEvents stream)
        |     +- panelLayout.apply(...)  (always — façade-leak reset)   SessionState.swift:315
        |     +- for each persisted tab: appendLazyTab(url:...)         SessionState.swift:401-415
        |     |       NEW Tab.id each; state .empty (no file read)
        |     +- for each expandedPath: toggleExpansion(url)            SessionState.swift:422-430
        |     |       lazily readdir's EACH expanded dir (FS, main thread)
        |     +- openInSplit / closeSplit  (façade-leak reset)          SessionState.swift:437-442
        |     +- selectTab(at: liveIndex)  for the persisted selection  SessionState.swift:459
        |           -> DocumentModel.swift:6540
        |           +- materializeIfNeeded(at:)  detached read of FOCUSED file  :6548
        |           +- updateDerived()  refreshDiffMarks/Folds/repoFocus/LSP warm  :6549
        |           +- startWatchingCurrentFile()                       :6550
        |           +- refreshDiskStateForActiveTab() + maybe reload    :6553-6564
        |           +- restoreScroll(forTabAt:)                         :6572
        +- state.mount() -> model.resumeFileWatcher()         :679
        +- active = state    @Published — SwiftUI invalidation :680
        +- bindActiveToPrimaryWindow()                       :681
        +- armAutosave(for: state)  rebuild 5 Combine subs + 30s timer  :682
                                       |
   The `active = state` publish + the tab-list mutation re-body ContentView.content,
   which mounts a FRESH WKWebView for the focused tab (make+load+didFinish).
```

**Critical grounded facts:**

1. **No disk read of the incoming session happens on switch.** `activate(id:)`
   serves the incoming `SessionSnapshot` from the **in-memory** `sessions:
   [SessionSnapshot]` array (`SessionsCoordinator.swift:69-72`, populated once
   at launch by `restore()`). `SessionStore.load(id:)` (the `index.json` +
   `<uuid>.json` reads) runs **only at launch**, not on switch. So the
   "disk reads" bucket for *the session blob itself* is **near-zero on switch**
   — grounded. (The per-file content reads that *do* happen are
   `materializeIfNeeded` of the focused tab and the sidebar's per-dir
   `readdir`s — see buckets below.)

2. **Pane retention cannot survive the switch.** `MountedPanesLRU` is
   `@Published ... capacity: 4` on the shared `DocumentModel`
   (`DocumentModel.swift:121`), keyed by `Tab.id`. `closeAllTabsPreservingDirty`
   removes every outgoing tab; `noteActiveTabForRetention`'s
   `retainOnly(openIDs)` (`DocumentModel.swift:7118-7123`) drops them all;
   incoming tabs get fresh UUIDs (`appendLazyTab`, `DocumentModel.swift:6616`).
   The retained-WebView fast path (`MarkdownRenderedView.updateNSView`'s
   `coord.lastHTML != html` reload-gate, `MarkdownRenderedView.swift:236`) is
   irrelevant because the WebView is *newly made*, not updated. **Grounded.**

3. **The whole switch runs on the main actor** (`@MainActor` on both
   coordinators + `DocumentModel`). The only off-main work is the *file content*
   read inside `materializeIfNeeded` (detached Task, `DocumentModel.swift:6715`)
   and the async persistence writes (`SessionStore.writeQueue`,
   `.utility`). Everything else — tab teardown, hydrate, sidebar `setRoot`,
   `toggleExpansion` readdirs, `makeSnapshot`, Combine re-subscribe — is **on
   the main thread**, so it directly costs frame time. **Grounded.**

4. **`makeSnapshot` runs twice on the way out** (detach-time at
   `SessionsAppCoordinator.swift:735`, and the autosave baseline seed in
   `armAutosave` for the *incoming*), and `captureUnsavedTextForAllTabs()` runs
   **three times** across detach + `closeAllTabsPreservingDirty`
   (`SessionsAppCoordinator.swift:734`, `DocumentModel.swift:6356`, and inside
   the per-tab close path). Each capture walks every tab and may read the editor
   buffer. Idempotent + equality-guarded, but not free. **Grounded**
   (redundancy); **hypothesis** that it's a measurable fraction (likely small
   unless buffers are large).

---

## Cost-attribution table

Legend: **G** = grounded fact · **H** = hypothesis (grounded in code, not yet
measured) · **M** = needs measurement to size. "Est. impact" is the author's
**ranked guess** of felt-latency contribution, *pending VM signpost confirmation*.

| Bucket | What happens on switch | G/H/M | Est. felt impact | How to measure |
|---|---|---|---|---|
| **Re-render** | **Incoming focused tab rebuilds its WKWebView from scratch** (rendered-MD `loadHTMLString`->`didFinish`, or CM6 `loadFileURL(codemirror.html)` bootstrap + JS `ready` handshake + first `cmDispatch`). Retention defeated (fact #2). TSK-598 measured WKWebView load = **~94%** of a rendered-MD open. | **G** path, **H** dominance on switch | **#1 — dominant** | `WKWebView.loadToFinish` signpost already exists (`MarkdownRenderedView.swift:262`). Add a `session.switch` interval (below) and read the ratio in a `vm-profile.sh reopen` trace. |
| **Re-render** | ContentView re-bodies on `active = state` publish + tab-list mutation; `ZStack`/`ForEach` over `mountedTabs` re-evaluates (`ContentView.swift:582`). SwiftUI diff + CA commit. | **G** | Moderate (rides on #1's CA commit) | Time Profiler samples immediately after the `session.switch` anchor interval. |
| **Re-render** | Highlight re-tokenize for the focused source/editor tab (cold per-tab `HighlightCacheActor` — closed tab dropped its actor in `purgeCaches`). `ts.query-compile` is the cold cost. | **H** | Moderate (source/editor tabs only) | `highlight` signposts already wired (`TreeSitterEngine.tokenize`); cold compile shows only on first-touch. |
| **Disk reads** | Incoming **session blob**: **0 reads on switch** — served from memory (fact #1). | **G** | Negligible | Confirm by tracing: no `JSONFileStore.read` in the switch. |
| **Disk reads** | Incoming **focused file** content read: `materializeIfNeeded` detached read (`DocumentModel.swift:6715`). Off-main. | **G** | Low-moderate (off-main; size-dependent) | `materialize` signpost exists. |
| **Disk reads** | Sidebar `setRoot` -> `ensureLoaded(root)` readdir + `GitClient.discoverRoot` (FS walk / `git`) + `ClaudeLogParser.hasTranscripts` (FS) — **main thread** (`SidebarModel.swift:249-255`). Only when the incoming root differs. | **G** thread, **H** cost | Low-moderate (root-change only) | New `switch.setRoot` signpost. `discoverRoot` is the suspect. |
| **Disk reads** | `toggleExpansion(url)` per persisted expanded path — each `readdir`s that dir on the **main thread** (`SessionState.swift:422-430`). Scales with how many dirs the user had expanded. | **G** thread, **H** cost | Low (usually few dirs); spikes for deep trees | New `switch.hydrate.expand` signpost. |
| **Model reorg** | Tab teardown: `closeAllTabsPreservingDirty` loops `closeTabUnconditionally` per outgoing tab — each does 6 per-tab dict cleanups, `purgeCaches` (drop highlight actor + rendered-HTML), `settleSelectionAfterClose`, `updateDerived`, `startWatchingCurrentFile`. **O(outgoing tabs)** with non-trivial per-tab constant. | **G** | Moderate (scales with outgoing tab count) | New `switch.drain` interval. |
| **Model reorg** | `settleSelectionAfterClose` inside the drain may **materialize a transient survivor** mid-teardown (a focused file read for a tab about to be closed too) — wasted work. | **H** | Low-moderate (wasted reads) | Count `materialize` intervals during a switch trace — >1 => transient waste. |
| **Model reorg** | `updateDerived()` fires on every per-tab close AND on the incoming `selectTab`: `refreshDiffMarks` (git diff, off-main), `refreshEditorFolds`, `repoFocus.recompute`, `warmLSPForCurrentFile` (may **spawn sourcekit-lsp**), `reapClosedLSPFiles`, `noteActiveTabForRetention` (`DocumentModel.swift:7064-7107`). Called **N+1 times** per switch. | **G** call-count, **H** cost | Moderate (LSP warm + git diff are the suspects) | New `switch.updateDerived` count; git/LSP have their own logging. |
| **Model reorg** | Autosave Combine teardown+rebuild: `disarmAutosave` drops 5 subs + invalidates timer; `armAutosave` rebuilds `Publishers.MergeMany([5])` + a new 30s `Timer`, and each `@Published` re-emits on subscribe -> initial volley of `scheduleAutosave` ticks (equality-guarded to no-ops). | **G** | Low | New `switch.armAutosave` interval; count autosave ticks post-arm. |
| **Memory** | New `SessionState` per switch (`switchSessionFaçade:661`) — cheap. Highlight actors for closed tabs freed; rendered-HTML cache purged; **new** WebView allocated (the costly one — process attach / JS heap). `MountedPanesLRU` churns (drop-all then grow-to-1). | **G** | Memory: low churn; the WebView *re-attach* is the real cost (it's the re-render bucket). | `Allocations` template alongside signposts. |
| **Memory** | `makeSnapshot` x2 + `captureUnsavedTextForAllTabs` x3 allocate transient `[TabSnapshot]` / buffer copies. Idempotent but redundant. | **G** redundancy, **H** cost | Low (unless huge unsaved buffers) | Allocations spike correlated to `switch.drain`. |

---

## Ranked proposals (biggest felt win first)

Effort = rough; Win = expected felt-latency reduction (**pending VM confirmation**);
Risk = regression surface.

### P1 — Survive WebView retention across a session switch (the headline)
**Win: large (targets the ~94% WebView-load cost).** Effort: M-L. Risk: M.

Today retention dies because (a) the shared `DocumentModel` drains all tabs and
(b) incoming tabs get fresh `Tab.id`s. Three sub-approaches, increasing ambition:

- **P1a — Stable per-(session,path) tab identity.** Make restored tabs reuse a
  **deterministic id** from `(sessionID, resolved path)` instead of a random
  UUID, so a switch *back* re-keys the same `Tab.id` and a retained pane (if
  still in the LRU) matches. Necessary but not sufficient without P1b/P1c (the
  LRU lives on the one model that gets drained — the panes are already gone).
- **P1b — Per-session `DocumentModel` (the documented Phase-2 seam).** The
  cleanest path: `SessionsAppCoordinator` docs lines 12-23 already anticipate
  "Phase 2 will hold a dictionary keyed by session UUID". With one model per
  session, a switch is a *view re-bind* to a different model whose WebViews
  never unmounted — the TSK-108 win lifted to the session level. **Right
  long-term fix**, bounded by an existing seam. Effort: L.
- **P1c — App-level warm-WebView LRU above the model.** Lighter: cache the
  *focused* pane's WKWebView for ~2-3 recent sessions and re-parent on
  switch-back rather than rebuild. Effort: M. Risk: M (re-parenting +
  first-responder / find-bar wiring across sessions).

**Recommendation:** confirm with P1's measurement first (is the rebuilt WebView
actually the dominant interval? — fact #2 says it should be). If yes, P1b is the
durable fix; P1c is the interim win if Phase-2 is too big a slice now. **File
P1b as the epic; P1c as the interim ticket.**

### P2 — Move hydrate work off the synchronous switch
**Win: moderate.** Effort: S-M. Risk: L-M.

- Move `GitClient.discoverRoot` + `ClaudeLogParser.hasTranscripts` off the
  **main thread** in `setRoot` (`SidebarModel.swift:249-252`) — FS/`git` on the
  critical path for chrome that isn't first-frame.
- Defer the `toggleExpansion` readdir storm (`SessionState.swift:422-430`):
  restore expansion **after** first paint (a `Task { }` hop) or batch readdirs
  off-main.
- Batch the `updateDerived()` storm during the drain: each per-tab
  `closeTabUnconditionally` calls `updateDerived` (-> `warmLSPForCurrentFile`,
  `refreshDiffMarks`). During a bulk drain only the final state matters — run
  `updateDerived` once at the end of `closeAllTabsPreservingDirty`. **Caution:
  the concurrent agent is editing this exact method — coordinate.**

### P3 — Eliminate the transient-survivor materialize during teardown
**Win: low-moderate (kills a wasted file read).** Effort: S. Risk: L.

`settleSelectionAfterClose` (`DocumentModel.swift:6371`) runs inside each
`closeTabUnconditionally`, so the drain may `materializeIfNeeded` a survivor
that's itself about to close. During a full session drain, suppress that
materialize (the incoming `selectTab` materializes the real focused tab).
Confirm via the trace (expect exactly 1 `materialize` per switch).

### P4 — De-duplicate snapshot/capture work
**Win: low.** Effort: S. Risk: L.

`captureUnsavedTextForAllTabs` x3 and `makeSnapshot` x2 per switch (fact #4).
Collapse the back-to-back detach + drain captures. Equality-guarded, so a
constant-factor cleanup — only worth it if the trace shows it's non-trivial
(likely only with large unsaved buffers). **Lowest priority.**

---

## Measurement plan (confirm before fixing)

The facility (`PerfSignpost`, `MDV_SIGNPOSTS=1`,
`docs/PERFORMANCE_PROFILING.md`) already instruments open/load/materialize/
highlight/render. The switch path is **under-instrumented** — it has
`materialize`, `WKWebView.loadToFinish`, and `highlight`/`render`, but **no
interval bounding the switch itself**. Proposed **new signpost intervals** (NOT
committed in this spike — proposed only):

| Stage (category) | Proposed interval | Where to add | Bounds |
|---|---|---|---|
| `interact` | `session.switch` | `switchSessionFaçade` (begin :640, end :682) | whole synchronous switch — umbrella anchor |
| `interact` | `switch.drain` | around `closeAllTabsPreservingDirty()` :654 | tab teardown (model-reorg) |
| `interact` | `switch.hydrate` | around `state.hydrate(from: snap)` :677 | incoming reorg + readdirs |
| `interact` | `switch.hydrate.expand` | around the `toggleExpansion` loop, `SessionState.swift:422-430` | the readdir storm (disk) |
| `interact` | `switch.setRoot` | around `model.sidebar.setRoot`, `SessionState.swift:291` | git-root + transcript FS (disk) |
| `interact` | `switch.select` | around `selectTab` via hydrate :459 | focused-tab select path |
| `interact` | `switch.armAutosave` | around `armAutosave(for:)` :682 | Combine re-subscribe cost |

The dominant proof point: with `session.switch` as the umbrella and
`WKWebView.loadToFinish` already present, the trace shows directly **what
fraction of the switch is the rebuilt WebView** (validates fact #2 / P1).

**Capture recipe (VM only — UI-opening, per CLAUDE.md):**

`vm-profile.sh`'s existing **`reopen`** mode (`PERFORMANCE_PROFILING.md` §Trace
modes) cold-opens, switches away, switches back — it exercises the same
`switchSessionFaçade`. Recipe:

```bash
# Host: build the release bundle with signposts available.
bash scripts/build-rust-core.sh
bash scripts/build-app.sh                       # -> dist/TextView.app

# VM lane (UTM; UI-opening captures run on the VM, never host).
# rsync the tree, then on macOS15 — ensure dist/ is FRESH (stale-dist trap,
# LESSONS.md: the profile spawns dist/; a stale app = false numbers):
ssh macOS15 'cd markdown_viewer && bash scripts/vm-profile.sh \
  /path/to/two-session-fixture/fileA.md 8 reopen release'

# Open the .trace in Instruments, os_signpost lane,
# subsystem com.markdownviewer.MarkdownViewer:
#   - read `interact | session.switch` vs `render | WKWebView.loadToFinish`
#   - check `materialize` interval count (>1 => P3 transient-survivor waste)
#   - check `highlight | ts.query-compile` presence (cold re-tokenize)
# Append `debug` as the config arg for symbolicated stacks within a hot phase.
```

Two fixtures matter: a **rendered-Markdown** focused tab and a **CM6 editor**
focused tab — different WebView bootstrap paths (`loadHTMLString` vs
`loadFileURL(codemirror.html)` + `ready` handshake) — measure both.

**Manual cross-check (host, no UI test):** the `MountProbe` counters
(`MountProbe.webViewMakes` / `webViewDismantles`, bumped in both
`make/dismantleNSView`, DEBUG-only) directly prove fact #2 — a switch that
defeats retention shows `webViewMakes` incrementing per switch. A headless
behaviour test could assert this without the VM (drive the model-level switch,
read the probe), giving teeth to any P1 fix on the host gate.

---

## What's grounded vs hypothesis vs needs-measurement (summary)

- **Grounded (read from code):** the switch sequence + ordering; incoming
  session blob served from memory (0 disk reads on switch); retention keyed by
  `Tab.id` and structurally defeated by drain + fresh-UUID rebuild; the switch
  runs on the main actor except the detached focused-file read + async writes;
  redundant capture/snapshot counts; sidebar `setRoot` git/transcript FS work
  and the `toggleExpansion` readdirs are on the main thread.
- **Hypothesis (grounded in code, not yet measured):** the rebuilt WebView load
  dominates felt switch latency (strongly implied by TSK-598's ~94% + fact #2,
  but the *switch* ratio is unmeasured); the `updateDerived` storm (LSP warm /
  git diff) is the #2 cost; relative sizing of the disk sub-costs.
- **Needs-measurement (VM):** absolute switch latency, per-phase breakdown,
  WebView-load fraction of the switch, transient-survivor materialize count,
  cold re-tokenize cost. **All blocked on the VM lane** (could not run this
  session). The signpost points above are the plan to get those numbers.

---

## Cross-references

- `docs/PERFORMANCE_PROFILING.md` — signpost facility, trace modes (`reopen`),
  `vm-profile.sh` recipe.
- TSK-598 — rendered-MD open ~= 94% WKWebView load (the cost P1 re-pays).
- TSK-108 / TSK-621 — `MountedPanesLRU` pane retention (the win the switch
  defeats); `docs/research/perf-fix1-view-retention.md`.
- TSK-889 / TSK-961 — `reopen` mode; warm re-display is *not* a cheap reselect.
- Phase-2 per-session `DocumentModel` (the documented seam for P1b) —
  `SessionsAppCoordinator.swift:12-23`, `SessionState.swift:45-47`.
