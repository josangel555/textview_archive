# Giga UAT — run state (2026-06-03)

- **Workflow run id:** `wf_7f6adec6-3ab`
- **Background task id:** `wmiioi0j7`
- **Script:** `.claude/workflows/giga-uat.js`
- **Session:** `80ad52ff-c401-4cd4-9a0a-7558a3ded7c4`
- **Args:** `date=2026-06-03, venue=host-live, fixPolicy=land-safe, mode=full`
- **App under test:** `dist/TextView.app` @ `main 798b7ee` (load-bug fix verified + installed)

## Phases
Context (mine git/docs/tasks/code + unprimed explorers) → Author (`docs/uat/smokes/*.md`) →
Consolidate (dedupe) → Execute (single-threaded live, occluded) → Fix (land safe to main, stage rest) → Report.

## Expected deliverables
- `docs/uat/smokes/*.md` + `INDEX.md` — durable, maintainable smoke catalog
- `Tests/ViewerUITests/uat/*` — executable T4 companion suites
- `docs/uat/UAT_RUN_2026-06-03.md` — live per-smoke run log (appended during Execute)
- `UAT_BUGS.md` — remaining / staged bugs
- `docs/uat/UAT_REPORT_2026-06-03.md` — morning review report
- low-risk gate-green fixes landed on `main`; riskier staged on branches (report lists them)

## Watchdog
Hourly cron (`UAT_WATCHDOG_LOG.md`); revives a dead run via
`Workflow({scriptPath, resumeFromRunId: "wf_7f6adec6-3ab"})`.

## Re-run later (skip discovery/authoring)
`Workflow({name: "giga-uat", args: {mode: "run-only", date: "<today>"}})`

## Resume #1 (2026-06-03 07:06)
Prior run failed: schema executor ended without StructuredOutput; bare await aborted the whole run. Script hardened (fault-tolerant Execute loop + mandatory-StructuredOutput executor prompt + scope guard + guarded land/report tail). Resumed run wf_7f6adec6-3ab -> new background task **w1elqlsz4** (catalog replays from cache, Execute re-runs live).

## COMPLETE (2026-06-03 11:08)
- Result: 33 found / 32 fixed / 1 non-bug; severity 7xS2, 14xS3, 12xS4, no S1.
- **Landed on main (ground truth): 2** — `136883e` (BUG-019 view-mode clamp, gate-green), `5ed7c85` (BUG-021 dirty-close verb). Report says 0 (trusted fixer self-reports); reconcile.
- **30 fixes NOT durable yet:** ~27 are UNCOMMITTED in their worktree dirs (`-49,-51..-79` mostly `commits=0 dirty>0`); only `-47/-50/-54/-58` committed. Report wrongly says "staged on branches."
- **31 worktrees / 55GB NOT reaped** — would destroy the uncommitted fixes. Needs harvest-first (commit each worktree fix to a clean branch, untangle the shared-stash mess: RECOVERED-*-belongs-to-sibling, dedupe -52/-56 [BUG-009] and -65/-71 [BUG-028]) THEN reap.
- **Gate can never be green on host** (macOS-26 MarkdownLinkPolicy + FoldBench/CrossFileSearchBench parallel flakes) → land-safe stages everything. Quarantine those to unblock landing.

## Harvest + reap (2026-06-03 12:51)
All 31 staged fixes committed to their `worktree-wf_7f6adec6-3ab-NN` branches (BUG-labeled commits); 31 worktree dirs reaped → **55GB reclaimed** (.claude/worktrees now empty). Branches + 12-entry shared stash stack preserved. Landing checklist: `docs/uat/STAGED_FIXES.md`. Nothing landed to main beyond the prior 2.

## LANDED (2026-06-03 13:19)
27 UAT fixes on main, full headless gate GREEN. 5 held on branches for manual reconcile (-54 BUG-010, -64 BUG-027 = real fixes worth landing; -63 dup of -51; -50/-79 comment-only). Redundant branches reaped. /Applications still on the pre-UAT build — rebuild pending.
