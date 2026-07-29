# Pre-launch audit — Read/write consistency scrutiny

**Date:** 2026-07-10 · **Dimension:** persisted read+write consistency (atomicity, torn/partial writes, stale reads, lost updates, concurrent-writer safety, crash-mid-write recovery)
**Repo:** `/Users/me/Documents/workspaces/claude/markdown_viewer` @ `92c72206` (+ uncommitted doc-only changes)

---

## Executive summary

The persistence layer is, on the whole, **unusually well engineered**: a single durable-write chokepoint (`JSONFileStore.writeDurably` — temp + fsync + rename + dir-fsync), serial per-URL coalescing write queues with terminate-time drains, a crash-safe snapshots-before-index persist order, forward-compat schema write blocks, an empty-index clobber guard with snapshot self-heal, and an editor save path that preserves mode/owner/xattrs and refuses symlink clobbers. Most classic torn-write and stale-read traps have already been found and fixed (the PERSIST-xx / FW-xx / EDIT-xx annotations are a visible audit trail).

The scrutiny still found **one P1 data-loss bug** and a cluster of P2 gaps:

1. **P1 — the session-switch tab drain deletes the hot-exit spill it just wrote.** Dirty editor buffers >1 MiB are spilled to a sidecar on session switch, then `closeTabUnconditionally` unconditionally removes that sidecar for every drained tab — the code directly contradicts its own "NOT done on the session-SWITCH close" comment. Unsaved edits in the 1–32 MiB range are silently destroyed by a mere session switch.
2. **P2 — write/read cap asymmetry on session snapshots**: the write side never checks size, the read side refuses >8 MiB, and the inline hot-exit text has a per-tab cap but no *total* budget — a snapshot can be written that the app then refuses to read back, silently dropping the whole session (including unsaved text) at restore.
3. **P2 — the user's *document* save is less durable than the app's *metadata* save**: `EditorWriter.save` does temp+rename with no fsync, while `history.json` gets fsync + directory fsync (TSK-1011). Power loss right after ⌘S can leave a truncated document.
4. **P2 — no cross-process guard**: two running app copies (e.g. `/Applications/TextView.app` + a dev `dist/` build — a real workflow in this repo) share the same Application Support stores with last-writer-wins semantics; the clobber guard only covers the empty-index case.
5. **P2 — hot-exit spill files are keyed by file path globally**, not per session, so the same file open in two sessions cross-clobbers/deletes the other session's spilled unsaved text.

Everything else found is P3 quality debt (lock-scope nit in the plugin-grant store, SQLite defaults in the `pm` crate, canvas save lacking a conflict guard, dead spill-prune code, a reset-vs-queue race, two-file torn pairs).

---

## Methodology

Static review (no repo mutation, no UI tests). Examined in depth:

