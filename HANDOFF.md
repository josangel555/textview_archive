<!-- CLAUDE-HANDOFF v1 -->
# Handoff — usability-queue drain (2026-07-03)

**cwd:** /Users/me/Documents/workspaces/claude/markdown_viewer · **branch:** main (keep gate-green)

## Mission
App-wide PRODUCTION-GRADE usability (owner recalibration: **built ≠ usable** — editor/vim/file-nav
work; everything else needs the end-user layer). Umbrella epic **TSK-1411**. Canvas M0–M6 is
COMPLETE + **PARKED** — do not build. Cron STOPPED — owner-driven sessions; work INLINE, one
ticket at a time (no subagent batches unless the owner asks; never commit while a subagent runs).

## The four load-bearing docs (read on demand, not wholesale)
- `docs/FEATURE_INVENTORY.md` — THE feature hierarchy + per-family Built/Logic/Usable + gap-ticket map.
- `docs/USABILITY_VALIDATION_PROTOCOL.md` — evidence rungs; implement = host tests+teeth+command-path
  → `fixed`; e2e/VM/UAT is a DEFERRED pass; batch queue table.
- `docs/WISHLIST_RECONCILE_2026-07-02.md` — OwnerWishlist ↔ board map; gaps = TSK-1483..1497.
- `docs/FOCUS_ROUTING.md` — rules for any imperative editor/pane channel.

## Current state
- **Done + verified:** Batch 1 (1483 focus-routing fix, 1435 empty states, 1436 ToastCenter,
  1479 paste toast, 1437 shortcuts) and Batch 2 (1461 snippets, 1462+1331 local history,
  1463 tree ops, 1464 bookmarks, 1465 cross-search) — all on main, gate PASSED clean.
- **IN FLIGHT:** ultracode workflow `wf_dadf7ab6-e88` — 9 Opus agents in isolated WORKTREES,
  ~43 tickets (families: data/viewing/media/git-lsp/term-search/web-auto/chrome/editor-safety/
  perf-theme). Agents commit per-ticket on their worktree branches, board→`fixed`, no
  CHANGELOG/HANDOFF edits, append-only on shared registries.
- **NEXT ACTION when workflow completes:** integrate INLINE — per family branch: rebase onto
  main → run `bash scripts/test-headless-gate.sh` (FoldBench/MsgPack wall-clock flakes under
  load don't count if green in isolation — TSK-1499) → `git merge --ff-only` → next branch.
  Then: consolidated CHANGELOG roll-up, reap worktrees (`git worktree unlock/remove/prune`,
  drop merged branches), board reconcile, fresh release build (`build-app.sh release --install`).

## Reuse, don't reinvent
`ToastCenter.shared` (async feedback) · `EmptyStateCatalog`/`HostedEmptyStateView` ·
`ToolResults`/`ToolResultsPanel` · command-path test pattern =
`Tests/ViewerUITests/ToolResultsPanelIntegrationTests.swift` (HeadlessHarness + ScriptVerb.apply).

## Owner-gated queue (don't build; surface when relevant)
TSK-1334 pixel/AX grant · TSK-838 DOM-patch flip (THE felt-latency fix) · finish-or-cut
1414/1418/1471/1491 · formula gate 788/1215 · hex-edit 1423 · paint persistence 1426 ·
git visualizer 1492 · far-future 1497 · Canvas review.

## Gotchas (full list in LESSONS.md)
- Rebuilding `rust-core/link/*.a` does NOT relink SwiftPM — `rm -rf .build/*.xctest` to force.
- Fresh worktrees lack the gitignored staticlib/header — run `bash scripts/build-rust-core.sh` first.
- Background gate tasks: judge by the `GATE_DONE rc=` marker in the log, never the task exit code.
- Never `killall MarkdownViewer`; no UI tests on the host; VM = `scripts/test-in-vm.sh` (see CLAUDE.md).

## How to resume cold
1. `git log --oneline -15` + `git status` (expect only owner's untracked files).
2. Check `/workflows` (or board `fixed` records from agents `claude-mdv-w*`) for workflow state.
3. If workflow done → integration steps above. Otherwise → next inline ticket from
   `docs/USABILITY_VALIDATION_PROTOCOL.md` batch table, per-slice loop: verify-first →
   implement → tests+teeth → targeted filter → gate → commit (trailer: Claude-Session link) →
   board restate/triage/claim/record→fixed.
