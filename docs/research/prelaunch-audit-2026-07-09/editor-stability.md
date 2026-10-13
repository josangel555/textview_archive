# Pre-launch product review — Editor stability + reliability

**Dimension:** Data-loss paths in the editor — external-change detection, save integrity,
encoding round-trips, undo reliability, dirty-state truthfulness.
**Date:** 2026-07-10 · **Reviewer:** Claude (automated pre-launch audit)
**Repo state:** `main` @ `304a8290` (working tree has unrelated uncommitted changes to
`main.swift` / `MCPSocketBridge.swift`, not reviewed here).

---

## Executive summary

The text-editor save/conflict machinery is **unusually well engineered** for a pre-1.0 app:
atomic rename saves with mode/owner/xattr replay and EACCES/symlink handling, a pure
write-time no-clobber decision table (`SaveConflictDecision`), watcher-time conflict
classification (`DiskConflictResolver`), a 3-way auto-merge for non-overlapping external
edits, hot-exit persistence with >1 MiB sidecar spill and restored external-edit baselines,
snapshot-on-save local history, and dense host-test coverage of all of it. The
2026-06-20 data-loss incident produced a layered defense that mostly holds.

The remaining risk concentrates in **two structural gaps and a cluster of secondary seams**:

1. **The Swift-side buffer is a trailing-edge-debounced mirror of CM6** (200 ms, reset per
   keystroke → unbounded staleness under continuous typing), and **no lifecycle boundary
   flushes it**. Menu ⌘S, close-prompt Save, save-on-blur, session-switch capture, and
   quit-time hot-exit capture all read the stale mirror. Every dirty-state decision
   (`Tab.isDirty`, close prompts, `hasAnyUnsavedEdits`) is made on lagged data. This is the
   single highest-value fix in this dimension (P1).
2. **The editable-HEX path never got the conflict machinery.** A dirty hex tab is
   auto-reloaded over on a watcher tick (no prompt) and `saveHexEdits` has no write-time
   no-clobber guard — the exact class the text path fixed after 2026-06-20 (P1).

Everything else found is P2/P3: an unbounded snapshot write vs. an 8 MiB read cap that can
silently void hot-exit restore, a wrong fingerprint baseline when seeding editor buffers,
write-through convert/transform commands that bypass the no-clobber guard, a no-op
"View Diff…" button in the save-conflict alert, missing symlink/encoding-failure recovery
prompts on the text save path, and UTF-8 BOM round-trip loss.

**Verdict for launch:** fix findings 1 and 2 before shipping; 3–6 strongly recommended;
the rest are fast-follow quality items.

---

## Methodology

Static review (no UI runs, no repo mutation beyond this report). Examined in full or in
targeted depth:

- **Core model:** `Sources/ViewerCore/EditorBuffer.swift` (buffer + `EditorWriter`),
  `TextFileLoader.swift` (+ `TextDecoder`), `FileWatcher.swift`,
  `DiskConflictResolver.swift`, `SaveConflictDecision.swift`, `ExternalEditReconciler.swift`,
  `HotExitSpill.swift`, `Sessions/SessionStore.swift`.
- **UI/coordination:** `Sources/ViewerUI/Coordinators/EditorCoordinator.swift` (all 1,283
  lines), `Coordinators/TabCoordinator.swift` (buffer seeding), `DocumentModel.swift`
  (watcher wiring, reload paths, lines ~2600–3420), `DocumentModel+DiskConflict.swift`,
  `DocumentModel+EditorBuffer.swift`, `DocumentModel+EditableHex.swift`,
  `DocumentModel+ActiveFileFormatConvert.swift`, `DocumentModel+ScrollPersistence.swift`
  (hot-exit capture/restore), `Sessions/SessionsAppCoordinator.swift` (quit flush),
  `CodeMirrorEditorView.swift` (bridge, warm cache, registry).
- **Web layer:** `Sources/ViewerUI/Resources/codemirror/codemirror.html` (change
  debounce/emit, save keymap, blur).
