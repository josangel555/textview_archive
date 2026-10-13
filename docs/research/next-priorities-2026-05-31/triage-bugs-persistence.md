# Triage — bugs:persistence

I have a comprehensive, code-verified picture. Both bugs are real and trace to the same architectural gap (no incremental snapshot writeback on tab mutation), with bug #1 being a specific manifestation. Let me write up the triage.

### Triage: state-persistence bugs

The workspace state path described in the task (`Workspaces/_last.json`, `WorkspaceStore`) was **retired** in commit `e0115f5` (decision G, 2026-05-25). State now lives under `~/Library/Application Support/com.markdownviewer.MarkdownViewer/Sessions/` as `index.json` + per-session `<uuid>.json`, owned by `SessionStore` / `SessionSnapshot` / `SessionsCoordinator`. The triage below is against that current path. There is **no `_last.json` fallback** anymore (`SessionsAppCoordinator.swift:76`, `main.swift:193`).

---

### 1. Closing with one tab open, reopening shows two tabs

**Status today**
- Cold-launch restore is single-append-per-persisted-tab and is correct in isolation: `SessionState.hydrate(from:)` iterates `snapshot.openTabs` once, calling `model.appendLazyTab(url:viewMode:)` per surviving tab (`Sessions/SessionState.swift:160-168`). One snapshot tab → one `appendLazyTab` → one live tab. `TabCoordinator` boots with an empty `TabsState` (`TabCoordinator.swift:49`); there is no auto-seeded blank tab at construction, and `main.swift:712` is only a menu builder, not a tab seed.
- The store round-trip is clean and tested (`SessionTabPersistenceRestartTests.test_singleSession_restoredOnNextLaunch`).
- `materializeIfNeeded(at:)` replaces the lazy tab in place; it never appends (`DocumentModel.swift:2471-2521`).

**Root cause / gap**
The duplication is a **save-side dedup mismatch**, not a restore-side double-append, and it is masked by the fact that the only place live tabs reach disk is `makeSnapshot()` on `detach`/terminate. The defect is a URL-normalization asymmetry between the three legs:

- `appendLazyTab` stores `url.standardizedFileURL.resolvingSymlinksInPath()` on the tab (`DocumentModel.swift:2397`).
- `makeSnapshot()` persists `t.url.path` verbatim (`SessionState.swift:114-118`) — i.e. the *already-resolved* path for restored tabs, but the *raw* path for tabs opened via code paths that don't resolve symlinks the same way.
- On relaunch, the restored lazy tab carries the resolved path. If the user (or argv, or a reveal, or the sidebar) opens that same file again, `TabsState.openOrReveal` dedups via `tabs.firstIndex(where: { $0.url == url })` using **exact `URL` equality** (`TabsState.swift:127`). A `file:///private/var/...` vs `file:///var/...` (the classic macOS `/var`→`/private/var` symlink) or a trailing-slash / percent-encoding difference defeats that equality check, so a second tab is appended instead of revealing the existing one.

The single-tab case is where this bites hardest: with the session rooted under a symlinked dir (`/tmp`, `/var/folders/...` — exactly the per-user scratch space TextView uses, and which the `hydrate` comment at `SessionState.swift:149-153` explicitly worries about), the restored tab's resolved path and a freshly-opened path diverge, and `openOrReveal`'s exact-equality dedup misses.

Note the asymmetry is acknowledged but only half-fixed: `hydrate`'s *selection* match resolves symlinks before comparing (`SessionState.swift:154-159`), but the *dedup* in `TabsState.openOrReveal` does a raw `URL ==`. So selection was hardened against this exact normalization gap; tab-dedup was not.

**Fix/build sketch**
- Normalize on both sides of the dedup. Either (a) have `TabsState.openOrReveal` compare on `standardizedFileURL.resolvingSymlinksInPath()` rather than raw `URL ==` (TabsState is pure ViewerKit-only value logic, so this is a self-contained change — `TabsState.swift:127`), or (b) make `makeSnapshot()` persist the resolved path so the on-disk value matches what `appendLazyTab` will store on restore (`SessionState.swift:114-118`), and ensure every live-open path resolves identically.
- Prefer (a): it fixes the dedup invariant at the single chokepoint all opens funnel through, independent of how the URL arrived. Add a `TabsStateTests` case: open `/var/folders/.../x.md`, then `openOrReveal` the `/private/var/...` form, assert one tab.
- Add the missing regression test: a full quit→relaunch cycle through `SessionsAppCoordinator.flushForTermination()` + fresh `bootstrap()` (the existing suite only tests session *switch*, never a cold restart through the coordinator — `SessionTabPersistenceTests.swift`).

