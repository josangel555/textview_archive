# Ultracode workflow scripts

Multi-agent `Workflow` scripts (ultracode) authored 2026-07-09 for the pre-launch
push. Launch with `Workflow({scriptPath: "scripts/workflows/<file>.js"})`. Each
embeds its inputs as `const`s (the `args` object failed to marshal — see LESSONS.md).

Model routing (owner directive): **Fable = high-priority / safety-critical work,
Opus = the bulk** (split spreads load across account limits).

| Script | Model | What it does | Output |
|--------|-------|--------------|--------|
| `prelaunch-audit.js` | Fable(hi-pri)+Opus(bulk) | ~45-dimension quality review → adversarial verify → synthesis → worktree fixes | `docs/research/prelaunch-audit-2026-07-09/` (per-dim + `MASTER_REPORT.md` + `NEEDS_OWNER.md`) + fix **branches** |
| `wf-feature-readiness.js` | Fable | review every feature → gaps + hierarchical tree | `FEATURE_TREE.md` + `FEATURE_GAPS.md` |
| `wf-uat-tests.js` | Opus | author AX+UI-UAT tests (concurrent worktrees) → **serial** VM-validation lane (VM GUI = singleton); AX = author-only | test **branches** + `VALIDATION_REPORT.md` |
| `wf-finish-50.js` | Fable | complete next ~50 board tasks via worktree batches → each to `review` | task **branches** |

**Nothing auto-lands on `main`** — fixes/tests commit to worktree branches;
integrate rebase + ff + gate after review. Don't run the autonomous chunk-loop
while one of these is running (reviewers read the code; fixers branch off main).
