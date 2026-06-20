# Adversarial Code Review — Concurrency (2026-06-18)

This codebase is, on the whole, unusually disciplined about concurrency: nearly every
`@unchecked Sendable` / `nonisolated(unsafe)` site is paired with an `NSLock` and a
documented audited-access invariant, the FFI transport seam serializes correctly, the
LSP client carefully orders continuation registration vs. timeout arming, and
`TrackedReposStore` is a textbook actor that off-loads blocking git to `Task.detached`
so it never pins its executor. The genuine defects that survive that bar cluster in the
git-stats / git-chip surface and the actor/`Task.detached` cancellation seam, where
asynchronous results are published without a freshness/cancellation guard, where a
concurrency-gate slot is released outside a `defer`, and where one actor does the exact
*opposite* of the codebase's own off-load-blocking-work rule. Findings below are ordered
roughly by severity.

### Stale/out-of-order async result clobbers the git-chip menu (last-writer-is-wrong)

**Severity:** high

**VERDICT: CONFIRMED** — `.task(id: root)` cancellation does not stop the default `enumerate`'s `Task.detached` git walk, and `load`'s non-throwing `await enumerate(root)` resumes after cancellation (no `checkCancellation`/freshness gate) and unconditionally publishes; an A-after-B finish leaves `loadedRoot = A` while the user is in repo B. Real, host-reproducible.

**Location:** `Sources/ViewerUI/GitChipStore.swift:41-46` (`load(root:)`), with the
detached enumeration at `:31-36`.

**Why:** `load(root:)` awaits `enumerate(root)` and then unconditionally publishes
`branches`, `worktrees`, and `loadedRoot` with no check that `root` is still the repo of
interest. The default `enumerate` runs the git work inside `Task.detached`, which is
**not** cancelled by parent-task cancellation. So when the call site's `.task(id: root)`
re-fires on a repo switch (A → B), SwiftUI cancels the prior `.task`, but the detached
`localBranches()/worktreeList()` for A keeps running and its `await …value` still resumes
`load(root: A)`, which then publishes A's data. If A's git walk finishes after B's (a
large repo A, a tiny repo B — entirely plausible), the final state is
`branches = A, loadedRoot = A` **while the user is sitting in repo B** — the chip menu
offers branches/worktrees from the wrong repository, and a "switch to branch X" action
keyed off that list operates on the wrong root. Pure logic, host-reproducible.

**Fix:** Make the publish freshness-guarded. Capture the requested root, and after the
await, only publish if it is still current — either gate on an in-flight token
(monotonic counter incremented per `load`, compared after the await) or drop
`Task.detached` in favor of a structured child task (`async let` / a child `Task`) that
honors cooperative cancellation and bail with `try Task.checkCancellation()` before
assigning `@Published` state. The token approach is safest because the detached work
can't be cancelled.

### `RepoStatsCache` actor blocks its serial executor on synchronous git history walks

**Severity:** high

**VERDICT: CONFIRMED** — `stats()` has no `await` and calls blocking `headInfo()`/`repoStats()` (real subprocess shell-outs) on the actor's serial executor, head-of-line-blocking every other `stats()`/`invalidate*()` for seconds; no in-flight coalescing, so N folder rows over one repo serialize N walks. Directly contrary to `TrackedReposStore.refresh`'s `Task.detached` off-load.

**Location:** `Sources/ViewerCore/Git/RepoStatsCache.swift:62-80` (`stats`), calling the
synchronous `GitClient.headInfo()` (`GitClient.swift:765`) and `GitClient.repoStats(…)`
(`GitClient.swift:905`, which shells out via `ProcessRunner.run`).

**Why:** `stats(...)` is an actor method that does **no `await`** — it calls blocking
git subprocesses (`rev-list --count`, `shortlog -sne` — the doc-comment itself says
"seconds on a large monorepo") directly on the actor's executor. Because an actor's
executor is serial, the entire git walk holds the actor exclusively: every other caller
`await`ing this *shared* cache (`DocumentModel.repoStatsCache`, used by every expanded
folder-stats row — `FolderStatsView.swift:242`) is head-of-line blocked behind it, and
`invalidateAll()` / `invalidate(repoRoot:)` from the UI cannot run until the walk
finishes. There is also no in-flight coalescing, so N folder-stats views over the same
repo issue N sequential multi-second walks back-to-back rather than sharing one. This is
the exact anti-pattern `TrackedReposStore.refresh` was written to avoid (it explicitly
`await Task.detached`s the blocking git so it "doesn't pin the actor's executor" —
`TrackedReposStore.swift:221-226`); `RepoStatsCache` does the opposite.

**Fix:** Move the blocking calls off the executor: wrap `headInfo()` + `repoStats(scope:)`
in `await Task.detached(priority: .userInitiated) { … }.value` so the actor suspends
(freeing its executor) during the git I/O, re-entering only to read/store the cache —
mirroring `TrackedReposStore.refresh`. Add an in-flight `[Key: Task<RepoStats, Never>]`
map so concurrent requests for the same key share one walk.

