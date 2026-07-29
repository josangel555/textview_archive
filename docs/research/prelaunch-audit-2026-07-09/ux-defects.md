# Pre-launch product review — Bad UX: defaults, icons, text

**Dimension lens:** bad default settings, confusing icons, unclear button/label/error copy,
jargon, destructive actions without confirmation, missing empty states.
**Date:** 2026-07-09 · **Method:** static code review (read-only) · **Reviewer:** agent audit

---

## Executive summary

The app has clearly been through a deliberate usability pass (the TSK-1434..1497 usability
queue is visible everywhere): tooltips (`helpInfo`) and accessibility labels are near-universal,
destructive git operations (discard / stash drop / worktree remove) are all confirm-gated,
file deletes go to Trash behind a confirmation, `File → Reset` is confirmed **and** recoverable,
dirty tabs get a standard Save/Don't Save/Cancel prompt, and there is a centralized, host-tested
empty-state catalog. Baseline quality is well above typical pre-launch.

The defects that remain cluster in four places:

1. **The Feed Reader is functionally inert as shipped** — the refresh wiring ("slice 3")
   never landed. No UI path ever fetches a feed, the empty state tells users to "press
   Refresh" but no Refresh control exists, and there is no way to remove a feed (the model
   API exists; no view calls it). Two P1s.
