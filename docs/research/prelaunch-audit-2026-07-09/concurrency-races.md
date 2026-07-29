# Pre-launch audit — Concurrency, threading, races

**Date:** 2026-07-10
**Reviewer:** Claude (automated pre-launch product review, dimension: concurrency/threading/races)
**Repo state:** `main` @ `92c72206` (+ uncommitted working-tree edits to `Sources/MarkdownViewer/main.swift`, `Sources/ViewerCore/Automation/MCPSocketBridge.swift` — reviewed as-is)

---

## Executive summary

This is one of the most concurrency-hardened codebases I have reviewed. Nearly every `@unchecked Sendable` / `nonisolated(unsafe)` in the tree carries an explicit invariant comment naming the lock or ordering that justifies it, and most of the classic races (double-fork on PTY start, LSP continuation-vs-timeout registration order, coalesced-write vs flush, FFI handle use-after-free) have already been found, fixed, and documented in place with ticket references.

The residual risk concentrates in **one seam: the Automation/MCP socket path's teardown and reconnect logic**. The project *knows* the two relevant macOS footguns — (a) closing an fd under a blocked `read(2)` does not reliably wake the reader, and (b) a closed fd number can be recycled and then read/written by a stale holder — because `MCPSocketBridge.ServeState` documents and correctly solves both (retain-across-syscall + `shutdown(2)`-not-`close`). But the *other three* components on the same seam (`MCPServer.stop()`, `MCPSocketBridge.pump()`, `MCPSocketListener.stop()`) still use bare `close()`, and `MCPServer` writes responses through a **cached raw fd** with no synchronization against that close. The worst-case interleaving (finding 1) can write JSON-RPC response bytes into a recycled descriptor during quit — i.e. into a session/history file mid-flush. Low probability, real mechanism, small fix (use `shutdown(2)` consistently).

Second theme: **timeout paths that abandon rather than cancel**. The MCP main-actor bridge and the async-tool lane both give the client a definite error on deadline, but the abandoned handler keeps running and may commit its side effects afterwards — for mutating tools (`rename_symbol` / `move_file` with `apply:true`) a client retry produces duplicate application.

No P0s. 12 findings total: 1×P1, 5×P2, 6×P3.

---

## Methodology

Static review, read-only (no tests were run; no repo file modified other than this report).

- **Sweeps across all of `Sources/` (4 strata) + `rust-core/crates/`** for: `@unchecked Sendable` (~60 files), `nonisolated(unsafe)` (~70 files), `DispatchSemaphore` (14 files), `NSLock`/`os_unfair_lock`/`NSCondition` (~40 files), `Task.detached` (~30 files), `Task.sleep`/`usleep`/`Thread.sleep`, `DispatchQueue.main.sync` (10 sites), `MainActor.assumeIsolated` (~20 sites), `withChecked*Continuation` (4 files), Rust `static mut`/`unsafe impl Send/Sync`/`thread::spawn`.
- **Full-file reads:** `MCPServer.swift` (593 lines), `MCPSocketBridge.swift` (263), `MCPSocketListener.swift` (177), `CoreTransport.swift` (181).
- **Targeted reads (relevant regions):** `MCPFraming.swift` (FileHandleReader), `MCPToolCatalog.swift` (async lane), `DocumentModel+AutomationHost.swift`, `LSPClient.swift`, `LSPPool.swift`, `SessionStore.swift` (enqueue/flush/syncWrite), `ProcessRunner.swift` (boxes/escalator), `PTYProcess.swift`, `TerminalModel.swift`, `HexView.swift` (chunked build), `ArchiveCatalog.swift`, `JSTransform.swift`, `ScriptRunner.swift`, `ClaudeMonitorView.swift`, `RepoStatsCache.swift`, `GrammarLoader.swift`, `TreeSitterEngine.swift`, `FileWatcher.swift`, `FolderWatcher.swift`, `StatusBar.swift`, `GitPanelModel.swift`, `Obs.swift`/`RingBufferSink.swift`, `CrossFileSearch.swift`, `DocumentModel+TabLoading.swift`, `main.swift` (launch + quit paths), `rust-core/crates/ffi/src/handle.rs` + `canvas_handle.rs` (headers), `rust-core/crates/serve/src/main.rs` (accept loop + lifecycle threads).
- Verification approach: for each candidate finding I traced the actual interleaving (who holds what, which thread is where) rather than pattern-matching on primitives; several dozen candidate sites were dismissed because the in-code invariant holds (listed under Positive observations).

