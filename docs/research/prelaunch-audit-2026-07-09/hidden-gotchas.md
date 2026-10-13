# Pre-launch audit — Hidden bugs + gotchas (silent failure paths)

**Dimension:** silent failure paths — `try?` swallowing errors, force-unwraps, force-casts,
ignored return values, implicit assumptions that break on edge inputs, fenceposts.
**Date:** 2026-07-10 · **Reviewer:** automated audit subagent · **Repo state:** main @ `304a8290` (+ doc-only working-tree changes)

---

## Executive summary

This codebase is **unusually disciplined** for its size on exactly this dimension. The Rust
core enforces `unwrap_used`/`expect_used`/`indexing_slicing`/`panic = "deny"` workspace-wide
(`rust-core/Cargo.toml:96-105`) and I found **zero production unwraps** in the core files I
sampled (wire, json, format, session, diff, transcript, doc_registry, dispatch, find_engine,
cm_edit, serve, watch — all unwraps sit behind `#[cfg(test)]`). The FFI boundary has a real
panic guard (`crates/ffi/src/guard.rs`) with poison detection, and `scripts/build-rust-core.sh:35-53`
actively **rejects** linking the `panic="abort"` release profile into the GUI app. The Swift
save path (`EditorWriter.save`) is one of the most careful atomic-write implementations I've
reviewed: O_NOFOLLOW symlink classification, EACCES mode/owner preservation, fsync-before-rename
durability in `JSONFileStore.writeDurably`, and a no-clobber re-stat guard at ⌘S.

The findings below are therefore mostly **P2/P3 residuals** plus **one P1**: the plugin
subprocess host force-closes pipe `FileHandle`s under reader threads blocked in
`availableData` — the exact uncatchable-ObjC-exception crash class this repo's own MCP code
documents (TSK-1552/1559) and deliberately avoids with raw `read(2)`. Several findings are
"the guard exists in one layer but not at the chokepoint" or "failure is mapped to a
success-shaped empty value" — the residue of a codebase that mostly got this right.

**Counts:** 1 × P1, 4 × P2, 8 × P3. No P0. No ship-blockers found on this dimension.

---

## Methodology

- **Pattern sweeps** (ripgrep) across all of `Sources/` (~380 K LOC) and
  `rust-core/crates/` for: `try?` (grouped by file; ~40 top files triaged), `try!`, `as!`,
  `.first!`/`.last!`, `URL(string:)!`, `Int(<float expr>)` NaN-trap candidates,
  division-by-count sites, `NSRange` construction, `.unwrap()`/`.expect(` in Rust
  (cross-checked against `#[cfg(test)]` boundaries per file), and workspace lint config.
- **Deep reads** of the highest-risk units: `EditorBuffer.swift` (full save path),
  `EditorCoordinator.saveEditor` (success + failure + conflict paths), `SessionStore.swift`
  (complete), `JSONFileStore.swift` (complete), `HotExitSpill.swift` (complete),
  `MCPSocketBridge.swift` (complete), `MCPFraming.swift` (complete), `MCPServer` framing/error
  paths, `ProcessRunner.run` + `drain`, `PluginSubprocessHost` spawn/drain/unwind,
  `CrossFileReplace.run`, `LocalHistoryStore` snapshot/sidecar/collision guard,
  `TextFileLoader`/`TextDecoder` encoding chain, `DocumentModel+EditableHex.saveHexEdits`,
  `DocumentModel+FileOperations`, `GitClient` (all 40 `try?` sites), `RustFindAdapter` +
  `mdvCoreFindSearch` (offset-unit seam), `CoreDocShadow`, `TerminalScreen`/`TerminalScrollbar`
  /`TerminalNSView` geometry, `SourceHoverHighlight` geometry, `LSPMarkdownRenderer` trim loop,
  `ForgeRemote`, `EditableCSVModel.serializeRow`, `AuditLog` rotation, `ImageEditorViewModel`
  export, app-shell `main.swift` `try?` sites, `ClaudeSessionIndex`.
- **Static analysis only** — no tests were run, no repo files modified other than this report.

---

