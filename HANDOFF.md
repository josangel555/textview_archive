<!-- CLAUDE-HANDOFF v1 -->
# Handoff — DRAIN BOARD TO DONE (every task → done) + continue ticks  (2026-06-19 PM)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `f7f6c6c1` (verify `git log -1`).

## Mission (owner directive 2026-06-19 PM — RECALIBRATED, overrides prior "hold when exhausted")
**Goal: drive EVERY task on the `tasked` board → `done`.** Owner sharply corrected a too-conservative "nothing to do / holding" stance: **"Never stop saying nothing to do — there is always plenty of things to do."** So: **NEVER idle.** Each cycle: pull the next ~50 actionable from the board → launch an aggressive **parallel drain** (the ultracode select-drain script) → **integrate** commits as they land → **launch the next wave**. Continuously, in waves. (Memory: `feedback_never_idle_drain_to_done` + `feedback_ultracode_parallel_mode`.) When asked for board status, cover ALL lanes (reported/ack/triaged/progress/fixed/review/validated/done), not a few.

## Current state
- **Done (prior integration mission, verified):** the 117-commit ultracode wave is on `main` (gate-green, shipped, `/Applications` rebuilt); VM render-validated (~3998/4000); both VM findings fixed (1020 `XCTSkip`, 1021 validated); perf measured (845 validated, 1022); **tmux re-landed host-side** (model+controller-core, 122 tests, `@4db0f360`); **5 design-Qs spiked+parked** (787 HYBRID / 788 audit / 781 LSP docs + 779/775); **security subset validated** (965/966/967/968/976/987). Detail: `docs/AUTONOMOUS_PROGRESS.md` + `LESSONS.md`.
- **Wave 1 (50-item drain `wfykpwfqh`) DONE + INTEGRATED** → main `f7e94872`: 48/50 succeeded (891/794 blocked = VM-profile-needed, correctly returned). Cherry-picked onto `wave2/integration`, resolved clashes (697 set_zoom+search_files catalog merge; MCP count 11→12; ScriptVerbCatalog parity for 326's 4 verbs), build+gate GREEN, ff main, board reconciled (all 48 → `fixed`), worktrees reaped, `/Applications` rebuilt (15:32). Logged in AP + LESSONS + CHANGELOG.
- **Wave 3 NOW IN FLIGHT** = `w99dpfj2i` (run `wf_950b59cc-36d`): 50 items, **security/perf/bug-first** (969/971/972/973/974/975/980/981/984/985/986/988/990/991/992/993/994/995/996/998/1000 from the 2026-06-18 review) + agent features (941/942/943) + epic foundation-slices (683/686/714/764/695/699/680/687/688/693/772/773/777) + paint (403-406) + stale revivals (276/279/293/296/298) + 400/691/320/380. **Auto-notifies on completion.**
- **Board: shrinking** — wave1's 48 now `fixed`; the big `reported` pool still holds the security/perf/bug review cluster (wave 3 is draining ~21 of them), the ack epics, and paint/photo. Plenty remains → keep launching waves.

## Next action (resume HERE)
1. **Check `wfykpwfqh`** (`TaskOutput`). On completion, read each result `{id, success, sha, summary, remaining}`. **Integrate the good commits onto `main`:** for each, verify ff-able (`git merge-base main <sha>` == `git rev-parse main`) → `git merge --ff-only <branch>` (or cherry-pick if not a clean descendant); batch ~5-8 then **gate once** (`bash scripts/test-headless-gate.sh`, look for "headless gate PASSED") — **never merge red**. Reap each worktree (`git worktree remove --force <path>` + `git worktree prune` + `git branch -D <branch>`). Reconcile board: `task_advance`→fixed (or `task_validate`→validated with the host-test proof artifact). Add user-facing items to `CHANGELOG.md`.
2. **Launch the NEXT 50-item wave** from the board (`docs/CURATED_TASKS_2026-06-19.md` §backlog-not-yet-pulled + reported/ack/triaged/progress). Reuse: `Workflow {scriptPath:"/Users/me/.claude/projects/-Users-me-Documents-workspaces-claude-markdown-viewer/80ad52ff-c401-4cd4-9a0a-7558a3ded7c4/workflows/scripts/ultracode-retry-drain.js", args:{batch:8, items:[{id,title,note}…]}}`. Skip owner-gated (dep-approval/decision/waiting:human) + foreign (wx_*/tasked-tool-dev 441-445).
3. **Keep waves going toward every-task-done.** Sweep `.build` / reap worktrees between waves (disk).

## Gotchas / lessons (also in LESSONS.md)
- **Parallel-worktree commits: clean git-merge ≠ it compiles.** Watch for semantic clashes (dup type names, renamed-symbol refs, union-strip brace loss). Gate-before-merge is non-negotiable. `$?` not `${PIPESTATUS[0]}` (zsh). Capture gate output to a FILE not `| tail`.
- **The select-drain script** already tells agents: read CLAUDE.md, `task_get` for intent, ONE slice per epic (don't attempt the whole epic), mandatory host tests, squash-commit, `rm -rf .build` after commit (disk). So passing `{id,title,note}` is enough; the agent does the rest.
- **VM render-validation** = the lever to drive the render-path `fixed`/`review` pile → validated (owner-greenlight; `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_RUN_WEBVIEW_TESTS=1 bash scripts/test-in-vm.sh all`).
- **NEVER `killall MarkdownViewer`; never commit `archive/Untitled.txt` or `untitled2.md`** (stage explicitly, never `-A` at repo root); land via rebase+ff (no merge bubbles); commit-msg footer ``.

## Open / owner-gated (shrinks the pile fastest)
- **VM render-validation pass** (greenlight) · **897** grammar deps (approval) · the **5 design decisions** (787/788/781/779/775 parked `waiting:human`) · the curated §Owner-gated section (854/810/589/470/709/751/936/956/301/498/831/852/584/585/587/835/851 + 343/733 repro).

## Files that matter
- `docs/CURATED_TASKS_2026-06-19.md` — reorganized **done→bottom**; §IN FLIGHT = the 50-wave items; lane counts; §Owner-gated + §backlog-not-yet-pulled = next waves' source.
- `docs/AUTONOMOUS_PROGRESS.md` — narrative log + all SHAs.
- `…/workflows/scripts/ultracode-retry-drain.js` — the select-drain script (reuse each wave).
- `docs/{TEST_FRAMEWORK_…,TEST_SUITE_AUDIT_…,LSP_OWN_VS_EXTERNAL_…}_2026-06-19.md` — the 3 design spikes done this session.

## Tracker (`tasked`, agent `claude-mdv`)
- 50-wave items (`wfykpwfqh`) IN FLIGHT — reconcile to fixed/validated as their commits integrate. 5 design-Qs parked `waiting:human`. Wave + security + migration = fixed/validated (owner closes →done). Board is the system of record; this doc is the selector.

## How to resume
`git -C /Users/me/Documents/workspaces/claude/markdown_viewer log -1` (confirm main). `TaskOutput wfykpwfqh` — if done, integrate its commits (step 1 above) + launch the next wave (step 2); if still running, no-op the tick (substantive work in flight) and re-check next firing. Then keep waves going toward every-task-done. Never report "nothing to do" — pull more from the board.
