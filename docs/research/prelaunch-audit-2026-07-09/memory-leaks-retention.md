# Pre-launch Product Review — Memory leaks, retain cycles & unbounded growth

**Dimension:** Swift retain cycles (closures/delegates/timers), WebView & subprocess
leaks, and whether the many Cache/LRU/Store classes stay bounded over a long
multi-tab / multi-session run.

**Reviewer:** automated static-analysis pass (read-only), 2026-07-09/10
**Repo:** `/Users/me/Documents/workspaces/claude/markdown_viewer`

---

## Executive summary

This dimension is in **strong shape**. The codebase carries an unusually deep
history of leak-hardening — retain-cycle fixes (`FileWatcher` FW-4 source↔handler
cycle), timer deinit backstops (`StatusBarMemorySampler` M14/TSK-989), PTY fork/reap
correctness (`PTYProcess` TSK-992/TSK-138), subprocess-tree teardown
(`PluginSubprocessHost` F-PMA-LEAK-1 process-group kill), LSP subprocess reaping
(`LSPPool.closeAll` TSK-485), and a close-path fan-out that prunes **every** per-tab
`[UUID: …]` dictionary. The WebView warm-caches (`WarmWebViewCache`,
`WarmEditorWebViewCache`) are bounded, take-once, and defend against handing out a
still-parented view. Nearly every cache I inspected has an explicit cap + LRU order
list (a recurring "S2-G" discipline note appears throughout).

I found **one genuine unbounded-growth defect** and a handful of low-severity /
informational items. The one defect (`SessionsAppCoordinator.lastPersistedContent`)
is the *same* class of bug the LSP maps carefully avoid: a side dictionary keyed by
session UUID that is written on every activate/detach/rename but **never pruned on
session close** — so each session ever activated leaks its full `SessionSnapshot`
(tab list + captured unsaved buffer text) for the life of the process.

**Findings:** 1 × P2, 3 × P3 (2 of which are documented/accepted trade-offs called
out for visibility, not defects).

---

## Methodology

Static analysis only (no window-opening tests; no full `swift test`). I read real
code via `rg`/`Read`. What I examined:

- **WebView caches:** `WarmWebViewCache.swift`, `WarmEditorWebViewCache.swift`
  (full), plus `WarmHTMLWebViewCache`, `SourceControllerCache`, `WarmWebViewCache`
  eviction. Confirmed bounded + take-once + un-parented-guard + `removeAll` teardown.
- **Timers:** all three scheduled-timer sites (`StatusBarMemory.swift`,
  `GitPanelModel.swift`, `SessionsAppCoordinator.swift`) — all `[weak self]`, one
  with a nonisolated-deinit invalidate backstop.
- **Dispatch sources / fds:** `FileWatcher.swift` (full), `PTYProcess.swift` (full).
  Verified weak source capture, cancel-handler fd close, exponential-backoff
  reattach with work-item cancellation on `stop()`.
- **Subprocesses:** `PTYProcess` (forkpty + `reapChild` poll/SIGKILL ladder),
  `PluginSubprocessHost` (process-group isolation + tree kill + pipe force-close),
  `LSPPool`/`LSPClient` (idle-reaper, concurrent `closeAll`, deinit backstop).
- **Per-tab `[UUID: …]` state:** enumerated ~30 per-tab dicts across
  `DocumentModel`, `EditorCoordinator`, `TabCoordinator`; traced every close path
  (`TabCoordinator.cleanupAfterClose`, `EditorCoordinator.resetEditorState` close
  hook, `DocumentModel.purgeCaches` live-tab sweep, `dropCanvasController`,
  `hostedViews` filter, `materializeTasks` cancel). All pruned.
- **LSP maps:** `LSPPool` `fileVersions`/`fileHashes`/`openedFiles` — verified
  `closeFile` prunes them and is wired into the tab-close path.
- **Bounded caches:** `InsertionOrderedCache`, `HighlightCacheActor` (cap 8),
  `renderedHTMLCache` (order list + tabID purge), `SidebarModel` childrenCache /
  sortedCache (LRU + 512 cap), `RepoFocusTracker.rootCache` (cap 4096),
  `ToastCenter` action/cancel-handler cleanup, `EditorCoordinator` preview memory cap.
