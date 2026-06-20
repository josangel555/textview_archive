# Adversarial Review — Error-Handling Dimension (2026-06-18)

Boundary error handling in this codebase is, on the whole, unusually disciplined: the
FFI seam (`CoreClient.swift`, `CoreTransport.swift`) maps every non-`Ok` status to a typed
`CoreError` and never swallows; `EditorWriter.save` is a textbook atomic-rename with
symlink/EACCES/metadata-preservation handling; `ProcessRunner` drains pipes concurrently
with SIGTERM→SIGKILL escalation and a combined byte cap; `GitClient` builds a minimal env
and distinguishes timeout from hard failure; `RemoteTransport`/`LSPClient` arm per-call
deadlines so a wedged peer can't hang an adapter. The defects that remain are concentrated
in the **UI-action layer**, where a handful of write/export paths swallow errors with `try?`
or proceed past a failed write — silent failures on user-initiated actions, and in one case
a real (if quiet) data-loss surface. The same codebase surfaces these errors correctly in
sibling code (audio export, HTML export), which is what makes the misses concrete defects
rather than design choices. A few transport-layer edges (EINTR handling, an attach/close
race) round out the list.

### Image-editor "Save a Copy…" swallows every write error (silent data loss)

**Severity:** high

**Location:** `Sources/ViewerUI/ImageEditorView.swift:149`

