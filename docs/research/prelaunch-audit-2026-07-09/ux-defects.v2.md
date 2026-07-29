# Pre-launch product review — Bad UX: defaults, icons, text (v2)

**Dimension lens:** bad default settings, confusing icons, unclear button/label/error copy,
jargon, destructive actions without confirmation, missing empty states.
**Date:** 2026-07-10 · **Method:** static code review (read-only) · **Reviewer:** agent audit (independent pass)

> **Note on this file:** a prior agent already wrote `ux-defects.md` in this directory
> (2026-07-09 19:32). Per the repo's safe-write rule I did **not** overwrite it; this is an
> independent second pass written as `ux-defects.v2.md`. There is meaningful overlap
> (raw-error copy, silent New-File failure, unconfirmed snippet delete, word-wrap default)
> and some distinct findings (hard-delete-without-confirm for **walkthroughs** and **review
> comments**, the "unborn HEAD" git jargon, the "invalid" hex label). Reconcile the two.

---

## Executive summary

The app's UX copy and defaults are, on the whole, **well above typical pre-launch quality**.
There is clear evidence of a deliberate usability pass (TSK-1434..1497): tooltips
(`helpInfo`) and accessibility labels are near-universal; the destructive **git** operations
(discard / stash drop / worktree remove) are all confirm-gated; filesystem deletes go to the
**Trash** behind a confirmation; `File → Reset` is both confirmed and recoverable; dirty-tab
close runs the standard Save / Don't Save / Cancel prompt; the write-time save-conflict flow
puts the non-destructive "Save as Copy" as the default button and "Overwrite" last; and there
is a **centralized, host-tested empty-state catalog** (`EmptyStateCatalog`) plus a genuinely
good app-landing screen with actionable CTAs.

The remaining defects cluster in three areas:

1. **Destructive actions that skipped the confirm sweep and are NOT recoverable.** Deleting a
   **walkthrough** and deleting a **review comment** both call `FileManager.removeItem` (a hard
   delete, not Trash) from a single unconfirmed click. This is inconsistent with the app's own
   established standard (file deletes → Trash + confirm; bookmarks → confirm; plugins → Trash +
   confirm). Snippet delete is also unconfirmed (recoverable only by retyping).
2. **User-initiated actions that fail SILENTLY** (log-only, no toast/alert). `createNewFile`,
   and several sibling file operations, emit to the observability log and return `nil` on
   error — the user clicks and sees nothing happen, with no explanation.
3. **Error/label copy that leaks raw internals or jargon.** Several user-facing alerts/toasts
   interpolate a raw Swift error (`"\(error)"`) instead of `localizedDescription`, producing
   `Error Domain=… Code=…` dumps; one git error surfaces "unborn HEAD"; the hex search shows a
   bare "invalid".

**No P0s were found in this dimension.** The core data-safety flows (save, close-dirty,
external-edit conflict, save-conflict) are robust.

---

## Methodology

- **Scope:** `Sources/ViewerUI/` (presentation/copy/icons/alerts) and the settings/defaults
  layer in `Sources/ViewerCore/` (`PreferencesStore`, `FirstRunExperience`,
  `HTMLTrustPolicy`, empty-state catalog). Read-only; no builds, no window-opening tests.
- **How much:** enumerated every `.destructive` button, every `NSAlert` / `confirmationDialog`
  call site, the full `PreferencesStore` default set, the empty-state catalog, and grepped all
  user-facing error/toast strings across `ViewerUI`. Read the load-bearing flows in full
  (`EditorCoordinator` save/close/conflict prompts, `FirstRunExperience`, `EmptyStateView`,
  `SettingsView`, `PreferencesStore`).
- **Verification:** every finding cites a file:line I opened and read; destructive findings
  were confirmed against the underlying store (`removeItem` vs `trashItem`).

---

## Findings

### F1 — Deleting a walkthrough is an unconfirmed hard delete (data loss)
- **Severity:** P2 · **Fix size:** S · **Fix risk:** safe
- **Where:** `Sources/ViewerUI/Walkthrough/WalkthroughsBrowserView.swift:85-88` →
  `Sources/ViewerCore/Walkthrough/WalkthroughCatalog.swift:161` (`try fileManager.removeItem(at: entry.url)`)
- **Evidence:** the context-menu `Button("Delete Walkthrough", role: .destructive)` calls
  `WalkthroughCatalog.delete(entry)` directly with no confirmation dialog. `delete` does
  `removeItem` — a permanent unlink, NOT `trashItem`. There is no undo toast and no in-app recovery.
- **Impact:** one accidental right-click → Delete permanently destroys a user-authored walkthrough
  file. Inconsistent with the app's own standard (sidebar file delete → Trash + confirm).
- **Fix:** route through `trashItem` and/or gate behind a `confirmationDialog`, matching
  `SidebarView.presentDeleteConfirm`.

