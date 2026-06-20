# Adversarial review — data-integrity & persistence (2026-06-18)

Scope: the session/autosave/bookmarks/recent-paths/local-history persistence layer
(`JSONFileStore`, `SessionStore`, `SessionsCoordinator`, `SessionsAppCoordinator`,
`SessionSnapshot`, `BookmarksStore`, `HistoryStore`, `GoToPathHistoryStore`,
`LocalHistoryStore`, `EditorBuffer`/`EditorWriter`, `AppCacheReset`). The layer is
notably defensive in places (lenient array decode, clobber-guard, downgrade banner,
coalesced+drainable write queues, symlink/permission preservation on editor saves).
The defects below are the spots where a hostile input, a crash/power-loss timing
window, an external-edit interleaving, or a hash collision still produces silent
data loss or corruption. The two highest-impact issues are the **hot-exit restore
having no external-modification guard** (a silent overwrite of edits made outside
the app while it was closed) and the **`.atomic` writes carrying no fsync barrier**
(crash/power-loss between rename and writeback truncates the user's session/bookmark
state to zero bytes).

### Hot-exit restore re-seeds the dirty baseline from the *current* disk file, with no external-change guard — silent clobber of edits made while the app was closed

**Severity:** high

**Location:** `Sources/ViewerUI/DocumentModel.swift:2002-2013`
(`restoreUnsavedTextIfNeeded`); capture side `:1980-1993`
(`captureUnsavedTextForAllTabs`); snapshot shape `Sources/ViewerCore/Sessions/SessionSnapshot.swift:36-56` (`TabSnapshot.unsavedText`).

**Why:** TSK-718 hot exit persists the *unsaved buffer text* in the session
snapshot, then on relaunch `restoreUnsavedTextIfNeeded` does
`editor.ensureEditorBuffer(for: file, tabID:)` — seeding the dirty baseline from
**whatever the file contains on disk right now** — and overlays the stale
`unsavedText`. The buffer comes back "dirty against current disk." But the editor's
entire external-edit/conflict machinery (`EditorBuffer.hasExternalEdit` /
`hasUnknownDiskState`, `EditorBuffer.swift:102-138`) keys off the `(mtime, size)`
fingerprint captured **at load time**. The snapshot stores no fingerprint of the
file as it was when the unsaved edits were made, and the restore captures a *fresh*
baseline. So if the user (or another tool, or a `git pull`, or a teammate via a
synced folder) modified the file on disk between quit and relaunch, the restored
buffer silently presents the user's *old* in-flight edits as the live state — and a
subsequent ⌘S overwrites the externally-changed file with no conflict prompt,
because the baseline was reseeded from the new disk content and the watcher never
saw an "external edit" (the change happened while the app was dead). This is
exactly the data-loss class the conflict-prompt was built to prevent, defeated on
the relaunch path.

**Fix:** Persist the file's `(mtime, size)` (and ideally a content hash) into
`TabSnapshot` alongside `unsavedText`. On `restoreUnsavedTextIfNeeded`, stat the
file: if its current fingerprint differs from the persisted one, do NOT silently
overlay — surface the same external-edit conflict prompt (keep-my-edits / discard /
diff) the live path uses. At minimum, set the restored buffer's `lastSavedMTime/Size`
to the *persisted* baseline (not the fresh re-read) so the next save triggers the
existing conflict detection instead of clobbering.

**CONFIRMED** — `restoreUnsavedTextIfNeeded` → `ensureEditorBuffer` → `EditorBuffer(from: file)` captures `lastSavedMTime/Size` fresh from disk (`EditorBuffer.swift:170-178`); `TabSnapshot` carries no fingerprint (only `path/viewMode/categoryOverride/scrollTopLine/unsavedText`, `SessionSnapshot.swift:47-56`); and the conflict prompt fires ONLY on a live file-watcher tick (`DocumentModel.swift:5258`), never inside the save path (`EditorCoordinator.saveEditor` calls `EditorWriter.save` with no `hasExternalEdit` check, `:498-499`). An edit made while the app is dead produces no watcher event, so a post-restore ⌘S silently overwrites externally-changed content.