2. **Session close is the one destructive flow that skipped the confirm/undo sweep** —
   one click on a session tab's × (or "Close Other Sessions") silently discards a whole
   session including unsaved edits, with no prompt, no undo toast, and no in-app recovery
   (the snapshot lands in an internal trash dir that is GC'd after 30 days and has no UI). P1.
3. **Error-copy inconsistency** — several user-facing alerts/toasts interpolate raw Swift
   error values (`"\(error)"`, `String(describing: error)`) producing
   `Error Domain=NSCocoaErrorDomain Code=513 …` style dumps, while sibling code correctly
   uses `localizedDescription`. Separately, a set of user-initiated actions (New File,
   Rename, Convert Encoding…) fail **silently** (log-only). Two P2 classes.
4. **Smaller copy/affordance polish** — "View Only" vs "Toggle Read-Only" menu ambiguity,
   no Reopen Closed Tab, word-wrap-off default in a markdown-first editor, unconfirmed
   snippet delete, an unexplained "Partial" status label.

No P0s were found in this dimension.

---

## Methodology

Examined (read-only, static):

- All confirmation surfaces: every `NSAlert` / `.alert` / `.confirmationDialog` site in
  `Sources/ViewerUI` (21 files) and `Sources/MarkdownViewer/main.swift` (File → Reset,
  rename prompt, session rename).
- All destructive call sites: `trashItem` / `removeItem` / `moveToTrash` across
  `ViewerUI` + `ViewerCore`, and their UI entry points (sidebar delete, git discard/stash/
  worktree, plugin remove, snippet delete, session close, terminal favorites).
- Defaults: `Sources/ViewerCore/PreferencesStore.swift` (all `?? fallback` getters),
  `SettingsView.swift` controls, `@AppStorage` keys, secret-detector treatment.
- Copy: every `messageText` / `informativeText` in ViewerUI; toast posts (`ToastCenter`);
  raw-error interpolation sweep (`"\(error)"`, `String(describing: error)`); all
  ~120 `NSMenuItem` titles in `main.swift`; Settings footnote text; empty-state catalog.
- Empty states: `HostedEmptyStateView.swift` catalog + per-surface wiring (Feeds, HTTP,
  SQLite, treemap, script console, task runner, snippets, local history), `EmptyStateView`
  (welcome screen), CSV/LSP/logs/find-bar empties.
- Icons/tooltips: `helpInfo`/`.help`/`accessibilityLabel` coverage sampled across
  `ContentToolbar`, `TabBar`, `MarkdownFindBar`, `SessionTabBar`, `BottomAttributesBar`,
  git tabs, `TerminalFavoritesEditor`.
- Flows traced end-to-end: feed reader (view → view-model → store; menu wiring), session
  close (SessionTabBar → SessionsAppCoordinator → SessionsCoordinator → SessionStore trash
  → GC), dirty-close prompt, hot-exit spill, quit path.

Not executed: no app launch, no UI tests, no VM runs (constraint). Everything below is
verifiable by opening the cited file:line.

---

## Findings

### F1 — P1 · Feed Reader never fetches: refresh is unreachable, so the feature is inert

- **Files:**
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/FeedReaderViewModel.swift:69` (`refresh()` — the only fetch path)
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/FeedReaderView.swift` (no Refresh control, no `.task`/`onAppear` fetch; header comment line 15: "the refresh wiring are slice 3")
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/FeedReaderViewModel.swift:99-102` (`addFeed` subscribes + recomputes only — no fetch)
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DocumentModel+ViewHosting.swift:32-38` (mount point — no refresh call)
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/MarkdownViewer/main.swift:1774-1780` (File → Feed Reader menu item — feature is user-reachable)
- **Evidence:** `rg "refresh" Sources/ViewerUI/FeedReaderView.swift` matches only the comment
  saying refresh wiring is a deferred slice. `refresh()` has zero callers outside tests.
  `addFeed` does `store.subscribe(...)` + `recompute()` — no network fetch. TSK-1417 wired the
  *mount* ("was fully built but ORPHANED — owner chose FINISH") but the fetch loop never landed.
- **Impact:** user opens File → Feed Reader, pastes a URL, presses Add → the feed appears in
  the sidebar with no items, forever. Nothing the user can do in the UI causes a fetch. The
  feature looks broken (because it is).
- **Compounding copy bug:** the items-pane empty state
  (`/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/HostedEmptyStateView.swift:63-67`)
  says *"Select a feed on the left, or **press Refresh** to fetch the latest items."* —
  there is no Refresh anywhere in the UI. Instructions pointing at a nonexistent control.
- **Suggested fix:** add a Refresh toolbar button in `FeedReaderView` calling
  `Task { await model.refresh() }`; fetch-on-add inside `addFeed`; `.task { await model.refresh() }`
  on mount. (The model + scheduler + failure toasts are already built and host-tested.)
- **Fix size:** M · **Fix risk:** safe

### F2 — P1 · Feed Reader has no unsubscribe: feeds can be added but never removed

- **Files:**
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/FeedReaderViewModel.swift:105-111` (`removeFeed(url:)` exists, tested)
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/FeedReaderView.swift:76-101` (feed row — no context menu, no swipe/delete, no remove button)
- **Evidence:** `rg "removeFeed" Sources Tests` → only the definition and
  `Tests/ViewerUITests/FeedReaderViewModelTests.swift`. No UI caller.
- **Impact:** a mistyped or abandoned subscription is permanent from the user's seat
  (subscriptions persist to `feeds.json` under Application Support). Missing table-stakes CRUD.
- **Suggested fix:** `.contextMenu { Button("Remove Feed", role: .destructive) … }` on the feed
  row wired to the existing `model.removeFeed(url:)`. (Import OPML is similarly unwired —
  `importOPML` at line 116 also has no UI caller; fold into the same slice.)
- **Fix size:** S · **Fix risk:** safe

### F3 — P1 · Closing a session (× / "Close Other Sessions") silently discards unsaved edits with no confirm and no in-app recovery

- **Files:**
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/Sessions/SessionTabBar.swift:60,244-255,356-358` (× button and context-menu "Close Session"/"Close Other Sessions" call `sessionsApp.close(...)` directly)
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/Sessions/SessionsAppCoordinator.swift:379-383` (pure pass-through — no dirty check, no prompt)
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/Sessions/SessionsCoordinator.swift:293-311` (`close`: saveSync → `store.moveToTrash` → remove; `closeOthers` at 321-327 loops it)
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/Sessions/SessionStore.swift:327-335` (snapshot moved to an internal `trash/` dir, not the macOS Trash)
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/Sessions/SessionsAppCoordinator.swift:187` (`store.emptyTrashOlderThan(30)` — GC'd after 30 days)
- **Evidence:** contrast with tab close, which runs `confirmCloseIfDirty`
  (`EditorCoordinator.swift:1188-1209`). Session close has no equivalent; a session carrying
  10 tabs, several dirty, closes on one click. The snapshot (which does capture unsaved text)
  lands in `Application Support/MarkdownViewer/Sessions/trash/` — there is **no UI** to list
  or restore trashed sessions (`rg "restore.*[Tt]rash" Sources/ViewerUI` → nothing), so from
  the user's perspective the work is gone. "Close Other Sessions" multiplies this by N.
- **Impact:** the only unconfirmed, un-undoable destructive action left in the app, and it is
  the one with the largest blast radius (an entire workspace of tabs + unsaved edits). A
  mis-click on the small hover × on a session tab is enough.
- **Suggested fix (either):** (a) confirm when the closing session has any dirty tab (reuse the
  dirty-close prompt), and/or (b) post an Undo toast ("Closed 'Project X' — Undo", ToastCenter
  already supports an action button per TSK-1479) that restores from the trash dir; a
  "Recently Closed Sessions" submenu would fully close the gap.
- **Fix size:** M · **Fix risk:** careful (session lifecycle code; mind the detach/mount ordering documented in `close`)

### F4 — P2 · Raw Swift error dumps shown verbatim in user-facing alerts, toasts, and panes

- **Files (user-visible sites):**
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/Coordinators/EditorCoordinator.swift:989` — save-failure alert: `alert.informativeText = "\(error)"`
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DocumentModel+EditableHex.swift:132` — hex save-failure alert, same pattern
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DocumentModel+FileOperations.swift:76,107` — toast `reason: String(describing: error)` (New Folder / Move)
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/ArchiveBrowserView.swift:263` — `loadError = "Could not read the archive (\(error))."`
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/SQLiteBrowserView.swift:296,335` — `let msg = "\(error)"` into the results pane
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/Canvas/CanvasTabController.swift:75,89` — `.failed(String(describing: error))` rendered in the canvas tab
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/ImageEditorViewModel.swift:358,382,404,1225,1336,1365` — `lastError = String(describing: error)`
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/SidebarPanelBody.swift:127` — LSP panel `store.setError("\(error)")`
- **Evidence:** interpolating an `NSError`/`CocoaError` yields
  `Error Domain=NSCocoaErrorDomain Code=513 "…" UserInfo={NSFilePath=…}` — debugger output in a
  dialog. The codebase knows the right pattern: the *same file*
  `DocumentModel+FileOperations.swift:32` uses `(error as NSError).localizedDescription` for
  the trash-failure toast, and `AudioEditorView.swift:302-318` maps known error types to
  human copy before falling back.
- **Impact:** the moments users most need clear guidance (a failed save!) are the moments they
  get engineering jargon. Inconsistent voice across identical failures.
- **Suggested fix:** a tiny shared helper (`error.userFacingDescription` → `localizedDescription`
  with a domain-specific override table) and mechanical substitution at the listed sites.
- **Fix size:** S · **Fix risk:** safe

### F5 — P2 · User-initiated actions that fail silently (log-only, no toast/alert)

- **Files:**
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DocumentModel.swift:737-741` — **New File** (File → New File, sidebar context menu): catch → `Obs.emit` → return nil. No user feedback.
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DocumentModel.swift:846-850` — **New Tab from Clipboard**: same.
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DocumentModel.swift:879-883` — **Rename** (sidebar rename prompt): same — the rename dialog closes and nothing happens.
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DocumentModel+ActiveFileFormatConvert.swift:68-72,89-93` — **Convert Line Endings / Convert Encoding**: write failure logged, function returns false, no surface.
- **Evidence:** contrast with the *same file family*: `deleteFileToTrash`, `createNewFolder`,
  `moveFile` (`DocumentModel+FileOperations.swift:30-38,75-77,105-108`) all post error toasts.
  The five sites above predate the ToastCenter sweep (TSK-1436's stated theme was exactly
  "failures are silent or console-only") and were missed.
- **Impact:** on a read-only folder or sandbox denial, "New File" and "Rename" appear to
  do nothing — the classic dead-button experience. Encoding conversion failing silently is
  worse: the user believes the file converted.
- **Suggested fix:** add the same `ToastCenter.shared.postError(...)` calls the sibling
  operations already use.
- **Fix size:** S · **Fix risk:** safe

### F6 — P2 · "View Only" vs "Toggle Read-Only": two adjacent View-menu items promise the same thing via different mechanisms

- **Files:**
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/MarkdownViewer/main.swift:2027` — View → **View Only** (command `view.toggleViewOnly`, swaps the Editor↔Source lens; persisted per mode)
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/MarkdownViewer/main.swift:2188-2195` — View → **Toggle Read-Only** (locks the CM6 `readOnly` facet; "session-level, not persisted")
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/Commands/CommandRegistry+BuiltIn.swift:112,118` — both registered as separate commands, so both also appear in the command palette
- **Evidence:** both items live in the same View menu; both make the document uneditable;
  they differ in mechanism (lens swap vs editor facet), persistence, and which surfaces they
  affect. Nothing in the labels communicates the difference. The toolbar checkbox is also
  labeled "View Only" (`ContentToolbar.swift:198`), which maps to the first, not the second.
- **Impact:** a user who wants "don't let me edit this" has a coin-flip between two items,
  and the one they pick behaves differently after switching tabs or relaunching.
- **Suggested fix:** either merge (make Toggle Read-Only an internal detail of View Only) or
  rename to disambiguate, e.g. "Lock Editing (this tab)" with a distinct help string; at
  minimum give the second item a `toolTip`.
- **Fix size:** S (rename) / M (merge) · **Fix risk:** careful (keybinding/scriptVerb ids are public automation surface)

### F7 — P2 · No "Reopen Closed Tab" (⌘⇧T)

- **Files:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/MarkdownViewer/main.swift:1698-1930` (full File menu — no reopen item); `rg -i "reopen"` finds no closed-tab stack anywhere in `Sources/`.
- **Evidence:** the app is tab-centric (Close Tab ⌘W at `main.swift:1922`, Close Others /
  Close to the Right in `DocumentModel+TabCloseVariants.swift`) but has no undo for a closed
  tab. Every mainstream tabbed editor/browser ships ⌘⇧T.
- **Impact:** mis-clicking × on a clean tab loses scroll position/mode context; recovery is
  manual (Open Recent / Recently Opened panel — both exist and soften this, hence P2 not P1).
- **Suggested fix:** small LIFO of recently-closed tab descriptors (url + viewMode + scroll)
  in `TabCoordinator`; File → Reopen Closed Tab (⌘⇧T). Bulk variants ("Close Others") push
  multiple entries.
- **Fix size:** M · **Fix risk:** safe

### F8 — P2 · Word wrap defaults OFF in a markdown-first editor

- **Files:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/PreferencesStore.swift:163-166` (`sourceWordWrap ?? false`); `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/SettingsView.swift:312` ("Wrap … appl[ies] to source and editor modes").
- **Evidence:** the product is a markdown viewer-editor; markdown prose is written as long
  logical lines. With wrap off, switching any `.md` file to Editor/Source means horizontal
  scrolling through paragraphs until the user finds View → Wrap Long Lines.
- **Impact:** first-session friction on the app's core editing flow. (Code files are the
  argument for off; but per-language default or on-for-prose is the standard resolution —
  e.g. VS Code wraps markdown via language-specific settings.)
- **Suggested fix:** default wrap ON for markdown/prose types (keyed off the detected
  language), leaving the global toggle semantics intact. Only affects users who never set
  the key.
- **Fix size:** M · **Fix risk:** careful (behavior change for existing users; make it
  per-language, not a flip of the global default)

### F9 — P3 · Snippet "Delete" acts immediately — no confirm, no undo

- **Files:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/SnippetManagerView.swift:253-258`.
- **Evidence:** `Button("Delete", role: .destructive) { _ = model.delete(id: editingID); resetForm() }` —
  fires instantly. A snippet can be a large, hand-authored template; every comparable
  destructive action in the app (plugin remove, stash drop, file delete) confirms.
- **Impact:** one mis-click permanently destroys a user-authored snippet.
- **Suggested fix:** confirmationDialog, or an "Undo" action toast (ToastCenter supports it).
- **Fix size:** S · **Fix risk:** safe

### F10 — P3 · File-association "Partial" status label is unexplained; "Make Default" failure only beeps

- **Files:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/SettingsView.swift:457-460` (orange `Text("Partial")`, no `.help`); comment at ~468-470: "a failure beeps (the row stays 'Make Default')".
- **Evidence:** "Partial" (some extensions in the group default to TextView, some don't) is
  internal vocabulary with no tooltip; an audible beep is the only failure signal for the
  Launch Services write.
- **Impact:** minor confusion in Settings; failed make-default looks like a dead button.
- **Suggested fix:** `.help("TextView is the default for some, but not all, of these
  extensions")`; replace beep with an error toast naming the failing group.
- **Fix size:** S · **Fix risk:** safe

### F11 — P3 · Image editor "Save" irreversibly overwrites the original — no binary local history, no first-time notice

- **Files:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/ImageEditorView.swift:590-596` (Save button, `.help("Overwrite the original file with your edits")`), `968-975` (save-in-place path); `LocalHistoryStore` snapshots are text-only (`EditorCoordinator.swift:975-981` comment: "Text-only").
- **Evidence:** destructive edits (crop, resize, draw) written over the source pixels; unlike
  text files there is no Local History version to roll back to. The tooltip is honest, which
  is why this is P3 not P2.
- **Impact:** a crop + ⌘S permanently destroys the original image.
- **Suggested fix:** snapshot the original bytes into local history (or a sidecar backup) on
  first in-place image save, or a one-time "This will overwrite the original" confirm with
  a "don't ask again".
- **Fix size:** M · **Fix risk:** careful (storage growth for large images — cap/evict)

### F12 — P3 · Secret-detector picker can render with no selected option

- **Files:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/SettingsView.swift:564,576-578` (tags `0` and `SecretBannerState.treatmentOff`); `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/SecretBannerState.swift:14` (`treatmentOff = 2`).
- **Evidence:** the picker offers tags 0 ("Warn badge") and 2 ("Off"); the backing store is a
  raw `Int` `@AppStorage`. Any other persisted value (a legacy `1`, hand-edited defaults)
  matches no tag → SwiftUI renders an empty picker. Detection logic treats non-2 as "on"
  (`SecretBannerState.swift:25`), so behavior is fine — only the control desyncs.
- **Impact:** cosmetic; confusing only in the drifted-prefs case.
- **Suggested fix:** normalize on read (`treatment == treatmentOff ? off : 0`) or map through
  an enum with a default case.
- **Fix size:** S · **Fix risk:** safe

### F13 — P3 · Internal jargon leaking into user-facing copy

- **Files / instances:**
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/SettingsView.swift:312` — "Indentation drives only the **CM6** editor (Tab key inserts)." (CodeMirror-internal name; users know it as "the editor")
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DiskConflictBanner.swift:36-38` — "**Keep Mine** / **Take Disk**" — "Take Disk" is terse to the point of oddness; the sibling modal uses the clearer "Keep My Edits / Discard & Reload" (`EditorCoordinator.swift:1233-1234`), so the same conflict presents two vocabularies depending on which surface catches it.
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/SettingsView.swift:127` — "LSP servers **spawn** … and **reap** after 5 minutes idle" — process-management verbs in Settings copy ("start"/"quit" would do).
- **Impact:** minor comprehension tax; inconsistent conflict vocabulary is the worst of the three.
- **Suggested fix:** copy edits only; align the banner verbs with the modal's.
- **Fix size:** S · **Fix risk:** safe

### F14 — P3 · Error toasts auto-expire in 8 s while carrying the only visible failure reason

- **Files:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/ToastCenter.swift:66-68` (error TTL 8 s).
- **Evidence:** failure reasons (e.g. why a move failed) appear only in the toast detail; after
  expiry the reason survives only in the Logs view (`ToastCenter.swift:113-118` emits an
  ObsEvent), which most users won't know to open.
- **Impact:** blink-and-you-miss-it failures for slower readers / walk-away moments. Mitigated
  by the durable log, hence P3.
- **Suggested fix:** errors persist until dismissed (or pause expiry on hover), or the toast
  carries a "Details…" action opening Logs filtered to the event.
- **Fix size:** S · **Fix risk:** safe

---

## Positive observations

- **Tooltip & accessibility discipline is exemplary.** Nearly every icon-only control carries
  `helpInfo(title:description:)` **and** `accessibilityLabel` (`MarkdownFindBar.swift`,
  `TabBar.swift:423-512`, `ContentToolbar.swift`, `SessionTabBar.swift:252-255`,
  `GitWorktreesTab.swift:53,124`). Stable `mdv.*` accessibility identifiers everywhere.
- **Centralized, host-tested empty states** (`HostedEmptyStateView.swift` +
  `EmptyStateCatalogTests`): every hosted tool pane explains what it is and the next step;
  CSV distinguishes "empty file" from "filtered to nothing" (`CSVTableView.swift:205-219`);
  the command palette distinguishes "No recent files" from "No matches"
  (`CommandPaletteView.swift:621`).
- **Destructive-action hygiene (outside F3/F9) is strong and principled:** file delete is
  trash-not-unlink with confirm (`DocumentModel+FileOperations.swift:16-40`,
  `SidebarView.swift:355-369`); git discard is confirm-gated *by construction*
  (`GitStatusTab.swift:38-52` — the model only reverts from `confirmDiscard()`); stash drop
  (`GitStashTab.swift:25-31`) and worktree remove (`GitWorktreesTab.swift:170-183`, with
  dirty-aware message) confirm; plugin removal confirms and trashes
  (`PluginsSettingsView.swift:166-175`); `File → Reset` confirms, backs up recoverably, and
  says so (`main.swift:926-933`); Settings' "remove all bookmarks" confirms with "This can't
  be undone" (`SettingsView.swift:540`); git Restore explains undo semantics
  (`UnifiedHistoryView.swift:260`).
- **Unsaved-work protection on the main flows:** standard Save/Don't Save/Cancel on dirty
  close (`EditorCoordinator.swift:1188-1209`), per-tab prompts on bulk close variants
  (`DocumentModel+TabCloseVariants.swift`), external-edit conflict prompts, hot-exit spill
  for >1 MiB buffers (`HotExitSpill.swift`), save failures keep the buffer dirty so ⌘S
  retries (`EditorCoordinator.swift:984-991`).
- **Good defaults where it counts:** markdown opens Rendered; sidebar visible; local history
  on; secret-detector warn-badge on by default with honest limits copy
  (`SettingsView.swift:584`); JavaScript in previews default-deny; first-run sample tour
  written collision-safely (`DocumentModel+FirstRun.swift`).
- **Failure-feedback architecture exists and is good** (`ToastCenter` — reasons, action
  buttons, durable log echo, progress + cancel for long ops); F4/F5 are adoption gaps, not
  design gaps.

## Coverage gaps (not examined)

- **On-screen rendering:** this was a static review; no VM/T5 pixel verification of any
  claim (icon legibility, contrast, dark-mode, occlusion, toast visibility). Findings are
  code-level; per project rules, on-screen behavior needs VM validation.
- **CodeMirror/web surfaces' internal copy:** strings inside the bundled CM6/mermaid/canvas
  JS (`Sources/ViewerUI/Resources/codemirror`) were not audited.
- **mdv-tui and mdv-web front-ends** (rust-core side): out of scope; only the macOS app.
- **Keyboard-shortcut conflicts** beyond spot checks (Toggle Sidebar ⌘⌃S verified fine);
  a full registry-vs-AppKit sweep wasn't done.
- **Localization:** the app is English-only; no i18n audit attempted.
- **Walkthroughs, Claude Monitor, Annotations, Log Patterns, Dependency Graph tool windows:**
  sampled for confirm coverage only, not full copy/empty-state audits.
- **Onboarding flow end-to-end** (first-run latch behavior at runtime) — code-read only.
