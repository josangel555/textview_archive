<!-- CLAUDE-HANDOFF v1 -->
# Handoff — DRAIN BOARD TO DONE (every task → done) + continue ticks  (2026-06-19 PM)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `417ddbd9` (verify `git log -1`).

## Mission (owner directive 2026-06-19 PM — RECALIBRATED, overrides prior "hold when exhausted")
**Goal: drive EVERY task on the `tasked` board → `done`.** Owner sharply corrected a too-conservative "nothing to do / holding" stance: **"Never stop saying nothing to do — there is always plenty of things to do."** So: **NEVER idle.** Each cycle: pull the next ~50 actionable from the board → launch an aggressive **parallel drain** (the ultracode select-drain script) → **integrate** commits as they land → **launch the next wave**. Continuously, in waves. (Memory: `feedback_never_idle_drain_to_done` + `feedback_ultracode_parallel_mode`.) When asked for board status, cover ALL lanes (reported/ack/triaged/progress/fixed/review/validated/done), not a few.

**METHOD REFINEMENT (owner 2026-06-19 PM): do the work INLINE in-session, a FEW tickets per tick — NO more giant background fleets.** Each tick: pick 2-3 actionable, implement directly (read → fix → host tests with teeth → commit per-item → `task_advance`→fixed → `task_validate`→validated with a checks/diff proof), then the next few. Do spikes/design inline too. Same goal: every task → done.

## Current state
- **Done (prior integration mission, verified):** the 117-commit ultracode wave is on `main` (gate-green, shipped, `/Applications` rebuilt); VM render-validated (~3998/4000); both VM findings fixed (1020 `XCTSkip`, 1021 validated); perf measured (845 validated, 1022); **tmux re-landed host-side** (model+controller-core, 122 tests, `@4db0f360`); **5 design-Qs spiked+parked** (787 HYBRID / 788 audit / 781 LSP docs + 779/775); **security subset validated** (965/966/967/968/976/987). Detail: `docs/AUTONOMOUS_PROGRESS.md` + `LESSONS.md`.
- **Wave 1 (50-item drain `wfykpwfqh`) DONE + INTEGRATED** → main `f7e94872`: 48/50 succeeded (891/794 blocked = VM-profile-needed, correctly returned). Cherry-picked onto `wave2/integration`, resolved clashes (697 set_zoom+search_files catalog merge; MCP count 11→12; ScriptVerbCatalog parity for 326's 4 verbs), build+gate GREEN, ff main, board reconciled (all 48 → `fixed`), worktrees reaped, `/Applications` rebuilt (15:32). Logged in AP + LESSONS + CHANGELOG.
- **Wave 3 STALLED after batch 1 → harvested** the 7 done commits → main `61e3e28f` (971 statusbar-rescan, 972 git-off-main, 973 search.files-prune [Rust], 974 exact-grammar-pins, 975 supply-chain-CI, 980 lsp-env-denylist, 981 WireError) — rust-core + Swift gates GREEN, all 7 → `validated`. The wave (`w99dpfj2i`) is STOPPED + reaped; 969 + batch 2-50 returned to the inline pool.
- **Inline since the cadence shift — 18 validated:** 1013, 1004, 1002, 1003, 1005, 1006, 1001, 1012, 990, 985, 988, 984, 1010, 996, 994, 995, 993, 1000 (each: fix + host tests with teeth + commit + `validated`; 990/1006 were already-fixed, reconciled with code proof). `/Applications` rebuilt @ 17:11.
- **NO active background waves.** Board shrinking; `reported` cluster remaining = 969, 992, 997/998/999, 1007, 1009, 1011, 1014, 1015, 986 + ack epics + paint + prio-3 backlog. Disk ~78 GB.

## Next action (resume HERE)
1. **Continue the INLINE cadence (no waves).** Each tick pick 2-3 actionable tickets and drive each to `validated`: read the code → fix → add host tests with TEETH → `swift test --filter '<Classes>'` (or `scripts/rust-core-gate.sh` for Rust) → commit per-item → `task_advance`→fixed → `task_validate`→validated (checks/diff proof). Render-path items: host-test the model, leave at `fixed`.
2. **Inline pool — remaining host-fixable:** 998 (LSP writable-dir check), 1007 (NSPopover leak), 1011 (persistence hot-exit/fsync), 1015 (dead-FFI cleanup), 969 (git-chip async clobber), 997/999 (low-sec); render/PTY/log-only (992 PTY double-fork, 1009 error-sink logging via os.Logger, 986 hex-debounce) land at `fixed` (not host-validatable with teeth). Then paint `403-406` + `[PARTIAL]`/epic foundation-slices. 991 PARKED (soft-cap UX). Skip owner-gated + foreign (441-445). `mcp__tasked__task_list` per lane to re-target as the clean pool thins.
3. **Per meaningful batch:** rebuild `/Applications` (`bash scripts/build-app.sh debug --install`); keep `main` gate-green. Parked for owner: 589/810 (+ 775/779/781/787/788 design-Qs).

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