- **Central write plumbing:** `Sources/ViewerCore/JSONFileStore.swift` (read caps, lenient array decode, `writeDurably`, `enqueueWrite` coalescer, `flushSync`), `Sources/ViewerCore/Sessions/SessionStore.swift` (serial queue, coalescing, `syncWrite`, clobber guard, trash, recovery), `Sources/ViewerCore/Sessions/SessionsCoordinator.swift` (persistPlan ordering, restore classification, close/trash ordering, TSK-438 self-heal).
- **Editor save + reload flow:** `Sources/ViewerCore/EditorBuffer.swift` (`EditorWriter.save`, fingerprints, `hasExternalEdit`/`hasUnknownDiskState`), `Sources/ViewerUI/Coordinators/EditorCoordinator.swift` (save path, no-clobber guard, watcher pause + FW-7 reconcile), `Sources/ViewerUI/DocumentModel.swift` (`reloadCurrentFile(matching:)`, `applyReload`, tab drain), `Sources/ViewerCore/FileWatcher.swift` (debounce, reattach, stop races).
- **Hot exit:** `Sources/ViewerCore/HotExitSpill.swift`, `Sources/ViewerUI/DocumentModel+ScrollPersistence.swift` (capture/restore), `Sources/ViewerUI/Sessions/SessionState.swift` (hydrate), `Sources/ViewerUI/Sessions/SessionsAppCoordinator.swift` (debounced autosave, mount/switch).
- **Small stores:** `BookmarksStore`, `HistoryStore`, `GoToPathHistoryStore`, `ScrollMemoryStore`, `TerminalCommandHistory`, `TerminalFavoritesStore`, `SnippetStore`, `FeedSubscriptionStore`, `WalkthroughHistory`, `ViewModeLockStore`, `RememberedLensStore`, `HTTPRequestStore` (all on the `enqueueWrite` pattern), `ReviewStore`/`ReviewSidecar`, `LocalHistoryStore` (adaptive full/diff records, prune/promote), `PluginGrantStore`, `HTMLTrustPolicy`/`HTMLTrustStore`/`HTMLNetworkConsentStore`, `PreferencesStore` (UserDefaults), `AppCacheReset` + the `main.swift` reset/relaunch and `applicationWillTerminate` flush paths, `CanvasDocumentStore`.
- **Rust side:** `rust-core/crates/pm/src/lib.rs` (rusqlite open + transactional append), grep of `serve`/`web`/`tui` for write sites (serve is read-only; writes found only in tests).
- **Cross-cutting:** grep sweeps for `atomic`, `fsync`, `flock`/`O_EXLOCK`, non-atomic `.write(to:)`, `UserDefaults` read-modify-write, store construction sites (to rule out divergent in-memory copies), and single-instance enforcement.

~30 files read in full or in large part; findings below cite exact lines from the current tree.

---

## Findings

### F1 · P1 — Session-switch tab drain deletes the hot-exit spill it just wrote (silent loss of >1 MiB unsaved edits)

- **Files:**
  - `Sources/ViewerUI/DocumentModel.swift:3221-3229` (unconditional spill remove in `closeTabUnconditionally`), `:3242` (the `isBulkDraining` guard that comes *too late*), `:3262-3293` (`closeAllTabsPreservingDirty`)
  - `Sources/ViewerUI/DocumentModel+ScrollPersistence.swift:263-269` (spill write at capture)
  - `Sources/ViewerUI/Sessions/SessionState.swift:399-447` + `DocumentModel+ScrollPersistence.swift:295-319` (restore reads the spill by path)
- **Evidence:** `closeAllTabsPreservingDirty()` (the session-switch drain) first calls `captureUnsavedTextForAllTabs()` — which for a dirty buffer over `hotExitMaxBytes` (1 MiB) writes the sidecar via `HotExitSpill.write(buf.text, forPath: p, …)` — then drains every tab through `closeTabUnconditionally(at: 0)`. That method runs:

  ```swift
  // DocumentModel.swift:3222-3229
  // TSK-1026: a DESTRUCTIVE close orphans any >1 MiB hot-exit spill for
  // this file … NOT done on the session-SWITCH close
  // (`closeAllTabsPreservingDirty`), which intentionally keeps the dirty
  // buffer for switch-back.
  if let p = closedURL?.path {
      HotExitSpill.remove(forPath: p, in: hotExitSpillDirectory)
  }
  ```

  The comment claims the removal is skipped on the switch path, but the `guard !isBulkDraining else { return }` sits at line 3242 — *after* the removal. Every session switch therefore writes the spill and immediately deletes it. The tab's `unsavedText` stays `nil` (only ≤1 MiB buffers inline), so on switch-back / relaunch `restoreUnsavedTextIfNeeded` finds neither inline text nor a spill → the buffer restores clean. `unsavedBaseMTime/Size` survive in the snapshot, but there is no text to overlay.
