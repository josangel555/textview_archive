<!-- CLAUDE-HANDOFF v1 -->
# Handoff — owner-intake drained + host-engine slices built; host-seam vein drained (2026-06-29)

**Session:** claude-mdv · **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer` · **branch:** `main` @ `5cf36751` (verify `git log -1`)

## Mission
Autonomous drain loop (cron). Work INLINE, one item/firing: read-first → implement → host-test → host-gate (`bash scripts/test-headless-gate.sh`) → commit per item; land rebase+ff; keep main gate-green; fold docs (CHANGELOG/AP/LESSONS) into the item's commit. Cron canonical = `docs/TASK_WORKFLOW.md §7`.

## What shipped this session (all host-tested + gate-verified)
- **Owner intake TSK-1302–1327: 14 → review**, 5 triaged, **2 parked** (TSK-1200 scroll, TSK-1322 paste — both need owner input), 1 spike (TSK-1320 annotations). Earlier commits; see git log + AUTONOMOUS_PROGRESS.md.
- **Host-model/engine slices (7):** TSK-1308 audio-persistence (`52d37b7f`) · TSK-1321 overlay-selection model (`7ff73246`) · TSK-723 structural-query grammar (`694a4700`) · **TSK-698 script console — slice 2 off-main exec (`17845599`), slice 4 log-line input (`bfbcf0d9`), slice 3a controller (`1b8d8049`), slice 4b CSV input (`5cf36751`)**.
- **TSK-698 is now FULLY HOST-COMPLETE**: engine (slice1) → off-main+soft-timeout exec (slice2) → JSON/log/CSV input (slice4/4b) → ScriptConsoleViewModel controller (slice3a). Only the **SwiftUI panel + menu trigger + apply-to-new-tab (slice 3b)** remains = render/VM.
- **Reconciled** stale-lease-reset (INT-126) host-engine epics to their real state: TSK-722 (task-runner, engine done, UI child 1160), TSK-703 (action-history, coordinator done, UI 1155), TSK-910 (diff multi-line, host core done, render child 1182), TSK-723/698.
- **Dogfood:** filed TSK-1329 (task_park needs a clarification kind) + TSK-1330 (task_record artifact status needs a note value) → `docs/TRACKER_FEEDBACK.md`.

## Current state / honest assessment
- The **host-testable-seam vein is DRAINED.** Every epic's host model/engine is built; what remains is **render-VM** (the UI children: 698-3b, 722-1160, 703-1155, 723-1161, 910-1182; the intake render remainder 1302/1310/1316/1317/1318/1319/1326; P0 render 891/1032) → VM lane / owner.
- **Owner-decision-gated:** parked TSK-1200 (scroll: real-bug-vs-harness-false — needs owner's real screen), TSK-1322 (paste repro), TSK-1320 (annotations keep/remove); flips TSK-838/1215/1202.
- VM/owner-only host work: TSK-382 (DocumentModel memory — measure-first VM profile), TSK-379 (rust EditorBuffer — supervised), CI/infra (835 needs a dep).

## ⭐ NEXT ACTION
1. **Re-scan for owner-UNBLOCKED host slices** (the highest-yield pattern this session — TSK-698's exec-safety park was resolved by the owner in a prior session, unblocking 3 host slices). Check epics' parks for owner `resolved` events. (The `audit` tool returned empty even with a wide `since` — read the epic event logs directly via `task_get`.)
2. The **substantial UIs are the VM render lane** (build + T5/webview-validate) or **owner sessions** — NOT blind inline builds.
3. Stale-reset reconcile sweep (board-hygiene) when no host slice is available.

## Gotchas / lessons (also LESSONS.md)
- **Backticks in `git commit -m "..."` trigger shell command-substitution** → mangled message. Use `git commit -F -` with a `<<'EOF'` heredoc (literal), or single-quotes.
- **TSK-1200 / the CM6 + spawned-app scroll "no-ops" are HARNESS-FALSE** (the VM GUI session doesn't framebuffer-composite the WKWebView; the headless in-process WKWebView has no measure/rAF cycle). Do NOT blind-"fix" owner-sensitive scroll code against these — disambiguate real-vs-harness via the owner's real screen or T5 window-ID capture first. (I drafted a requestMeasure fix, caught the LESSONS contradiction, reverted, parked.)
- **Build-render boundary that worked all session:** build render features only through a **host-testable seam** (a view-model / engine / model, host-tested) and leave the thin view at review. Do NOT build large blind multi-file UI integrations (panel + menu wiring + DocumentModel apply-back) with no validatable seam — that's the VM/owner venue.
- **Read-first ALWAYS** — most P0/board items were already fixed→review this session (1188 `c0fd1543`, 1271 `6e9e4efb`) or stale-reset-but-done; don't re-build.

## Tracker (tasked / claude-mdv)
TSK-698 progress (host-complete; 3b render tail) · TSK-722/703/910/723 progress (engines done, UI children) · TSK-1200/1322 parked (owner) · TSK-1329/1330 filed. ~20 commits this run.

## How to resume
Read this + `BACKLOG.md` + `git log -1`. Confirm main gate-green (`bash scripts/test-headless-gate.sh`). The host-seam vein is drained — re-scan for owner-unblocked host slices (NEXT ACTION 1); else the render UIs are the VM lane / owner, and the parked items await owner input. Don't blind-build substantial UI integrations or owner-sensitive scroll/render.
