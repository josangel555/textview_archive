# Verification pass 1/2 — DATA-SAFETY audit findings vs current `main`

Verified against `markdown_viewer @ be3b1008` (2026-07-10 00:14:33 -0400), read fresh from
the working tree on 2026-07-11. Original audit findings dated 2026-07-09; line numbers had
drift in a couple of spots (noted per-item). This pass is READ-ONLY — no repo files touched
outside this corpus doc.

---

## 1. CM6→Swift 200ms debounce never flushed on save/close/quit

**Verdict: CONFIRMED**

The JS-side change emitter debounces 200ms (`Sources/ViewerUI/Resources/codemirror/codemirror.html:119-121`):

```js
function scheduleChangeEmit() {
    if (changeTimer) clearTimeout(changeTimer);
    changeTimer = setTimeout(emitChange, 200);
}
```

An immediate-flush path (`emitChangeImmediate()`) exists and IS wired to three JS-originated
save triggers: the CM6-captured ⌘S keybinding (`codemirror.html:817`), the legacy `save`
helper (`codemirror.html:693`), and vim `:w`/`:wq`/`:x` (`codemirror.html:693-696`). It is
also wired to Swift-requested drift recovery (`flushChanges` dispatch →
`flushChangesForced()`, `codemirror.html:1280,1721`; Swift side
`Sources/ViewerUI/CodeMirrorEditorView.swift:945`).

But the three Swift-native surfaces that read the buffer WITHOUT going through the JS
keybinding never request a flush first:

- **Menu Save (⌘S via `NSMenuItem`)** — `Sources/MarkdownViewer/main.swift:994-1000`
  (`@objc func saveActiveEditor`) calls `model.saveActiveEditor()` directly. No
  `dispatch(.flushChanges, …)` call anywhere in this path.
- **Tab close (dirty-prompt "Save")** — `Sources/ViewerUI/DocumentModel+TabCloseVariants.swift:33,74`
  call `saveEditor(forTabID:)` directly off the `isDirty` flag, which is itself only set when
  Swift *receives* a debounced `change`/`incrementalChange` message — so an edit inside the
  last 200ms may not even be reflected in `isDirty`, meaning the close-confirm dialog won't
  even fire for it.
- **Quit** — `Sources/MarkdownViewer/main.swift:708-731` (`applicationWillTerminate`) flushes
  `SessionStore` and `JSONFileStore`'s write queues, but never touches the WebView/JS side —
  no `evaluateJavaScript`/`flushChanges` dispatch anywhere in the teardown path. There is also
  no `applicationShouldTerminate` override in `main.swift` at all, so quit does not even
  prompt for dirty tabs before `applicationWillTerminate` runs.

`saveEditor(forTabID:)` itself (`Sources/ViewerUI/Coordinators/EditorCoordinator.swift:863-919`)
reads `buf.text` — the Swift-side mirror populated only by the JS `change`/`incrementalChange`
messages — with no flush request beforehand.

Net effect: keystrokes typed in the final <200ms before a menu Save, a tab close, or app quit
can be silently dropped from what gets written/snapshotted, exactly as audited.

---

## 2. Session-switch tab drain deletes the hot-exit spill it just wrote