**Size** — **S**. The actual fix is a one-line equality-normalization in pure value code plus a couple of tests. The investigation cost dominates, not the change.

**Dependencies** — none; `TabsState` is leaf value logic. Should land *before* item 2's incremental-save work, because incremental saves will write the live tab list far more often, so any dedup mismatch will surface more aggressively (every mutation persists, not just on quit).

**Risk/one-way-door note** — Low. Changing `openOrReveal` to resolve symlinks could theoretically collapse two tabs the user deliberately opened via two different symlinks to the same file — but `Tab` identity is per-`UUID` and the app has no "open same file twice via distinct symlinks" feature, so this is the desired behavior (it matches the *session-level* dedup policy in `SessionsCoordinator.openFolder`, `SessionsCoordinator.swift:184-192`, which already resolves symlinks). No on-disk schema change in option (a), so it's reversible.

---

### 2. After a crash, reopen does not show last state (persist only on clean quit)

**Status today**
- **Confirmed: persistence is clean-quit-only for intra-session state.** Every writer of the live tab/editor/sidebar state goes through `SessionState.makeSnapshot()` → `SessionsCoordinator.replaceSnapshot()`, and there are exactly **two** call sites:
  1. `SessionsAppCoordinator.flushForTermination()` — `applicationWillTerminate` only (`SessionsAppCoordinator.swift:191-197`, called from `main.swift:396`).
  2. `LifecycleBridge.detach(_:)` — fires only on a **session switch / close** (`SessionsAppCoordinator.swift:310-322`).
- `SessionsCoordinator.persist()` (`SessionsCoordinator.swift:360-402`) *is* called incrementally — but only on **session-list** mutations: `openFolder`, `activate`, `close`, `updateSession`, `replaceSnapshot` (lines 211, 241, 265, 317, 345). It re-serializes whatever `openTabs` the in-memory `SessionSnapshot` already holds — and that in-memory snapshot is **frozen at session-create time with `openTabs: []`** (`SessionsCoordinator.openFolder` builds the snapshot with no tabs, `SessionsCoordinator.swift:199-205`) until a `detach`/terminate refreshes it.
- **Net effect:** open a folder, open files, type edits, reorder tabs, change zoom/theme — none of it is written to the active session's `<uuid>.json` until you switch sessions or quit cleanly. A crash (or `SIGKILL`, force-quit, panic) loses everything since the last clean session-switch/quit. `applicationWillTerminate` does **not** fire on crash, so `flushForTermination` never runs.
- The persistence *infrastructure* for incremental saves already exists and is unused for this purpose: `SessionStore.enqueueSave` is a URL-coalescing serial-queue writer (`SessionStore.swift:173-272`) with a fixpoint-drain `flushSync()` (`SessionStore.swift:189-208`). It is wired for *index/session-list* writes but never driven by *tab/editor* mutations.
- **The design doc explicitly specifies what's missing.** `docs/SESSIONS_DESIGN.md:856-867` §5.4 "Auto-save cadence": *"Every state mutation on a `SessionState` triggers a 500 ms debounced write of its own snapshot file."* This was never implemented — only the terminate-flush half of §5.4 shipped.

**Root cause / gap**
There is no observer bridging `DocumentModel` mutations → `makeSnapshot()` → `enqueueSave`. The `SessionState` deliberately does **not** forward `model.objectWillChange` (REPUB-1, `SessionState.swift:62-78`) — for good reasons (the LESSONS.md republish-amplification trap) — but that means there is also no signal anyone listens to in order to schedule a debounced snapshot. The coalescing write queue solves the *I/O* side of debouncing but nothing feeds it on the *mutation* side.

**Fix/build sketch** — debounced incremental persistence, exactly as §5.4 specifies:
- Add a debounced writeback driven off the session's live state. Two viable shapes:
  - **Narrow/recommended:** have `SessionsAppCoordinator` subscribe to a small set of *coarse* `DocumentModel` `@Published` streams that actually change persisted fields — `tabCoordinator.$tabs` (covers open/close/select/reorder/viewMode), `sidebar.$rootURL`, plus `zoom`/`sourceWordWrap`/`themeOverride`. Debounce 500 ms on the main actor (`Publishers.Debounce` or a single `DispatchWorkItem` cancel/reschedule), then `active.makeSnapshot()` → `core.replaceSnapshot(id:with:)`. `replaceSnapshot` already routes through `persist()` → `enqueueSave`, which coalesces — so a typing/drag storm collapses to one disk write. This keeps the REPUB-1 discipline (subscribe to *narrow* streams with equality guards, never the whole-model firehose).
  - **Broader:** introduce a `SessionState.markDirty()` that `DocumentModel` calls at the same chokepoints it already updates derived state (`updateDerived`, the close/open/select paths), feeding a debouncer. More invasive; more call sites to keep honest.