### `JSONFileStore.write` / `EditorWriter` rely on `Data.write(.atomic)` with no fsync — power-loss/crash can truncate session, bookmark, and history files to zero bytes

**Severity:** high

**Location:** `Sources/ViewerCore/JSONFileStore.swift:84-91` (`write` →
`data.write(to:options:.atomic)`); same pattern in
`Sources/ViewerCore/LocalHistoryStore.swift:95,101`,
`Sources/ViewerCore/EditorBuffer.swift:338` (temp write) and `:358` (rename).

**Why:** `Data.write(.atomic)` writes to a temp file then `rename(2)`s it over the
target. `rename` is atomic *with respect to other processes*, but it does **not**
fsync the temp file's data blocks before the rename, nor fsync the parent directory
after. On a crash or power loss in the window after the metadata rename commits but
before the data blocks are flushed, the file can come back **zero-length or
truncated** — the classic "atomic rename ≠ durable" trap. The docstrings throughout
this layer claim "atomic write; on disk failure the existing file is preserved"
(`JSONFileStore.swift:72-73`) and "atomically so a crash mid-write doesn't leave a
half-written file" (`EditorBuffer.swift:201-203`). Both overstate the guarantee: a
crash mid-write is safe against *partial visible content*, but a crash *after*
rename can still lose the bytes. For `Sessions/index.json` this means the entire
session strip can come back empty after a hard power-off — the very failure the
TSK-438 clobber-guard was written to defend against, reachable by a different route
(crash vs. logic bug). The `applicationWillTerminate` flush (`main.swift:497-503`)
covers a *clean* quit but does nothing for a panic/OOM-kill/power-loss.

**Fix:** Do the temp-write → `fsync(tempfd)` → `rename` → `fsync(dirfd)` sequence
explicitly (the `EditorWriter` path already opens fds and renames by hand — add the
two fsyncs there; for `JSONFileStore.write`, drop `Data.write(.atomic)` in favour of
a hand-rolled temp+fsync+rename+dir-fsync helper). At minimum, soften the docstrings
so callers don't assume durability that isn't there.

**CONFIRMED** — grep finds NO `fsync`/`F_FULLFSYNC` in any ViewerCore write path (the lone JSONFileStore.swift:96 hit is a comment that *wrongly* claims fsync happens). `Data.write(.atomic)` is temp+rename with no data-block flush nor parent-dir fsync. The overstated docstrings are real (`JSONFileStore.swift:72-73`, `EditorBuffer.swift:201-203`, and `CODE_REVIEW_V2_DESIGN_2026-06-01.md:191` calls it "crash-safe"). `docs/RUST_CORE_MIGRATION.md:165-167` independently acknowledges the gap, planning the four-step `sync_data`+dir-fsync in the Rust port. (Severity note: on APFS copy-on-write a torn rename yielding a *zero-length* file is less likely than the classic ext4 case, but durability is genuinely not guaranteed without F_FULLFSYNC — high-leaning-medium.)

### Hot-exit silently discards in-flight edits larger than 1 MiB

**Severity:** medium

**Location:** `Sources/ViewerUI/DocumentModel.swift:1962-1966` (`hotExitMaxBytes`),
`:1984-1987` (capture skips when `buf.text.utf8.count > hotExitMaxBytes`).