---

## Findings

### 1. [P1] MCP connection teardown races an in-flight response: cached `outputFD` can be written after `close()`, landing on a recycled descriptor

- **Files:**
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/Automation/MCPServer.swift:33` (fd cached once at init), `:115-120` (`stop()` = `try? input.close()`), `:504-507` (`send` writes via cached fd, no stop-check), `:429` (async-tool lane completes on a detached task, independent of main)
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/MarkdownViewer/main.swift:708-726` (`applicationWillTerminate`: `mcpSocketListener?.stop()` **then** `sessions.flushForTermination()` + `JSONFileStore.flushSync()` — which open new fds)
- **Evidence / mechanism:** For socket-listener connections, `input === output` = the connection's `FileHandle`. `MCPServer.stop()` closes it, freeing the fd *number* while a request may still be in flight (the reader thread parked on its per-request semaphore, up to 20 s). `send(response:)` then writes via the **cached** `outputFD` (`MCPServer.swift:504-507`, raw `write(2)` per TSK-1559) with no synchronization against `stop()` — `writeLock` is not taken by `stop()`, and `send` never rechecks `stopFlag`. Concrete quit-path interleaving: (1) agent issues an async tool call (`goto_definition`) → reader parked, detached LSP task running; (2) user quits; (3) `applicationWillTerminate` stops the listener → connection fd N closed; (4) `flushForTermination` / `JSONFileStore.flushSync` open temp files on the write queue — one gets fd N; (5) the detached tool task completes (it does not need the blocked main thread) and signals; (6) the reader thread writes the framed JSON-RPC response to fd N → **response bytes are injected into the session/history file being flushed**. The project's own comments show full awareness of this hazard class: `MCPSocketBridge.swift:130-134` ("Hold the retained HANDLE across the write: the fd can never be closed+recycled out from under the syscall") and `:253-258` (`shutdown(2)`, not `close()`). `MCPServer` has neither guard.
- **Impact:** Corruption of user persistence files (session snapshots, history, bookmarks) at quit, or byte injection into any other concurrently-opened descriptor (LSP pipe). Narrow window, but MCP traffic concurrent with quit is a realistic steady state for this product (agents drive the app continuously).
- **Suggested fix:** In `MCPServer.stop()`, `shutdown(fd, SHUT_RDWR)` *before* (or instead of) `close()` — mirroring `ServeState.clientClosed` — so the fd number stays reserved until the last holder releases; additionally have `send` check `stopFlag` under `writeLock` and drop the write once stopped. Atomic-rename writes in `JSONFileStore` reduce but do not eliminate the blast radius (the temp file gets corrupted, then renamed into place).
- **Fix size:** S. **Fix risk:** careful (teardown-order sensitive; wants a wedge-style regression test like `MCPServerWedgeTests`).

### 2. [P2] MCP bridge reconnect truncates in-flight messages in both directions — contradicts the "no message loss" contract