- `applicationWillTerminate`'s `flushSync()` already drains the queue, so the debounced writes + the terminate flush compose correctly.
- **Editor-buffer caveat:** `openTabs` persists only URL + viewMode (`TabSnapshot`, `SessionSnapshot.swift:7-15`). Unsaved editor text is **not** in the snapshot, so debounced session-snapshot saves recover *which files were open*, not *unsaved edits*. Crash-recovery of unsaved buffer contents is a separate, larger feature (would need per-tab dirty-buffer persistence, à la a swap/journal file) — call that out explicitly so expectations are set; the §5.4 fix recovers tab layout, not in-flight typing.

**Size** — **M**. The narrow shape is a focused subscription + debounce + one `makeSnapshot`/`replaceSnapshot` call, but it must be done carefully to avoid re-introducing the republish-amplification regression (per-stream equality guards, main-actor debounce, no whole-model observation), and it needs tests for the debounce/coalesce behavior and a crash-simulation (write-without-terminate-flush) round-trip. Editor-buffer crash recovery, if wanted, is a separate **L**.

**Dependencies**
- Item 1's dedup fix should land first (incremental saves amplify any dedup bug).
- Leans on `SessionStore`'s existing coalescing queue (already present, `SessionStore.swift:173-272`) — no new infra needed for the layout case.

**Risk/one-way-door note**
- **Performance/republish risk** is the real hazard, not data safety. Wiring this wrong (observing `model.objectWillChange` wholesale, or no equality guard) re-creates the exact fan-out LESSONS.md and REPUB-1 were written to kill — every keystroke/FS-event/git-poll would schedule a snapshot. Mitigate with narrow `@Published` subscriptions + debounce + dedup-on-publish. Not a one-way door — it's reversible config — but easy to regress silently.
- **No schema change**, so it's forward/backward compatible with existing `<uuid>.json` files; the downgrade guard (`indexWriteBlocked`, `SessionsCoordinator.swift:367` / PERSIST-04) still applies and is unaffected.
- Writing more frequently slightly raises the odds of an atomic-write landing mid-crash, but `JSONFileStore.write` uses `.atomic` (POSIX rename, `JSONFileStore.swift:84-87`), so a torn file can't result — worst case is losing the very last debounce window.

---

### Interaction with "session independence" / crash-recovery expectations

- **Session independence (Phase 2):** Today there is one shared `DocumentModel` behind a per-session `SessionState` façade (`SessionsAppCoordinator.swift:16-23`, "Phase-1 façade trick"). The incremental-save subscription in item 2 must hang off the **active** `SessionState`/`SessionsAppCoordinator`, and be re-pointed on every mount/detach — otherwise after Phase 2 splits into a per-session `DocumentModel` dictionary, a stale subscription would snapshot the wrong session into the wrong file. Build the debounce so it's owned by the coordinator keyed on `active.id` and torn down/re-armed in `mountSession`/`switchSessionFaçade` (`SessionsAppCoordinator.swift:208-279`). The `detach`-time `replaceSnapshot` (`SessionsAppCoordinator.swift:319-320`) already establishes the right boundary; the incremental save is the same call, just driven by a debouncer instead of only by the lifecycle edge.
- **Crash-recovery expectations:** §5.4 + the trash retention (`emptyTrashOlderThan(30)`, `SessionStore.swift:228`) imply the user expects "relaunch puts you back exactly where you left off" (design §line 248). With clean-quit-only persistence, that promise holds for graceful quit but silently breaks on crash. Item 2 closes the gap for **tab/sidebar/zoom layout**. It does **not** by itself restore **unsaved editor edits** — set that expectation explicitly; that needs a separate dirty-buffer journal and is the larger follow-on. The `lastActiveID` pointer is already written immediately on activate (no debounce, `SessionsCoordinator.activate` → `persist`), matching §5.4's "activations write immediately" rule, so after the fix a crash recovers both *which session was active* and *that session's tab layout as of the last 500 ms window*.

**Key file:line references:** `SessionsAppCoordinator.swift:191-197,310-322`; `SessionsCoordinator.swift:199-213,360-402`; `SessionState.swift:104-127,160-168`; `SessionStore.swift:173-208`; `TabsState.swift:122-170` (esp. `:127`); `DocumentModel.swift:2396-2409,2471-2521`; `main.swift:193-198,396`; `docs/SESSIONS_DESIGN.md:856-867`.