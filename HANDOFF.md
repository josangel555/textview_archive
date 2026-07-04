<!-- CLAUDE-HANDOFF v1 -->
# Handoff — usability drain PARKED; park + persist checkpoint (2026-07-04)

**cwd:** /Users/me/Documents/workspaces/claude/markdown_viewer · **branch:** main @ 92dec034 (gate-green)

## Mission (parked)
App-wide production-grade usability (owner: **built ≠ usable**; editor/vim/file-nav work, the rest
needs the end-user layer). Umbrella **TSK-1411**. **PARKED by the owner 2026-07-04** — do not
resume without an owner ask. Canvas M0–M6 also parked. Cron stopped. When work resumes: INLINE,
one ticket at a time (no subagent batches unless the owner asks).

## Current state
- **Done on main (gate-verified):** batch 1 (1483 focus-routing + docs/FOCUS_ROUTING.md · 1435
  empty states · 1436 ToastCenter · 1479 paste toast · 1437 shortcuts), batch 2 (1461 snippets ·
  1462+1331 local history · 1463 tree ops · 1464 bookmarks · 1465 cross-search), 1434 tool-results
  panel, spell/autocomplete footer toggles (92dec034 — commit says TSK-1500, REAL ticket TSK-1503).
  Release build installed → /Applications/TextView.app (2026-07-03 02:39, 72MB).
- **Salvaged, NOT integrated:** branches `worktree-wf_dadf7ab6-e88-{1..9}` (dirs reaped, branches
  kept) from the session-limit-killed 9-agent Opus workflow — 7 complete ticket commits
  (1439-export · 1466 · 1467 · 1446 · 1447 · 1498 · 1484) + 9 `wip(salvage)` commits (NOT
  gate-verified). **System of record: TSK-1506** (prio-1, full branch↔ticket map + recipe).
- **Next action on resume:** work TSK-1506 — per branch: `git rebase main` → host gate →
  `git merge --ff-only` → next; append-conflicts expected on ScriptVerbCatalog/Dispatch/
  CommandRegistry (keep both sides); reconcile each ticket's board state against what lands;
  then CHANGELOG roll-up + `git branch -d` merged branches + fresh release build.

## Key decisions
- One-subagent-at-a-time → then INLINE (owner; overloaded fleets non-ideal — and the 9-agent
  fleet died on session limits, validating the call).
- e2e/VM/UAT validation DEFERRED to its own pass — docs/USABILITY_VALIDATION_PROTOCOL.md (rungs,
  VM recipe, batch queue). Implement-time bar = host tests+teeth+command-path → `fixed`.
- Context budgets have teeth: ContextBudgetTests (HANDOFF ≤12KB, CLAUDE.md ≤40KB) + the re-inject
  hook truncates over-budget handoffs. HANDOFF is STATE, not a log.

## Gotchas (full list LESSONS.md)
- Session limits kill fleets; worktrees are the salvage net (WIP-commit each, keep branches).
- Inline subagents share the git index with the main loop — no main-loop commits while one runs.
- Rebuilding rust-core/link/*.a does NOT relink SwiftPM — `rm -rf .build/*.xctest`.
- Fresh worktrees lack the gitignored staticlib — `bash scripts/build-rust-core.sh` first.
- FoldBench/MsgPack wall-clock benches are load-flaky (TSK-1499): only count non-bench failures.
- Background gates: judge by the `GATE_DONE rc=` log marker, never the task exit code.

## Files that matter
- docs/FEATURE_INVENTORY.md — THE hierarchy (12 domains, Built/Logic/Usable, gap-ticket map).
- docs/USABILITY_VALIDATION_PROTOCOL.md — validation rungs + the remaining batch queue.
- docs/WISHLIST_RECONCILE_2026-07-02.md — OwnerWishlist↔board map (gaps = 1483..1497).
- BACKLOG.md §Usability-drain PARKED — the park record.
- Reusable components: ToastCenter.shared · EmptyStateCatalog/HostedEmptyStateView ·
  ToolResults(Panel) · EditorAssistChips · CMOneShotRouting (docs/FOCUS_ROUTING.md).

## Open questions / owner levers
TSK-1334 pixel/AX grant · TSK-838 DOM-patch flip (felt latency) · finish-or-cut 1414/1418/1471/
1491 · formula gate 788/1215 · hex-edit 1423 · paint persistence 1426 · git visualizer 1492 ·
far-future 1497 · Canvas review · CLAUDE.md rules-vs-history restructure (proposed, ~9k→~4k tok).

## Tracker
- TSK-1411 (umbrella) — park comment with the full state · TSK-1506 — the integration ticket
  (prio-1, deliberately-deferred) · batches 1-2 + 1434 + 1503 at `fixed`/`validated` ·
  claude-mdv-w* agent records may be PARTIAL vs their branches (reconcile during 1506).

## How to resume (cold)
1. Read this file + BACKLOG.md §PARKED; `git log --oneline -15`; `git branch | grep wf_dadf7ab6`.
2. `mcp__tasked__task_get TSK-1506` — it carries the branch↔ticket map + integration recipe.
3. Integrate (rebase→gate→ff per branch), reconcile board, CHANGELOG roll-up, release build.
4. Then the protocol batch queue INLINE, per-slice: verify-first → implement → tests+teeth →
   gate → commit (Claude-Session trailer) → board to `fixed` (validation deferred).