### Concurrency-gate slot leaked when refresh unwinds abnormally

**Severity:** medium

**VERDICT: REFUTED** — `refresh` is `async` but NOT `throws`; the only suspension points between acquire (:219) and release (:240) are `acquireRefreshSlot()` (`withCheckedContinuation`, non-throwing) and `await Task.detached{…}.value` (closure has no `try`, the await is non-throwing, and cancellation doesn't throw on a non-throwing value await). The finding's concrete triggers — a `fatalError`/trap/OOM inside the detached closure — abort the whole process rather than unwind this method, so they cannot leak a slot while the process survives. The `defer` asymmetry vs `inFlight` is a worthwhile defensive hardening (a future `try`/throwing refactor would leak), but as written no reachable path leaks the slot. Not a live defect.

**Location:** `Sources/ViewerCore/Git/TrackedReposStore.swift:213-294` — `acquireRefreshSlot()`
at `:219`, `releaseRefreshSlot()` at `:240` (not deferred); gate impl at `:115-135`.

**Why:** `refresh(root:)` does `await acquireRefreshSlot()` and then calls
`releaseRefreshSlot()` as a *plain statement* on the success path (`:240`), not in a
`defer`. The `inFlight` flag right above it (`:217`) *is* protected by `defer { inFlight.remove(r) }`,
so the asymmetry is the tell. If anything between acquire and release fails to fall
through to `:240` — most concretely a trap/`fatalError` inside the `Task.detached`
closure (a force-unwrap in `GitClient` against a pathological repo, an OOM, an assertion)
— the actor method unwinds without releasing the slot. Each such event permanently
decrements available capacity; after `maxConcurrentRefreshes` of them, **every** future
`refresh` parks forever in `acquireRefreshSlot()`'s continuation and git badges silently
stop updating app-wide, with no error surfaced. The `refreshWaiters` continuations are
also never drained on store teardown, but the slot-leak is the live hazard.

**Fix:** Acquire then immediately `defer { releaseRefreshSlot() }`, exactly as `inFlight`
is handled, so the slot is returned on every exit path including a trapping child. (Also
consider draining/resuming any parked `refreshWaiters` if the store can be deinitialized
while waiters are queued, to avoid leaked suspended tasks.)

### `RemoteTransport` subscription handler can fire after `unsubscribe` returns

**Severity:** medium

**VERDICT: CONFIRMED** — `route`'s event case copies the handler out of `subs` under the lock, unlocks, then invokes it; `unsubscribe` only nils `subs[sub]` under the lock and returns. The reader's local copy survives the nil-out, so `handler(event)` can run after `unsubscribe` (and any teardown of its captured state) has completed. The "no events after unsubscribe returns" guarantee callers will assume does not hold. Medium is right: not-yet-default remote carrier. (NOTE: the actual path is `Sources/RustCore/RemoteTransport.swift`, not `Sources/ViewerCore/...` as the report header states.)

**Location:** `Sources/ViewerCore/RemoteTransport.swift:269-298` (`route`, event case at
`:282-288`) vs. `:181-188` (`unsubscribe`).

**Why:** In `route`, the event path reads `subs[event.sub]` under `state`, releases the
lock, **then** invokes `handler(event)`. `unsubscribe` sets `subs[sub] = nil` under the
same lock and returns. There is a window where the reader thread has already captured the
handler reference and unlocked, the caller's `unsubscribe` then completes and the caller
proceeds to tear down whatever the handler closes over, and only *then* does the reader
thread call `handler(event)` — a use-after-teardown of the handler's captured state. The
"events run on the reader thread" contract is documented, but the implicit guarantee
callers will assume — "no events after `unsubscribe` returns" — does not hold. Because
this is the remote carrier (not yet the default in-process path) it is medium, not high,
but it is a real ordering defect that will bite once the remote transport ships.

**Fix:** Either (a) snapshot+invoke the handler entirely under a guarantee that
`unsubscribe` waits for the in-flight dispatch (e.g. dispatch event delivery onto a
per-transport serial queue and have `unsubscribe` sync-barrier on it), or (b) document
loudly that handlers must tolerate one trailing call after `unsubscribe` and keep their
captured state valid until the transport closes. The serial-delivery-queue option also
removes the need for handlers to be reentrancy-safe against `route`.

### `MCPServer.runOnMainActor` parks the reader thread on an unkillable semaphore

**Severity:** medium

**VERDICT: CONFIRMED (no-deadline wait only; force-unwrap is presently sound)** — `semaphore.wait()` has no deadline, so a wedged/slow main actor parks the reader thread with no recovery, and `stop()` (which only closes stdin) cannot release a thread already past the read and parked on this semaphore. That is a real liveness gap on a documented lifecycle path. The `return box!` force-unwrap, however, is sound as written: `work()` is non-throwing and the unstructured Task always assigns `box` before `signal()`; the crash is only a future-refactor hazard, not a live one. Confirming the no-deadline-wait edge; the unwrap concern is hardening, not a current defect.

**Location:** `Sources/ViewerCore/Automation/MCPServer.swift:222-240` (`runOnMainActor`),
interacting with `stop()` at `:80-85`.

**Why:** The bridge spawns an unstructured `Task { @MainActor in box = work(); semaphore.signal() }`
and blocks the reader thread on `semaphore.wait()` with **no deadline**. Two real
hazards: (1) If the main actor is wedged or extremely slow (a long-running main-actor
operation, a modal run loop), the reader thread is parked indefinitely and `stop()`
cannot release it — `stop()` only closes stdin (which unblocks the *read*, not a thread
already past the read and parked on this semaphore mid-request). (2) `return box!`
force-unwraps; it is sound only as long as the `Task` always runs `box = work()` before
signaling — but the `Task` is unstructured and `@MainActor`-hopped, so if the process is
torn down between `signal()` and the unwrap the ordering still holds, but any future
refactor that lets the semaphore be signaled on an error path before `box` is assigned
turns this into a crash. The `precondition(!Thread.isMainThread)` correctly catches the
main-on-main deadlock, but the no-deadline wait + force-unwrap are the residual sharp
edges.

**Fix:** Give the wait a generous deadline and, on timeout, return a JSON-RPC internal
error for that request instead of parking forever (so a wedged handler degrades one
request rather than freezing the whole stdio loop). Keep `box` as a `Result` so the
signal path always carries a value and the unwrap becomes a `switch` with no `!`.

### `PTYProcess.start()` double-fork window; `onOutput`/`onExit` read unsynchronized

**Severity:** low

**VERDICT: CONFIRMED** — `start()` checks the `childPID <= 0` guard under `lock`, unlocks (:71), runs `forkpty`, then re-locks to assign `childPID` (:103-107): two concurrent `start()` calls both passing the guard would fork two shells and leak a master fd/pid. `onOutput`/`onExit` are plain `var`s read on `readQueue` with no `lock`. Real TOCTOU + unsynchronized-read on a `public @unchecked Sendable` surface; correctly scoped low — the only in-tree caller is `@MainActor TerminalModel`, which serializes and guards with `!pty.isRunning`.

**Location:** `Sources/ViewerUI/Terminal/PTYProcess.swift:68-111` (`start`, the
unlock-fork-relock window) and `:29-32` / `:170,225` (the `var onOutput`/`onExit`
callbacks read on `readQueue` without `lock`).

**Why:** `start()` reads the `childPID <= 0` guard under `lock`, **unlocks**, runs the
(slow) `forkpty`, then re-locks to store `childPID`. Two concurrent `start()` calls both
passing the guard before either assigns would fork two shells and leak one master
fd/pid; the type is `public` + `@unchecked Sendable` and documents "a second start while
running is ignored," but that is only true if callers serialize. Separately, `onOutput`
/ `onExit` are plain `var`s read from the read-source handler on the background
`readQueue` while the type's contract is "set before start" — fine in the current sole
caller (`TerminalModel`, which is `@MainActor` and guards with `!pty.isRunning`), but the
public surface invites a data race that the `lock` does not cover. Real but low because
the only in-tree caller is single-threaded `@MainActor`.

**Fix:** Hold `lock` across the guard-check and `childPID`/`masterFD` assignment (fork
inside the critical section is acceptable here, or use a separate `starting` flag set
under the lock to reserve the slot before unlocking to fork). Guard `onOutput`/`onExit`
reads under `lock`, or make them `let` constructor params / document that the public
contract requires external serialization of `start`.

### `AudioEditorViewModel.load()` has no re-entrancy guard (duplicate decodes)

**Severity:** low

**VERDICT: CONFIRMED** — call site is `AudioEditorView.swift:50 .task { await vm.load() }`; a disappear/reappear cancels the `.task` but the in-flight `Task.detached` decode keeps running (detached ignores parent cancellation) and `load()` neither checks `isLoading`/an in-flight `Task?` nor `Task.checkCancellation()`. A re-fire launches a second multi-MB decode concurrently; the later completion clobbers the earlier's published state. Wasteful, not incorrect (`@MainActor` ⇒ no data race) — low is right.

**Location:** `Sources/ViewerUI/AudioEditorViewModel.swift:94-114`.

**Why:** `load()` is `@MainActor` so there is no data race, but it has no guard against
being invoked while a prior `load()` is still awaiting its `Task.detached` decode (e.g. a
view re-appears, or `.task` fires twice). Two full multi-MB audio decodes run
concurrently and the later completion clobbers the earlier's published state. Wasteful
(CPU + transient memory doubling on a large file) rather than incorrect, hence low.

**Fix:** Track the decode in a `Task?` property; cancel/await-or-ignore a prior in-flight
load before starting a new one, or early-return if `!isLoading` / a decode is already in
flight.