- **App shell:** `Sources/MarkdownViewer/main.swift` (Save menu, quit path, undo/redo).
- **Ancillary writers:** `CrossFileReplace.swift`, CSV save chokepoint
  (`saveCSVEdits`), automation save verb (`ScriptVerbDispatch.swift`).
- **Tests (existence/coverage survey):** `EditorSaveNoClobberTests`,
  `EditorWriterBOMTests`, `ExternalEditReconcilerTests`, `DiskConflictResolverTests`,
  `SaveConflictDecisionTests`, `HotExitTests`, `HotExitSpillTests`,
  `DiskConflictBannerWiringTests`, `EditorBufferTests`, and others.

Not executed: any test suite (static-only pass; permitted headless filters were not needed
to confirm findings — all are code-evident).

---

## Findings

Severity: P0 ship-blocker · P1 major · P2 quality · P3 polish.
Fix size: S/M/L/XL. Fix risk: safe / careful / one-way-door.

---

### F1 · P1 — CM6→Swift text sync is trailing-edge debounced and **never flushed at any decision boundary**; every dirty/save/close/quit decision reads a stale mirror

**Files/lines:**
- `Sources/ViewerUI/Resources/codemirror/codemirror.html:121-124` — `scheduleChangeEmit()`
  clears and re-arms a 200 ms timer on *every* transaction (trailing edge; continuous
  typing postpones the emit indefinitely).
- `Sources/ViewerUI/CodeMirrorEditorView.swift:916-947` — Swift receives text only via the
  debounced `change`/`incrementalChange`; `dispatch(.flushChanges)` is sent **only** in
  drift recovery (line 945). Repo-wide grep confirms no other flush request.
- `Sources/ViewerUI/Coordinators/EditorCoordinator.swift:863-993` (`saveEditor` reads
  `buf.text`), `:1189-1210` (`confirmCloseIfDirty` reads `tab.isDirty`), `:508-510`
  (`hasAnyUnsavedEdits`).
- `Sources/MarkdownViewer/main.swift:994-1000` — File ▸ Save (⌘S) menu action calls
  `model.saveActiveEditor()` directly; no flush. (The in-page CM6 `Mod-s` keymap *does*
  flush — `codemirror.html:815-817` `emitChangeImmediate(); post("save")` — but the menu
  route, the close-prompt Save route, save-on-blur, and the automation `save` verb
  (`ScriptVerbDispatch.swift:328`) all bypass it.)
- `codemirror.html:888` — the blur handler posts `editorBlurred` **without** flushing, so
  `saveEditorOnBlur` saves the stale mirror too.
- `Sources/ViewerUI/Sessions/SessionsAppCoordinator.swift:432-453`
  (`flushForTermination` → `captureUnsavedTextForAllTabs`) and
  `Sources/ViewerUI/DocumentModel+ScrollPersistence.swift:249-285` — quit-time hot-exit
  capture reads the same stale buffers; the WKWebView is then torn down, so the pending
  `change` never arrives.

**Evidence chain (concrete scenarios):**
1. *Lost typing on close:* type into a previously-clean buffer and hit ⌘W within the
   debounce window (or while typing continuously). `Tab.isDirty` is still `false` →
   `confirmCloseIfDirty` returns nil → `closeTabUnconditionally` drops the buffer. The
   typed text exists only in the doomed WKWebView. Silent loss.
2. *Stale save:* dirty tab, type more, close → prompt → "Save". `saveEditor` writes
   `buf.text` **without** the last debounce-window of typing, then the tab closes. Tail
   lost, file on disk ≠ what the user last saw.
3. *Quit:* ⌘Q while typing → `applicationWillTerminate` → hot-exit capture misses the
   tail; relaunch restores older text with no signal.
4. *Session switch / warm-cache park:* park removes the message handler
   (`CodeMirrorEditorView.swift:336`); a pending JS emit fires into the removed handler and
   is swallowed (`codemirror.html:78-84` try/catch), and JS sets `lastEmittedText` as if
   delivered. On re-attach the cache's `expectedText` check compares two *equally stale*
   mirrors and passes — CM6 then displays text the Swift model doesn't have. The next
   keystroke heals it via the `contentLength` drift check, but a ⌘S before that writes
   stale text while the screen shows newer text.