## Findings

### F1 (P1) — PluginSubprocessHost force-closes pipe handles under readers blocked in `availableData` — the repo's own documented uncatchable-exception crash class

- **File:** `Sources/ViewerCore/Plugins/PluginSubprocessHost.swift:265-285` (drain loops), `:343-354` (force-close unwind)
- **Evidence:** The stdout/stderr drain threads loop on `stdoutHandle.availableData`
  (line 268, 281). The F-PMA-LEAK-1 unwind (lines 343-354) handles the escaped-grandchild
  case — a write-end survivor keeps the pipe open, the 500 ms semaphore join times out, and
  the orchestrating thread then does `try? stdoutHandle.close()` / `try? stderrHandle.close()`
  **while the drain threads are still blocked inside `availableData` on those same handles.**
  This repo's own institutional lesson says exactly this is a crash:
  `MCPFraming.swift:314-330` — *"refill via RAW read(2), not `availableData`: the FileHandle
  API raises an UNCATCHABLE (from Swift) ObjC NSFileHandleOperationException when the
  descriptor is closed under a blocked reader (TSK-1552 found it as a test crash; the app
  quit path had the same landmine)"* — and `MCPSocketBridge.swift:253-257` documents the
  alternate failure mode (*"closing a unix-socket fd under a blocked reader does not reliably
  wake it on macOS"*). The `try?` on line 346 only covers the `close()` call throwing; the
  exception is raised **on the reader thread**, where nothing catches it — an ObjC exception
  on a GCD worker aborts the process.
- **Impact:** A plugin whose grandchild escapes the process-group kill (re-parented daemon,
  `setsid` child) drives the app into either (a) an uncatchable-exception **crash** of the
  whole app, or (b) the close not waking the reader, in which case the fd/thread leak the
  unwind was built to fix persists anyway (compounding toward `RLIMIT_NOFILE`, per the
  comment's own F-PMA-LEAK-1 analysis). Either way the unwind mechanism doesn't do what its
  comment claims. `ProcessRunner.drain` (`ProcessRunner.swift:359-384`) also uses
  `availableData` but is safe *by design* — it never closes a handle from another thread; its
  overflow path SIGTERMs the child instead.
- **Suggested fix:** Convert the two drain loops to raw `read(2)` on a cached fd (the exact
  pattern already implemented in `MCPFraming.FileHandleReader.readByte`, lines 314-337):
  `read` returns 0/EBADF after an external close instead of raising. Keep the force-close;
  it then deterministically unblocks the readers.
- **Fix size:** M · **Fix risk:** careful (concurrency; add a test with a write-end-holding
  grandchild, which the F-PMA-LEAK-1 comment implies once existed)

### F2 (P2) — MCP reconnect bridge can tear a JSON-RPC frame across an app restart; the "no message loss" contract overclaims

- **File:** `Sources/ViewerCore/Automation/MCPSocketBridge.swift:104-108` (contract comment), `:129-145` (chunk resume)
- **Evidence:** `serve`'s stdin thread reads ≤64 KiB chunks and, when a write fails mid-chunk
  (`w < 0` → `state.remoteDied` → retry loop), re-sends **from `off` within the current
  chunk** to the next socket. Two tear cases are not handled: (1) bytes `0..<off` of the
  current chunk were already written to the dead socket and may never have been processed;
  the fresh server receives a stream starting mid-message; (2) a message spanning multiple
  chunks whose earlier chunks fully landed on the dead socket — the fresh connection begins
  with a tail fragment. The header comment claims *"no message loss across an app restart …
  the write position is tracked per message buffer"*, but the bridge is protocol-blind
  (deliberately, line 8-9) and cannot know message boundaries — "per message buffer" is
  actually "per 64 KiB read chunk".
- **Impact:** After an app quit/relaunch mid-request, the new `MCPServer` hits a parse
  failure on the fragment and replies `parseError` with `id: .null`
  (`MCPServer.swift:170-177`). The MCP client (Claude Code) never receives a response for
  the torn request's real id → that tool call hangs until client timeout. Session survives;
  one agent call is silently lost — precisely what the comment promises can't happen.
- **Suggested fix:** Either (a) fix the comment to state the real guarantee (at-most-one
  request torn per reconnect; queued-but-unsent requests survive), or (b) make the bridge
  minimally NDJSON-aware on the stdin side: buffer to `\n` boundaries and only ever re-send
  whole lines after a socket swap (the client side is NDJSON in practice, per TSK-1545).
- **Fix size:** S (comment) / M (line-buffering) · **Fix risk:** safe

### F3 (P2) — UTF-8 BOM is silently stripped on every save and every cross-file replace

- **Files:** `Sources/ViewerCore/TextFileLoader.swift:499-504` (BOM strip on decode),
  `Sources/ViewerCore/EditorBuffer.swift:243-252` (`withByteOrderMark` restores UTF-16 only),
  affected writers: `Sources/ViewerUI/Coordinators/EditorCoordinator.swift:915`,
  `Sources/ViewerCore/CrossFileReplace.swift:204`
- **Evidence:** `TextDecoder.decodeViaBOM` decodes a `EF BB BF`-prefixed file via
  `data.dropFirst(3)` and records plain `.utf8`. On save, `EditorWriter.save` calls
  `withByteOrderMark`, whose `switch` re-emits a BOM **only** for `.utf16LittleEndian` /
  `.utf16BigEndian` (the TSK-861 fix); `.utf8` falls to `default: return data`. The original
  UTF-8 BOM is silently dropped. `CrossFileReplace` funnels through the same
  decode→`EditorWriter.save` path, so a project-wide replace strips the BOM from **every
  matched UTF-8-BOM file**, a byte-level modification beyond the requested edit.
- **Impact:** Files consumed by BOM-sensitive tooling (PowerShell 5.x script encoding
  detection, Excel CSV UTF-8 auto-detection, some legacy Windows editors) change behavior
  after an unrelated one-character edit in TextView. Diffs/hashes churn on the first byte.
  The inverse asymmetry also exists and is worth documenting: a BOM-less UTF-16 file
  (detected by `decodeUTF16WithoutBOM`, `TextFileLoader.swift:445-477`) **gains** a BOM on
  save — that one is deliberate (TSK-861, prevents short-file re-decode corruption) but the
  pair of behaviors means "open + save = byte-identical" does not hold for either BOM class.
- **Suggested fix:** Record `sawUTF8BOM` at decode (either a distinct pseudo-encoding or a
  flag on `TextFile`/`EditorBuffer`) and have `withByteOrderMark` re-emit `EF BB BF` for it.
  One flag threaded through `EditorBuffer.load`/`save` + a round-trip test.
- **Fix size:** M · **Fix risk:** careful (encoding fingerprints feed external-edit detection; keep `markSaved` size consistent)

### F4 (P2) — `saveHexEdits` chokepoint doesn't refuse truncated loads; the only guard is a SwiftUI computed property

- **File:** `Sources/ViewerUI/DocumentModel+EditableHex.swift:68-97`; sole guard at `Sources/ViewerUI/HexView.swift:71-75`
- **Evidence:** A binary file larger than the hex load cap is loaded truncated
  (`BinaryFileLoader`, `isTruncated: true`) and `HexView.isEditable` correctly refuses to
  edit it (*"saving would drop the unread tail"*, HexView.swift:68). But the actual write
  chokepoint `DocumentModel.saveHexEdits(_:forTabID:)` is a **public** method that writes
  whatever `Data` it is handed via `HexBinaryWriter.write` and then stamps the tab
  `BinaryFile(..., totalByteCount: data.count, isTruncated: false)` (line 93-94) — no check
  that the buffer covers the on-disk file. Contrast the text path, where the equivalent
  refusal was deliberately duplicated at the chokepoint (TSK-1204's
  *"last-line guard at the write chokepoint"*, `EditorCoordinator.swift:865-870`,
  `guard !buf.isReadOnly`).
- **Impact:** Latent truncation data loss: any future caller (MCP tool, script verb,
  another view mode) that reaches `saveHexEdits` with a truncated tab's bytes silently
  rewrites a multi-MB file down to its loaded 4 MB prefix, and the model then *records* it
  as non-truncated. Today `hexDirtyBytes` is only populated by the gated hex editor, so this
  is defense-in-depth — but the codebase's own standard (TSK-1204) is that read-only refusal
  lives at the chokepoint, not the UI.
- **Suggested fix:** In `saveHexEdits`, look up the tab's current `.binary(file)` state and
  `guard !file.isTruncated else { return false }` (or compare `data.count` against on-disk
  size and refuse shrinking writes for truncated origins).
- **Fix size:** S · **Fix risk:** safe

### F5 (P2) — SessionStore's coalesced write path has zero failure observability, and `_encodeAndWrite` silently drops unknown types

- **File:** `Sources/ViewerCore/Sessions/SessionStore.swift:414-422` (`_encodeAndWrite`), `:373-384` (async drain), `:302-321` (`flushSync`)
- **Evidence:** `_encodeAndWrite` ignores `JSONFileStore.write`'s `Bool` result on both
  branches and has an explicit *"Other types: silently dropped"* fall-through. Every
  production session persist (`enqueueSave`/`enqueueSaveIndex` → async drain → `flushSync`
  on quit) funnels through it. `JSONFileStore.write` itself returns `false` on encode
  failure/disk-full/rename failure (`JSONFileStore.swift:79-118`) precisely *"for tests +
  future loud-on-error paths"* — but no production caller on this path reads it. Contrast
  the same file's clobber guard, which does log to stderr (`noteRefusedClobber`, :260-265).
- **Impact:** On a full disk / permission regression / sandbox change, the user's session
  state (open tabs, unsaved-buffer references, scroll positions) silently stops persisting.
  Every launch restores stale state with no signal anywhere — the exact symptom class of the
  TSK-438 session-clobber incident, minus the breadcrumbs to diagnose it.
- **Suggested fix:** Log (stderr/`Obs`) on the first write failure per URL with a reset on
  success (rate-limited), both in `_encodeAndWrite` and `JSONFileStore.enqueueWrite`'s drain
  (`JSONFileStore.swift:169-174`, which also discards the job's `Bool`).
- **Fix size:** S · **Fix risk:** safe

### F6 (P3) — GitClient maps command failure to success-shaped empty values throughout

- **File:** `Sources/ViewerCore/Git/GitClient.swift:118, 212, 225, 254, 350, 429, 448, 520, 566, 661, 803, 986, 1009, 1013, 1140`
- **Evidence:** The dominant idiom is `(try? run([...])) ?? ""` / `guard let out = try? run(...) else { return [] }`.
  E.g. `:118` (`status --porcelain -uall` → `""`), `:212` (file diff → `""`), `:986-1013`
  (repo stats → zeros). A launch failure, a repo with a corrupt index, or git-not-installed
  is indistinguishable from "clean repo / no diff / no commits". The codebase knows better —
  `:152` uses `runResult` to distinguish failure for the status tab — but most read sites
  don't.
- **Impact:** Misleading UI on degraded environments: sidebar diff markers vanish, the diff
  view shows "no changes" for a file with real changes, repo stats show 0 commits — all
  silently. Mutation paths (`stash apply/pop/drop` :536-546) do return `Bool`, so the worst
  (mutations reporting success on failure) is avoided.
- **Suggested fix:** Migrate high-signal read paths (status, file diff) to `runResult` and
  surface a "git unavailable/failed" state distinct from empty; leave cosmetic reads as-is.
- **Fix size:** M · **Fix risk:** safe

### F7 (P3) — Stash/status diff export writes swallowed → stale-cache mispresentation

- **File:** `Sources/ViewerUI/Git/GitStashTab.swift:93-106`, `Sources/ViewerUI/Git/GitStatusTab.swift:~317`
- **Evidence:** `show(_:)` renders a stash's patch by writing
  `…/Caches/MarkdownViewer/diffs/<ref>.diff` via `try? body.write(...)` and then opening
  that path. Two silent failures compound: `stashShow` returns `""` on git failure (F6), and
  the write itself is `try?`. The filename is deterministic per ref, so if a **previous**
  export for the same ref exists and today's write fails, the user is shown the *old* diff
  with no indication.
- **Impact:** User views an outdated or empty patch believing it current. Low frequency,
  but it's a correctness-of-displayed-data bug, and cheap to fix.
- **Suggested fix:** Check the write result; on failure post a toast (the codebase already
  has `ToastCenter`) and don't open the stale path. Consider a UUID-suffixed filename.
- **Fix size:** S · **Fix risk:** safe

### F8 (P3) — LocalHistoryStore `_path` sidecar: swallowed write + fail-open collision guard

- **File:** `Sources/ViewerCore/LocalHistoryStore.swift:243-247` (write), `:536-543` (`dirBelongsTo` fail-open), `:286-301` (`allTrackedPaths` skip)
- **Evidence:** The per-directory `_path` sidecar (which both guards FNV-64 hash-collision
  cross-pollution — TSK-1027 — and powers the recover-deleted enumeration) is written with
  `try? Data(path.utf8).write(...)` exactly once, on first snapshot. If that write fails,
  it is never retried (the `!fm.fileExists` check only re-attempts if the file is absent on
  a *later* snapshot — which it would be — so partial mitigation exists), and while missing:
  `dirBelongsTo` returns `true` (fail-open, by design for legacy dirs), and
  `allTrackedPaths()` silently skips the file, so recover-deleted can't surface it.
- **Impact:** Degraded-disk scenarios quietly lose the collision guard and the
  recover-deleted inventory for affected files. Bounded severity because the snapshot
  records themselves still land (their write *is* checked, line 241).
- **Suggested fix:** Log on sidecar-write failure; optionally verify the sidecar exists in
  `versions(for:)` and re-write it (self-heal).
- **Fix size:** S · **Fix risk:** safe

### F9 (P3) — HotExitSpill keys spill files by bare FNV-1a-64 path hash with no identity verification (unlike its sibling store)

- **File:** `Sources/ViewerCore/HotExitSpill.swift:26-38` (`pathKey`/`url(forPath:)`), `:55-61` (`read`)
- **Evidence:** Spilled unsaved buffers (1–32 MiB dirty text) are stored at
  `<fnv64(path)>.txt` and restored purely by hash — there is no `_path` sidecar or content
  check confirming the file belongs to the requesting path. `LocalHistoryStore` uses the
  identical hash but added the sidecar guard specifically because of collisions (TSK-1027).
- **Impact:** An FNV-64 collision between two open file paths would restore file A's unsaved
  text into file B's editor buffer as "your unsaved changes" — user-visible data corruption.
  Probability is astronomically low (~n²/2⁶⁵ for n open files), so P3 — but the project
  already judged this class worth guarding once, and the fix is the established pattern.
- **Suggested fix:** Prefix the spill file with the origin path (first line) or add a
  sibling `<hash>.path` sidecar; verify on `read(forPath:)`.
- **Fix size:** S · **Fix risk:** safe (bump spill format defensively; old spills are ephemeral)

### F10 (P3) — `relaunchAndExit` swallows the relaunch: File → Reset can quit without restarting

- **File:** `Sources/MarkdownViewer/main.swift:955-968`
- **Evidence:** After a settings reset, `relaunchAndExit` does `try? p.run()` on
  `/usr/bin/open -n <app>` and then unconditionally `exit(0)`. If `open` fails to launch
  (or the bundle path check `pathExtension == "app"` fails — e.g. a dev binary run from
  `.build/`), the app just exits. The dialog promised *"then the app relaunches"*
  (main.swift:930).
- **Impact:** Cosmetic-to-confusing: user clicks "Reset & Relaunch", app disappears and
  stays gone. Data is safe (reset backups are taken first).
- **Suggested fix:** Check `p.run()`'s result; on failure show a "Reset complete — please
  reopen TextView" alert before `exit(0)`.
- **Fix size:** S · **Fix risk:** safe

### F11 (P3) — Post-rename fingerprint is taken by path, not from the renamed inode

- **File:** `Sources/ViewerCore/EditorBuffer.swift:367-379` (`rename` → `statFingerprint(targetPath)`)
- **Evidence:** `EditorWriter.save` commits via `rename(2)` and then fingerprints the
  target **by path**. If another process replaces the file in the window between the rename
  and the stat, the returned `(mtime, size)` describes the *external* write, and
  `markSaved` records it as the editor's own baseline — the subsequent external-edit
  detection (`hasExternalEdit`) then can't see that write. The coordinator's FW-7 recheck
  (`EditorCoordinator.swift:896-912`) compares against this same stamp, so it inherits the
  blind spot.
- **Impact:** Millisecond-scale race; consequence is a missed "file changed on disk" prompt
  followed by the no-clobber guard *also* not firing on the next ⌘S (same stale baseline) —
  i.e. the one scenario the TSK-768 guard exists for, through a much smaller window.
- **Suggested fix:** `fstat` the temp file's fd (or `open(O_NOFOLLOW)` + `fstat` the target
  immediately) before/after `rename` and derive the fingerprint from the inode actually
  written; alternatively re-stat and compare `st_ino`.
- **Fix size:** S · **Fix risk:** careful (fingerprint semantics feed three consumers; keep them agreeing)

### F12 (P3) — `JSONFileStore.read`'s size guard defaults to off (`maxSize: .max`); only some stores opt in

- **File:** `Sources/ViewerCore/JSONFileStore.swift:22-36`; capped callers e.g. `SessionStore.swift:63-64`; uncapped e.g. `Sources/ViewerCore/ScrollMemoryStore.swift`, `Sources/ViewerCore/Terminal/TerminalPaneLayout.swift:~185` (via own decode), assorted `JSONFileStore.read` sites without `maxSize:`
- **Evidence:** The documented purpose of the guard is *"so a tampered file can't inflate
  into memory"*, but the default parameter disables it; each caller must remember to pass a
  cap. SessionStore/BookmarksStore/PluginGrantStore do; a `rg 'JSONFileStore.read('` sweep
  shows other callers relying on the default.
- **Impact:** A runaway/corrupt multi-GB store file (the class the guard was built for) is
  slurped whole into RAM on launch for the uncapped stores. Not attacker-interesting
  (local files), but a real "app won't launch after disk corruption" hazard.
- **Suggested fix:** Flip the default to a generous global cap (e.g. 64 MiB) and let the
  rare legitimate big-file caller pass `.max` explicitly.
- **Fix size:** S · **Fix risk:** careful (audit callers for legitimately large files first)

### F13 (P3) — MCP tool argument parsing: `try?` on typed getters conflates "absent" with "present but wrong type"

- **File:** `Sources/ViewerCore/Automation/MCPToolCatalog.swift:145, 401, 422, 456, 506-508, 596-598, 1221, 1360, 1397, 1496` (pattern)
- **Evidence:** Optional tool args are read as `(try? args.bool("regex")) ?? false`,
  `(try? args.int("slides")) ?? 3`, etc. If an agent sends `"regex": "true"` (string) or
  `"slides": "5"`, the throw from the typed getter is swallowed and the **default** is used
  silently — the tool executes with different semantics than the caller asked for, returning
  plausible results (e.g. a literal search instead of regex).
- **Impact:** Agent-facing correctness: miscased/mistyped args degrade silently instead of
  erroring loudly. MCP clients (LLMs) are exactly the population that sends `"true"` for
  booleans. This subverts the schema contract the tool catalog advertises.
- **Suggested fix:** Distinguish "key absent" (default OK) from "key present but mistyped"
  (return an MCP invalid-params error). One helper on `args` used everywhere.
- **Fix size:** M · **Fix risk:** safe

---

## Positive observations

These are worth calling out because they are the reason this dimension has no P0:

1. **Rust core: panic-freedom is enforced, not aspirational.** `unwrap_used`, `expect_used`,
   `indexing_slicing`, `panic` all `deny` at the workspace level (`rust-core/Cargo.toml:95-105`);
   every `.unwrap()` I sampled across 10+ core files sits behind `#[cfg(test)]`. `cm_edit.rs`
   carries per-`allow` justifications tied to validation loops (TSK-575).
2. **The FFI panic boundary is real and tested** (`crates/ffi/src/guard.rs`,
   `tests.rs:192-195` proves panic→`MdvStatus::Panic` without process death; lock-poisoning
   surfaces as `HandleDead`, TSK-581), and `scripts/build-rust-core.sh:37-53` **refuses** to
   link the `panic="abort"` release profile into the app — the `dist` profile
   (`panic="unwind"`) is the shipping GUI profile, so `catch_unwind` genuinely works.
3. **`EditorWriter.save` is a model implementation**: O_NOFOLLOW/ELOOP symlink
   classification, EACCES mode/owner recovery via lstat with refusal when even that fails
   (a permission *leak* is chosen as the error, not the default), xattr replay, same-dir
   temp + atomic rename, per-error-type user-visible failures. The save failure path stays
   dirty and alerts (`EditorCoordinator.swift:983-992`) — no silent drop.
4. **Durability was actually thought through**: `JSONFileStore.writeDurably` fsyncs the temp
   file *and* the directory around the rename (TSK-1011) — rare even in mature apps.
5. **The session-clobber guard** (`SessionStore.wouldClobberLiveSnapshots`, TSK-438) refuses
   to persist an empty index while live snapshots exist — a targeted fix for a real incident,
   with recovery (`recoverableSnapshots`) layered on top.
6. **UTF-16 offset discipline at the find seam**: the Rust `find_engine` computes match
   offsets in UTF-16 code units (`find_engine.rs:153-202`) specifically so
   `RustFindAdapter`'s `NSRange` construction is unit-correct.
7. **Zero-denominator/NaN traps I hunted for were consistently guarded**
   (`SourceHoverGeometry.lineAtPointer:23`, `TerminalNSView.scrollWheel:229`,
   `TerminalScrollbar.thumb:20`, `TerminalScreen` clamps sizes to ≥1 at init/resize).
8. **SIGPIPE is systematically suppressed** on every child-stdin write fd
   (`ProcessRunner.swift:260`, `PluginSubprocessHost.swift:248`, `MCPSocketBridge.swift:39-41`)
   with accurate comments about why `try?` can't catch a signal.
9. **Force-unwrap hygiene**: 1 `as!` and 3 `try!` in ~380 K LOC of Swift (the `try!`s are
   compile-time-constant regexes — acceptable idiom), and the `.first!`/`.last!` sites I
   checked are all dominated by guards.

---

## Coverage gaps (not examined)

- **Web assets** (`Sources/ViewerUI/Resources/` CodeMirror/Mermaid/Canvas JS) — silent JS
  failure paths in the WKWebView layer were out of scope for this static pass.
- **Canvas subsystem** (Rust `canvas/` ~10 files + Swift Canvas UI) — only spot-checked
  `lower.rs` for unwraps (all test-side); the DSL/patch/undo logic was not line-audited.
- **LSP subsystem** (`Sources/ViewerCore/LSP/`, 22 `try?` in LSPClient) — sampled
  `LSPPool.didSave`/`didRenameFiles` fire-and-forget sites only; JSON-RPC id bookkeeping and
  server lifecycle not audited.
- **Terminal escape-sequence parser** (`TerminalOutputParser` etc.) — geometry/screen model
  audited; the CSI/OSC byte parser itself not.
- **`tui`/`web`/`serve` Rust front-ends** — `main.rs` files carry unwraps (107/76) but are
  developer-facing binaries, deprioritized; `serve`/`watch`/`search` production code was
  checked (clean).
- **Tests as evidence** — I did not run any test suite; all claims are from reading code.
- **Concurrency-only races** (actor isolation, `@unchecked Sendable` audits) — noted where
  they intersected a silent-failure path (F1, F11) but not swept systematically; that is the
  `code-quality`/`regressions` dimensions' territory.
- **`arithmetic_side_effects`** in Rust remains un-denied (205 sites measured per
  `Cargo.toml:102-103` comment) — overflow behavior was not audited beyond the lint note.