- **File:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/Automation/MCPSocketBridge.swift:129-145` (stdin→socket loop), `:169-183` (socket→stdout loop), doc claim `:104-108`.
- **Evidence:** The stdin pump writes `buf[off..<n]`; on write failure it calls `state.remoteDied(handle)` and retries **from the same `off`** against the next socket. Bytes `0..<off` were already consumed by the *dead* app instance — so the fresh app-side `MCPServer` receives a message **tail** starting mid-frame. Comment `:106-108` claims "no message loss across an app restart … the write position is tracked per message buffer", but the buffer is a raw 64 KiB read chunk, not a message: the head is gone. Symmetrically, a response half-forwarded to stdout when the socket dies (`:177-183`) leaves the client's framing decoder desynced — the next connection's responses concatenate onto a partial frame.
- **Impact:** After an app quit/relaunch mid-request: with newline framing the server answers a parse error for a request the client believes is still pending (client-side hang until its own timeout); with Content-Length framing the decoder desyncs and the connection churns. The self-healing loop recovers the *transport* but silently drops/corrupts the *session's* in-flight exchange.
- **Suggested fix:** Make the pump message-aware on the client→server side (buffer until a frame boundary before forwarding; only re-send whole frames after a swap). On the server→client side, track whether a response frame was mid-flight at death and emit a synthetic JSON-RPC error / resync marker instead of splicing streams. Alternatively, drop the mid-write message and document the loss honestly.
- **Fix size:** M. **Fix risk:** careful (protocol-visible behavior; needs bridge round-trip tests over kill/reconnect).

### 3. [P2] MCP timeout paths abandon (never cancel) in-flight handlers — mutating tools can double-apply on client retry

- **Files:**
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/Automation/MCPServer.swift:318-333` (`runOnMainActor` deadline: "The wedged Task may still complete later"), `:429-434` (async lane 20 s deadline, same abandonment)
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/Automation/MCPToolCatalog.swift:343-345` (`isAsyncTool`: includes `rename_symbol`, `run_task`, `move_file`)
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/Automation/DocumentModel+AutomationHost.swift:104-160` (`automationRenameSymbol` / `automationMoveFile` with `apply: true` mutate open buffers + move files via `MainActor.run`)
- **Evidence:** On deadline expiry the client receives a definite error, but the spawned `Task` (main-actor bridge) / `Task.detached` (async lane) is never cancelled — the code explicitly calls the orphaned completion "harmless" because the *semaphore* is local. The *side effects* are not local: a `move_file(apply:true)` that exceeds 20 s (LSP `willRenameFiles` on a cold server is the documented slow path) still applies workspace edits and moves the file **after** the client was told it failed. A retrying client then applies edits twice (the second move fails on never-overwrite, but the buffer edits re-apply). The wedged-main variant additionally executes request N's side effects *after* request N+1 has been dispatched and answered — out-of-order mutation relative to the response stream.
- **Impact:** Duplicate/misordered model mutations driven by the agent lane; buffer edits applied twice; agent and app state silently diverge (agent believes the operation failed).
- **Suggested fix:** Keep the `Task` handle and `cancel()` it on `.timedOut` (handlers already ride async LSP calls that propagate cancellation); for the main-actor bridge, check `Task.isCancelled` before committing mutations. Longer-term: a per-request idempotency key for mutating tools.
- **Fix size:** M. **Fix risk:** careful (cancellation propagation through the LSP pool needs verifying; a cancelled-after-apply window still needs a commit-point check).

### 4. [P2] `MCPServer.stop()` and `pump()` use `close()` where the project's own lesson requires `shutdown(2)` — blocked readers may never wake (thread/instance leak, potential `pump` hang)