- **Observer patterns:** grepped `addObserver(forName:` (none in ViewerCore/ViewerUI),
  `.sink` (the non-weak hits are field assignments, not Combine subscriptions).
- **Session state:** `SessionsAppCoordinator.swift`, `SessionsCoordinator.swift`,
  `SessionStore.swift`.

What I did **not** examine: see Coverage gaps below.

---

## Findings

### F1 — `SessionsAppCoordinator.lastPersistedContent` grows unbounded (never pruned on session close)

- **Severity:** P2
- **File:** `Sources/ViewerUI/Sessions/SessionsAppCoordinator.swift:101` (declaration);
  writers at lines `415`, `449`, `470`, `561`, `565`, `641`, `771`; close paths that
  fail to prune at `379` (`close(id:)`), `383` (`closeOthers(except:)`),
  `422` (`closeActive()`).
- **Evidence:**
  - `private var lastPersistedContent: [UUID: SessionSnapshot] = [:]` — an autosave
    equality-baseline map keyed by session id.
  - It is written on activate/detach/rename/seed (7 sites) but `rg -c "removeValue"
    Sources/ViewerUI/Sessions/SessionsAppCoordinator.swift` returns **0** — there is
    no `removeValue`, no `= nil`, and no reconcile-to-live-sessions sweep anywhere in
    the file.
  - `close(id:)` merely forwards: `public func close(id: UUID) { core.close(id: id) }`
    — `core.close` trashes the on-disk snapshot but the app-level in-memory
    `lastPersistedContent[id]` entry is left behind. Same for `closeOthers` and
    `closeActive`.
  - `SessionSnapshot` is not a small key — the autosave path deliberately fattens it
    right before storing: `active.model.captureUnsavedTextForAllTabs()` then
    `makeSnapshot()` (see `fireAutosave`, line ~555), so each retained value carries
    the session's full tab list **and** captured unsaved buffer text.
- **Impact:** Over a long-lived process the user opens/closes many folders
  (= sessions). Every session ever activated leaves a `SessionSnapshot` resident for
  the life of the app — including sessions the user explicitly closed (trashed). This
  is exactly the "long multi-tab session" growth the review lens targets: memory
  grows monotonically with *distinct sessions touched*, not with what's currently
  open, and each entry can be large (unsaved buffers). It is the same unbounded-map
  hazard `LSPPool.closeFile` was written to avoid (see F3) — just missed here.
- **Suggested fix:** In `close(id:)` / `closeOthers(except:)` / `closeActive()`
  (or, cleanest, a single `reconcileBaselines()` that runs after any core mutation)
  drop entries not in `core.sessions`: `lastPersistedContent.removeValue(forKey: id)`
  on close, and/or `lastPersistedContent = lastPersistedContent.filter { live.contains($0.key) }`
  keyed off the surviving `core.sessions` ids. Mirror the `DocumentModel.purgeCaches`
  live-set sweep pattern already used for `hostedViews`.
- **Fix size:** S
- **Fix risk:** safe (pure eviction of an equality-baseline cache; a re-activated
  session simply re-seeds its baseline on next detach/autosave — worst case one
  redundant write, never incorrect data).

---

### F2 — `LSPDiscovery.binaryCache` is a process-static map that never invalidates

- **Severity:** P3
- **File:** `Sources/ViewerCore/LSP/LSPDiscovery.swift:345`
- **Evidence:** `nonisolated(unsafe) private static var binaryCache: [String: URL?] = [:]`
  — a static cache of resolved LSP binary paths, keyed by binary name.
- **Impact:** Bounded in practice — the key space is the set of *distinct LSP
  executable names* (a dozen or so), so this cannot grow with user activity. The only
  real concern is *staleness*, not growth: a binary installed/removed mid-session
  (e.g. `brew install`) is never re-resolved because a resolved-nil is cached
  forever. Low severity; noted for completeness because a process-static mutable map
  is a growth/staleness smell worth a bound + TTL if the discovered-tool set ever
  becomes user-extensible.
