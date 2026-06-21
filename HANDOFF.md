<!-- CLAUDE-HANDOFF v1 -->
# Handoff — autonomous curated-drain in progress  (2026-06-21)

**Session:** claude-mdv (AUTONOMOUS).  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch:** `main` (verify `git log -1`).

## Mode — AUTONOMOUS DRAIN (cron ARMED)
The owner re-armed a **5-min cron** (`CronCreate 994c7c56`) whose prompt FORCES reading
`docs/TASK_WORKFLOW.md` + the CLAUDE.md SOP + the latest `docs/CURATED_TASKS_*.md` every
tick, then draining relentlessly (curated top-30 → rest → board). **NEVER idle/hold** —
that is the process failure the owner called out. BUILD render-path/VM/perf features too
(host-test the model, leave render validation at review; do NOT hold for on-screen confirm).
One item per tick: spike → implement → test → host-gate → commit. Land rebase+ff. Commit
trailer ``.

## Done this autonomous run (all on main, gate-green)
- **TSK-1100** — surfaced DependencyGraphView (File ▸ Dependency Graph + command). fixed.
- **TSK-506** — surfaced FolderTreemapView (File ▸ Folder Sizes Treemap + command). fixed.
- **TSK-1105** — Settings ▸ Advanced ▸ Multi-session workspace toggle. fixed.
- **TSK-1112** — Settings ▸ Extensions plugins inventory list (IN FLIGHT: gate `byxn4xg8d`,
  commit on green). Walkthroughs in the inventory = a tracked follow-on (needs off-main
  WalkthroughCatalog→snapshot load).
- Earlier this session: trust-local-HTML (TSK-1189, review), kill Swift tree-sitter
  (TSK-854, −12.7MB, validated), sidebar cache fix (TSK-991), read-only-doc foundation
  (TSK-1204), multi-format viewer rtf/docx/ods/xlsx (TSK-1036), LocalHistory cluster (TSK-1103).

## Hard lesson this run
**NEVER commit in the same shell compound as the gate-check** — the commit runs regardless
of the grep result. I landed a red commit (9a173eb9: a verb in ScriptVerbDispatch but not
ScriptVerbCatalog; `testCatalogMatchesDispatchSwitch` caught it), fixed forward (aa0354f6).
Now: gate → READ result in a SEPARATE step → commit only if "headless gate PASSED" + 0 failed.

## Pattern that's working (the clean drain lane)
Built-but-unreachable **views** wired to a reachable entry: a `showX()` DocumentModel method →
`openHostedView(...)` (host-testable: a hosted tab opens) + a File-menu item + a command verb
in BOTH `ScriptVerbDispatch` AND `ScriptVerbCatalog` (sync test) + 2 host wiring tests; the
Canvas/SwiftUI render stays review-ceiling. Scan caveat: a view with a same-file WindowController
(e.g. SettingsView) is a FALSE "0 callers" — verify before wiring.

## Owner-gated (parked, do not block on)
- **Scroll (TSK-1046, parked)** — warm-cache fix on worktree `a7063b42`, test build was on
  `/Applications`. Editor scroll is UNVERIFIABLE by any agent (the editor-scroll automation verb
  is a no-op, TSK-1200) → owner's eyes only. If owner confirms → merge a7063b42; else drop.
- TSK-1189 trust-HTML (built, review), TSK-1195 render-verify approach.

## Next actions
1. Commit TSK-1112 on gate-green; record fixed + CHANGELOG; file the walkthroughs follow-on.
2. Continue the curated drain. Remaining curated clusters: P0 perf (598/591/891/838 — need VM
   Instruments traces, measure-don't-guess), action-history backend (TSK-703), notebook (717),
   CSV cursor (1102), then the board's groomed pools.
3. Keep `main` headless-gate-green; one item per tick; never idle.

## How to resume
1. `git -C <cwd> log -1` + `git status --short`.
2. Check any in-flight gate log under `/tmp/*-gate.log` (e.g. `extinv-gate.log`).
3. `CronList` — confirm `994c7c56` armed; if gone, the owner stopped it (then go owner-driven).
4. Pick the next curated item per `docs/TASK_WORKFLOW.md` §3 and drain.
