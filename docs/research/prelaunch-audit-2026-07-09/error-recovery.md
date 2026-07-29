# Pre-launch audit — Error recovery + handling

Date: 2026-07-10 · Reviewer: error-recovery dimension agent
Lens: boundary error handling quality, user-facing degradation vs silent breakage, corrupted-store recovery, disk-full / permission-denied / network-gone paths.

## Executive summary

The error-handling posture of this codebase is **well above typical pre-launch quality** at the primitive layer, and the weak spots are concentrated in one theme: **persistence write failures are silent end-to-end**. The document save path (`EditorBuffer.save`) is genuinely production-grade (symlink-safe classify, EACCES metadata preservation, atomic rename, typed errors, NSAlert surfacing). The session store is the best corrupted-store recovery implementation I've seen in a codebase this size (schema classification, downgrade write-block, clobber guard, orphan-snapshot self-heal). The FFI seam has a real panic boundary with a dead-flag state machine, and the build system actively refuses to link a `panic=abort` profile into the app.

The residual risk is the **fire-and-forget JSON store write path**: `JSONFileStore.write` returns a `Bool` that every production caller discards. On a disk-full volume, session snapshots, hot-exit unsaved text, bookmarks, history, and plugin-grant revocations all silently fail to persist — and because the app deliberately has **no dirty-buffer quit prompt** (hot exit *is* the data-safety mechanism), a disk-full quit can silently lose user edits. Second theme: one store (`BookmarksStore`) missed the lenient-array-decode migration its own helper was built for, so a single malformed entry still nukes the whole bookmarks list — and the next toggle overwrites the file, destroying the evidence. Corrupt store files are never quarantined before overwrite anywhere except the session index.

8 findings: 2×P1, 4×P2, 2×P3. No P0. All fixes are S/M and safe or careful; nothing is a one-way door.

## Methodology

Static review (read + `rg`) of:

- Persistence layer: `Sources/ViewerCore/JSONFileStore.swift` (full), `Sessions/SessionStore.swift` (full), `Sessions/SessionsCoordinator.swift` (restore/recovery paths), `BookmarksStore.swift`, `HistoryStore.swift`, `LocalHistoryStore.swift`, `HotExitSpill.swift` (full), `Plugins/PluginGrantStore.swift`, `Review/ReviewSidecar.swift`, `AppCacheReset.swift`.
- Save/write boundaries: `Sources/ViewerCore/EditorBuffer.swift` (save path, full), `Sources/ViewerUI/Coordinators/EditorCoordinator.swift` (save/conflict/close-prompt surfacing), `DocumentModel+EditableHex.swift`, `DocumentModel+SaveCopy.swift`, `DocumentModel+ScrollPersistence.swift` (hot-exit capture), `main.swift` (terminate flow, Save-a-Copy, MCP startup).
- File-open boundary: `TextFileLoader.swift`, `DocumentController.swift`, `BinaryFileLoader.swift`.
- FFI seam: `rust-core/crates/ffi/src/guard.rs`, `handle.rs`, `status.rs` (grep-level), `rust-core/Cargo.toml` profiles, `scripts/build-rust-core.sh` profile guard, `Sources/RustCore/CoreClient.swift` (dead-flag), `CoreTransport.swift`, `RemoteTransport.swift` (deadline/orphan-store/EINTR).
- Subprocess/child boundaries: `LSP/LSPPool.swift` + `LSPProblemsViewModel.swift` (grep-level), `Plugins/PluginSubprocessHost.swift`, terminal (`ViewerUI/Terminal/PTYProcess.swift`, `TerminalModel.swift`, grep-level).
- Network: all three `URLSession` users (`Feeds/FeedFetcher.swift` full, `HTTPClientCore.swift`, `Automation/MCPServer.swift` grep-level), `FeedReaderViewModel.swift` failure surfacing.
- WebView crash recovery: `CodeMirrorEditorView.swift`, `MarkdownRenderedView.swift`, `CanvasWebViewHost.swift` (`webViewWebContentProcessDidTerminate` handlers).
- Automation: `MCPSocketListener.swift`, `MCPProtocol.swift` (grep-level).
- Crash-path sweep: `fatalError` / `try!` across `Sources/` (all hits inspected — benign).

Not exhaustive; see Coverage gaps.

## Findings

