# UX best practices — review addendum

**Purpose:** A second independent pass over the same dimension found that the primary report
(`ux-best-practices.md`, F1–F12) already covers the substantive findings — and corroborates them.
This addendum records the three *additional* minor findings that pass surfaced and nothing else.
`ux-best-practices.md` remains the authoritative report for this dimension.

**Independent corroboration:** my pass independently re-derived the primary report's F10 (raw
`String(describing: error)` in user-facing feedback — confirmed at
`Sources/ViewerUI/DocumentModel+FileOperations.swift:76,107`,
`DocumentModel+ActiveFileFormatConvert.swift:70,92`, `DocumentModel.swift:739,848,881,2708`) and
F12 (delete-to-Trash toast lacks an Undo action despite `ToastCenter` supporting one). It also
confirmed the strong positives: `FirstRunExperience`, `EmptyStateCatalog`, native dirty-close
prompt with a **safe default** (Save is the Return button), Trash-only deletes, and the
backed-up File ▸ Reset flow.

---

## Additional findings (not in the primary report)

### A1 · P3 — HTTP client "Clear History" is irreversible with neither confirmation nor undo

- **File:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/HTTPClientView.swift:100` (`Button("Clear History") { model.clearHistory() }`), impl `:292-293`.
- **Evidence:** Clicking fires `store.clearHistory()` immediately — no `confirmationDialog`, no undo toast. Contrast the app's own established pattern for the same class of action: `SettingsView.swift:529-535` guards "Clear all bookmarks" behind a `.confirmationDialog` with a `.destructive` button.
- **Impact:** A mis-click wipes the request history with no recovery. Low stakes (regenerable by re-sending), but a gratuitous inconsistency with the app's own convention for irreversible list-clears.
- **Suggested fix:** Route through the same `confirmationDialog` idiom, or post an "Undo" toast holding the cleared list for the toast's lifetime.
- **Fix size:** S · **Fix risk:** safe

### A2 · P3 — "Reset window state" (Settings) executes on click with no confirmation and a deferred, unconfirmed effect

- **File:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/SettingsView.swift:544` (`Button("Reset") { resetWindowState() }`), impl `:558-559`; adjacent help text `:546` ("Quit and relaunch for the window to re-center.").
- **Evidence:** Clicking immediately calls `PreferencesStore.resetWindowState()` (clears zoom, sidebar width, saved window position). No confirmation and no completion feedback; per the help text the visible effect is partly deferred to relaunch.
- **Impact:** Broken feedback loop at a settings control — the action fires silently and its effect is deferred, so the user has no signal it worked and may re-click. Low stakes (reversible by re-adjusting), but the missing confirmation toast is a one-liner.
- **Suggested fix:** Post a confirming toast on completion ("Window state reset — relaunch to re-center").
- **Fix size:** S · **Fix risk:** safe

### A3 · P3 — Destructive confirmation prompts make the destructive verb the default (Return) button

- **Files:** `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/SidebarView.swift:366` ("Move to Trash" added first ⇒ default/Return), `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/MarkdownViewer/main.swift:931` ("Reset & Relaunch" added first ⇒ default/Return).
- **Evidence:** Both `NSAlert`s `addButton` the destructive verb first, making it the Return/Space target. The dirty-close prompt (`EditorCoordinator.swift:1202`) does the opposite — **Save** is first/default — so the app is internally inconsistent about safe defaults.
- **Impact:** Low, and partly defensible (both actions are recoverable — Trash put-back; reset backs up to `_reset-backups/` — which is the HIG carve-out for a destructive default). But a Return-masher can trash/reset without reading, against the safe-default posture the app takes elsewhere.
- **Suggested fix:** Make Cancel the default (or at least not the destructive verb) for the delete + reset-everything prompts, matching the dirty-close prompt.
- **Fix size:** S · **Fix risk:** careful (changes learned muscle-memory for existing users)

---

## Coverage note

Same static-only scope as the primary report: no UI/window tests were run; on-screen behavior is
inferred from code. The dual-UI (TUI/web) front-ends, Canvas, and Review-module UX were not
traced end-to-end.
