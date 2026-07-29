# Pre-launch product review — UX best practices

**Dimension:** Discoverability, feedback loops, undo-ability, progressive disclosure, onboarding, error prevention over error messages.
**Date:** 2026-07-09 · **Repo:** `/Users/me/Documents/workspaces/claude/markdown_viewer` (read-only review)

---

## Executive summary

The app's UX infrastructure is unusually mature for a pre-launch product — the 2026-07 usability drain (TSK-1434..1497) clearly landed. There is a central toast/progress surface with durable error logging, a host-tested empty-state catalog, a first-run sample tour, a registry-driven Keyboard Shortcuts window, dirty-close prompts, a no-clobber save guard, hot exit with large-buffer spill, delete-to-Trash-only file operations, Local History with a deleted-file recovery picker, and consent gates on risky flows (URL-scheme walkthroughs, HTML script trust). Error *prevention* is generally favored over error dialogs.

The remaining problems are at the seams:

1. **The onboarding actively teaches a dead shortcut.** Both the first-run sample document and the Help ▸ Capabilities page tell new users to "Press **⌘K**" for the command palette — but ⌘K was deliberately unbound (TSK-709); the palette is ⇧⌘P / double-Shift. The very first instruction a new user follows does nothing. (P1)
2. **Tab/session close has no undo surface.** No "Reopen Closed Tab" (⇧⌘T) anywhere; closed sessions go to a 30-day trash that has **no user-facing restore UI**. Table-stakes undo-ability for a tabbed editor is missing. (P1)
3. **The disk-conflict banner's "Merge…" button silently acts as "Keep Mine"** — and refreshes the saved fingerprint, so the next ⌘S overwrites the external edit without any further prompt. A user who clicked "Merge…" reasonably believes the disk change was incorporated; it is then clobbered. (P1)
4. A cluster of **silent-failure / missing-feedback** spots: git stash apply/pop/drop swallow failures (stash-apply conflicts are silent), terminal close kills running jobs with no warning, menu-bar Copy commands give no confirmation while other copy surfaces do.

Nothing found rises to P0. Findings below are ordered by severity.

---

## Methodology

Static review of the UI and app-shell layers, tracing user-facing flows end-to-end from action entry points (menus, buttons, key equivalents) through the model layer to their feedback/confirmation surfaces. No UI tests were run; no repo files modified other than this report.

Examined in depth (read fully or in targeted sections):

- App shell & menus: `Sources/MarkdownViewer/main.swift` (4,435 LOC — menu construction, `validateMenuItem`, first-run gating, quit path, URL-scheme handling, export handlers)
- Save/close/data-safety: `Sources/ViewerUI/Coordinators/EditorCoordinator.swift` (save chokepoint, dirty-close prompt, external-edit conflict), `DocumentModel+EditorBuffer.swift`, `DocumentModel+TabCloseVariants.swift`, `DocumentModel+ScrollPersistence.swift` (hot exit), `ViewerCore/HotExitSpill.swift`, `DocumentModel+DiskConflict.swift`, `DiskConflictBanner.swift`, `ViewerCore/SaveConflictDecision.swift` (signature-level)
- Feedback surfaces: `ToastCenter.swift`, `ToastOverlayView.swift` (usage census across all call sites), `HostedEmptyStateView.swift`, `MetadataPanel.swift` (copy feedback), `MarkdownFindBar.swift`
- Onboarding/discoverability: `ViewerCore/FirstRunExperience.swift`, `DocumentModel+FirstRun.swift`, `ViewerCore/CapabilitiesDocument.swift`, `docs/CAPABILITIES.md`, `CommandPaletteView.swift`, `KeyboardShortcutsView.swift`, `ViewerCore/Commands/CommandRegistry+BuiltIn.swift`, `KeybindingConfig.swift`, `DocumentModel+CommandRegistry.swift`, `DoubleShiftMonitor.swift`, Walkthrough player (exit affordances)
- Destructive-action guards: `DocumentModel+FileOperations.swift` (trash/move/new-folder), `Git/GitStatusTab.swift`, `Git/GitStashTab.swift`, `Git/GitPanelModel.swift`, `ViewerCore/Git/GitClient.swift` (stash API), Sessions close path (`Sessions/SessionsAppCoordinator.swift`, `SessionTabBar.swift`), File ▸ Reset (`AppCacheReset` wiring), `Terminal/TerminalPaneStore.swift`, `Terminal/PTYProcess.swift`
- Undo-ability: `ViewerCore/EditableCSVModel.swift`, `ViewerCore/HexEditBuffer.swift` (undo stacks), `RecoverDeletedFileView.swift`, `DocumentModel+Resurrection.swift`, Local History empty state
- Error handling & recovery: `ContentView.swift` `ErrorView`, `DropRouter.swift`, `HTMLTrustBanner.swift`, `SecretWarningBanner.swift`, `SettingsView.swift`, `ConvertImageViewModel.swift`, `ImageEditorViewModel.swift` (save-copy failure surfacing)