**Why:** `captureUnsavedTextForAllTabs` captures `unsavedText` only when the dirty
buffer is ≤ 1 MiB; over that, it captures `nil` and the file "reloads from disk on
relaunch." The user is given no warning. A user who pastes a large block into the
editor (a generated config, a big JSON, a CSV they're hand-editing) and quits
trusting hot-exit to keep their work will silently lose every unsaved byte on
relaunch — the buffer reverts to the on-disk version. The cap is a sound bloat
defense for the *session JSON*, but the failure mode (silent total loss of the edit)
is the opposite of what "hot exit" promises. The editor's own edit cap is 32 MiB
(`EditorBuffer.load`, `EditorBuffer.swift:154`), so a 1–32 MiB dirty buffer is
entirely reachable.

**Fix:** When a dirty buffer exceeds `hotExitMaxBytes`, don't silently drop it —
either (a) spill the unsaved text to a sidecar file under the session dir and
reference it from the snapshot, or (b) on quit, prompt the user that N MB of unsaved
edits in `<file>` won't be preserved by hot-exit and offer to save now. Tie the
behaviour to the same conflict/save UI rather than a silent `nil`.

**CONFIRMED** — `captureUnsavedTextForAllTabs` captures `nil` for any dirty buffer over `hotExitMaxBytes` (1 MiB) with no prompt and no sidecar spill (`DocumentModel.swift:1984-1987`); the editor's own cap is 32 MiB (`EditorBuffer.load`, loader `maxBytes: 32 * 1024 * 1024`, `:154`), so a 1–32 MiB dirty buffer is reachable and silently reverts to disk on relaunch.

### `LocalHistoryStore` keys revision dirs on a 64-bit FNV-1a hash with no collision check — two files can silently share/overwrite each other's history

**Severity:** medium

**Location:** `Sources/ViewerCore/LocalHistoryStore.swift:170-179` (`pathKey`),
used by `fileDirectory(for:)` `:146-148`; the `_path` sidecar `:99-102` records only
the *first* path seen and is never consulted to detect a mismatch.

**Why:** `pathKey(path)` is FNV-1a-64 of the absolute path, used as the directory
name that holds a file's revision snapshots. There is no collision detection: if two
distinct file paths hash to the same 64-bit value, their revisions land in the same
directory, interleave by timestamp, and the `pruneIfNeeded` cap
(`maxVersionsPerFile = 50`, `:152-162`) will evict the *other* file's revisions as
if they were the same file's history. `contentString(of:for:)` would then return
file B's bytes for a "restore file A to an earlier version" action — restoring the
wrong file's content. The `_path` sidecar is written once (whichever file created
the dir first) and never checked, so the collision is invisible and the `versions()`
listing has no way to filter to the requested path. 64-bit collisions are
astronomically unlikely by chance, but the input is **attacker/user-controlled path
strings**, and FNV-1a is not collision-resistant — a crafted pair of paths colliding
is feasible. Even absent an attacker, the design has no integrity check.

**Fix:** Store the absolute path inside each snapshot dir (already partially done via
`_path`) and verify it matches the requested path in `versions`/`contentString`
before returning anything; on mismatch, treat the dir as belonging to a different
file (fall back to an empty history or a secondary suffixed dir). Or switch the dir
key to a collision-resistant hash (SHA-256) and still keep the `_path` verification.

**CONFIRMED** — `pathKey` is FNV-1a-64 of the path (`LocalHistoryStore.swift:172-179`); `fileDirectory(for:)` keys solely on it (`:146-148`); `_path` is written once and never read back (`:99-102`); neither `versions(for:)` (`:109-129`) nor `contentString(of:for:)` (`:133-137`) verify the requested path against `_path`, and `pruneIfNeeded` evicts by timestamp across the shared dir (`:152-162`). A collision returns/evicts the wrong file's bytes with no integrity check. (Practical reachability is low — a 64-bit collision is astronomical by chance and a crafted colliding path must also be a real openable file — hence medium-leaning-low, but the missing-verification defect is real.)

### `SessionIndex` makes `version` a required field; an index missing it (legacy / hand-edited / partial write) is classified `corrupt`, discarding `lastActiveID` and session order

**Severity:** medium

**Location:** `Sources/ViewerCore/Sessions/SessionSnapshot.swift:230-242`
(`SessionIndex.version: Int` non-optional), `SessionStore.swift:140` (`SchemaProbe`
also requires `version`), classification `SessionStore.swift:144-168`,
recovery path `SessionsCoordinator.swift:105-112,187-205`.

