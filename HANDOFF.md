<!-- CLAUDE-HANDOFF v1 -->
# Handoff — owner UI-bug batch + VM-lane + killall footgun  (2026-06-06 19:00)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main @ 6116e76`

> Newer than `docs/HANDOFF_2026-06-06.md` (AM). Read THIS first, then `docs/AUTONOMOUS_PROGRESS.md` (LOG latest+30 down) for the narrative.

## Mission
SwiftUI macOS app **TextView/MarkdownViewer** (`Sources/`). Autonomous loop: fix owner-reported UI bugs first, keep `main` headless-gate-green, commit per item, land via ff. Owner runs the installed `/Applications/TextView.app` and reports bugs interactively.

## Current state
- **Done + installed (relaunch picks them up):**
  - Terminal **Enter** now reaches the shell — TWO fixes: `performKeyEquivalent` claims Return (`c3a7b83`) AND `SidebarKeyMonitor` (app-wide NSEvent monitor) now yields to the terminal via a `SidebarKeyMonitorExempt` marker (`8b8a547`). The monitor was the real culprit ("file nav eats the keystroke").
  - Command palette: no more **scroll-on-hover** (`65b2b32`).
  - Settings → Plugins/LSP: explicit **"‹ Settings" back button** (`e3cd4a2`).
  - **KILLALL FOOTGUN (`e5ffa08`)** — `install-app.sh` ran `killall MarkdownViewer` on every `--install` → killed the owner's running app. Removed. This was "app keeps getting closed."
  - Build/install xattr: sign in non-iCloud TMPDIR + `ditto --noextattr` + `xattr -cr` (`47adc00`,`d9d5b1c`) — iCloud codesign-detritus race closed (TSK-449).
  - Status-bar lazy-`.loading` blank fixed → shows Size+"loading…" (`1615b98`) + headless test `test_selectTab_statusBarDataSourceTracksSelectedFile` proving the data source tracks the selected file.
  - VM toolchain (TSK-439) + build-app cargo-fallback (TSK-446) earlier this session — VM can build+test+assemble dist via `bash scripts/test-in-vm.sh`.
- **In flight / awaiting owner:** **status-bar tab-switch (TSK-452)** — data source + wiring proven correct headlessly; if stats STILL go blank/stale switching between ALREADY-LOADED tabs, it's a SwiftUI re-render (live-only). Owner to report symptom after relaunch.
- **Next action:** await owner's status-bar symptom word (blank/frozen/fine). If "frozen/blank on loaded-tab switch" → it's a live re-body bug; needs VM/live repro. Otherwise close TSK-452.

## Key decisions & rationale
- **Removed `killall` from install-app.sh** (didn't make it targeted) — `--install` runs constantly on the autonomous loop; macOS swaps a running bundle fine without killing it. Don't reintroduce.
- **Settings back via explicit Button + `@Environment(\.dismiss)`**, not NavigationStack's auto chevron — the hosted Settings window has no toolbar so the auto chevron is invisible.
- **Marker protocol `SidebarKeyMonitorExempt`** over `is TerminalNSView` — extensible for the next custom-key view.
- **Did NOT guess the status-bar live fix** — verified the headless layer instead (owner explicitly asked for headless verification; see memory `feedback-verify-headless-before-asking`).

## Gotchas / lessons (full text in LESSONS.md "Session 2026-06-06 (evening)")
- App-wide `NSEvent.addLocalMonitorForEvents(.keyDown)` (SidebarKeyMonitor) pre-empts BOTH the responder chain AND `performKeyEquivalent` — check it FIRST when a custom NSView "doesn't get keys."
- NEVER `killall <shipping-exec-name>` in scripts/tests (shared exec name = kills owner's app). Grep `killall scripts/ Tests/` if owner says app closes.
- Repo is under **iCloud `~/Documents`** → file provider re-stamps FinderInfo/fpfs#P mid-`codesign` → intermittent "detritus not allowed". Sign outside the synced tree.
- macOS NavigationStack back chevron needs a window toolbar (hosted windows lack one).
- A "live-only" UI bug usually has a headless-testable data/wiring layer — prove it first.

## Files that matter
- `Sources/ViewerUI/SidebarKeyMonitor.swift` — `SidebarKeyMonitorExempt` protocol + `shouldYieldToFirstResponder()`.
- `Sources/ViewerUI/Terminal/TerminalNSView.swift:21` — conforms to marker; `performKeyEquivalent` claims Return.
- `Sources/ViewerUI/CommandPaletteView.swift` — `scrollOnSelectionChange` flag (hover vs keyboard scroll).
- `Sources/ViewerUI/SettingsView.swift` — `SettingsSubPage` wrapper (explicit back).
- `Sources/ViewerUI/StatusBar.swift:~435` — `.loading` case shows Size; `currentMetrics`. Data source = `model.tabs.selected`.
- `scripts/install-app.sh` — no killall; `ditto --noextattr` + `xattr -cr`. `scripts/build-app.sh:~188` — TMPDIR sign.
- `Tests/ViewerUITests/DocumentModelTests.swift` — `test_selectTab_statusBarDataSourceTracksSelectedFile`.

## Open questions / blockers
- **Status-bar live re-render (TSK-452)** — owner symptom needed.
- **VM full-suite hang (TSK-451)** — `test-in-vm.sh all` hangs after `TabBarWidthTests`; orphan VM PIDs **28912/29140** need `ssh macOS15 'kill 28912 29140'` (auto-classifier blocked me). Blocks GP_10 (TSK-447) + sidebar-resize (TSK-440) live validation.
- VM creds: `macOS15` / `vm-tester@<vm-ip>` / sudo `<vm-sudo-password>`.

## Tracker (`tasked` board @ localhost:8787 — SoR; helper `python3 /tmp/board.py <tool> '<json>'`, agent `claude-mdv`)
- TSK-439 (VM 6.3 toolchain) **fixed** · TSK-446 (build-app cargo fallback) **fixed** · TSK-448 (terminal Enter) **fixed** · TSK-449 (iCloud codesign) **fixed** · TSK-454 (killall) **fixed** · TSK-276 (IndentDetector CRLF, verify-closed) **fixed**
- TSK-447 (GP_10 stale test) **progress** — fix committed `541b3df`, VM-validation blocked by TSK-451
- TSK-452 (status-bar tab-switch) **progress** — has resume comment
- TSK-451 (VM all hang) **reported**, TSK-440 (sidebar resize) blocked-on-VM

## How to resume
1. `cd /Users/me/Documents/workspaces/claude/markdown_viewer` · `git log --oneline -12` (HEAD `6116e76`).
2. Read `docs/AUTONOMOUS_PROGRESS.md` LOG latest+30 → latest+27 for the full narrative.
3. If owner replied re status bar: act on TSK-452 per its board comment. Else continue the autonomous loop: `python3 /tmp/board.py task_list '{"project":"tasked"}'`, pick a SwiftUI `Sources/` task (skip stale audit #266–#345 + foreign `agent:forge`), drive to `fixed`.
4. Gate before landing: `bash scripts/test-headless-gate.sh` (window-free; perf benches `FoldBench`/`CrossFileSearchBench` flake under load — re-run / ignore if those are the only reds). Build+install for the owner: `bash scripts/build-app.sh debug --install` (now safe — no killall).
5. To reopen the VM lane: have owner kill PIDs 28912/29140, then `bash scripts/test-in-vm.sh test` (auto-selects Swift 6.3). UI tests run on the VM only (owner directive: NO UI tests on the Mac).