- **Suggested fix:** Leave as-is for launch, or add an explicit `invalidate()`
  callable from a "rescan tools" action. Not worth a size/risk beyond S/safe.
- **Fix size:** S
- **Fix risk:** safe

---

### F3 — Accepted server-side LSP document leak (documented trade-off, not a defect)

- **Severity:** P3 (informational)
- **File:** `Sources/ViewerCore/LSP/LSPPool.swift:370–388`
- **Evidence:** The Swift-side `fileVersions`/`fileHashes`/`openedFiles` maps **are**
  pruned promptly via `closeFile(fileURL:)`, which is wired into the tab-close path
  (`DocumentModel.swift`: `Task { for url in closed { await pool.closeFile(fileURL: url) } }`,
  guarded by the "no surviving tab uses this URL" check). But the code deliberately
  does **not** send `textDocument/didClose` to the language server (`LSPClient`
  exposes no `didClose`), so the *server's* view of opened documents grows for the
  life of a warm pool entry.
- **Impact:** Bounded and reclaimed on idle-reap / server restart / app teardown. The
  memory lives in the child `sourcekit-lsp` process, not the app. Explicitly reasoned
  about in-code as an accepted trade-off. Listed here only so the audit record shows
  it was seen and judged acceptable — no action needed for launch.
- **Suggested fix:** none for launch; a future `textDocument/didClose` lifecycle
  feature (already noted in BACKLOG per the in-code comment) would close it.
- **Fix size:** M (protocol lifecycle work)
- **Fix risk:** careful (desyncing the server's document view is the reason it was
  deferred)

---

### F4 — `WarmWebViewCache` eviction drops a WebView without `stopLoading()` (minor)

- **Severity:** P3
- **File:** `Sources/ViewerUI/WarmWebViewCache.swift:153–160`
  (`evictBeyondCapacity`); compare `WarmEditorWebViewCache.swift:189–196`.
- **Evidence:** `stash(...)` calls `webView.stopLoading()` before parking (good), but
  the LRU **eviction** path (`evictBeyondCapacity`) just `entries.removeValue(...)`
  and relies on ARC to release the `WKWebView` and tear down its WebContent process.
  For an entry parked while a load was still in flight (or a mermaid/async render
  pending), eviction releases it without an explicit `stopLoading()`/navigation-
  delegate detach.
- **Impact:** Very low. ARC release of a `WKWebView` does tear down its process; the
  cap is 4, so at most a handful of WebViews. The theoretical concern is a WebView
  released mid-navigation holding its WebContent helper a beat longer than necessary,
  or (defensively) a navigation delegate callback firing into a torn-down coordinator
  — but `WKWebView` holds its delegate weakly and the coordinator is released with the
  entry, so no cycle. Noted as a robustness nit, not a live leak.
- **Suggested fix:** In `evictBeyondCapacity`, before dropping the entry, call
  `entry.webView.stopLoading()` and `entry.webView.navigationDelegate = nil` (mirror
  the `stash` hygiene). Apply to both warm caches.
- **Fix size:** S
- **Fix risk:** safe

---

## Positive observations

The following were checked and found **correct** — worth recording so the next audit
doesn't re-walk them:

- **Timers (all 3 sites) use `[weak self]`.** `StatusBarMemorySampler` additionally
  invalidates in a `nonisolated deinit` as an unconditional backstop (M14/TSK-989),
  with a `timerForTesting` seam proving the deinit fires — a model example.
- **`FileWatcher`** captures both `self` and the `DispatchSource` *weakly* in the
  event handler (FW-4 fixed the source↔handler↔source cycle that kept the fd alive);
  cancel handler closes the fd; `stop()` cancels the source + both pending work items;
  reattach uses capped exponential backoff and cancels prior work under one lock.
- **`PTYProcess`** reaps the child with a bounded `waitpid(WNOHANG)` poll escalating
  to `SIGKILL` (no zombies), closes the master fd exactly once in the source cancel
  handler, and `deinit` calls `terminate()` with a `static reapChild` so the dispatch
  closure captures only the pid value (safe from deinit).