Census greps: all `NSAlert` / `.alert(` / `confirmationDialog` sites, all `ToastCenter.shared` call sites, empty `catch {}` blocks (none found in ViewerUI), `try?` on user-initiated write paths, `killall`-class hazards, "Reopen"/closed-tab affordances (none found).

---

## Findings

### F1 · P1 — Onboarding teaches a dead shortcut: "Press ⌘K" for a palette that is bound to ⇧⌘P

- **Files:**
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/FirstRunExperience.swift:69` — sample tour: `- [ ] Press **⌘K** — the command palette reaches everything`
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/CapabilitiesDocument.swift:33` — Help ▸ Capabilities: `Press **⌘K** to reach every command…`
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/docs/CAPABILITIES.md:108,129` — two more `⌘K` palette references (this file is bundled and opened by Help ▸ Capabilities, TSK-1575)
- **Evidence:** `Sources/MarkdownViewer/main.swift:2260-2263` builds the palette menu item with `keyEquivalent: ""` and the comment `TSK-709: ⌘K freed for the terminal; palette = ⇧⌘P + double-Shift`. `Sources/ViewerCore/Commands/CommandRegistry+BuiltIn.swift:174-176` confirms `view.quickOpen` ships with **no** default shortcut ("⌘K UNBOUND — freed for the terminal"). A global grep finds no app-wide command bound to plain ⌘K (only ⇧⌘K = Check Links).
- **Impact:** The sample document is the FIRST thing a fresh-profile user sees (auto-opened at `main.swift:575-580`), and its "Try next" checklist is the app's primary onboarding CTA. Its first actionable instruction silently does nothing. Same for the Capabilities page — the reference document users consult to learn the app. This directly poisons the discoverability story the drain built: users conclude the palette (the app's stated "reaches everything" surface) is broken.
- **Suggested fix:** Update all four references to the real bindings ("Press **⇧⌘P** — or tap **Shift twice**"). Better: render the shortcut from `CommandRegistry` (`nav.showPalette`) when generating the sample/capabilities text so future rebinds can't drift; add a host test pinning that every shortcut mentioned in `FirstRunExperience.sampleDocument` / `CapabilitiesDocument` exists in the registry's effective binding space.
- **Fix size:** S · **Fix risk:** safe

### F2 · P1 — No "Reopen Closed Tab", and the 30-day session trash has no restore UI

- **Files:**
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/Coordinators/TabCoordinator.swift:249-276` — tab close paths return/discard the closed tab; no closed-tab stack exists
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/MarkdownViewer/main.swift:1697-1706` — File menu: New Tab ⌘T exists; no Reopen Closed Tab item anywhere in menu construction
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/Sessions/SessionsAppCoordinator.swift:376-383` — `close(id:)` / `closeOthers(except:)` route to the core trash pipeline
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/Sessions/SessionsCoordinator.swift` — close stages the snapshot to trash with 30-day retention
- **Evidence:** Greps for `Reopen`, `Recently Closed`, `restoreFromTrash`, `reopenSession`, `undoClose`, `closedTab`, `lastClosed` across `Sources/` return no tab/session restore affordance. `SessionTabBar.swift:356` offers "Close Session" (and "Close Other Sessions") with no confirmation and no undo path; the engine-level trash is reachable only via the filesystem (`~/Library/Application Support/MarkdownViewer/Sessions/` trash dir).
- **Impact:** Undo-ability gap on the two most frequent destructive gestures in a tabbed app. A mis-aimed ⌘W or tab-strip middle-click permanently loses tab context (scroll position, view mode, pinned lens); "Close Session" from a context menu discards an entire workspace with one click — the engine keeps the data for 30 days, but the user has no way to know that or get it back. Every peer app (VS Code, Sublime, all browsers, Xcode) ships ⇧⌘T. Notably the *infrastructure is already built* (session trash retention; tabs are value types easily stacked) — only the surface is missing.
- **Suggested fix:** (a) Keep a small LRU stack of closed-tab descriptors in `TabCoordinator`; add File ▸ Reopen Closed Tab (⇧⌘T) + tab-strip context item. (b) Add a "Recently Closed Sessions" submenu (or section in the sessions strip) that restores from the existing trash; a close-session toast with an "Undo" action (ToastCenter already supports action buttons) would cover the immediate-regret case cheaply.
- **Fix size:** M · **Fix risk:** careful (tab restore must respect the session snapshot lifecycle; reuse `Tab` + trash primitives rather than new persistence)

### F3 · P1 — Disk-conflict "Merge…" button silently resolves as Keep Mine, then the next save clobbers the external edit

- **Files:**
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DiskConflictBanner.swift:40-41` — `Button("Merge…") { onResolve(.merge) }` with help text "Capture both versions for a three-way merge (coming soon)."
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DocumentModel+DiskConflict.swift:43-44` — `case .keepMine, .merge:` → `applyExternalEditOutcome(.keepEdits, …)`
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/Coordinators/EditorCoordinator.swift:1254-1267` — `.keepEdits` refreshes the buffer's saved fingerprint so the watcher/no-clobber guard won't re-prompt for this disk state
- **Evidence:** The three intents are rendered as coequal buttons on the banner ("Keep Mine / Take Disk / Merge…"). `.merge` maps to exactly the same side effect as `.keepMine`. The "(coming soon)" disclosure lives only in a hover tooltip — hidden disclosure a user in a conflict moment will not see. Because `.keepEdits` deliberately refreshes `refreshSavedFingerprint`, the subsequent ⌘S passes the `SaveConflictDecision` guard and writes the buffer over the external edit with no further prompt.
- **Impact:** On the app's *data-safety-critical* surface (the one built in response to the TSK-768 data-loss incident), a labeled action does something other than what it says. A user who clicks "Merge…" believes both versions will be reconciled; in reality the on-disk change is scheduled to be silently overwritten on next save. This converts a correct conflict detection into user-believed-merged data loss. The trailing ellipsis compounds it — HIG semantics promise a follow-up UI that never appears.
- **Suggested fix:** Remove (or disable with a visible "coming soon" caption) the Merge button until the merge surface ships. Cheap middle ground: have `.merge` open both versions in the existing diff view (a "diverted to a diff view" path the save guard already contemplates, `EditorCoordinator.swift:1005-1007`) so the user can reconcile manually — that is an honest "Merge…".
- **Fix size:** S (remove/disable) to M (diff-view divert) · **Fix risk:** safe

