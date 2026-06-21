<!-- CLAUDE-HANDOFF v1 -->
# Handoff — autonomous run: ~20 features shipped, build-pool drained  (2026-06-21)

**Session:** claude-mdv (AUTONOMOUS).  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch:** `main` (verify `git log -1`).

## Mode — AUTONOMOUS DRAIN (cron ARMED: `994c7c56`, every 5 min)
Each tick forces reading `docs/TASK_WORKFLOW.md` + the CLAUDE.md SOP + the latest
`docs/CURATED_TASKS_*.md`, then drains. Discipline that's working: **front-load ONE
focused spike (what already exists) → build → host-gate → commit per item**; never
commit in the gate's shell compound (read the verdict first); land rebase+ff.
Commit trailer ``.

## Shipped this run (all gate-green on main, ~20 items)
Reachable views/Settings: **Dependency Graph** (TSK-1100), **Folder Treemap** (506),
**Sessions toggle** (1105), **Extensions list** (1112). Bugs/perf: sidebar cache
**bounded-eviction** (591 cand.3 — `InsertionOrderedCache`), **find-bar keep-text**
(1207), **tooltip delay** (1209). Features: **New Image** + size/color dialog +
new-file type (1054/1208/1167), **CSV cell cursor** (1102), **awaitUser reply UI**
(1115), **Walkthroughs browser** — browse/run/resume/rename/delete (1107 + 1211),
**gated notebook viewer** (717, off by default). Rust: **eviction-policy core +
CoreRuntime registry** (589 slices 1+2, host-validated). Filed: **TSK-1210**
(VM 6.1.2 forward-compat broken by RustCore remote-core cycle — owner decides
toolchain-bump vs source-fix vs drop). Reconciled already-built: 1143 (search
palette = CommandPaletteView), 1115-handler.

## ⚠️ The build pool is DRAINED — what's left + WHY it's blocked
Verified: no clean "built-but-unreachable view" wires remain (the deps-graph
pattern is exhausted). Remaining work is one of:
- **OWNER-GATED (the real bottleneck):** `task_next` head = **TSK-590** perf cluster
  (review-lane epic). Children **591** (hover-lag cand.1 tracking-area density),
  **592** (resize jank), **598** (MD-open — measured 94% WebKit), **601** (Swift-open)
  need a LIVE counter read / on-screen re-feel / approval — agent can't progress.
- **RISKY-BLIND RENDER refactors:** image off-main render (1049), single-surface
  sidebar hover (591 cand.1), paint gesture (1101) — central/hot views, felt-perf is
  VM-only; "don't ship risky blind" ⇒ these need a VM-validated pass, not a host tick.
- **OWNER-INPUT:** 709 (Cmd+K/G unify scheme), 751 (menu org — subjective).
- **BACKEND builds:** ActionHistory (703 — needs invasive recording hooks),
  notebook editing/kernels (717 epic tail).
- **Flag-WIP:** RichText (off-by-default).

## ⚠️ Review backlog needs the owner / a VM-UAT pass to reach DONE
The ~20 shipped items are at **fixed/review** — their MODELS are host-tested but the
RENDER (menus/dialogs/views/pixels) is unconfirmed (review ceiling). They reach
`validated`/`done` only via the owner on-screen OR a VM GUI/UAT pass
(`scripts/test-in-vm.sh all` + the run-uat skill). This is the biggest lever for
"every task to done".

## How to resume
1. `git -C <cwd> log -1`; `CronList` (confirm `994c7c56`).
2. Pick a SAFE item: another gated/foundation slice, OR a board reconcile/triage
   (front-load-spike reported items → reclassify already-built). AVOID blind-building
   the risky render refactors; they want VM validation.
3. Process note for future me: I over-deliberated several late ticks (scanning for
   "the perfect clean pick" when the pool is drained). Decide FAST: if no clean
   host-completable build in one spike, do a reconcile/triage drain — don't burn a
   tick scanning.
4. When the owner returns: the highest-value asks are (a) re-feel/counter-read the
   TSK-590 perf cluster, (b) confirm/VM-UAT the review backlog → validated.