**Why:** Both the full `SessionIndex` decode and the `SchemaProbe` fallback require a
non-optional integer `version`. Any `index.json` without that key — a file written by
a hypothetical pre-versioning build, a user/tool that hand-edited the JSON and dropped
the field, or a *partial* write that landed the `sessions` array but not `version`
(possible given the no-fsync issue above) — fails both decodes and is classified
`.corrupt`. The corrupt path (`SessionsCoordinator.swift:105-112`) then either
self-heals from orphaned snapshots (good) or, if recovery yields nothing usable,
**starts empty and is free to overwrite** the file. Even when snapshot-recovery
succeeds, the recovered index is rebuilt from snapshot files and the user's explicit
`lastActiveID` and tab/session *ordering* in the original index are lost (recovery
sorts by `lastActiveAt`, `SessionStore.swift:236-239`). A more graceful migration —
"no version key ⇒ assume v1" — would preserve the index instead of treating a benign
schema-drift as corruption.

**Fix:** Make `version` decode-optional with a default of `1` (treat a missing
version as the original schema), so a version-less but otherwise-valid index loads
intact. Keep the `> currentSchema` newer-schema guard for genuine downgrades. This
turns a "lose ordering / risk overwrite" path into a clean load.

**CONFIRMED** — `SessionIndex.version` is non-optional `Int` (`SessionSnapshot.swift:232`) and `SchemaProbe { let version: Int }` likewise (`SessionStore.swift:140`), so a version-less `index.json` fails both decodes → `.corrupt` (`:144-168`). The `.corrupt` recovery rebuilds from snapshots sorted by `lastActiveAt` and re-derives `activeID` (`SessionsCoordinator.swift:105-112`, `adoptRecoveredSnapshotsIfAny` `:187-205`), losing the index's explicit `lastActiveID`/ordering. (Caveat: a *truncated* write yields invalid JSON that fails decode regardless of the version key, so the realistic trigger is a hand-edit, not a partial write — but the assume-v1 robustness gap and the recovery-path ordering loss are real.)

### `SessionStore.flushSync` and `JSONFileStore.flushSync` drain two independent queues with no cross-queue ordering — a clean quit can still leave a stale `index.json` pointing at a not-yet-written snapshot

**Severity:** low

**Location:** `Sources/ViewerCore/Sessions/SessionStore.swift:35-38` (its own
`writeQueue`) vs `Sources/ViewerCore/JSONFileStore.swift:113-116` (a *different*
`writeQueue`); terminate drains them sequentially in `main.swift:497` (sessions)
then `:503` (JSONFileStore). Within `SessionStore.persist`, the index and the
snapshots are enqueued onto the *same* serial queue but as *separate* coalescing
entries keyed by URL (`SessionsCoordinator.swift:400-417`).

**Why:** Two concerns. (1) Sessions and the bookmark/history/recent-paths stores use
**separate** GCD queues; terminate flushes them one after the other, which is fine
for a clean quit but means there is no global ordering invariant — a future caller
that flushes only one queue (e.g. a "save sessions now" without the JSONFileStore
drain) would leave the other dirty. (2) More concretely: `index.json` and each
per-session snapshot are independent coalescing slots on the SessionStore queue. The
index references session ids; if a crash interrupts the queue *between* the index
write and a snapshot write (the no-fsync window above, or an OOM kill between two
async blocks), `index.json` can list a session whose snapshot file is older/partial
or absent. `restore` handles a *fully missing* snapshot (skip + log,
`SessionsCoordinator.swift:128-131`), but a snapshot that's present-but-stale
(reflecting an earlier index generation) silently restores out-of-date tab state.

