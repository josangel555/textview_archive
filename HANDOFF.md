<!-- CLAUDE-HANDOFF v1 -->
# Handoff — scroll fix (VM-verifying) + session-switch perf + editor-highlighting decision  (2026-06-20 02:10)

**Session:** claude-mdv (OWNER-DRIVEN interactive — the autonomous cron is STOPPED)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `fdb94df1` (verify `git log -1`).

## Mode change (important)
The autonomous loop **cron was stopped** by the owner earlier this session (`CronDelete 0614b865`). This is now a hands-on, owner-driven session — respond to the owner's asks; do NOT resume autonomous board-draining unless they ask.

## Mission
Owner is iterating on three things: (1) **scroll resets on session/tab switch** — must be preserved; (2) **session/tab switch is slow** — make it faster; (3) **editor syntax-highlighting architecture** — should CM6 drop its Lezer packs and use core tree-sitter for all 22 langs? Plus they asked deep questions about the TreeSitter/Lezer tradeoffs (answered; see LESSONS 2026-06-20 + the research doc).

## Current state
- **Scroll bug — REAL fix written, VM-verifying NOW.** Model fixes landed on main (TSK-1037 editor `97206db3`, TSK-1041 rendered-MD `24f58ddd`, both host-validated) but the owner confirmed the bug PERSISTS ON SCREEN — the defect is the RENDER hop (restored offset never re-applied to the live WebView after its reload-on-switch). The render fix IS written: commit `c6f010f7` on worktree branch **`worktree-agent-af63e63e1cc2c94b7`** ("apply restored scroll to live editor/preview on switch-in") + a 250-line VM UAT `ScrollRestoreUATTests` (SCROLL01-04 = rendered/editor × tab/session). I rebased that branch onto current main (CLEAN) and launched the VM verification via a background run.
  - **VM RESULT (log `/tmp/vm-scroll.log`, 3 ran):** ✅ SCROLL02 rendered-MD SESSION-switch PASSED; ❌ SCROLL01 rendered-MD TAB-switch FAILED; ❌ SCROLL03 editor/CM6 TAB-switch FAILED ("scroll RESET to top, top line=1, expected ~220"). So the fix is **PARTIAL** — only rendered-MD session-switch works on real UI. **Do NOT merge as-is.** Host tests were 23/23 green but real UI shows 2/3 still reset (the VM-verification lesson, exactly). The TAB-switch path (rendered + editor) still doesn't re-apply the restored offset on switch-in.
- **Session-switch perf — landed (rendered-MD only).** TSK-1042 warm-WebView cache (`9dc9dde3`, → review), TSK-1043/1044 batched drain (`72894a3b`, validated). On `main`.
- **Tab-switch perf — STILL SLOW (owner-reported), UNADDRESSED.** The warm cache only helps SESSION switch; tab-switch uses `MountedPanesLRU(capacity: 4)` → >4 tabs rebuilds the WebView → slow. Needs its own fix (see BACKLOG; file a ticket).
- **Editor highlighting — DECISION PENDING.** Cutover agent (TSK-1038, "drop CM Lezer packs") is PAUSED at worktree branch `worktree-agent-a0d2dd34575664953` (partial impl). Research (TSK-1039) shows a pure cutover regresses markdown-fence highlighting (core), auto-indent, comment-toggle, large-file perf → **recommend HYBRID**. Owner was mid-clarifying, then pivoted to perf/scroll.
- `/Applications` was last rebuilt at `fdb94df1` (perf + scroll-MODEL, NOT the scroll render fix).

## Next action (resume HERE)
1. **The scroll fix is PARTIAL (VM-proven): fix the TAB-switch path.** SCROLL01 (rendered-MD tab) + SCROLL03 (editor/CM6 tab) still reset; only SCROLL02 (rendered session) works. On the worktree branch `worktree-agent-af63e63e1cc2c94b7`, diagnose why the restored offset isn't re-applied on a TAB switch-back (panes stay mounted on tab-switch via `MountedPanesLRU`, so the dismantle/make re-attach path that SCROLL02 uses may not fire — the restore must hook the tab-SELECT path, not just mount). The UAT `ScrollRestoreUATTests` is the teeth (SCROLL01/03 must go green).
2. **Re-run the VM (from the MAIN loop, NOT a sub-agent):** `rsync -az --delete --exclude='.git' --exclude='.build/' --exclude='.swiftpm/' --exclude='dist/' <worktree>/ macOS15:markdown_viewer/` then `ssh macOS15 'cd markdown_viewer && MDV_SKIP_SMOKE_GATE=1 MDV_VM_SUDO_PASS=<vm-sudo-password> bash scripts/test-in-vm.sh smoke ; MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_RUN_WEBVIEW_TESTS=1 bash scripts/test-in-vm.sh test --filter ViewerUITests.ScrollRestoreUATTests'` via `Bash(run_in_background)` → read `/tmp/...log` for SCROLL01-04.
3. **Only when all SCROLL scenarios pass on the VM:** `git merge --ff-only worktree-agent-af63e63e1cc2c94b7` → headless gate → `build-app.sh debug --install` → tell owner to test → reap the worktree.
4. **Then:** editor-highlighting decision (recommend hybrid; TSK-1038 paused), and tab-switch-cap-4 perf.