- **Impact:** silent, unrecoverable loss of in-flight (unsaved) edits for any buffer between 1 MiB and the 32 MiB editor cap, triggered by an ordinary session switch. Local History only helps if the file was previously *saved* with that content — by definition these edits were not. The hot-exit contract ("switching back rehydrates the in-flight edits byte-identical", `DocumentModel.swift:3253-3255`) is broken exactly in the case TSK-1026 was built for.
- **Suggested fix:** move the `HotExitSpill.remove` behind the `isBulkDraining` guard (or gate it on "this close is destructive"), and add a host test: dirty >cap buffer → `closeAllTabsPreservingDirty()` → assert the spill file still exists → rehydrate → assert the text returns. (Existing `HotExitTests` pin only the destructive-close cleanup.)
- **Fix size:** S · **Fix risk:** safe

### F2 · P2 — Snapshot write/read cap asymmetry: a session snapshot can be written that restore then refuses (whole-session drop)

- **Files:** `Sources/ViewerCore/Sessions/SessionStore.swift:64` (`maxSnapshotFileSize = 8 MiB`, read side), `:269-277` (`load(id:)` → nil on oversize), `Sources/ViewerCore/Sessions/SessionsCoordinator.swift:128-132` (unloadable snapshot → session skipped at restore), `Sources/ViewerUI/DocumentModel+ScrollPersistence.swift:260` (per-tab 1 MiB inline cap, no total budget), `SessionStore.enqueueSave`/`JSONFileStore.write` (no size check anywhere on the write side).
- **Evidence:** `unsavedText` is capped per tab at 1 MiB, but a session with N dirty tabs inlines up to N MiB — and JSON string escaping (`\n`, `\"`, `\\`, non-ASCII) plus pretty-printing can multiply the on-disk footprint 2–3×. Nothing on the write path validates the encoded size against `maxSnapshotFileSize`; the 8 MiB guard exists only in `load`. At the next launch, `store.load(id:)` returns nil, `restore()` appends the id to `skipped` and continues; the next `persist()` writes a fresh index *without* the session. The snapshot file remains on disk but orphaned (and `recoverableSnapshots()` only runs when the whole index is empty/corrupt, so it never rescues a single dropped session).
- **Impact:** with roughly ≥4–8 heavily-dirty tabs, an entire session — tab set, layout, *and* all inline unsaved text — silently vanishes on relaunch, with only a generic "Skipped 1 unreadable session snapshot(s)" note. The write succeeded; the read policy discards it: a self-inflicted "corruption".
- **Suggested fix (layered):** (a) enforce a total inline-unsaved budget at capture time, spilling overflow tabs to `HotExitSpill` (the mechanism already exists); (b) size-check the encoded snapshot in `SessionStore` before write and degrade (spill / strip inline text) rather than write an unreadable file; (c) at restore, treat an *oversized-but-parseable* snapshot differently from corrupt (e.g. attempt a decode anyway or raise the cap with a warning) so policy never trumps user data.
- **Fix size:** M · **Fix risk:** careful (restore-path behavior change; needs tests for the boundary)

### F3 · P2 — User-document saves are not power-loss durable (no fsync before rename), weaker than the app's own metadata writes

- **Files:** `Sources/ViewerCore/EditorBuffer.swift:339-372` (`EditorWriter.save`: temp write + `rename(2)`, no `fsync`), contrast `Sources/ViewerCore/JSONFileStore.swift:88-118` (`writeDurably`: fsync temp + rename + fsync dir, added by TSK-1011 precisely because "`Data.write(.atomic)` … does NOT fsync, so a crash/power-loss right after the rename can leave a zero-length or truncated file").
- **Evidence:** the editor save path writes the new bytes to a temp sibling (`data.write(to: tempURL, options: [.atomic])` — itself only an in-directory temp+rename, no sync) and then `rename(tempURL.path, targetPath)`. On APFS the rename metadata can commit before the file data is flushed; a power failure / kernel panic in that window yields a truncated or empty *document* at the target path. `applyTextTransformToActiveFile` (`DocumentModel.swift:2700-2714`) and `CanvasDocumentStore.save` share the same path. Meanwhile `history.json` and `bookmarks.json` get the full fsync treatment — the durability hierarchy is inverted: the user's document is the highest-stakes artifact in the app.
- **Impact:** crash-mid-write is handled (rename is atomic), but power-loss-after-save can destroy the just-saved document. Local History snapshots (taken post-save, also non-fsynced `.atomic` writes — see F13) may or may not survive the same event.
- **Suggested fix:** in `EditorWriter.save`, open the temp file, `fsync` (or `fcntl(F_FULLFSYNC)` for true platter durability) before the rename, optionally fsync the directory after — mirroring `writeDurably`. One fsync per explicit ⌘S is imperceptible.
- **Fix size:** S · **Fix risk:** careful (touch the metadata-replay ordering; keep the symlink/EACCES branches intact)