- **`PluginSubprocessHost`** isolates each child in its own process group (`setpgid`)
  so a timeout `killpg`s the whole tree, and force-closes the read pipes so reader
  threads always see EOF (F-PMA-LEAK-1) — a class of grandchild-holds-the-pipe leak
  handled correctly.
- **`LSPPool.closeAll`** shuts every live client concurrently via a `TaskGroup`
  (bounded quit deadline, no reparent-to-launchd leak — TSK-485) and drains in a loop
  to catch a spawn racing teardown.
- **Every per-tab `[UUID: …]` dictionary is pruned on close.** `TabCoordinator`
  fan-out (`cleanupAfterClose`), `EditorCoordinator.resetEditorState` (9 dicts) via a
  close hook, `DocumentModel.purgeCaches` (highlight actor, renderedHTML cache +
  order list, htmlJavaScriptOptIn, source-controller cache, LSP diagnostics),
  `dropCanvasController` (with `teardown()`), a live-tab sweep for `hostedViews`, and
  `materializeTasks[id]?.cancel()`. The close-path-agnostic *live-set sweep* pattern
  (`filter { live.contains($0.key) }`) is the robust idiom — F1 is the one place it's
  missing.
- **Bounded caches everywhere:** `InsertionOrderedCache` (batch eviction to 2/3 cap),
  `HighlightCacheActor` (cap 8 + order list), `SidebarModel` (LRU + 512 sort cap),
  `RepoFocusTracker.rootCache` (cap 4096), `EditorCoordinator` preview memory cap,
  `renderedHTMLCache` order-list eviction. A consistent "S2-G" note documents the
  avoid-`Dictionary.keys.prefix(N)`-drops-the-just-inserted-entry hazard.
- **No block-based `NotificationCenter` observers** in ViewerCore/ViewerUI (the
  classic "observer token never removed" leak surface is absent).

---

## Coverage gaps (not examined / examined shallowly)

- **Rust core (`rust-core/crates/`)** — I did **not** audit Rust-side allocation,
  `Box::leak`, `Rc`/`Arc` cycles, or FFI handle leaks across the extern-C boundary
  (e.g. an FFI `*mut` handle allocated in Rust and never freed by the Swift side, or
  a windowed-snapshot buffer not released). This is a distinct and important surface
  for this lens and deserves its own pass — the `ffi` crate's handle lifecycle and
  `Sources/RustCore/` `CoreClient` free-paths in particular.
- **Canvas subsystem** (`ViewerCore/Canvas`, `CanvasTabController`) — I confirmed
  `dropCanvasController` calls `teardown()` on close but did not read `teardown()`'s
  body to verify it fully releases its webview host / observers / any timers.
- **Git subsystem** (`GitPanelModel` 60s timer is weak-captured; but the broader
  Git/FSEvents watcher lifecycle, `RepoStatsCache`, `GitChipStore` growth) — shallow.
- **Automation/MCP** (`MCPSocketBridge`, `MCPSocketListener`, `AutomationHost`,
  `ElementRefExecutor`) — I confirmed `MCPSocketListener` tracks `servers: [MCPServer]`
  and has a `stop()`, but did not trace per-connection buffer/handle lifecycle or
  whether long-lived agent sessions accumulate element-ref or pending-request state.
- **Terminal** (`TerminalPaneStore.models: [UUID: TerminalModel]`) — `closeTab(_:)`
  exists; I did not verify every terminal-pane teardown path drains the `PTYProcess`
  and removes the model on all close routes (split close, session drain).
- **SwiftUI view-graph retain cycles** — `@StateObject`/`@ObservedObject` ownership
  and closure captures inside view bodies are hard to see statically and were not
  chased; they'd need Instruments (Leaks/Allocations) on the VM.
- **Runtime confirmation** — everything here is static. None of it was confirmed with
  an Instruments Allocations/Leaks trace over a real long multi-tab/multi-session
  run, which is the authoritative signal for this dimension (and the natural
  follow-up for F1: watch `phys_footprint` while opening/closing N sessions).