### F4 · P2 — Closing a terminal tab/pane (or quitting) kills running processes with no warning

- **Files:**
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/Terminal/TerminalPaneStore.swift:283-295` — `closeTab` reaps the shell immediately (`model?.stop()`); closing the last tab closes the whole pane
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/Terminal/PTYProcess.swift:441-470` — `terminate()` SIGHUPs the child; `deinit` does so defensively
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/MarkdownViewer/main.swift:731` — `applicationWillTerminate` → `model.terminalPane.shutdown()` unconditionally
- **Evidence:** No `foregroundProcess` / running-child detection exists anywhere under `Sources/ViewerUI/Terminal/` (grep for `foregroundProcess|hasRunningProcess|isBusy|childProcess` is empty). The only terminal alert is the rename prompt (`TerminalView.swift:376`). By contrast, editor tabs get the full Save/Don't Save/Cancel treatment (`EditorCoordinator.swift:1189`).
- **Impact:** A long build, an ssh session, or a running dev server dies on a single mis-click of the tab's close affordance or on ⌘Q — with zero friction and zero feedback. Terminal.app and iTerm2 both warn when a tab with a running foreground process is closed; users port that expectation.
- **Suggested fix:** Before reaping, check for a live foreground child on the PTY (`tcgetpgrp(masterFD)` vs the shell's pgid — cheap, synchronous) and show a confirm ("A process is still running in this tab — close anyway?"). Gate the quit path on the same check (one prompt listing busy tabs). Skip the prompt when the child is just the idle shell.
- **Fix size:** M · **Fix risk:** careful (pgrp probing must not race `terminate()`; keep the prompt out of the session-switch path, which detaches rather than closes)

### F5 · P2 — Git stash Apply/Pop/Drop swallow failures; a stash-apply conflict is completely silent

- **Files:**
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/Git/GitStashTab.swift:81-91` — `apply`/`pop`: `_ = GitClient(repoRoot: root).stashApply(s.ref)` then refresh; result discarded
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/Git/GitStashTab.swift:29-33` — Drop (post-confirmation): `_ = …stashDrop(entry.ref)`
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/Git/GitClient.swift:535-547` — `stashApply/Pop/Drop` return `(try? run(…)) != nil`, discarding git's stderr (the conflict/reason text)
- **Evidence:** Contrast with the same panel's status tab: `GitPanelModel.swift:563-586` toasts both failures (`"Git \(op.verb) failed"` with the message) and successes (`"Committed."`). The stash tab predates the toast pattern and was never migrated.
- **Impact:** `git stash apply`/`pop` failing on conflicts is the *common* failure mode, not the edge: the user clicks Apply, nothing visibly changes (or worse — conflict markers now sit in their working tree), and the app says nothing. Pop that half-applied leaves the stash entry present, contradicting the user's mental model. Inconsistent feedback within the same Git panel.
- **Suggested fix:** Return a `(ok, message)` result (as `GitStageOp` already does) from the stash calls and toast failures via `ToastCenter.postError` with git's stderr; toast success for pop/drop ("Applied stash@{0}", "Dropped…"). One-file change per layer, pattern already established.
- **Fix size:** S · **Fix risk:** safe