### F2 — Deleting a review comment is an unconfirmed hard delete
- **Severity:** P2 · **Fix size:** S · **Fix risk:** safe
- **Where:** `Sources/ViewerUI/Review/CommentCards.swift:190` (`Button("Delete", role: .destructive, action: onDelete)`)
  → `Sources/ViewerCore/Review/ReviewStore.swift:123` (`try? FileManager.default.removeItem(at: url)`)
- **Evidence:** the comment card's Delete button fires `onDelete` immediately; the store hard-deletes
  the comment file with `removeItem`. No confirm, no undo. (The `try?` also swallows failure silently.)
- **Impact:** a review thread/comment is destroyed on a single click with no confirmation and no recovery.
- **Fix:** add a confirm for delete (comments are cheap to protect), or an undo toast; stop discarding
  the error with `try?`.

### F3 — User-initiated file actions fail SILENTLY (no user feedback)
- **Severity:** P2 · **Fix size:** M · **Fix risk:** safe
- **Where:** `Sources/ViewerUI/DocumentModel.swift:737-740` (`createNewFile` catch → `Obs.shared.emit(...)` then `return nil`);
  same pattern at `DocumentModel.swift:848` (New Tab from Clipboard), `881` (Rename), `2708` (Text cleanup);
  `DocumentModel+ActiveFileFormatConvert.swift:70` (Convert line endings), `92` (Convert encoding).
- **Evidence:** on failure these paths emit to the observability log only and return `nil`; there is
  no `ToastCenter.post`/`NSAlert`. Contrast `DocumentModel+FileOperations.swift:30-32`, which correctly
  posts a user toast on trash failure.
- **Impact:** the user invokes "New File" / "Rename" / "Convert Encoding…", nothing appears, and there
  is zero explanation. Reads as a dead/broken command. Silent failure is a table-stakes UX gap.
- **Fix:** post an error toast (`ToastCenter.shared.postError`) at these catch sites, mirroring the
  file-operations path.

### F4 — User-facing alerts/toasts interpolate raw Swift errors instead of `localizedDescription`
- **Severity:** P2 · **Fix size:** S · **Fix risk:** safe
- **Where:** `Sources/ViewerUI/DocumentModel+EditableHex.swift:132` (`alert.informativeText = "\(error)"`);
  `Sources/ViewerUI/Coordinators/EditorCoordinator.swift:989` (`alert.informativeText = "\(error)"`);
  `Sources/ViewerUI/ArchiveBrowserView.swift:263` (`loadError = "Could not read the archive (\(error))."`);
  `Sources/ViewerUI/DiagnosticWindowView.swift:290` (`exportMessage = "Export failed: \(error)"`);
  `Sources/ViewerUI/DocumentModel+GitLog.swift:118` (`"…couldn't be written to a temporary file: \(error)"`).
- **Evidence:** `"\(error)"` on an `NSError` renders `Error Domain=NSCocoaErrorDomain Code=513
  "…" UserInfo={…}`; on a Swift enum error it renders the raw case name. Sibling code does this
  correctly — `DocumentModel+FileOperations.swift:32` uses `(error as NSError).localizedDescription`.
- **Impact:** developer-facing error dumps shown to end users in a save/read failure — the exact
  moment copy quality matters most. Inconsistent within the same codebase.
- **Fix:** use `(error as NSError).localizedDescription` (or a `describe(_:)` helper) at these sites.

### F5 — Snippet delete has no confirmation
- **Severity:** P3 · **Fix size:** S · **Fix risk:** safe
- **Where:** `Sources/ViewerUI/SnippetManagerView.swift:252-258` (`Button("Delete", role: .destructive)` → `model.delete(id:)`)
- **Evidence:** the editor's Delete button removes the user's snippet immediately; no confirm, no undo.
  Built-ins are protected (`!model.isBuiltIn`), so only user snippets are at risk — but they're
  unrecoverable except by retyping.
- **Impact:** a user's saved snippet is lost on a misclick. Low blast radius but inconsistent with the
  confirm-gated destructive actions elsewhere.
- **Fix:** add a `confirmationDialog`, matching the bookmarks/plugin pattern.

### F6 — Git worktree error leaks "unborn HEAD" jargon
- **Severity:** P3 · **Fix size:** S · **Fix risk:** safe
- **Where:** `Sources/ViewerUI/Git/GitWorktreesTab.swift:317`
  (`errorMessage = "git could not create the worktree (branch already checked out elsewhere, or an unborn HEAD)."`)
- **Evidence:** "unborn HEAD" is git plumbing terminology (a repo with no commits yet) surfaced verbatim
  to the user.
- **Impact:** a non-git-expert user cannot act on this. Minor, but it's user-facing copy.
- **Fix:** "…or the repository has no commits yet."