**Impact:** silent loss of the most recent typing (200 ms minimum; unbounded under
continuous typing) across close, save, blur-save, session switch, and quit; dirty-dot and
close-prompt decisions made on lagged state. This is the largest remaining "editor loses
my words" hole in an otherwise defense-in-depth design.

**Suggested fix (M, careful):** introduce a synchronous flush seam and call it at every
decision boundary:
- JS already exposes `window.flushChanges` (`codemirror.html:1721`). Add an async Swift
  helper `flushPendingEdits(for tabID:) async` that evaluates `window.flushChanges()` and
  awaits the resulting `change` message (postMessage ordering on the main queue makes
  eval-then-message-delivery reliable; add a short timeout fallback).
- Call before: `saveEditor` (menu/verb/blur routes), `confirmCloseIfDirty`,
  `captureUnsavedTextForAllTabs` (session detach + quit), and warm-cache park.
- For the synchronous AppKit call sites (close prompt, quit), either make the flows async
  or use `evaluateJavaScript` with a bounded `RunLoop` drain — careful, but the flush is
  tiny and local.
Alternative cheap partial: also emit on JS `blur` and on `visibilitychange`, and drop the
debounce to leading+trailing edge with a max-latency cap (e.g. emit at least every 1 s of
continuous typing).

---

### F2 · P1 — Editable HEX: dirty tab is auto-reloaded over on external change (no prompt), and `saveHexEdits` has no write-time no-clobber guard

**Files/lines:**
- `Sources/ViewerUI/DocumentModel.swift:2792-2818` — `reloadCurrentFile(matching:)` gates
  the conflict path on `tab.isDirty && editorBuffers[tab.id] != nil`. A dirty HEX tab has
  `isDirty == true` but **no** text `EditorBuffer` (its edits live in `hexDirtyBytes`), so
  the guard falls through to the unconditional `reload(url:at:)` — no banner, no prompt.
- `Sources/ViewerUI/DocumentModel.swift:2901-2933` — `refreshDiskState(at:)` has no
  baseline for `.binary` state ("leave as-is unless the file vanished"), so the
  tab-switch-back staleness reload/conflict path (`selectTab`,
  `DocumentModel.swift:3397-3410`) never fires for hex tabs either.
- `Sources/ViewerUI/DocumentModel+EditableHex.swift:68-110` — `saveHexEdits` writes the
  stashed bytes with **no re-stat / fingerprint comparison** (contrast
  `EditorCoordinator.resolveSaveConflict`, EditorCoordinator.swift:1009-1040). The
  2026-06-20 incident class ("⌘S blind-overwrites a change another process made") is fixed
  for text but fully open for hex.

**Impact:** edit bytes in a hex tab; another process rewrites the file; the app silently
reloads the display (watcher tick) while keeping the dirty stash; ⌘S then writes the
stale-base stash over the external change with no warning and no recovery (hex writes get
no local-history snapshot either). Both halves of the text-path defense are absent.

**Suggested fix (M, careful):**
- In `reloadCurrentFile(matching:)`, treat `isHexDirtyTab(at: i)` as dirty: surface the
  existing `DiskConflictBanner` (or the modal) instead of reloading.
- Give `BinaryFile`/hex tabs a load-time `(mtime, size)` baseline and add the
  `SaveConflictDecision.decide` re-stat to `saveHexEdits` before writing.
- Optional: snapshot pre-overwrite bytes to Local History (it already self-gates binary —
  would need a raw-bytes lane or a size-capped copy).

---

### F3 · P2 — Session snapshots have no write-side size cap but an 8 MiB read cap: an oversized snapshot voids the entire session (including all hot-exit unsaved text) silently on next launch

**Files/lines:**
- `Sources/ViewerCore/Sessions/SessionStore.swift:64` — `maxSnapshotFileSize = 8 MiB`;
  `:269-277` — `load(id:)` returns nil for an oversized file (routed to
  "corrupt/start-empty").