### F6 · P2 — Silent drop of >1 MiB unsaved edits when the hot-exit spill write fails; no quit-time fallback

- **Files:**
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DocumentModel+ScrollPersistence.swift:263-272` — spill failure: `baseMTime = nil; baseSize = nil // spill failed → can't preserve` — capture proceeds with the text dropped; untitled >1 MiB is dropped unconditionally (comment: `// untitled >1 MiB → drop`)
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/MarkdownViewer/main.swift:704-726` — no `applicationShouldTerminate`; quit never prompts for dirty buffers (hot exit is the only safety net)
- **Evidence:** `HotExitSpill.write` returns `Bool`; the false branch neither toasts, nor logs at error level, nor falls back to a save prompt. The app deliberately has no quit-time Save prompt (VS Code-style hot exit) — which is fine **while the net holds**; when the net itself fails (disk full — precisely the situation where a big buffer is likely), the failure is invisible and the user's edits are gone on relaunch.
- **Impact:** Narrow but severity-amplified path: silent loss of potentially large amounts of work, in a failure mode (disk pressure) that correlates with big buffers. The mitigating "untitled" branch is near-unreachable today (New File writes `Untitled.txt` to disk immediately, `ViewerCore/NewFileCreator.swift`), so the live risk is the spill-write failure.
- **Suggested fix:** On spill failure at the quit boundary, fall back to the modal Save prompt for that tab (the machinery exists — `confirmCloseIfDirty`), or at minimum block quit with an alert naming the file. On non-quit snapshot boundaries, post an error toast ("Couldn't preserve unsaved changes to X — save now").
- **Fix size:** S–M · **Fix risk:** careful (quit-path modality; must not regress the fast common quit)

### F7 · P2 — Rendered-lens find reports only yes/no; Source lens shows a full match count

- **Files:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/MarkdownFindBar.swift:63-71` — `NoResultsMode.boolean(matched:)` ("Rendered view: WKWebView returns a bool — we know 'no results' but not how many") vs `.countOnly` for source view.
- **Evidence:** The same find bar component renders "No results" in both modes (lines 223, 235) but a running "n of m" counter only where the full match list exists. The rendered path uses the WKWebView bool-returning find.
- **Impact:** Feedback inconsistency across lenses of the *same document*: users in the default rendered markdown view can't see how many matches exist or where they are in the sequence — a signal every peer app's find (Safari, Preview, VS Code) provides. It also makes "did my Next wrap around?" unanswerable.
- **Suggested fix:** Count matches in the rendered DOM via injected JS (e.g. a `window.__mdvFindCount(term, flags)` walker mirroring the search options) and feed the existing counter; the CM6/source machinery shows the display side is already built.
- **Fix size:** M · **Fix risk:** careful (keep count consistent with WKWebView's own match semantics; degrade to boolean when JS unavailable)

### F8 · P3 — Menu-bar Copy commands give zero success feedback (other copy surfaces confirm)

- **Files:**
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/MarkdownViewer/main.swift:3457-3461` — `copyAsHTML` writes the pasteboard and returns; same for Copy as RTF (`:1197`), Copy as Markdown Table / JSON / CSV handlers
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/SidebarView.swift:1176` — context-menu "Copy Path", no feedback
- **Evidence:** Contrast: `SQLiteBrowserView.swift:368-380` toasts "Copied N rows as CSV"; `MetadataPanel.swift:198-206` flips the button to "Copied!". The menu-bar copies are the *most* invisible (no state change anywhere on screen) yet the only ones without confirmation.
- **Impact:** Clipboard operations have no inherent visible effect; without confirmation users re-invoke or paste-to-verify. Inconsistency also undermines learned trust in the toast channel.
- **Suggested fix:** One `ToastCenter.shared.post(.success, "Copied as HTML")` line per handler (≈6 call sites).
- **Fix size:** S · **Fix risk:** safe

### F9 · P3 — `keybinding.json` errors are visible only in the Logs view; user edits fail silently in-face

- **Files:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DocumentModel+CommandRegistry.swift:28-52` — malformed file / invalid shortcut strings / unknown command ids / shadowing collisions all emit `Obs` events only.
- **Evidence:** `logKeybindingResult` writes warn/info-level `Obs` events; nothing posts to `ToastCenter` and the Keyboard Shortcuts window shows no per-binding error badge. A user who typos `"cmd+shft+p"` sees their binding silently not take effect.
- **Impact:** The feedback loop for a deliberate power-user customization is broken — the user acted, nothing happened, and the explanation is buried in a diagnostics surface they may not know exists. (Good: the collision last-wins rule *is* logged; same visibility problem.)
- **Suggested fix:** After a reload with failures, post one summary toast ("2 keybindings ignored — open Logs for details", action button → Logs view). Optionally badge affected rows in `KeyboardShortcutsView`.
- **Fix size:** S · **Fix risk:** safe

### F10 · P3 — Error alerts interpolate raw Swift errors

- **Files:**
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/Coordinators/EditorCoordinator.swift:989` — save-failure alert: `alert.informativeText = "\(error)"`
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/MarkdownViewer/main.swift:3483` — HTML export failure: `String(describing: error)`
  - `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DocumentModel+FileOperations.swift:76` — new-folder failure toast reason: `String(describing: error)` (note: the trash path at `:32` correctly uses `localizedDescription`)
- **Evidence:** Swift error interpolation yields developer-facing dumps for non-NSError values (`Error Domain=NSCocoaErrorDomain Code=640 …` or enum case dumps) rather than the localized failure reason + recovery suggestion.
- **Impact:** The app's most stressful dialogs (save failed!) speak debugger. Actionability suffers — `NSError.localizedRecoverySuggestion` ("The disk is full…") is exactly what the user needs and is being discarded.
- **Suggested fix:** Standardize on `(error as NSError).localizedDescription` + append `localizedRecoverySuggestion` when present; a tiny `UserFacingError.describe(_:)` helper used at all alert/toast sites.
- **Fix size:** S · **Fix risk:** safe

### F11 · P3 — Settings is a single flat scroll of 12 sections with no search

- **Files:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/SettingsView.swift:6-8` ("Kitchen-sink Settings page. Single page, no tabs… Tabs/categories can wait until we have enough settings to actually need them"), body at `:31-57` (appearance / editor / languages / terminal / viewer / file-associations / audio / privacy / plugins / extensions / LSP / advanced).
- **Evidence:** The "can wait" comment predates the current scale: 12 sections, ~708 lines of view code, plus pushed sub-pages (Plugins, LSP Diagnostics). No filter field; a user hunting "word wrap" or "vim" must scan the full scroll.
- **Impact:** Progressive-disclosure debt at the exact surface users visit *to find something specific*. macOS System Settings, VS Code, and every peer normalize settings search at far lower knob counts. Discoverability of already-shipped preferences suffers (features exist but can't be found → perceived as missing).
- **Suggested fix:** Add a filter `TextField` that hides non-matching rows/sections (rows are already built via a uniform `row(_:)` helper — tag each with its label string); sidebar categories can genuinely wait.
- **Fix size:** M · **Fix risk:** safe

### F12 · P3 — Delete-to-Trash toast has no "Undo"/"Put Back" action (paste toast has one)

- **Files:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DocumentModel+FileOperations.swift:37-38` — success toast `Moved "X" to Trash`, no action; contrast `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/DocumentModel.swift:2264` — paste toast wires `actionLabel: "Undo"`.
- **Evidence:** `ToastCenter.post` supports a single action button (used for paste undo, TSK-1479). The trash toast — the app's most destructive routine file action — doesn't use it, even though the pre-trash URL is in hand and `FileManager.trashItem(resultingItemURL:)` can return the trashed location for a put-back.
- **Impact:** Recovering from a mis-delete requires leaving the app (Finder → Trash → Put Back). In-place undo is one toast action away and matches the pattern the app already taught users on paste.
- **Suggested fix:** Capture `resultingItemURL` in `deleteFileToTrash`, add `actionLabel: "Undo"` moving the item back and reloading the sidebar node.
- **Fix size:** S · **Fix risk:** safe

---

## Positive observations

Genuinely strong practice worth preserving (and citing as the internal bar):

- **Error prevention over dialogs, systematically.** The no-clobber save guard re-stats before every write (`EditorCoordinator.swift:873-887`); a post-save watcher-blind-window reconcile catches lost FSEvents (`:896-911`); read-only extracted views are refused at the write chokepoint (`:865-870`); file deletes are Trash-only with the unlink footgun explicitly banned (`DocumentModel+FileOperations.swift:16-26`), and tabs over deleted files stay open with content preserved.
- **Undo-ability in the data models:** per-edit undo/redo stacks in the CSV grid (`EditableCSVModel.swift:64-215`) and hex editor (`HexEditBuffer.swift:20`); Local History snapshot-on-save (`EditorCoordinator.swift:980-981`); deleted-file resurrection with a dedicated picker (`RecoverDeletedFileView.swift`) and success toast (`DocumentModel+Resurrection.swift:72`).
- **Hot exit done properly:** dirty buffers captured for *all* tabs (not just active), inline ≤1 MiB / sidecar spill above, with the pre-edit disk baseline preserved so the external-edit detector still fires across a relaunch (`DocumentModel+ScrollPersistence.swift:249-321`).
- **A real feedback architecture, not ad-hoc:** `ToastCenter` centralizes toasts + long-operation progress with cancel hooks, error TTL longer than success, a max-visible cap, and every error mirrored to a durable Logs record (`ToastCenter.swift:113-118`).
- **Onboarding exists and demonstrates rather than tells:** the first-run sample exercises outline/tables/code/mermaid on real surfaces, is one-shot latched, collision-safe on write, skipped for test/harness launches, and re-reachable via Help (`FirstRunExperience.swift`, `main.swift:569-581`).
- **Empty states are a tested catalog:** every hosted surface draws from `EmptyStateCatalog` with a completeness test, each with what-is-this + next-step + optional action (`HostedEmptyStateView.swift`).
- **Discoverability infrastructure:** command palette with macOS-glyph shortcut hints and double-Shift invocation; a registry-generated Keyboard Shortcuts window (no hand-maintained drift); `validateMenuItem` renames items contextually ("Pretty-Print JSON", "Show Rendered") so menus self-document (`main.swift:3575+`).
- **Consent gates on risky flows:** URL-scheme walkthroughs prompt before driving UI automation (`main.swift:680-693`); local-HTML scripts are stripped by default with per-document "Trust & Run" (`HTMLTrustBanner.swift`); a secret-detection warn banner never renders the secret value (`SecretWarningBanner.swift`).
- **Recoverable factory reset:** File ▸ Reset variants confirm, back up to `_reset-backups/`, and relaunch (`main.swift:892-945`).
- **Destructive git ops confirm:** stage-panel discard is unreachable except through its confirmation dialog (`GitStatusTab.swift:38-52`); stash drop confirms before invoking (`GitStashTab.swift:25-35`).
- **A11y as part of feedback:** "No results" is announced to VoiceOver on the transition, not per keystroke (`MarkdownFindBar.swift:98-107`).

---

## Coverage gaps (not examined)

- **On-screen behavior:** this is a static review; nothing was VM-pixel-verified. Any finding above that ships a fix still owes the project's partial-T6 on-screen confirmation.
- **CodeMirror-internal UX** (editor keymap completeness, autocomplete/hover interaction feel) — the CM6 bundle (`Sources/ViewerUI/Resources/codemirror`) was not reviewed.
- **Canvas subsystem** (`Sources/ViewerUI/Canvas`, parked epic) and **Claude Monitor**, **Review** module UX — skimmed only.
- **mdv-tui / mdv-web front-ends** — out of scope; this review covers the macOS app.
- **Localization/copy quality** beyond the specific findings; the app appears en-only.
- **Performance-as-UX** (perceived latency, spinner thresholds) — covered by the separate perf dimension.
- **Accessibility depth** (full VoiceOver traversal, contrast) — only touched where it intersected feedback loops; deserves its own dimension.
- **Plugins/LSP settings sub-pages** and the walkthrough *authoring* UX — not traced end-to-end.