### F7 — Hex search shows a bare "invalid" with no guidance
- **Severity:** P3 · **Fix size:** S · **Fix risk:** safe
- **Where:** `Sources/ViewerUI/HexView.swift:200` (`if queryIsInvalid { return "invalid" }`)
- **Evidence:** the match-count label reads just `invalid` when the hex query can't be parsed, with no
  hint about the expected format (e.g. even number of hex digits, or a text query).
- **Impact:** the user sees "invalid" and doesn't know why or how to fix it.
- **Fix:** "Enter hex bytes (e.g. `ff 0a`) or text" or an inline format hint.

### F8 — "Reset window state" has no confirmation and no visible effect until relaunch
- **Severity:** P3 · **Fix size:** S · **Fix risk:** safe
- **Where:** `Sources/ViewerUI/SettingsView.swift:543-549` (`Button("Reset") { resetWindowState() }` +
  the caption "Quit and relaunch for the window to re-center.")
- **Evidence:** clicking Reset gives no confirmation and no immediate feedback; the caption admits the
  re-center only happens after a relaunch. The button therefore appears to do nothing.
- **Impact:** user clicks Reset, nothing visibly changes, no confirmation it worked → confusion / repeat clicks.
- **Fix:** post a confirmation toast ("Window state reset — relaunch to re-center") on click.

### F9 — Source word-wrap defaults OFF in a markdown/prose-first viewer
- **Severity:** P3 · **Fix size:** S · **Fix risk:** careful (changes default behavior for all users)
- **Where:** `Sources/ViewerCore/PreferencesStore.swift:164` (`sourceWordWrap` default `?? false`)
- **Evidence:** Source view and the editor default to no wrap, so a long markdown paragraph in Source
  mode scrolls horizontally on first open.
- **Impact:** for a viewer whose primary content is markdown/prose, horizontal-scrolling long lines is a
  surprising default. Debatable (good for code, bad for prose) — flagging as a default-choice smell, not a bug.
- **Fix:** consider defaulting wrap ON for text/markdown categories, or leave as a product decision.

---

## Positive observations

- **Save-conflict alert is exemplary** (`EditorCoordinator.swift:1097-1131`): non-destructive
  "Save as Copy…" is the default button, destructive "Overwrite" is deliberately last so it's never the
  accidental Return. Clear message text.
- **Dirty-close and external-edit prompts** (`EditorCoordinator.swift:1189-1240`) use standard,
  plain-language copy ("Your changes will be lost if you don't save them.", "Keep My Edits" /
  "Discard & Reload").
- **Filesystem delete, bookmarks-clear, and plugin-remove** are all confirm-gated, and file delete uses
  the **Trash** (recoverable) with a clear "Move … to Trash?" dialog (`SidebarView.swift:355-368`,
  `SettingsView.swift:528-542`, `PluginsSettingsView.swift:166-173`).
- **Centralized, host-tested empty-state catalog** (`HostedEmptyStateView.swift` / `EmptyStateCatalog`)
  with a completeness test — every hosted surface gets an empty state. The app-landing
  `EmptyStateView` (`ContentView.swift:1905`) has real CTAs (New File / New Image / Open File… /
  Open Folder…), an omnibox, and recents/bookmarks sections.
- **Settings copy is genuinely good**: nearly every setting has an explanatory footnote in plain
  language (`SettingsView.swift` — LSP idle-reap note, plugins folder path, MP3/ffmpeg explanation,
  Full Disk Access instructions, secret-scanner disclaimer with "not a guarantee").
- **First-run sample document** (`FirstRunExperience.swift`) is a thoughtful onboarding tour, one-shot,
  dismissable-forever, re-findable via Help, and written collision-safe (`OutputNaming.nonColliding`).
- **Security banners** (`HTMLTrustBanner`, `SecretWarningBanner`) use clear, non-alarmist copy and
  reassure the user the file is never modified.

---

## Coverage gaps (what I did NOT examine)

- **On-screen rendering / actual pixels** — this was static code review only; icon *legibility*, color
  contrast, and whether labels are visually truncated were not verified on a running UI (VM lane).
- **Rust/TUI/web front-ends** (`rust-core/crates/tui`, `web`, `serve`) — only the macOS SwiftUI/AppKit
  layer was reviewed for copy/defaults.
- **Menu-bar command titles** (`AppMenuActions`, command palette entries) were not exhaustively swept for
  label ambiguity (the prior `ux-defects.md` flags a "View Only" vs "Toggle Read-Only" ambiguity I did
  not independently verify).
- **Feed Reader / Session-close flows** — the prior `ux-defects.md` reports these as P1 (inert feed
  refresh; unconfirmed session close). I did not re-verify them in this pass; treat that report as the
  source for those two and reconcile.
- **Localization / i18n** — all copy is English-only string literals; no assessment of localization
  readiness was in scope.
- **Full enumeration of every `systemImage`** for icon-meaning correctness — I spot-checked toolbar /
  status-bar / tab-bar icons (all conventional) but did not audit all ~hundreds of SF Symbol usages.