**Fix:** Write per-session snapshots *before* the index that references them (so the
index never points ahead of what's on disk), and fsync each snapshot before writing
the index. Longer term, consider a single write queue / generation counter so a torn
write is detectable (index carries a generation; a snapshot older than the index's
generation is treated as stale).

**CONFIRMED** (low) — confirmed the two separate static queues (`SessionStore.writeQueue` `:35-38` vs `JSONFileStore.writeQueue` `:113-116`) drained sequentially on terminate (`main.swift:497` then `:503`), and that `persist()` enqueues the index BEFORE the snapshots on the shared serial queue (`SessionsCoordinator.swift:410` index, `:413-417` snapshots) — so a crash in the no-fsync window can leave the index one generation ahead of an interrupted snapshot. The recommended fix (snapshots-before-index + generation counter) is sound. Scoped low: the index `Entry` carries no tab CONTENT (only id/rootPath/displayName/lastActiveAt), so the worst case is "snapshot is one autosave behind" — the same lost-last-write window the fsync finding covers, not a dangling reference; a fully-missing snapshot is already skipped on restore.

### `EditorWriter` symlink classification still has a residual TOCTOU on the EACCES path

**Severity:** low

**Location:** `Sources/ViewerCore/EditorBuffer.swift:299-324` (the `EACCES` branch
recovers metadata via `lstat`), then the temp-write + `rename` at `:333-362`.

**Why:** The happy path closes the symlink TOCTOU well (it classifies via an
`O_RDONLY | O_NOFOLLOW` open and keeps the fd, `:274-277`). But the `EACCES` branch
(file exists, read denied) falls back to `lstat(path)` for mode/owner recovery and
then proceeds to temp-write-and-rename against `targetPath` by name. Between the
`lstat` and the `rename`, the path could be swapped (e.g. an attacker with write
access to the directory replaces the unreadable file with a symlink). The code
comments at `:354-357` argue rename "replaces the link itself," which is the safe
outcome for the *refuse* path — but on the EACCES branch we are *proceeding* with the
write, replaying the `lstat`'d mode/owner onto the temp, and renaming over whatever
now sits at the path. This is a narrow privilege/identity window (only when the file
is unreadable-but-writable and the directory is attacker-influenced), but it's a real
classify-then-act gap, unlike the fd-anchored happy path.

**Fix:** On the EACCES branch, prefer `fstatat`/`renameatx_np(RENAME_EXCL/…)` or
re-open the path no-follow after the temp is staged to confirm it's still the
non-symlink regular file `lstat` saw, and abort with a recoverable error on a
mismatch — closing the window the way the happy path already does with its retained
fd.

**REFUTED** — the residual gap is real (the EACCES branch re-derives identity by name via `lstat` rather than holding an fd, `EditorBuffer.swift:299-324`), but the claimed HARM does not occur. (1) `replay()` chowns/chmods the **temp file we just created** (`:350` → `:414-423`), not the target — replaying onto an owned temp is harmless. (2) The final `rename(temp, target)` (`:358`) replaces the destination *by name*; POSIX rename does not follow a symlink in the final destination component, so if an attacker swapped in a symlink post-lstat, rename replaces the LINK itself, never writing through to the link's target (the code's own comment at `:353-357` is correct). (3) The EACCES path is only reached when `open(O_RDONLY|O_NOFOLLOW)` returned EACCES, which means the target was NOT a symlink at classify time (a symlink would have returned ELOOP, handled earlier at `:280`). So there is no write-through-symlink and no clobber-of-attacker-target — the unsafe outcome the finding describes is prevented by rename-by-name semantics. Hardening (re-confirm no-follow / `renameatx_np`) is defensible defense-in-depth, but no exploitable identity/privilege window exists.

### `BookmarkEntry` decode falls back to `Date()` for an unparseable `addedAt`, silently corrupting "most-recently-pinned-first" ordering

**Severity:** low

**Location:** `Sources/ViewerCore/BookmarksStore.swift:251-269`
(`init(from:)` → `self.addedAt = Date()` fallback), ordering relies on insertion
order maintained at `:83` and `relocate`/`undo` preserving `addedAt`.