- `SessionStore.swift:280-320` (`saveSync`/`enqueueSave`/`_encodeAndWrite`) — no size
  check on the write side.
- `Sources/ViewerUI/DocumentModel+ScrollPersistence.swift:249-285` — each dirty tab may
  inline up to 1 MiB (`hotExitMaxBytes`) of `unsavedText` into the snapshot; the number of
  tabs is unbounded, and JSON string-escaping inflates the bytes further.

**Evidence:** ~7–8 dirty tabs near the 1 MiB inline cap (or many mid-size dirty buffers)
produce a snapshot > 8 MiB. The write succeeds; the next launch's `load(id:)` rejects the
file and the session restores empty — tabs, scroll, and **every unsaved buffer** gone at
once, with only a start-empty. The HotExitSpill doc comment
(`Sources/ViewerCore/HotExitSpill.swift:8-9`) already names this trap ("trip the 8 MiB
snapshot read cap → silent data loss on restore") but only the single->1 MiB-buffer case
was fixed; the aggregate case is open.

**Impact:** rare but catastrophic-scope silent loss of all in-flight work in a session.

**Suggested fix (M, safe):** enforce the budget at write time — if the encoded snapshot
exceeds (say) 6 MiB, spill the largest `unsavedText` fields to `HotExitSpill` sidecars
(mechanism already exists and restore already checks the sidecar when inline text is
absent, `DocumentModel+ScrollPersistence.swift:299-308`) and re-encode. Additionally, on
read, before discarding an oversized snapshot, attempt a salvage decode (the cap defends
against tampering, but the file is self-written; a one-line "snapshot too large" stderr
note would also end the silence).

---

### F4 · P2 — Editor buffer seeding fingerprints against a *fresh* stat while taking *stale* loaded contents — blinding external-edit detection for the gap

**Files/lines:** `Sources/ViewerCore/EditorBuffer.swift:174-187` — `init(from file: TextFile)`
takes `original: file.contents` (read at load time) but stats the file **now** for
`lastSavedMTime/Size`. Used by `TabCoordinator.editorBuffer(forTabID:)` /
`ensureEditorBuffer` (`Sources/ViewerUI/Coordinators/TabCoordinator.swift:468-483`) when a
tab enters `.editor` mode.

**Evidence:** file loaded at T0; external write at T1; user switches the tab to editor
mode at T2. The buffer now holds T0 contents with a T1 fingerprint. `hasExternalEdit`
compares watcher/current stats against the T1 baseline → **false** → the T0→T1 change is
undetectable forever: the watcher tick reloads nothing (buffer clean → reload does fix
it), but if the user types first, the conflict path *and* the write-time
`SaveConflictDecision` both see a matching fingerprint and let ⌘S overwrite the T1
external change with T0-based text. The normal protection (watcher auto-reload of clean
active tabs) usually closes this within ~100 ms, but it is exactly the watcher-missed
window (`liveReloadUnavailable`, FSEvents coalescing, background tab entering editor mode
on restore) the write-time guard was built for — and this seed defeats it. `TextFile`
already carries the correct pair (`modifiedTime`, `byteCount`,
`Sources/ViewerCore/TextFileLoader.swift:33,21`).

**Impact:** narrow-window silent clobber of external changes; undermines the no-clobber
guard's "unknown ⇒ conflict" safety rule with a confidently-wrong baseline.

**Suggested fix (S, safe):** seed `lastSavedMTime/Size` from `file.modifiedTime` /
`file.byteCount` instead of a fresh `attributesOfItem` stat. (Same note applies to
`EditorBuffer.load(url:)`, EditorBuffer.swift:160-172, which stats *after* the read —
prefer the loader's own captured attrs.)

---

### F5 · P2 — Convert/transform write-through commands bypass the no-clobber guard and the watcher pause

**Files/lines:**
- `Sources/ViewerUI/DocumentModel.swift:2700-2714` — `applyTextTransformToActiveFile`
  (sort/dedupe/trim/etc.): `EditorWriter.save` directly, no `SaveConflictDecision`, no
  watcher pause, no local-history snapshot.
- `Sources/ViewerUI/DocumentModel+ActiveFileFormatConvert.swift:62-76` (line endings),
  `:86-98` (encoding convert): same pattern.

**Evidence:** these commands write `ctx.text` (buffer including unsaved edits) straight
over the file. If the file changed on disk unseen (watcher dead/coalesced — the exact
premise of TSK-768), the external change is silently overwritten. They also skip the
snapshot-on-save chokepoint (`EditorCoordinator.saveEditor`,
EditorCoordinator.swift:980-981), so the overwrite is not locally recoverable, and they
don't pause the watcher (benign double-reload today, but a needless race).
Failure handling is also log-only (`Obs.shared.emit(.warn, ...)`) — a failed "Convert
Encoding" (e.g. emoji → Latin-1 `.encodingFailed`) shows the user nothing (see F8).

**Impact:** medium-probability silent clobber + non-recoverable overwrite via a menu
command the user thinks of as "formatting", not "saving".

**Suggested fix (M, safe):** route these writes through a shared guarded chokepoint
(re-stat + `SaveConflictDecision`, watcher pause, local-history snapshot) — essentially
`saveEditor(forTabID:)` with a text override, or extract `saveEditor`'s guard block into a
reusable `guardedWrite(text:to:encoding:)`.

---

### F6 · P2 — "View Diff…" in the save-conflict alert is a permanently-unwired no-op

**Files/lines:** `Sources/ViewerUI/Coordinators/EditorCoordinator.swift:415` declares
`onViewSaveConflictDiff` ("until wired this is a no-op"); `:1079-1084` invokes it.
Repo-wide grep: **no assignment anywhere** (only declaration + call site).
The alert (`runSaveConflictAlert`, `:1097-1132`) lists "View Diff…" **first** — the
position the decision layer reserves for the safest choice
(`SaveConflictDecision.conflictActions`, `Sources/ViewerCore/SaveConflictDecision.swift:68-70`).

**Impact:** at the exact moment a user faces a data-loss decision, the first-offered,
most-conservative option dismisses the dialog and does nothing. Users may believe they
viewed/accepted something, or lose trust and pick "Overwrite" out of frustration. The
save is correctly aborted, so no direct loss — but it degrades the one dialog whose whole
job is preventing loss.

**Suggested fix (S to drop / M to wire, safe):** either wire it to the existing
buffer-vs-disk diff surface (`beginConflictResolution` /
`ConflictResolutionModel`, `DocumentModel.swift:3020-3027`, already builds the 3-pane
model), or stop offering the action until wired (filter it from `conflictActions` at the
prompt layer).

---

### F7 · P2 — Text-editor save onto a symlink fails with a raw error dump; the designed "follow the link?" prompt exists only on the HEX path

**Files/lines:**
- `Sources/ViewerCore/EditorBuffer.swift:196-203` — `EditorWriteError.targetIsSymlink`
  exists precisely "so the UI can prompt 'follow the link?'".
- `Sources/ViewerUI/Coordinators/EditorCoordinator.swift:983-992` — `saveEditor`'s catch-all
  shows `informativeText = "\(error)"` → the user sees
  `targetIsSymlink(resolvedTarget: "/actual/path")` and has no way to save.
- Contrast `Sources/ViewerUI/DocumentModel+EditableHex.swift:76-84,136-147` — the hex path
  implements the prompt (`presentHexSymlinkPrompt`) and retries with `allowSymlink: true`.

**Impact:** a user who opened a file through a symlink (common in dotfile setups) can
*never* ⌘S — every save fails with an opaque alert; edits are stranded (recoverable only
via Save-a-Copy or hot exit). Data-loss adjacent: repeated failed saves + a quit is a
plausible loss path, and the error text is developer-facing.

**Suggested fix (S, safe):** mirror the hex prompt in `saveEditor`'s catch:
on `.targetIsSymlink`, offer "Replace Link" (retry with `allowSymlink: true`) /
"Save a Copy…" / Cancel. Also humanize `.encodingFailed` and generic write failures while
in the same switch.

---

### F8 · P2 — Encoding-unrepresentable buffer makes ⌘S fail with a raw error and no path forward

**Files/lines:** `Sources/ViewerCore/EditorBuffer.swift:260-262`
(`text.data(using: encoding)` nil → `.encodingFailed`), surfaced by the same generic alert
(`EditorCoordinator.swift:983-992`).

**Evidence:** open a CP1252/Latin-1 file (the decode ladder's common fallback for legacy
text, `TextFileLoader.swift:417-424`), type an emoji or any character outside the
codepage, ⌘S → "Couldn't save … encodingFailed(…)". The buffer stays dirty (good), but the
alert offers no "Save as UTF-8" / "Convert" escape; the menu command that would fix it
(Format ▸ Convert Encoding) is unreferenced by the alert. A user who doesn't find it can
only lose the edits or park them in hot exit forever.

**Impact:** stranded edits + repeated failed saves on legacy-encoded files; the fix
already exists in-app but is undiscoverable at the failure point.

**Suggested fix (S/M, safe):** on `.encodingFailed`, offer "Save as UTF-8" (write-through
with `.utf8` via the F5 chokepoint + reload, mirroring `convertActiveFileEncoding`) and
"Cancel". Name the offending encoding in plain language.

---

### F9 · P2 — UTF-8 BOM is silently dropped on save (encoding round-trip infidelity)

**Files/lines:** `Sources/ViewerCore/TextFileLoader.swift:499-504` — `decodeViaBOM` strips
the EF BB BF BOM and records plain `.utf8` (indistinguishable from BOM-less);
`Sources/ViewerCore/EditorBuffer.swift:243-252` — `withByteOrderMark` re-emits BOMs only
for explicit-endianness UTF-16; `Tests/ViewerCoreTests/EditorWriterBOMTests.swift:104` pins
"UTF8SaveRemainsBOMless" — correct for BOM-less input, but the BOM-ful case has no
representation.

**Evidence:** open a UTF-8-with-BOM file, change one character, save → the file loses its
3 BOM bytes. Round-trip is not byte-faithful for untouched content. Consumers that key on
the BOM (Excel CSV import, some Windows toolchains, PowerShell 5 script encoding
detection) change behavior after an innocent edit.

**Impact:** no text loss, but silent byte-level mutation of file identity outside the
user's edit — the same class the UTF-16 BOM fix (TSK-861) treated as a bug.

**Suggested fix (S, safe):** record BOM presence at decode (e.g. a `hadUTF8BOM` flag on
`TextFile`/`EditorBuffer` or a distinct sentinel encoding) and re-emit it in
`withByteOrderMark`. Update the pinned test to cover both cases.

---

### F10 · P3 — Destructive discard paths ("Take disk", close-"Don't Save") never snapshot the discarded text to Local History

**Files/lines:** `Sources/ViewerUI/Coordinators/EditorCoordinator.swift:1247-1269`
(`applyExternalEditOutcome .discardAndReload` → `discardEditorBuffer`, no snapshot);
`DocumentModel.swift:3163-3178` (close `.discard` branch); contrast the save path's
snapshot-on-save (`EditorCoordinator.swift:980-981`, TSK-1103).

**Impact:** the only two flows that *intentionally destroy* user text are the only ones
with no recovery net; a mis-click on "Discard & Reload" / "Don't Save" is final (undo may
partially help only while the CM6 view is still alive).

**Suggested fix (S, safe):** call `localHistoryStore.snapshot(path:content:at:)` with the
buffer's text immediately before `discardEditorBuffer` in both flows (store already
self-gates size/secrets/dedup).

---

### F11 · P3 — External auto-merge composes against the debounce-stale mirror and pushes `setText` over CM6, discarding un-emitted keystrokes

**Files/lines:** `Sources/ViewerUI/DocumentModel.swift:3002-3012`
(`applyExternalAutoMerge` — merges `buf.text`, i.e. the stale mirror), delivered to CM6 via
`bind → pendingText → setText(preserveSelection: true, resetHistory: false)`
(`CodeMirrorEditorView.swift:513,720-741`).

**Evidence:** watcher tick fires while the user typed within the last 200 ms. The 3-way
merge uses `ours = stale buffer text`; the resulting `setText` replaces the CM6 doc,
overwriting the keystrokes that never made it to Swift. (Sub-case of F1 — fixed for free
by flushing before reconcile; listed separately because the merge is the one path that
rewrites CM6's doc unprompted while the user is actively typing.)

**Suggested fix (S once F1's flush exists, careful):** flush pending edits for the tab
before `reconcileExternalEdit`; optionally skip auto-merge when a flush round-trip fails.

---

### F12 · P3 — Post-save fingerprint is stat'd after the rename, so a fast foreign write can be adopted as "our" baseline

**Files/lines:** `Sources/ViewerCore/EditorBuffer.swift:367-379` — `rename()` then
`statFingerprint(targetPath)`; a foreign write landing in that gap yields a stamp that
`markSaved` records as the saved state (`EditorCoordinator.swift:915-917`), and the FW-7
lost-event recheck (`EditorCoordinator.swift:1149-1177`) then compares current-vs-foreign
and sees no divergence.

**Impact:** very narrow race; consequence is a missed conflict prompt (next ⌘S is still
guarded only by the equally-poisoned baseline). Worth closing because the writer could
report ground truth for free.

**Suggested fix (S, safe):** `fstat` the temp file's fd (or stat the temp path) *before*
the rename and return that as the fingerprint — mtime/size of the renamed inode are
preserved by `rename(2)`.

---

### F13 · P3 — Edit ▸ Undo fallback can route ⌘Z into a non-focused editor pane

**Files/lines:** `Sources/MarkdownViewer/main.swift:1032-1043` (menu undo →
`CodeMirrorEditorRegistry.shared.current()` → JS `undo()`);
`Sources/ViewerUI/CodeMirrorEditorView.swift:1405-1428` — `current()` falls back to
"first-in-window (then last-registered)" when focus is outside every editor pane.

**Evidence:** with MountedPanesLRU keeping several panes mounted, a ⌘Z issued while focus
is in a sidebar/tool field reaches an arbitrary mounted editor and mutates *that*
document (its change event then dirties its buffer). The mutation is at least undoable and
visible via the dirty dot, hence P3.

**Suggested fix (S, safe):** in the no-focused-editor case, beep/no-op (or route to the
app-level bookmark undo only) instead of falling back to an unfocused pane.

---

### F14 · P3 — `EditorWriter` does not fsync before the atomic rename (crash-window durability)

**Files/lines:** `Sources/ViewerCore/EditorBuffer.swift:342-372` — temp write via
`Data.write(.atomic)` then `rename(2)`; no `fcntl(F_FULLFSYNC)`/`fsync` on the temp file or
directory.

**Impact:** on power loss within the OS write-back window, APFS may commit the rename
metadata before the temp file's data blocks — the "saved" file can be truncated/empty
after reboot. Most Mac editors accept this trade-off, and Local History (snapshot-on-save
is written the same way, though) plus hot exit reduce exposure; noted for completeness
rather than urgency.

**Suggested fix (S, careful — perf):** `fsync`/`F_FULLFSYNC` the temp fd before `rename`
for files under a size threshold, or gate behind a "durable saves" preference.

---

### F15 · P3 — Menu text transforms fail silently (log-only) on write errors

**Files/lines:** `Sources/ViewerUI/DocumentModel.swift:2704-2710` and
`DocumentModel+ActiveFileFormatConvert.swift:68-71,90-93` — failures emit to `Obs` and
return false; no alert, no toast.

**Impact:** "Trim Trailing Whitespace" / "Convert Line Endings" that hit a permission or
encoding error appear to succeed (nothing happens); the user's mental model of the file
state is now wrong. Fold into F5's chokepoint work.

**Suggested fix (S, safe):** surface a toast/alert on failure (the editor save path
already models this).

---

## Positive observations

These are genuinely strong and worth preserving through any refactor:

- **`EditorWriter.save`** (`EditorBuffer.swift:254-380`): atomic same-directory temp +
  `rename(2)`, metadata replay (mode/owner/xattrs) captured from an O_NOFOLLOW fd,
  ELOOP-based symlink classification (TOCTOU-closed), and the EACCES path that refuses to
  save rather than silently downgrade a 0600 file's permissions. This is better than most
  shipping editors.
- **Layered external-change defense:** watcher tick (`FileWatcher` with debounce, backoff,
  reattach, `onLost` surfacing + `liveReloadUnavailable` cue) → tab-switch re-stat
  (`selectTab` → `refreshDiskState` → guarded reload, `DocumentModel.swift:3396-3410`) →
  write-time no-clobber re-stat (`SaveConflictDecision`) → post-save FW-7 lost-event
  recheck. Four independent nets for the text path.
- **"Can't tell ⇒ conflict" discipline:** `hasUnknownDiskState`
  (`EditorBuffer.swift:137-146`) and its mirrored decision tables in
  `DiskConflictResolver.classify` and `SaveConflictDecision.decide` — nil-fingerprint cases
  escalate to a prompt instead of a silent reload. Excellent.
- **3-way auto-merge for non-overlapping external edits** (`ExternalEditReconciler`,
  `applyExternalAutoMerge`) keeps both sides with a toast; overlapping edits fall to a
  non-modal banner backstopped by the write-time guard.
- **Hot exit** (TSK-718/1025/1026): per-tab unsaved text with the *pre-exit* disk baseline
  re-seeded on restore so the conflict path fires for changes made while the app was
  closed; >1 MiB buffers spill to sidecars keyed by path hash; orphan pruning.
- **Snapshot-on-save Local History** (TSK-1103) at the single save chokepoint, making
  "Overwrite" in the conflict dialog recoverable.
- **Read-only extracted views** (TSK-1204): `isReadOnly` refusal at the write chokepoint so
  a .docx/.xlsx extraction can never overwrite its binary source.
- **Warm-editor cache** re-attach is text-gated (`expectedText` check) so a parked WebView
  can't resurrect stale content over newer model state — and it preserves undo history
  across tab/session switches.
- **UTF-16 BOM round-trip** handled end-to-end (TSK-861) with teeth-tested regression
  guards (`EditorWriterBOMTests`).
- **Test density:** dedicated host suites exist for the no-clobber guard, conflict
  classifiers, reconciler, disk-state transitions, hot exit + spill, EACCES metadata
  preservation, and the banner wiring — the pure-logic layer of this dimension is
  genuinely well covered.

---

## Coverage gaps (not examined)

- **CM6 JS internals** beyond the host-glue (`codemirror.js` is a minified bundle) — undo
  granularity, IME/composition edge cases inside CodeMirror itself.
- **Notebook (`NotebookDocument`), Canvas (`canvas_save`), and Image-editor persistence**
  — each has its own dirty/save lifecycle; only the text/hex/CSV lanes were audited.
- **LSP-driven workspace edits** (rename_symbol / code actions writing multiple files) and
  **plugin write paths** — separate write surfaces not routed through `EditorWriter`
  (unverified either way).
- **Automation/MCP mutation tools** beyond the `save` verb routing check (`move_file`,
  `canvas_apply`, edit-apply flows).
- **Multi-window/multi-instance concurrency** (`InstanceRegistry`, two app instances
  editing the same file) — the watcher/no-clobber machinery should cover it, but the
  instance-level interplay was not traced.
- **Rust-core find/replace engines** under `rust-core/crates/` (the Swift
  `CrossFileReplace` wrapper was reviewed; the Rust twin was not).
- **Runtime verification:** all findings are static; none were reproduced in the VM UI
  lane (per constraints). F1's WKWebView message-ordering assumptions and the
  menu-vs-keymap ⌘S race in particular deserve a VM repro before/after the fix.
- Session **restore** interplay with `MDV_SKIP_WORKSPACE_RESTORE` and multi-session
  detach ordering beyond the quit path traced above.