### F4 · P2 — No cross-process concurrency guard on the shared Application Support stores (two app instances = lost updates)

- **Files:** `Sources/ViewerCore/Sessions/SessionStore.swift:94-99` (fixed shared directory), whole-repo grep: no `flock`, `O_EXLOCK`, lockfile, or `NSRunningApplication` single-instance check anywhere in `Sources/`.
- **Evidence:** all consistency machinery (serial queues, coalescing, clobber guard) is **in-process**. Two simultaneously-running copies of the app — a real workflow here: the installed `/Applications/TextView.app` plus a dev `dist/TextView.app` run, or a test spawn without `MDV_SESSIONS_DIR` (the harness sets it, per BUG-027, but a manual launch doesn't) — both mount the same `Sessions/`, `bookmarks.json`, `history.json`. Every write is a whole-file replace of that process's in-memory view: sessions created/renamed in instance A are erased by instance B's next `persist()`; bookmark/history mutations ping-pong last-writer-wins. The TSK-438 guard (`SessionStore.swift:255-258`) only refuses *empty* index writes; a non-empty stale index sails through. `UserDefaults` is cross-process safe per key but last-writer-wins too.
- **Impact:** silent lost updates of sessions/bookmarks/history whenever two instances coexist; the on-screen symptom would look exactly like the historical "session tabs vanished" incident.
- **Suggested fix:** acquire an advisory lock (e.g. `open(…, O_EXLOCK|O_NONBLOCK)` on `Sessions/.lock`) at startup; on failure either activate the existing instance and exit, or degrade to read-only persistence with a visible banner. Per-write `flock` on `index.json` would be a smaller but weaker alternative.
- **Fix size:** M · **Fix risk:** careful (must not break the VM/UAT harness spawns, which rely on env-redirected store dirs)

### F5 · P2 — Hot-exit spill keyed by file path *globally*: same file open in two sessions cross-clobbers / deletes the other session's unsaved text

- **Files:** `Sources/ViewerCore/HotExitSpill.swift:27-38` (`pathKey` = FNV of the file path only), `Sources/ViewerUI/DocumentModel+ScrollPersistence.swift:262` (inline-capture removes spill), `:267` (dirty write), `:273-274` (**clean tab removes any spill for its path**), `Sources/ViewerUI/Sessions/SessionState.swift:399-447` (restore reads by path).
- **Evidence:** sessions are isolated per-snapshot for *inline* unsaved text, but the spill sidecar namespace is app-global by path. Scenarios (independent of F1):
  1. `/x/big.log` dirty (>1 MiB) in session A → A's capture writes the spill. The same file open **clean** in session B → any capture while B is active (autosave fires on every model tick, `SessionsAppCoordinator.swift:71-95`) hits the `else if let p = tab.url?.path { HotExitSpill.remove(forPath: p…) }` branch and deletes A's spill. A's edits are gone before A is ever remounted.
  2. Dirty in both A and B with different content → one session's spill overwrites the other's; switch-back restores the *wrong* session's bytes into the tab (cross-session bleed) and the loser's edits are lost.
- **Impact:** silent loss/corruption of large unsaved buffers when a file is open in more than one session — plausible for shared notes/log files. Currently masked by F1 (the spill rarely survives a switch at all); once F1 is fixed this becomes the next hole in the same contract.
- **Suggested fix:** namespace spills per session (`spill/<sessionID>/<pathKey>.txt`); the clean-tab cleanup then only touches its own session's namespace. Wire `pruneOrphans` (see F9) against the union of all sessions' paths.
- **Fix size:** M · **Fix risk:** careful (restore must try the session-scoped key first, then the legacy global key for migration)

### F6 · P3 — `PluginGrantStore.persist` runs outside the lock: concurrent record/revoke can be reordered on disk (a revoke can be resurrected)

- **Files:** `Sources/ViewerCore/Plugins/PluginGrantStore.swift:164-199`.
- **Evidence:** `record`/`revoke` mutate `cached` and take a snapshot under `lock`, then call `persist(snapshot)` **after** `lock.unlock()`. `persist` → `JSONFileStore.write` is synchronous on the caller's thread with no per-URL ordering. Two racing mutations can serialize their snapshots correctly in memory yet write in reverse order — the older snapshot lands last. For a *security* store the bad case is: user revokes; a racing grant-record write (snapshotted pre-revoke) lands after; disk now says granted. In practice both calls come from main-thread UI prompts, so exploitation needs an automation-driven mutation off-main — low probability, but the store is `@unchecked Sendable` and advertises thread safety via its lock.
- **Suggested fix:** hold the lock across the write, or route through `JSONFileStore.enqueueWrite` (per-URL ordered) + `flushSync` on terminate.
- **Fix size:** S · **Fix risk:** safe

### F7 · P3 — `pm` crate opens SQLite with default journal/locking settings (no WAL, no busy_timeout)

- **Files:** `rust-core/crates/pm/src/lib.rs:381-385`.
- **Evidence:** `Connection::open(path)` + schema, no `PRAGMA journal_mode=WAL`, no `busy_timeout`. Transactional append discipline is good (event + projection commit together, `:387-460`), so single-writer crash consistency is fine. But the moment a second connection exists (a future CLI/TUI/daemon front-end — several already live in the workspace), writers get an immediate `SQLITE_BUSY` error instead of queueing, and rollback-journal mode blocks readers during writes.
- **Suggested fix:** on open: `journal_mode=WAL`, `synchronous=NORMAL` (WAL-safe), `busy_timeout=5000`, `foreign_keys=ON`.
- **Fix size:** S · **Fix risk:** safe

### F8 · P3 — Canvas save has no external-change conflict guard (blind last-writer-wins on `.canvas` files)

- **Files:** `Sources/ViewerCore/Canvas/CanvasDocumentStore.swift:125-154`.
- **Evidence:** `save` serializes the engine doc and writes via `EditorWriter.save` with no disk fingerprint captured at open or checked at save — unlike the text-editor path, which stats before write (`EditorCoordinator.resolveSaveConflict`) and reconciles watcher gaps. A canvas edited concurrently by an MCP agent (the primary canvas client) and any external process/editor silently loses one side.
- **Suggested fix:** capture `(mtime, size)` at open/save in `CanvasOpenDocument`, re-stat before write, refuse/surface on mismatch (the MCP error channel already exists).
- **Fix size:** M · **Fix risk:** careful

### F9 · P3 — `HotExitSpill.pruneOrphans` is dead code: the documented disk-leak guard is never wired

- **Files:** `Sources/ViewerCore/HotExitSpill.swift:71-84`; repo grep shows zero call sites.
- **Evidence:** spills are only removed per-path on capture/close events that actually fire; a crash, a session deleted from disk, or F1-style churn leaves orphans forever. Each orphan can be up to 32 MiB.
- **Suggested fix:** call `pruneOrphans(keepingPaths:)` at launch (after session restore) with the union of open-tab paths across **all** sessions — and per-session once F5 lands.
- **Fix size:** S · **Fix risk:** safe

### F10 · P3 — File → Reset can race in-flight queued writes; a straggler write can recreate state right after the backup move

- **Files:** `Sources/MarkdownViewer/main.swift:921-953` (`performReset` → `AppCacheReset.reset` → `relaunchAndExit`), `Sources/ViewerCore/AppCacheReset.swift:135-169`.
- **Evidence:** the reset deliberately hard-exits (`exit(0)`) to *avoid* the terminate-flush resurrecting state — good. But it never **drains** the `SessionStore.writeQueue` / `JSONFileStore.writeQueue` before moving the directories. A coalesced write dispatched before the modal (dispatch main-queue blocks are serviced during `runModal`, and the write queues are background queues anyway) can land between `moveItem` and `exit`, recreating `Sessions/index.json` (all writers `createDirectory` their parents) — so the relaunched app finds a partial ghost of the state the user just reset.
- **Suggested fix:** call `sessions.flushForTermination()` + `JSONFileStore.flushSync()` (or at minimum drain both queues) *before* `AppCacheReset.reset`, then suppress further persists until `exit`.
- **Fix size:** S · **Fix risk:** safe

### F11 · P3 — Residual TOCTOU in the no-clobber save guard (stat → rename window)

- **Files:** `Sources/ViewerUI/Coordinators/EditorCoordinator.swift:1009-1030` (fresh stat in `resolveSaveConflict`), `Sources/ViewerCore/EditorBuffer.swift:367` (rename commits).
- **Evidence:** the write-time guard re-stats and decides, then the write proceeds; an external write landing between the stat and the rename is replaced without any conflict surface, and the post-save FW-7 reconcile (`EditorCoordinator.swift:896-912`) can't see it (the post-rename stat matches *our* stamp). Unavoidable without file locking; the app's own layered defenses (watcher conflict banner, save guard, Local History snapshot-on-save of *our* text) make the practical window tiny — but the overwritten external version is unrecoverable.
- **Suggested fix:** document as accepted residual risk; optionally narrow further by fstat-comparing the target's inode/mtime via an `O_NOFOLLOW` fd immediately before `rename` and aborting on change.
- **Fix size:** M · **Fix risk:** careful

### F12 · P3 — Two-file stores persist related state without a transaction (torn pairs on crash)

- **Files:** `Sources/ViewerCore/FeedSubscriptionStore.swift:370-376` (`subscriptions` + `readState` enqueued as two independent writes); same shape in `HTTPRequestStore.swift:220-224` (`history` + `saved`).
- **Evidence:** the coalescing queue orders writes per-URL only; a crash between the two `enqueueWrite`s (or between their drains) leaves e.g. read-state entries for a subscription that isn't persisted, or vice versa. Both stores tolerate the skew on read (unknown keys ignored), so impact is cosmetic — stale unread counts / orphan read-state.
- **Suggested fix:** none required beyond a comment; or merge each pair into a single versioned file if the stores grow coupling.
- **Fix size:** S · **Fix risk:** safe

### F13 · P3 — Durability tier below `JSONFileStore` is atomic-but-not-fsynced (`.atomic` only)

- **Files:** `Sources/ViewerCore/LocalHistoryStore.swift:438-441` (`writeRecord`) and `:246` (`_path` sidecar), `Sources/ViewerCore/HotExitSpill.swift:48`, `Sources/ViewerCore/Highlight/ThemeStore.swift:60`, `Sources/ViewerCore/Archive/ArchiveCatalog.swift:142`.
- **Evidence:** these all use `Data.write(options: .atomic)` — atomic vs. crash-mid-write, but not durable vs. power loss (the exact gap TSK-1011 documented and fixed for `JSONFileStore` clients). Local History is the *recovery* net for editor saves; losing the just-written revision in the same power event that truncates a save (F3) compounds the loss.
- **Suggested fix:** route these through `JSONFileStore.writeDurably` (it takes raw `Data`) or accept and document the tier. Prioritize `LocalHistoryStore.writeRecord` and `HotExitSpill.write`.
- **Fix size:** S · **Fix risk:** safe

---

## Positive observations

Genuinely strong patterns worth preserving (and copying into new stores):

- **`JSONFileStore.writeDurably`** (`JSONFileStore.swift:94-118`): temp + fsync + `rename(2)` + directory fsync — the correct full sequence, with the TSK-1011 rationale written down.
- **Per-URL ordered, coalesced, drainable write queues** in both `JSONFileStore.enqueueWrite` and `SessionStore` — with a terminate-time `flushSync` actually wired (`main.swift:708-726`), and `SessionStore.syncWrite` correctly running *inside* the serial queue so sync writes can't be overtaken by stale coalesced values (`SessionStore.swift:398-406`).
- **Crash-safe persist ordering** — snapshots before index in one FIFO (`SessionsCoordinator.persistPlan`, `:397-429`), so the index can never dangle-reference an unwritten snapshot.
- **The TSK-438 empty-index clobber guard + orphan-snapshot self-heal** (`SessionStore.swift:248-265`, `SessionsCoordinator.adoptRecoveredSnapshotsIfAny`) — a real incident turned into a two-layer defense.
- **Forward-compat schema discipline**: newer-schema files block writes rather than being truncated (`PERSIST-04` in `SessionStore.loadIndexResult`, `PERSIST-06` in `PluginGrantStore`), unknown plugin-grant decisions fail *closed* to `.denied`, and `readLenientArray` (PERSIST-02) drops bad elements instead of nuking whole history files.
- **Session close ordering** (`SessionsCoordinator.close`, `:293-311`): `saveSync` (queue-coherent, evicts pending) → `moveToTrash` → `persist()` — the trashed file carries the latest state and pending coalesced saves can't resurrect a closed session.
- **`EditorWriter.save`**: symlink refusal via `O_NOFOLLOW`/`ELOOP` classification against the same inode, EACCES mode/owner recovery via `lstat` (refusing the save rather than silently downgrading a 0600 secret), xattr/mode/owner replay before rename, and same-directory temp so the rename is same-volume atomic.
- **Save-vs-watcher coherence**: watcher paused across the write, single write-stamp reused for both the buffer baseline and the TextFile identity (EDIT-S2-SAVE), and a post-resume re-stat reconciling lost watcher events (FW-7) — plus the pure `hasExternalEdit` / `hasUnknownDiskState` decision table treating "can't tell" as a conflict on the destructive path.
- **`ReviewStore`'s index-as-cache** with an on-disk-set staleness check and scan-path source of truth (`ReviewStore.swift:134-154`) — the index can never serve deleted/added files wrongly.
- **`LocalHistoryStore` prune/promote ordering** is crash-safe: the promoted full and re-based diffs are written *before* the victim full is removed, so no interleaving of the multi-step re-anchor orphans a chain.
- **Test-state hermeticity** (TSK-1288 `TestStateRedirect`) keeping XCTest runs out of the real `~/Library` state — a consistency guard for the *developer's* data.

## Coverage gaps (not examined)

- **Rendered/WebView-side state** (CodeMirror doc sync via `CoreDocStore`, scroll channels) — in-memory consistency, not persisted; skipped except where it touches snapshots.
- **Git integration writes** (stash/commit flows shell out to `git`; export paths write temp files) — only spot-checked for atomic options.
- **LSP server on-disk caches** (`jdtls-data/`) — treated as rebuildable cache; only the reset path reviewed.
- **Image editor export encoders** beyond confirming `.atomic` usage; TIFF/PNG payload correctness out of scope.
- **The MCP socket bridge / automation dispatch threading** (uncommitted `MCPSocketBridge.swift` changes) — verified mutations route to the main-actor model, but did not audit every tool for write paths.
- **Runtime/dynamic validation** — no tests were run (static-analysis-only per constraints); the races described in F1/F5/F10 were traced through code, not reproduced live. F1's trace is deterministic (straight-line code), so confidence is high; F10's window depends on queue timing.
- **iCloud/xattr interactions** on the build path (covered by prior audits per CLAUDE.md; not re-verified).
