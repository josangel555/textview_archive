<!-- CLAUDE-HANDOFF v1 -->
# Handoff — to changelog + session wrap  (2026-06-13)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `2cb1197`

## Mission
Autonomous loop: drive the `tasked` board (http://localhost:8787/) toward Done, user-facing bug fixes first. Keep `main` headless-gate-green; commit per item; log to `docs/AUTONOMOUS_PROGRESS.md`; **NEW: keep `CHANGELOG.md` updated with user-facing changes each tick.**

## Current state
- **Done this session (gate-green on main):** TSK-741 (terminal large-paste ANR) ✅validated · TSK-736 (hover-highlight lag) ✅validated · TSK-619 (first-open TS-compile off-main) ✅validated · TSK-822 (T5 tier-gate) ✅validated · TSK-806 (split shows unsaved edits) fixed/VM · TSK-743 (source preview scroll) fixed/VM · TSK-821 (rendered-markdown preview scroll) fixed/VM. Plus the 580 FFI-envelope close-out (validated) + 819 VM .build chown.
- **Owner asks (this turn): DONE.** Added `CHANGELOG.md` (user-facing progress view) + the keep-updated discipline in `CLAUDE.md` (SOP) + `docs/TASK_WORKFLOW.md` §4 (per-firing reminder). Committed `2cb1197`.
- **In flight:** nothing half-done. (Was about to build a TSK-821 WebView-lane test — NOT started, just researched; see BACKLOG.)
- **Host-actionable user-facing pool is DRAINED.** Remaining = the VM render/interaction validation tail + the parked perf re-feel (below).
- **Next action:** owner asked to `/compact` after this handoff. On resume, the cleanest next work is the TSK-821 `PaneScrollRestoreWebViewTests` (#192-gated; round-trip primitives on our rendered page) OR awaiting the owner's TSK-598 perf re-feel.

## Key decisions & rationale
- **"Output-identical work-reduction optimizations are self-validatable on the host."** Used to validate TSK-741/736 from review (same pixels, fewer cycles; visual-regression modes host-tested). Don't reflexively hold these for VM.
- **Perf cluster un-blocked.** MountedPanesLRU was NOT pending owner approval — it shipped 2026-06-06 (TSK-108 validated). A fresh VM profile (`vm-profile.sh nav/resize`) showed switch `apply`=6.7ms (the stale ~199ms residual is GONE) + resize no-hangs → TSK-598 PARKED for owner re-feel; residual is inherent WebKit first-open `loadToFinish`.
- **TSK-822** gates the whole T5 `PixelTestCase` tier on `MDV_VM_GUI_SESSION` (via `LaunchHarness.shouldRunLiveTiers`) — fixes non-GUI-VM false-failures AND a bare-host window-opening footgun.
- **TSK-821 design:** PULL via `evaluateJavaScript` (capture `window.scrollY` before reload, restore on `didFinish`) — `MarkdownRenderedView`'s `Context` isn't constructible so the view-bridge can't be unit-driven; the store is host-tested, the round-trip is VM.

## Gotchas / lessons (also in LESSONS.md, dated 2026-06-13)
- `test-in-vm.sh test` (non-GUI) false-fails GUI-lane suites + flakes PTY tests — its real signal is the HEADLESS tiers. Use the GUI lane (`MDV_VM_GUI_SESSION=1`) for render/visual suites.
- A "blocked, awaiting owner" item may already be DONE — grep the code before re-pinging (the MountedPanesLRU mis-framing burned ticks).
- Signpost thread-id ≠ Main Thread is how you verify "moved off main" from a trace (TSK-619).
- WV-7 governs user-SCRIPTS (mermaid), NOT message handlers / `evaluateJavaScript`-injected listeners.

## Files that matter
- `CHANGELOG.md` — NEW owner-facing changelog (user-facing only). Keep it updated per the discipline.
- `CLAUDE.md` (SOP §"Automated runs") + `docs/TASK_WORKFLOW.md` §4 — the changelog keep-updated reminder.
- `Sources/ViewerUI/MarkdownRenderedView.swift` — TSK-821 scroll capture (updateNSView, before `loadHTMLString`) + restore (`didFinish`). `Sources/ViewerUI/DocumentModel.swift` `renderedScrollByURL` + `rememberRenderedScroll`/`renderedScrollOffset`.
- `Tests/ViewerUITests/Harness/TierBaseCases.swift` `PixelTestCase.setUpWithError` — TSK-822 gate.
- `docs/AUTONOMOUS_PROGRESS.md` — LOG +397..+406 (this session). `BACKLOG.md` 2026-06-13 — the VM-validation tail.

## Open questions / blockers
- **TSK-598 (waiting:human):** does tab-switch/resize still FEEL laggy in the installed build? Measured as resolved; owner's felt judgment gates closing 591/592/266/455.

## Tracker
- `tasked` / TSK-741,736,619,822 → validated · 806,743,821 → fixed (VM render/interaction pending) · 598 → parked (owner re-feel) · 820,821,822 filed (822 done) · 590 epic → review (session summary commented).

## How to resume
1. The SessionStart hook re-injects this file. Read it, then `docs/AUTONOMOUS_PROGRESS.md` head (LOG +406) + `BACKLOG.md` (2026-06-13).
2. `main` is gate-green at `2cb1197` (or later). Verify: `git -C /Users/me/Documents/workspaces/claude/markdown_viewer log --oneline -3`.
3. Each tick: read `docs/TASK_WORKFLOW.md` IN FULL, query the board (`mcp__tasked__task_next {agent:claude-mdv, project:tasked}`), pick the highest-value actionable item. **Remember the new CHANGELOG.md discipline for any user-facing change.**
4. Host-actionable pool is drained — the next work is the VM-validation tail or the parked perf re-feel. Don't manufacture paper cuts (§5).