---

### F1 · P1 — `BookmarksStore` uses strict array decode: one malformed entry silently destroys all bookmarks, and the next save clobbers the file

- **File:** `Sources/ViewerCore/BookmarksStore.swift:242-248` (load), `:256-261` (save)
- **Evidence:**
  ```swift
  private func load() {
      guard let decoded = JSONFileStore.read(
          [BookmarkEntry].self, from: storeURL, maxSize: maxStoreFileBytes
      ) else { return }
  ```
  `JSONFileStore.readLenientArray` (`Sources/ViewerCore/JSONFileStore.swift:48-58`) exists **specifically for this** — its own doc comment (PERSIST-02) says: "One malformed entry … would otherwise nuke the user's entire history / **bookmarks** list." `HistoryStore` was migrated (`Sources/ViewerCore/HistoryStore.swift:151` uses `readLenientArray`); `BookmarksStore` was not.
- **Impact:** any single element that fails to decode (a future `kind`/field written by a newer build, a path the encoder couldn't round-trip, partial corruption) makes the whole-array decode fail → `entries` stays `[]` → UI shows zero bookmarks with no message → the user's first bookmark toggle calls `save()` (`:260`, `JSONFileStore.enqueueWrite`) and **overwrites the recoverable file permanently**. `BookmarkEntry` also carries newer optional fields (`line`, identity capture — `:271-289`), i.e. schema drift is a live concern, not hypothetical.
- **Suggested fix:** switch `load()` to `JSONFileStore.readLenientArray(BookmarkEntry.self, ...)`, exactly mirroring `HistoryStore`.
- **Fix size:** S · **Fix risk:** safe

---

### F2 · P1 — Persistence write failures are silent end-to-end: a disk-full quit loses sessions and hot-exit unsaved edits with zero signal

- **Files:**
  - `Sources/ViewerCore/Sessions/SessionStore.swift:414-422` — `_encodeAndWrite` discards `JSONFileStore.write`'s `Bool`.
  - `Sources/ViewerCore/JSONFileStore.swift:169-174, 185-191` — enqueue drain and `flushSync` discard `job()` results (`_ = job()`).
  - `Sources/ViewerUI/Sessions/SessionsAppCoordinator.swift:432-453` — `flushForTermination()` has no failure channel.
  - `Sources/MarkdownViewer/main.swift:708-726` — `applicationWillTerminate` calls both flushes; return values/void, quit proceeds unconditionally.
- **Evidence:** `JSONFileStore.write` deliberately surfaces a `Bool` "for tests + future loud-on-error paths" (`JSONFileStore.swift:75-78`) — but no production caller ever reads it. Grep confirms every call site is `_ =` or bare.
- **Impact:** the app has **no dirty-buffer quit prompt by design** — hot exit (TSK-718) is the data-safety mechanism: unsaved editor text rides the session snapshot (`SessionSnapshot.swift:61-77`). If the snapshot write fails at quit (disk full, quota, permissions changed on `~/Library/Application Support`), the quit completes normally and the user's in-flight edits are **gone on relaunch, with no error at quit time and no explanation at launch time**. Same silent path for bookmarks/history/go-to-path/index writes during normal use. `writeDurably` correctly preserves the *old* file on failure (temp + rename), so this is loss of the *newest* state, not corruption — but for hot-exit text the newest state is the user's data.
- **Suggested fix (M, careful):** bubble a `Bool`/error out of `flushForTermination` + `JSONFileStore.flushSync`; in `applicationWillTerminate` (or better, an `applicationShouldTerminate` that runs the flush first) show one modal on failure — "Couldn't save your session (disk may be full). Quit anyway?" — with Cancel. Independently: increment an `Obs` counter on any failed store write so field failures are at least observable.
- **Fix size:** M · **Fix risk:** careful (terminate-path changes; keep the flush drain semantics intact)

---

### F3 · P2 — Corrupt JSON store files are overwritten in place; no quarantine/backup of the bad bytes anywhere except the session index

- **Files:** `Sources/ViewerCore/JSONFileStore.swift:22-36` (read → nil on corrupt), consumers: `BookmarksStore.swift:242`, `HistoryStore.swift:151`, `Plugins/PluginGrantStore.swift`, `Review/ReviewSidecar.swift:138-144`, `SessionStore.load(id:)` (`SessionStore.swift:269-277`).
- **Evidence:** on decode failure every store silently starts empty; the first subsequent save writes over the corrupt file. `rg` for any `.corrupt`/`.bak` quarantine rename in `Sources/` finds none. The only protected surfaces are the session **index** (clobber guard + orphan recovery, `SessionStore.swift:255-265`, `SessionsCoordinator.swift:94-124`) and the explicit `File → Reset` flow (`AppCacheReset.swift` backs up to `_reset-backups/<stamp>/`).
- **Impact:** a truncated-by-crash or half-synced `bookmarks.json` / per-session snapshot is often trivially hand-recoverable (it's pretty-printed JSON) — until the app destroys it on the next write. Combined with F1 this turns a recoverable glitch into permanent loss. Also a **silent-breakage UX**: the user is never told "your bookmarks file was unreadable" (contrast: sessions set `lastError` — `SessionsCoordinator.swift:111`).
- **Suggested fix:** in `JSONFileStore.read`, when a file **exists** but fails to decode, rename it aside to `<name>.corrupt-<timestamp>` (bounded: keep 1) before returning nil; optionally expose a "store was reset" flag callers can surface.
- **Fix size:** S–M · **Fix risk:** safe

---

### F4 · P2 — Hot-exit spill failure silently drops >1 MiB of unsaved edits; >1 MiB untitled buffers are dropped by design with no warning

- **File:** `Sources/ViewerUI/DocumentModel+ScrollPersistence.swift:260-272`; `Sources/ViewerCore/HotExitSpill.swift:43-53`.
- **Evidence:**
  ```swift
  } else if let p = tab.url?.path {
      if !HotExitSpill.write(buf.text, forPath: p, in: hotExitSpillDirectory) {
          baseMTime = nil; baseSize = nil   // spill failed → can't preserve
      }
  } else {
      baseMTime = nil; baseSize = nil       // untitled >1 MiB → drop
  }
  ```
  `HotExitSpill.write` returns `false` on any write error (disk full, permission); the capture path notes it and moves on. No alert, no log, no quit interruption.
- **Impact:** narrow but severe when hit: a dirty buffer over `hotExitMaxBytes` (1 MiB, `DocumentModel.swift:1447`) + a failed spill (most likely *exactly when the disk is full*) = quit proceeds, edits silently lost. The untitled->1 MiB case loses edits even on a healthy disk. This is the same silence class as F2 but with its own dedicated decision points, so fix separately.
- **Suggested fix:** on spill failure or the untitled-over-cap case during a **termination** capture, surface a modal (offer "Save now / Quit anyway"); during a session-switch capture, post a toast. Falling back to inline capture despite the cap is also acceptable (a one-off big JSON beats data loss).
- **Fix size:** S–M · **Fix risk:** careful (quit path)

---

### F5 · P2 — Canvas WebContent crash flag is write-only: canvas pane stays permanently blank after a renderer crash

- **File:** `Sources/ViewerUI/CanvasWebViewHost.swift:20-25`.
- **Evidence:**
  ```swift
  public private(set) var contentProcessDied = false
  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      contentProcessDied = true
      NSLog("CanvasWebViewHost: WebContent process TERMINATED")
  }
  ```
  `rg contentProcessDied` across `Sources/` finds only these two lines — no consumer, no re-bootstrap. Contrast the sibling surfaces which both self-heal: CM6 re-bootstraps with a 3-attempt cap (`CodeMirrorEditorView.swift:1046-1056`) and the rendered pane drops its dedup baseline + reloads (`MarkdownRenderedView.swift:844-853`).
- **Impact:** a jetsam/crash of the canvas WebContent process leaves a blank, dead pane until the tab is closed/reopened; unsent canvas state in the JS runtime is lost. Mitigating: the Canvas epic is owner-parked, but the code ships in-tree.
- **Suggested fix:** mirror the CM6 pattern — reset ready gates, re-bootstrap the host page, re-hydrate from the engine-side document (the Rust canvas engine holds the document of record), cap retries.
- **Fix size:** M · **Fix risk:** safe

---

### F6 · P2 — Plugin-grant revocation persist failure is silent (security-relevant)

- **File:** `Sources/ViewerCore/Plugins/PluginGrantStore.swift:184-199`.
- **Evidence:**
  ```swift
  public func revoke(pluginID: String) { ... persist(snapshot) }
  private func persist(_ snapshot: StoreFile) {
      guard !isNewerSchemaOnDisk else { return }
      _ = JSONFileStore.write(snapshot, to: url)
  }
  ```
- **Impact:** user revokes a plugin's capabilities in Settings; if the write fails the revocation applies only in-memory and the grant **silently resurrects on relaunch**. Inverse direction (a new grant failing to persist) is only an annoyance; the revoke direction is a trust/security expectation. Note the `isNewerSchemaOnDisk` guard has the same property — a downgrade-blocked revoke is silently session-only (comment at `:192-195` acknowledges this, but the *user* is never told).
- **Suggested fix:** `revoke`/`record` return `Bool`; Settings surfaces "couldn't persist this change" on failure. S.
- **Fix size:** S · **Fix risk:** safe

---

### F7 · P3 — MCP socket listener startup failure is stderr-only; automation surface degrades invisibly

- **File:** `Sources/MarkdownViewer/main.swift:4144-4153`.
- **Evidence:** `catch { FileHandle.standardError.write(... "mcp: socket listener failed to start" ...) }` — a GUI app's stderr goes nowhere the user or an attaching agent can see. `MCPSocketListener.start()` throws typed `bindFailed/listenFailed` (`MCPSocketListener.swift:29-30, 92-99`) — good — but the caller flattens it.
- **Impact:** agents simply can't connect (`connection refused` / missing socket) with no in-app breadcrumb; given the product's agent-driven UAT strategy this lane failing silently costs debugging time. Stale-socket unlink-before-bind is handled (`:66-74`), so the residual risk is small.
- **Suggested fix:** also emit through `Obs` (the listener already logs runtime events via `Obs.shared.emit`, `:174`) and reflect listener state in the automation status surface (`current_state` tool / status chip).
- **Fix size:** S · **Fix risk:** safe

---

### F8 · P3 — File → New Image (and its script verb) fails with no feedback on read-only/full target

- **Files:** `Sources/ViewerUI/DocumentModel.swift:786-806` (`createNewBlankImage` returns nil on write failure, `catch { return nil }` at `:803-805`); callers discard: `Sources/MarkdownViewer/main.swift:1253`, `Sources/ViewerUI/ContentView.swift:1932`, `Sources/ViewerUI/Automation/ScriptVerbDispatch.swift:230`.
- **Impact:** clicking "New Image" with a read-only open folder (or full disk) does nothing — no beep, no alert, no tab. The MCP verb path similarly returns success-shaped nothing. Contrast: `saveCopyAs` alerts on failure (`main.swift:1016-1021`), dirty-save alerts (`EditorCoordinator.swift:983-990`).
- **Suggested fix:** beep + alert (or toast) on nil at the two UI call sites; return a proper tool error from the script verb.
- **Fix size:** S · **Fix risk:** safe

---

### Minor notes (not ranked findings)

- `FeedFetcher`'s `URLSessionFeedTransport` uses `URLSession.shared` with default timeouts (`Feeds/FeedFetcher.swift:10-16`); a black-holed feed host stalls a refresh task ~60s+. Failure *surfacing* is already good (toast, `FeedReaderViewModel.swift:80-92`, TSK-1436). A `URLSessionConfiguration` with `timeoutIntervalForRequest ≈ 15s` would tighten the offline experience. (S, safe.)
- `SessionStore.enqueue`'s `_encodeAndWrite` silently drops unknown types (`SessionStore.swift:414-422`) — by construction unreachable today; a `assertionFailure` in debug would keep it honest. (S.)

## Positive observations

Genuinely strong work worth preserving as patterns:

- **`EditorBuffer.save`** (`Sources/ViewerCore/EditorBuffer.swift:254-373`): O_NOFOLLOW/ELOOP symlink classification, EACCES path that *refuses to save* rather than silently downgrade a 0600 secret's permissions, same-dir temp + atomic `rename(2)`, typed `EditorWriteError`, and UI surfacing via NSAlert (`EditorCoordinator.swift:983-990`). Conflict handling (changed-on-disk) has real three-way prompts (`EditorCoordinator.swift:1100-1124, 1229-1236`).
- **`JSONFileStore.writeDurably`** (`JSONFileStore.swift:94-118`): fsync-before-rename + directory fsync (TSK-1011) — crash/power-loss durable, old file preserved on failure.
- **Session store recovery is exemplary** — four-way load classification incl. `.newerSchema` downgrade write-block (PERSIST-04) (`SessionStore.swift:134-174`), the TSK-438 empty-index clobber guard (`:255-265`), orphan-snapshot self-heal with root-existence + non-empty-tab filters (`:229-246`, `SessionsCoordinator.swift:187-199`), and user-visible `lastError` banners for every degraded outcome (`SessionsCoordinator.swift:105-123, 165-174`).
- **FFI panic boundary done right**: `catch_unwind` guard macros (`rust-core/crates/ffi/src/guard.rs`), poisoned-lock tri-state (`status.rs`), Swift-side dead-flag latch that distinguishes retryable contention from fatal poison (`CoreClient.swift:354-414`) — and crucially **`scripts/build-rust-core.sh:37-53` rejects `panic=abort` profiles at build time**, closing the "guard silently compiled to a no-op" trap; the `dist` profile pins `panic="unwind"` (`rust-core/Cargo.toml:140-150`).
- **`RemoteTransport`**: 30s per-call deadline so a wedged daemon can't hang an adapter thread (`RemoteTransport.swift:74-76`), EINTR retry on read/write (`:675, :694`), and a three-axis-bounded orphan event buffer preventing a hostile/buggy daemon from OOMing the client (`:78-102`); in-process Swift fallback on remote fault (`:336`).
- **LSP**: crash → respawn with exponential backoff (`LSPPool.swift:18-28`), per-server health/crash counts surfaced in UI (`LSPProblemsViewModel.swift`), and a bounded (8s) concurrent quit teardown that logs instead of hanging (`main.swift:755-768`).
- **Plugin host**: hard wall-clock timeout with process-group SIGTERM→SIGKILL escalation and `F_SETNOSIGPIPE` so a crashing plugin can't SIGPIPE the host (`PluginSubprocessHost.swift:217-343`).
- **File-open boundary**: typed `FileLoadError` (not-found / not-readable / too-large with byte counts / binary / decode-failed) with per-case user messages (`DocumentController.swift:145-191`); size ceilings before slurping.
- **WebView crash self-healing** for CM6 (retry-capped re-bootstrap, `CodeMirrorEditorView.swift:1046-1056`) and the rendered pane (`MarkdownRenderedView.swift:844-853`).
- **Hot exit + spill design** (TSK-718/1026): unsaved text survives quit, >1 MiB spills to a sidecar keyed by path, orphan pruning.
- **Feed refresh failures surface as toasts** naming the failed feeds (TSK-1436, `FeedReaderViewModel.swift:80-92`) — the "failures used to vanish" fix pattern this audit wants everywhere.
- Git mutations return `(ok, message)` rather than throwing away stderr (`GitClient.swift:679-761`).
- `fatalError`/`try!` sweep: only `init(coder:)` stubs and static regex literals — no reachable crash paths.

## Coverage gaps (not examined, or grep-level only)

- **Rust crates beyond the FFI seam**: `serve`, `tui`, `web`, `pm` (SQLite corruption/recovery in the pm store), `highlight`, the `canvas/` DSL engine — not reviewed for internal error handling.
- **CSV / hex / image / audio editors' full save-export paths** (only hex write-back and image-create spot-checked; `ImageDocument` export errors not traced to UI).
- **Walkthrough, Review store (beyond `ReviewSidecar`), ScrollMemoryStore, ViewModeLockStore, GoToPathHistoryStore, InstanceRegistry, ClaudeSessionIndex, AuditLog, HTTPRequestStore** — assumed to follow the `JSONFileStore` pattern (F2/F3 apply generically) but not individually read.
- **File-watcher edge cases**: file deleted while open, volume ejected under an open tab, network-volume disappearance (changed-on-disk conflicts *are* handled; deletion path not traced).
- **MCPServer stdio-mode framing-error recovery** and the AX driver.
- **`mdv-serve` daemon lifecycle** (spawn failure, restart policy) beyond the transport-level fallback.
- **UserDefaults-backed preferences** (low stakes; not audited).
- No dynamic testing — this is a static review; none of the disk-full/EACCES paths were exercised live.