## Key decisions & rationale
- **Drive the VM run from the main loop, not a sub-agent.** The scroll sub-agent (TSK-1046) wrote the fix but got STUCK waiting on the long VM GUI-lane run (~27min, "waiters armed", no completion). I stopped relying on it and run the VM myself via `run_in_background` (clean completion notification).
- **Paused the editor cutover (TSK-1038).** The research the owner also asked for contradicts the cutover directive (markdown-fence regression in a markdown app). Surfaced it + recommended the hybrid rather than silently shipping the regression.
- **Filtered VM UAT, not the full suite.** `test-in-vm.sh smoke` (build fresh dist, `MDV_SKIP_SMOKE_GATE=1`) then `test --filter ...UATTests` under the GUI env — much faster than `all` (~20min). See LESSONS.

## Gotchas / lessons (also in LESSONS.md 2026-06-20)
- A host-tested MODEL fix ≠ a render-bug fix; don't tell the owner "fixed" until proven on real UI (burned twice this session).
- Scroll reset + session-switch slowness share ONE root cause: the WebView is rebuilt on switch.
- `test-in-vm.sh test --filter X` skips `build_all` (stale-dist trap); rsync a WORKTREE with `--exclude='.git'` (worktree `.git` is a file).

## Files that matter
- `worktree-agent-af63e63e1cc2c94b7` (branch) `c6f010f7` — the scroll RENDER fix (MarkdownRenderedView/DocumentModel/codemirror.html) + `Tests/ViewerUITests/uat/ScrollRestoreUATTests.swift`.
- `worktree-agent-a0d2dd34575664953` (branch) — the PAUSED editor cutover (partial).
- `Sources/ViewerUI/WarmWebViewCache.swift` + `MarkdownRenderedView.swift` — the perf warm cache (on main).
- `docs/research/session-switch-perf-2026-06-20/FINDINGS.md` + `P1b-per-session-documentmodel-design.md` — perf audit + the parked durable design.
- `docs/research/cm-lezer-vs-treesitter-parity-2026-06-20/` — the Lezer-vs-tree-sitter parity spike (informs the editor decision).

## Open questions / blockers (owner)
- **Editor highlighting:** hybrid (recommended) vs full cutover vs hold? (TSK-1038 paused.)
- **P1b per-session `DocumentModel`** (TSK-1045): build it, or is the warm cache enough? (VM-measure first.)
- **Tab-switch cap-4** — acceptable to raise the LRU cap / extend the warm cache?

## Tracker (tasked, agent `claude-mdv`)
- TSK-1046 (scroll render fix) — `progress`, VM-verifying (full resume note on the ticket). TSK-1037/1041 — validated (MODEL only). TSK-1042 — review. TSK-1043/1044 — validated. TSK-1040 (perf spike) — review. TSK-1045 (P1b) — parked. TSK-1047 (CM6 editor warm cache) — filed. TSK-1038 (cutover) — paused. TSK-1039 (parity research) — review (doc untracked, for owner review).

## How to resume
1. `git -C /Users/me/Documents/workspaces/claude/markdown_viewer log -1` (expect `fdb94df1` unless the scroll branch was merged).
2. Read `/tmp/vm-scroll.log` for the SCROLL01-04 result of the in-flight VM run (`bjc7e6ha6`). Follow "Next action" above.
3. If the cron is to stay stopped (it is, unless the owner says otherwise), do NOT auto-resume board-draining — wait for the owner.
4. `git worktree list` — two agent worktrees are live (scroll `af63e63e`, cutover `a0d2dd34`); reap the scroll one after merge, keep the cutover one until the highlighting decision.