**Why:** When a bookmark entry's `addedAt` can't be decoded as ISO-8601 or as the
legacy string format, the decoder substitutes `Date()` (the load time). Bookmarks
are documented as "insertion-order (most recently pinned first)"
(`BookmarksStore.swift:4-5`); while the live list keeps array order, any feature that
sorts or displays by `addedAt` (and `relocate`'s preservation of `addedAt` across
renames, `:166,174`) now sees a fabricated timestamp equal to *every other*
unparseable entry's load time. A partially-corrupt store (a few bad `addedAt`
values) thus reorders the user's pins to the top en masse on next launch. It's a
deliberate "don't drop the entry" trade, but the silent fabrication is a data-
integrity smell — the entry's true age is lost with no marker.

**Fix:** On an unparseable `addedAt`, fall back to `Date.distantPast` (so a malformed
entry sorts to the *bottom*, not the top, and is visibly stale) rather than `Date()`,
or carry a `dateUncertain` flag so the UI can avoid trusting it for ordering.

**CONFIRMED** (with a correction) — the `Date()` fallback is real (`BookmarksStore.swift:263`). The reviewer's "reorders on next launch" framing is WRONG: `load()` preserves the on-disk ARRAY order verbatim with no sort (`:200-206`), so the raw insertion-order list is unaffected. BUT `BookmarksSection.swift` genuinely sorts by `addedAt` in its `.recent` (`:157`, descending) and `.created` (`:164`) sort modes — there, a corrupt entry's fabricated load-time `Date()` sorts it to the TOP in `.recent` mode and corrupts its position in `.created`. So the data-integrity smell and the `.distantPast` fix are valid for the sidebar sort surface; the relative-date display (`:247`) also shows a fabricated age.

### `AppCacheReset.reset` moves live store files out from under the running app's in-memory state, leaving the next coalesced write to recreate a partial file

**Severity:** low

**Location:** `Sources/ViewerCore/AppCacheReset.swift:140-175` (`reset` →
`fm.moveItem`); interacts with the still-armed periodic flush
(`SessionsAppCoordinator.swift:383-394`) and the coalescing write queues.

**Why:** `File → Reset` moves `Sessions/`, `bookmarks.json`, `history.json`, etc.
into a backup dir while the app is *running*. The in-memory stores
(`BookmarksStore.entries`, `HistoryStore.entries`, the `SessionsCoordinator`'s live
`sessions`, the periodic autosave timer) are unaware. The reset does not clear those
in-memory models or cancel the armed autosave/periodic-flush. So immediately after a
"Reset Session Tabs" the next debounced autosave (`fireAutosave`,
`SessionsAppCoordinator.swift:432-449`) or periodic tick re-enqueues the *current*
in-memory session set and recreates `Sessions/index.json` + snapshots — partially
undoing the reset and possibly re-materializing exactly the "stuck" state the user
was trying to clear. Bookmarks/history are less affected (their stores aren't
re-saved unless mutated), but a bookmark toggle right after the reset rewrites
`bookmarks.json` from the un-cleared in-memory `entries`.

**Fix:** After a reset, have the executor (or its caller) also clear/reload the
corresponding in-memory models and cancel any armed autosave so the on-disk and
in-memory views agree — or perform resets only on a path that forces the app to
re-bootstrap those stores from the now-empty disk state.

**REFUTED** — the sole caller, `performReset` (`main.swift:652-684`), runs fully SYNCHRONOUSLY on the main thread (`alert.runModal()` → `AppCacheReset.reset` move → optional UserDefaults clear → `relaunchAndExit()`) with no `await`, no `DispatchQueue.async`, and no run-loop spin between the move and `exit(0)`. `relaunchAndExit()` calls `exit(0)` (`:690-699`) deliberately bypassing `applicationWillTerminate`'s flush (comment at `:686-689` states exactly this rationale: "would re-persist the in-memory state we just cleared"). Because the main thread never returns to its run loop between the file move and process death, neither the debounced autosave (`asyncAfter` block, `SessionsAppCoordinator.swift:422`) nor the periodic timer (`:385-393`) can fire to recreate `index.json`/snapshots, and the "bookmark toggle right after reset" is impossible — the process is dead and relaunches into the now-empty disk. The reset's resurrection risk is closed by the synchronous `exit(0)`, not left open.