**Verdict: CONFIRMED** (code comment is aspirational/wrong — the guard doesn't cover what it claims to)

`closeAllTabsPreservingDirty()` (`Sources/ViewerUI/DocumentModel.swift:3262-3293`, the
session-switch drain) first calls `captureUnsavedTextForAllTabs()` (line 3269), which for any
dirty buffer >1 MiB **writes** a hot-exit spill sidecar:
`Sources/ViewerUI/DocumentModel+ScrollPersistence.swift:263-269`:

```swift
} else if let p = tab.url?.path {
    if !HotExitSpill.write(buf.text, forPath: p, in: hotExitSpillDirectory) {
        baseMTime = nil; baseSize = nil
    }
}
```

It then sets `isBulkDraining = true` and loops `closeTabUnconditionally(at: 0)` for every tab
(`DocumentModel.swift:3280-3285`). Inside `closeTabUnconditionally`
(`DocumentModel.swift:3211-3246`), the spill-removal call is **unconditional** and runs
*before* the `isBulkDraining` check:

```swift
let closedURL = tabs.tabs[index].url
// TSK-1026: a DESTRUCTIVE close orphans any >1 MiB hot-exit spill for
// this file (no tab will re-capture it) — drop it so it can't leak on
// disk. NOT done on the session-SWITCH close
// (`closeAllTabsPreservingDirty`), which intentionally keeps the dirty
// buffer for switch-back.
if let p = closedURL?.path {
    HotExitSpill.remove(forPath: p, in: hotExitSpillDirectory)   // ← runs regardless of isBulkDraining
}
...
guard !isBulkDraining else { return }   // ← only gates settle/updateDerived/watch, AFTER the removal above
```

The comment (lines 3222-3226) explicitly asserts this removal is "NOT done on the
session-SWITCH close" — but the `!isBulkDraining` guard that would make that true sits three
lines *after* the `HotExitSpill.remove` call, so it never actually protects it. For any dirty
tab whose buffer exceeded 1 MiB, the spill file written by `captureUnsavedTextForAllTabs()`
moments earlier in the very same drain is deleted again before the drain finishes — the
switch-back restore path (`DocumentModel+ScrollPersistence.swift:305`,
`HotExitSpill.read(forPath:in:)`) will find nothing.

---

## 3. Editable-hex: no conflict guard, dirty bytes lost on quit

**Verdict: CONFIRMED**

`saveHexEdits(_:forTabID:)` (`Sources/ViewerUI/DocumentModel+EditableHex.swift:67-110`) writes
straight to disk with no pre-write conflict check:

```swift
public func saveHexEdits(_ data: Data, forTabID id: UUID) -> Bool {
    guard let idx = tabs.tabs.firstIndex(where: { $0.id == id }),
          let url = tabs.tabs[idx].url else { return false }
    let wasWatchingURL = watchedURL
    pauseFileWatcher()
    defer { ... }
    do {
        try HexBinaryWriter.write(data, to: url)
    } catch ... { ... }
    ...
}
```

Contrast with the text-editor save path, `saveEditor(forTabID:)`
(`Sources/ViewerUI/Coordinators/EditorCoordinator.swift:863-919`), which calls
`resolveSaveConflict(forTabID:buffer:)` (line 882) — a TSK-768 no-clobber guard comparing
on-disk mtime/size against the buffer's baseline before writing. The hex save path has no
equivalent call anywhere in `DocumentModel+EditableHex.swift`; `HexBinaryWriter.write` will
blind-overwrite a file that changed on disk since the hex buffer was loaded.

`hexDirtyBytes: [UUID: Data]` (`DocumentModel.swift:1828`) is the only place in-flight hex
edits live. It has **zero** persistence path: `grep`ing `HotExitSpill`/session-snapshot code
for `hexDirtyBytes` turns up nothing outside `DocumentModel+EditableHex.swift` and
`DocumentModel+TabCloseVariants.swift` (which only *discards* it on the Discard branch,
lines 29/70). `captureUnsavedTextForAllTabs()` (the hot-exit capture routine, verified above)
only walks `editor.editorBuffers` — text tabs — never `hexDirtyBytes`. Combined with the
absence of any `applicationShouldTerminate` override (verified in finding 1) to prompt for
dirty tabs on quit, unsaved hex edits are unconditionally lost on quit with no warning and no
recovery path.

---

## 4. JSONFileStore.write Bool discarded by every caller

**Verdict: PARTIAL** — true for the cited `SessionStore` async path; "every caller"
project-wide is an overstatement (one caller does check it).

`JSONFileStore.write` is `@discardableResult` (`Sources/ViewerCore/JSONFileStore.swift:78-79`),
with its own doc comment admitting the pattern: *"Callers historically ignored the return
value (best-effort persistence)..."* (lines 75-76).

At the cited location, `SessionStore.swift` `_encodeAndWrite` (now lines 414-419, `~414` as
audited — unchanged), the result is genuinely discarded, and this is the **async, fire-and-forget
coalesced write path** used for every session snapshot/index write:

```swift
private static func _encodeAndWrite(_ value: Any, to url: URL) {
    if let snap = value as? SessionSnapshot {
        JSONFileStore.write(snap, to: url)          // Bool discarded, no log, no propagation
    } else if let idx = value as? SessionIndex {
        JSONFileStore.write(idx, to: url)            // same
    }
}
```

This runs inside `Self.writeQueue.async { ... Self._encodeAndWrite(snapshot, to: url) }`
(`SessionStore.swift:373-383`, the `enqueue` helper) — a disk-full/permission-denied failure
here is silently swallowed with no error surfaced to the user or logs, for what is the primary
session-persistence path (autosave + hot-exit).

Repo-wide grep of all `JSONFileStore.write(` call sites:

| Site | Captures the Bool? |
|---|---|
| `PluginGrantStore.swift:198` | `_ = ...` (discarded, explicit) |
| `SessionStore.swift:404` (`syncWrite`) | returned up (used by `flushForTermination`) |
| `SessionStore.swift:416,418` (`_encodeAndWrite`, async path) | **discarded** |
| `ReviewStore.swift:84` | **checked** (`let ok = ...; if ok { rebuildIndex() }`) — the one exception |
| `ReviewStore.swift:152,167` | `_ =` (discarded) |
| `ReviewSidecar.swift:148,168` | discarded |

So the specific cited SessionStore async path is exactly as described (silent, unlogged
failure on the hot path); the blanket "every caller" claim is not literally true
(`ReviewStore.save` does check and act on the result), but that's the sole exception and it
doesn't cover the audited file/line.

---

## 5. BookmarksStore strict-decode wipes all bookmarks on one malformed entry

**Verdict: CONFIRMED**

`BookmarksStore.load()` (`Sources/ViewerCore/BookmarksStore.swift:242-248`):

```swift
private func load() {
    guard let decoded = JSONFileStore.read(
        [BookmarkEntry].self, from: storeURL, maxSize: maxStoreFileBytes
    ) else { return }
    entries = Array(decoded.prefix(maxEntries))
    rebuildIndex()
}
```

`JSONFileStore.read` for an array type decodes via `Self.decoder.decode([BookmarkEntry].self,
from: data)` (`JSONFileStore.swift:35`) — a plain `Array<Decodable>` decode, which is
all-or-nothing: one element that throws (a `Bookmark` future-`kind`, an unrepresentable path,
schema drift) fails the whole array decode, `read` returns `nil`, and `load()`'s guard bails
with `entries` left at its initial empty state — the entire bookmark list is wiped in memory
(and on the next `save()`, on disk).

The codebase already has the fix pattern built and in use elsewhere:
`JSONFileStore.readLenientArray` (`JSONFileStore.swift:48-58`, explicitly documented as the
PERSIST-02 fix: *"dropping any element that fails to decode instead of discarding the whole
file... would otherwise nuke the user's entire history / bookmarks list"*) via a
`FailableDecodable<T>` wrapper. `HistoryStore.swift:151`, `HTTPRequestStore.swift:205,211`,
and `FeedSubscriptionStore.swift:344` all use `readLenientArray`. `BookmarksStore` was never
migrated — it still calls the strict `JSONFileStore.read` — despite the helper's own doc
comment naming bookmarks as the exact case it exists to protect.

---

## 6. DiskConflictBanner "Merge…" maps to .keepEdits

**Verdict: CONFIRMED** (case names have drifted since the 2026-07-09 audit — there is now a
distinct `.merge` `DiskConflictIntent` case — but it still funnels to the same `.keepEdits`
outcome as "Keep Mine", so the underlying finding is intact.)

`DiskConflictBanner` (`Sources/ViewerUI/DiskConflictBanner.swift:40`):

```swift
Button("Merge…") { onResolve(.merge) }
    .help("Capture both versions for a three-way merge (coming soon).")
```

`DiskConflictIntent` (`Sources/ViewerCore/DiskConflictResolver.swift:44-54`) has three
distinct cases: `.keepMine`, `.takeDisk`, `.merge`. The banner's `onResolve` callback is wired
to `DocumentModel.resolveDiskConflict(_:)`
(`Sources/ViewerUI/DocumentModel+DiskConflict.swift:34-47`):

```swift
switch intent {
case .takeDisk:
    editor.applyExternalEditOutcome(.discardAndReload, forTabID: conflict.id, at: index, url: conflict.url)
case .keepMine, .merge:
    editor.applyExternalEditOutcome(.keepEdits, forTabID: conflict.id, at: index, url: conflict.url)
}
```

`.keepEdits` is `EditorCoordinator`'s `ExternalEditPrompt` outcome case
(`Sources/ViewerUI/Coordinators/EditorCoordinator.swift:72`). So "Merge…" is
behaviorally IDENTICAL to "Keep Mine" today — it keeps the in-memory edits and discards the
disk-side version, with no actual merge, despite the button copy promising to "capture both
versions for a three-way merge." The doc comment on `resolveDiskConflict` (lines 27-32)
confirms this is known/deliberate-for-now: *"merge → keep the edits for now (a three-way merge
UI is future work, TSK-768)."*

Notably, a real 3-way merge stack already exists in the tree —
`Sources/ViewerCore/ThreeWayMerge.swift`, `Sources/ViewerUI/ConflictResolutionModel.swift`
(landed 2026-07-10, commit `3755420f`, per git log: *"feat(merge): 3-way merge
conflict-resolution stack — resolution model + 3-pane UI [CH-H: TSK-1171]"*) — but it is not
wired to `resolveDiskConflict`/`DiskConflictBanner` as of HEAD. The disk-conflict banner's
Merge button is still a stub pointing at the pre-existing merge engine's future integration.