**Why:** `saveCopy()` presents an `NSSavePanel`, computes the format, then writes with
`try? vm.export(format: format, to: url)`. `ImageEditorViewModel.export` →
`Exporter.export` → `Data.write(.atomic)` can throw for every realistic reason: target dir
not writable, disk full, an `ExportSpec`/encoder failure (e.g. HEIC unsupported on the
target, or a 0×0 / pathological image the CIContext can't render). All of those are
discarded. The user picks a destination, clicks Save, the file is **not written**, and the
editor gives **zero feedback** — they believe their edited image is safely on disk. If they
were exporting *over* an existing file they just consider replaced, or close the source after
"saving", the edit is lost. This is the exact failure the OWNER directive about the
terminal-tab-strip ("proved it worked when it didn't") warns against, applied to a write
path. Note the *sibling* `AudioEditorView.saveCopy()`
(`Sources/ViewerUI/AudioEditorView.swift:282-290`) handles the identical flow correctly with
a `do/catch` + `NSAlert`, and `exportAsHTML` (`Sources/MarkdownViewer/main.swift:2553-2561`)
does too — so the standard is established and this is a deviation, not a convention.

**Fix:** Mirror `AudioEditorView.saveCopy()`: wrap the export in `do { try vm.export(...) }
catch { NSAlert … runModal() }` with a human-readable message keyed off the error. Bonus:
add a host test that injects an `Exporter` failure and asserts the model surfaces it (the
view-model already has `lastError` plumbing — route export failures through a published
error the view shows, so it's headless-testable per the CLAUDE.md teeth mandate).

**CONFIRMED** — `ImageEditorView.swift:149` is `try? vm.export(...)` with no surfacing; the sibling `AudioEditorView.saveCopy()` (lines 282-290) uses do/catch + NSAlert, confirming the deviation. Real silent-data-loss surface.

### Git-log markdown tab opens even when the file write failed

**Severity:** medium

**Location:** `Sources/ViewerUI/DocumentModel.swift:2241-2242`

**Why:** The git-history-to-markdown action does `try? md.write(to: out, atomically: true,
encoding: .utf8)` and then **unconditionally** `openInNewTab(out)`. Two compounding problems:
(1) the write error is swallowed, and (2) the success path proceeds regardless. If the write
fails (the `MarkdownViewer/git-log` caches dir isn't writable, disk full, or the
`createDirectory` on the line above silently failed — also `try?`), `openInNewTab` opens a
tab pointing at a path that doesn't exist, or — worse, because the filename is a *stable
content hash* of `repoRoot + relPath` — at a **stale prior** git-log file for the same path.
The user then reads outdated history believing it's current, with no signal that the refresh
write failed. Silent staleness is harder to catch than an outright error.

**Fix:** Branch on the write result: `do { try md.write(...) ; openInNewTab(out) } catch {
Obs.shared.emit(.warn, "git", "…") ; present an NSAlert or open the content as an in-memory
Untitled tab instead of a path that may be stale }`. At minimum, don't `openInNewTab` a
hashed path when the write that was supposed to refresh it threw.

**CONFIRMED** — line 2241 `try? md.write(...)` then unconditional `openInNewTab(out)` (2242); filename is a `Hasher`-stable content hash (2228-2240), so a failed refresh re-opens a stale prior file with no signal. `createDirectory` (2237) is also `try?`.

### "Open in Browser" silently no-ops when the temp HTML write fails

**Severity:** medium

**Location:** `Sources/MarkdownViewer/main.swift:2540` (and the producer
`Sources/ViewerUI/DocumentModel.swift:5107-5114`)

**Why:** `writeActiveMarkdownPreviewHTML()` returns `nil` on a write failure (`do { try
Data(html.utf8).write(...) } catch { return nil }`, line 5112). The menu handler
`openInBrowser` does `guard let url = … else { return }` — so on a temp-dir write failure
the menu item does **nothing**, with no alert, no log, no cursor change. The user clicks
"Open in Browser", a browser never opens, and there's no way to tell whether the action ran.
The temp dir is normally writable, but a full `/var/folders` volume, a sandbox/TCC denial,
or an oversized inlined-image HTML (the producer inlines all local images as base64) makes
this reachable. Same swallow-and-no-op shape as the image-editor save, lower stakes (no data
loss).

**Fix:** Surface the failure. Have `writeActiveMarkdownPreviewHTML` either throw or log via
`Obs.shared.emit`, and have `openInBrowser` present an `NSAlert` (consistent with
`exportAsHTML`) when the URL is nil because of a real failure (distinguish "no markdown
active" — a legitimate disabled state — from "write failed").

**CONFIRMED** — producer `DocumentModel.swift:5112` `catch { return nil }`; consumer `main.swift:2540` `guard let url = … else { return }` collapses "no markdown active" and "write failed" into the same silent no-op. Sibling `exportAsHTML` (main.swift:2553-2561) does do/catch + NSAlert. Medium is fair (no data loss).

### RemoteTransport read/write treat EINTR as a fatal connection error

**Severity:** medium

**Location:** `Sources/RustCore/RemoteTransport.swift:442-454` (`readExact`) and
`:423-440` (`writeEnvelope`)

**Why:** Both loops call raw `read(2)` / `write(2)` and, on a `-1` return, immediately throw
`.io("read/write: errno \(errno)")` — which the reader loop maps to a terminal error that
fails **every pending call**, drops all subscriptions, and tears the connection down for
good (`readerDidExit`, no reconnect in v1). But `errno == EINTR` is not a connection
failure: a `read`/`write` can be interrupted by any signal delivered to the process (e.g. a
`SIGCHLD` from a subprocess, a profiler signal, `SIGINFO`). On a syscall without
`SA_RESTART`, that returns `-1`/EINTR and the *correct* behavior is to retry the same call.
Here a single stray signal during a remote-core session permanently drops the tunnel and
reverts the whole app to in-process engines mid-operation. `EAGAIN`/`EWOULDBLOCK` would be
similarly mishandled if the fd were ever non-blocking. (`InProcessTransport` is unaffected;
this is remote-only, which is why it hasn't bitten yet — but the remote path is the stated
forward direction.)

**Fix:** In both loops, `if got < 0 && (errno == EINTR) { continue }` (retry) before
treating `-1` as fatal; likewise guard `EAGAIN`/`EWOULDBLOCK`. This is the standard
`readExact`/`writeAll` idiom and the codebase already knows it (the `SO_NOSIGPIPE` handling
shows signal-awareness — EINTR is the matching gap).

**CONFIRMED** — `readExact:450` `guard got > 0` and `writeEnvelope:437` `guard wrote > 0` both throw `.io` on any `-1` with no `errno == EINTR` retry. The reader routes that throw into `readerDidExit` (302-323) which sets `closedError` (terminal — every later `callInner` throws at 105-107), drops all subs, and there is no reconnect in v1, so one stray signal permanently drops the tunnel.

### Remote-core attach can install a connection that died during the init→register window

**Severity:** low

**Location:** `Sources/ViewerCore/RemoteCoreAttach.swift:40-52` interacting with
`Sources/RustCore/RemoteTransport.swift:76-81, 302-323`

**Why:** `RemoteTransport.init` starts the reader thread *before* returning. `RemoteCoreAttach`
then sets `remote.onClose` (line 44) and only afterwards installs the transport into the
registry (line 52). If the server dies in the window between the reader starting and
`onClose` being assigned, `readerDidExit` fires `closeHandler` while it is still `nil` — the
auto-revert-to-in-process never runs. Worse, line 52 then installs an *already-dead*
transport as the process-wide core: `closedError` is set, so every subsequent adapter call
takes the `if let dead = closedError { throw dead }` fast path. With the fallback wrapper
that degrades to Swift, this is survivable, but a remote-only capability (fs/git/search,
which have no in-process twin) would fail for the whole session with no revert, and `onClose`
will never re-fire to fix the registry. The race is narrow but the failure is sticky.

**Fix:** Have `RemoteTransport.init` accept `onClose` as a constructor parameter (set under
the same `state` lock before the reader thread starts), OR after assigning `onClose`,
re-check `closedError` and, if the connection already died, call `resetToInProcess()` /
return `.failed(...)` instead of installing the dead transport. The lock-guarded
`readerDidExit` already guarantees `onClose` fires at most once, so wiring it in before the
reader starts closes the window cleanly.

**CONFIRMED** — `init` calls `startReader()` (RemoteTransport.swift:80) before returning; `RemoteCoreAttach` assigns `onClose` only after (lines 44-51) then installs into the registry (52). `readerDidExit` captures `let closeHandler = onClose` (314) and is one-shot via `guard closedError == nil` (305), so a death in the window fires nothing and installs an already-dead transport (`closedError` set ⇒ every call throws). Narrow race, sticky failure; low is fair.

### Git output decode failure collapses to empty string (silent "no history / clean tree")

**Severity:** low

**Location:** `Sources/ViewerCore/Git/GitClient.swift:1287` (and the stderr twin at `:1296`)

**Why:** `let out = String(data: result.stdout, encoding: .utf8) ?? ""`. If git emits bytes
that aren't valid UTF-8 — reachable via non-UTF-8 filenames in the repo with `core.quotepath`
off, or embedded binary content in a `git log -p` / `git show` of a file the differ treats as
text — the **entire** stdout silently becomes `""`. Downstream that reads as "no log
entries", "clean tree", "no remotes", etc. (every read method does `guard let out = try?
run(...) else { return [] }` then parses `out`). So a repo with one undecodable byte in its
output can make file history / status / stash appear empty, indistinguishable from a genuinely
empty result. No error, no log line.

**Fix:** Decode with a lossy fallback so undecodable bytes degrade to replacement chars
rather than nuking the whole payload — e.g. `String(decoding: result.stdout, as: UTF8.self)`
(lossy, never nil), or try UTF-8 then fall back to `.isoLatin1`. For the porcelain/`-z`
parsers this is strictly safer; for log/diff bodies a replacement char beats a blank panel.

**CONFIRMED** — line 1287 `String(data: result.stdout, encoding: .utf8) ?? ""` (stderr twin 1296); downstream readers do `guard let out = try? run(...) else { return [] }` then parse `out` (e.g. lines 139, 251, 347, 378, 426, 445, 517, 563), so a single undecodable byte ⇒ empty payload ⇒ "empty result" indistinguishable from genuinely empty. Low is fair (needs non-UTF-8 git output).

### SQLite schema-listing failures are swallowed, showing an empty (but "opened") database

**Severity:** low

**Location:** `Sources/ViewerCore/../SQLiteBrowserView.swift:225-228`

**Why:** After a successful `SQLiteReader(url:)` open, the four schema listings use `try?`
with an `?? []` fallback: `let tables = (try? r.tableNames()) ?? []`, etc. If the DB opens but
schema enumeration fails (a corrupt `sqlite_master`, a locked DB whose `PRAGMA` step errors,
an encrypted/partially-written file that opens but can't be read), the user sees a
*successfully-opened* database with an **empty schema** and no error — the `openError` path
(line 236-238) only catches an open *throw*, not a post-open listing failure. They conclude
the DB is empty rather than unreadable.

**Fix:** Don't `try?` the listings independently of the open. Either let them throw into the
same `catch` that sets `openError`, or accumulate a per-section error so the UI can show
"couldn't read tables: …" instead of a silent empty list. At minimum log via `Obs.shared`.

**CONFIRMED** — lines 225-228 each `(try? r.<x>Names()) ?? []`; the four methods do `throws` (`SQLiteReader.swift:133/139/145/151`); the `catch` (236-238) only catches the `SQLiteReader(url:)` open throw, not the listing failures, so a DB that opens but can't enumerate its schema shows empty with no error. Low is fair.

### "Save a Copy" silently re-encodes to UTF-8 when the buffer encoding can't represent the text

**Severity:** low

**Location:** `Sources/ViewerUI/DocumentModel.swift:3284-3288`

**Why:** For an editor-dirty tab, `saveCopy` does `buf.text.data(using: buf.encoding) ??
buf.text.data(using: .utf8)`. If the user opened a Latin-1 / CP1252 file, typed characters
that encoding can't represent (an emoji, a CJK glyph), the primary encode returns nil and the
code **silently writes UTF-8 instead** — a copy in a *different encoding than the source*,
with no notice. The interactive editor-save path is careful here (`EditorWriteError.encodingFailed`
is a first-class recoverable error that the UI can prompt on), but the "Save a Copy" path
quietly diverges. The result is a file the user may later reopen expecting their original
encoding and find mis-detected, or a downstream tool that assumes Latin-1 mis-reads it.

**Fix:** Make the fallback explicit: either throw `SaveCopyError.encodingFailed` (consistent
with the editor-save path, letting the UI offer "save as UTF-8 instead?"), or record the
encoding change and surface it. Don't silently swap the on-disk encoding of a "copy" the user
believes is faithful.

**CONFIRMED** — line 3284-3285 `buf.text.data(using: buf.encoding) ?? buf.text.data(using: .utf8)` silently re-encodes to UTF-8 when the buffer encoding can't represent the text; the `SaveCopyError.encodingFailed` throw (3286) is effectively dead (UTF-8 encodes any Swift String). The editor-save path (`EditorBuffer.save`, EditorBuffer.swift:252-253) instead throws `EditorWriteError.encodingFailed(encoding)` with no UTF-8 fallback, confirming the divergence. Low is fair (a "copy" path).