- **Files:**
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/Automation/MCPServer.swift:115-120` (`stop()` doc claims "Closing stdin causes any blocking read … to return EOF")
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/Automation/MCPSocketBridge.swift:63-94` (`pump`'s `copyLoop` closes the *other* handles on EOF while the sibling thread is blocked reading them; `group.wait()` at `:94` then depends on that reader waking)
  - Contradicting lesson, same file `:253-258`: "`shutdown(2)`, not `close()`: … closing a unix-socket fd under a blocked reader does not reliably wake it on macOS".
- **Evidence:** For socket-backed connections (`MCPSocketListener.serve`, where the `MCPServer`'s input *is* a unix socket), `stop()`'s `close()` hits exactly the unreliable-wake case the bridge's own comment documents. A reader parked in `read(2)` between frames stays parked; the `MCPServer`, its thread, and the `FileHandle` leak until the peer closes. In `pump()`, the stdin→socket thread closing `remote` under the socket→stdout thread's blocked `read` can leave `group.wait()` blocked — a bridge-process hang on the one-round path.
- **Impact:** Leaked threads/servers per connection on listener stop (quit path masks it; tests and any future listener restart do not); possible hang of the `pump`-based bridge round.
- **Suggested fix:** `shutdown(fd, SHUT_RDWR)` before close in `MCPServer.stop()` (same change as finding 1) and in `pump`'s `thenClosing` path for socket handles.
- **Fix size:** S. **Fix risk:** safe.

### 5. [P2] `ArchiveCatalog.run` timeout path: no SIGKILL escalation, no reap → zombie child + leaked reader thread; result handoff has no formal happens-before

- **File:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/Archive/ArchiveCatalog.swift:196-224` (`terminate()` at `:216`, `reader.isFinished` poll at `:220`).
- **Evidence:** On deadline the code calls `p.terminate()` (SIGTERM only) and throws immediately — no SIGKILL escalation, no `waitUntilExit()`. An archive tool that ignores SIGTERM (or is wedged in uninterruptible IO) keeps running; its exit status is never collected (zombie until the parent quits), and the reader `Thread` blocked in `readDataToEndOfFile()` leaks with it. Compare `ProcessRunner._Escalator` (`/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/ProcessRunner.swift:485-505`) and `PluginSubprocessHost` (`:290-322`), which both do the full SIGTERM→grace→SIGKILL→reap dance — this file rolled its own and skipped the second half. Additionally `data` is written on the reader thread and read by the caller after a `while !reader.isFinished { Thread.sleep(0.005) }` poll — `Thread.isFinished` is not a documented memory barrier (works in practice on ARM64 through the sleep/scheduling fences, but it is the letter-of-the-law data race, and `swift test -sanitize=thread` would flag it).
- **Impact:** Wedged archive tool → accumulating zombies + threads per open attempt; TSan-unclean handoff.
- **Suggested fix:** Route through `ProcessRunner` (it already owns escalation, byte caps, and drain queues), or copy the `_Escalator` pattern + join the reader via `DispatchGroup` instead of `isFinished` polling.
- **Fix size:** S–M. **Fix risk:** safe.

### 6. [P2] `MCPSocketListener` stop()/start() restart race: shared `stopped` flag + recycled listen fd can leave the *old* accept loop serving the *new* generation

- **File:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/Automation/MCPSocketListener.swift:102` (`start()` resets `stopped = false` on the shared instance), `:112-123` (`stop()` closes fd, does not join the thread), `:125-139` (loop re-checks the *shared* `stopped` after each `accept`).
- **Evidence:** `stop()` neither joins nor generation-fences the accept thread. If `start()` is called again promptly: (a) it resets `stopped = false`; (b) the new `socket()` can be assigned the just-closed fd *number*. The old thread — woken from `accept` by the close, or about to re-enter it — now sees `stopped == false` and `accept(fd)`s on a descriptor that aliases the **new** listener's socket. Result: two accept loops on one fd; the old loop `serve()`s connections and appends servers to the same `servers` array under a `stopped` regime it doesn't own. Today the only `stop()` caller is `applicationWillTerminate` (`main.swift:712`), so production never restarts — this is latent, but the class is public and a settings toggle or test that restarts it trips the race.
- **Suggested fix:** Capture a generation token (or simply the fd value checked against `listenFD` under `lock`) in the loop closure and exit when it no longer matches; or have `stop()` join the thread before returning.
- **Fix size:** S. **Fix risk:** safe.

### 7. [P3] `MCPFraming.FileHandleReader` fd-recycle comment overclaims safety: a mid-frame `stop()` can read bytes from an unrelated recycled descriptor

- **File:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/Automation/MCPFraming.swift:263-277` ("a post-close fd recycle would at worst frame-error into EOF, never crash").
- **Evidence:** `read(2)` on a *recycled* descriptor does not return EBADF — it succeeds and **consumes bytes belonging to whatever now owns that fd number** (an LSP pipe, a file). The `shouldStop` check in `MCPServer.runLoop` (`MCPServer.swift:136`) guards loop re-entry, but `decodeDetecting` performs multiple reads per frame (header scan, then body); a `stop()` landing between them leaves the next read un-guarded. Same family as finding 1, read side; the `shutdown`-first fix removes the window for both.
- **Impact:** Byte theft from an unrelated channel (corrupting *that* subsystem's stream) in a very narrow window.
- **Suggested fix:** Covered by finding 1's `shutdown(2)` change; also correct the comment.
- **Fix size:** S. **Fix risk:** safe.

### 8. [P3] `MCPServer.send` reads `wireMode` outside `writeLock`, contradicting its own synchronization contract

- **File:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/Automation/MCPServer.swift:84` ("read under `writeLock` when sending"), `:149` (write under lock — correct), `:504-507` (read at `:504` **before** `writeLock.lock()` at `:505`).
- **Evidence:** `let framed = MCPFraming.encode(body: body, mode: wireMode)` evaluates `wireMode` before the lock is taken. Today every `send` happens on the reader thread, so the race is unreachable — but `writeLock`'s stated reason for existing is a future "concurrent notification publish" (`:72-75`), and the first such publisher inherits a mode-tear (a notification framed in the wrong mode corrupts the client's decoder).
- **Suggested fix:** Hoist the `wireMode` read inside the `writeLock` critical section (one-line move).
- **Fix size:** S. **Fix risk:** safe.

### 9. [P3] `JSTransform.runAsync`: a timed-out user expression leaks a whole OS thread, unboundedly across retries

- **File:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/JSTransform.swift:69-86` (`Thread.detachNewThread` + `OneShot` timeout; the losing thread runs to "completion" that never comes for an infinite loop).
- **Evidence:** The continuation race is handled correctly (`OneShot` resolves exactly once), but a JS expression that never terminates (`while(true);` — user-authored, and the doc comment acknowledges the edge) leaves the detached thread spinning at 100 % of a core forever. Each re-run of the transform (the natural user reaction to a "timed out" toast) adds another. There is no JSC watchdog installed.
- **Impact:** CPU burn + thread accumulation proportional to user retries of a bad expression.
- **Suggested fix:** Install a JSC execution time limit (`JSContextGroupSetExecutionTimeLimit` via the C API on the context's group, with a callback that terminates the script) so the worker thread actually exits at the deadline; keep the semaphore/`OneShot` as the outer fence.
- **Fix size:** M. **Fix risk:** careful (C-API surface on JSContext; needs a wedge test).

### 10. [P3] `ClaudeMonitorModel.loadSessions` has no generation guard — overlapping scans can land out of order

- **File:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/ClaudeMonitor/ClaudeMonitorView.swift:158-173`.
- **Evidence:** `loadSessions()` sets `isLoadingSessions = true` but does not itself check it (only `refreshIfChanged` at `:191` does), and the detached scan publishes unconditionally at `:169-172`. Two triggers in quick succession (e.g. `onAppear` + a root change, or a manual reload racing the poll) run two directory scans whose completion order is unspecified — the older result can overwrite the newer, and `lastFingerprint` regresses with it (which then *suppresses* the next `refreshIfChanged` because the fingerprint matches the stale scan). Contrast with the content-search path, which does this correctly via `contentGeneration` (`:215-229`) and the detail path via `detailGeneration`.
- **Suggested fix:** Add the same generation counter to the session-list load (3 lines, matching `:215/:229`).
- **Fix size:** S. **Fix risk:** safe.

### 11. [P3] `HexView` chunked build parks a cooperative-pool thread in `DispatchQueue.main.sync` per chunk

- **File:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/HexView.swift:767-796`.
- **Evidence:** The detached producer blocks in `main.sync` for every chunk push. Deadlock-safety is correctly argued in the comment (detached ⇒ no main-actor frame beneath it), but each concurrent hex build pins one cooperative-pool thread for the build's duration in wait-on-main; the pool is width-of-cores, so a handful of simultaneous large hex tabs (session restore) plus other detached work can starve unrelated async jobs. Priority inheritance across `main.sync` from a detached task is also weaker than an actor hop.
- **Suggested fix:** Replace the synchronous callback bridge with an `AsyncStream` of chunk `String`s consumed by a main-actor task (backpressure via the stream's buffering policy) — removes the blocked pool thread entirely.
- **Fix size:** M. **Fix risk:** careful (streaming order/generation guards must be preserved).

### 12. [P3] Fixed settle sleeps in the `--script` automation harness (self-acknowledged flake source)

- **File:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/MarkdownViewer/ScriptRunner.swift:49` (1 s launch settle), `:65` (fixed 300 ms per-step settle), vs `:132-141` (`wait-editor-line`, the condition-polling pattern done right, added precisely because the fixed delay "was never PROVEN").
- **Evidence / impact:** The harness's own comments document that fixed delays under-wait on a loaded VM (the TSK-1047 history). Every remaining fixed-sleep verb is a latent UAT flake; this is the "arbitrary sleeps" lens applied to the validation lane rather than the product.
- **Suggested fix:** Generalize the `wait-*` condition-poll verbs and migrate step-settle to condition-based waits where a condition exists (scroll settled, accordion measured), keeping the fixed floor only as a cap.
- **Fix size:** M (incremental per verb). **Fix risk:** safe.

---

## Positive observations

Genuinely strong work, worth keeping as exemplars:

- **`MCPServer.runOnMainActor`** (`MCPServer.swift:250-334`): the `main.sync` → semaphore-bridge redesign is correct and superbly documented (why `main.sync` wedges, why the kernel semaphore can't, the bounded-wait liveness fix, the happens-before argument for the result box). Findings 1/3 are about its *teardown/abandonment* edges, not its core.
- **`MCPSocketBridge.ServeState`** (`MCPSocketBridge.swift:210-262`): textbook handling of the two macOS fd footguns — retained-handle-across-syscall to prevent fd recycle, `shutdown(2)` to wake a blocked reader, stale-death dedupe (`remote === handle`). The remaining findings are the *other* components not yet using this pattern.
- **`LSPClient`** (`LSPClient.swift`): dedicated reader `Thread` with an explicit cooperative-pool-starvation rationale (`:241-246`); the register-continuation-*then*-arm-timeout ordering fix (`:442-450`) closes a real lost-wakeup race; teardown polls SIGTERM asynchronously and reaps exactly once off-pool (`:1104-1126`).
- **`SessionStore`** (`SessionStore.swift`): single static serial write queue, lock-guarded coalescing map, `flushSync` draining to a fixpoint (`:302-321`), and `syncWrite` deliberately routed *through* the queue to stay ordered with async drains (`:398-406`). The clobber-guard (`enqueueSaveIndex` refusing to write an index that orphans live snapshots) is defense-in-depth against a prior race.
- **`PTYProcess`** (`PTYProcess.swift`): the `starting` flag closing the double-fork window (`:56-59`), lock-synchronized callback wiring with invokes deliberately outside the lock (`:29-38`), and a dedicated blocking-write queue for the paste-into-slow-reader case (`:61-65`).
- **Rust FFI handle layer** (`rust-core/crates/ffi/src/handle.rs`, `canvas_handle.rs`): the registry-of-`Arc` redesign (free = deregister; in-flight calls keep the session alive; no locked-Mutex drop) is the correct fix for the C-ABI use-after-free class, with the history documented in the module header and a threaded hammer test (`tests.rs:1128-1140`).
- **`mdv-serve`** (`rust-core/crates/serve/src/main.rs:135-150`): per-connection threads are capped (`MAX_CONNECTIONS` refuse-by-hangup), and idle-exit/retire are gated on atomics with a documented activity-generation scheme.
- **`ProcessRunner._Escalator` / `_ByteCounter`** (`ProcessRunner.swift:443-505`): the shared terminate→SIGKILL escalation and the cross-queue byte cap are exactly what `ArchiveCatalog` (finding 5) should reuse.
- **Discipline artifacts:** essentially every `nonisolated(unsafe)` names its guarding lock and audited call sites (`GrammarLoader.swift:292-296`, `Obs.swift:20-24`, `StatusBar.swift:627-629`); view-model async work consistently uses generation guards (`GitPanelModel`, HexView `buildGeneration`, TabLoading's Bug-C guards at `DocumentModel+TabLoading.swift:12-67`); `RepoStatsCache` coalesces concurrent walks via an in-flight table on an actor.

---

## Coverage gaps (not examined)

- **~255 flat ViewerCore engine files and most of ViewerUI's 71 K LOC** were covered only by the primitive sweeps, not read line-by-line; a race that uses no greppable primitive (e.g. plain `var` shared via closure capture between two `DispatchQueue.global().async` blocks) could hide there.
- **Canvas subsystem** (Rust `canvas/` DSL + `CanvasWebViewHost` beyond its `assumeIsolated` sites) — skimmed only.
- **WebView JS bridges** (CodeMirror/Mermaid message handlers, `evaluateJavaScript` completion ordering) — not traced; WKWebView delivers on main, so the risk shape is stale-callback-vs-model rather than data races, but I did not verify the generation guards there.
- **Walkthrough, Review, Plugins (beyond `PluginSubprocessHost`), Feeds, ImageEditing, Audio** feature clusters — sweep-level only.
- **Rust `tui`, `web`, `highlight`, `pm` crates** — not reviewed (only `ffi` and `serve`).
- **No dynamic verification**: no TSan run, no test execution (per constraints). Findings 1, 4, 6, 7 describe interleavings I traced statically; a TSan pass over `ViewerCoreTests` plus a wedge-style test for the MCP teardown seam would be the natural follow-up. Note `swift test -sanitize=thread` on `ViewerCoreTests` (host-safe, headless) would likely confirm finding 5's handoff and is cheap to add to the nightly VM lane.
- **Working-tree state**: `main.swift` and `MCPSocketBridge.swift` carry uncommitted edits; this review reflects the working tree, and line numbers there may drift from `HEAD`.
