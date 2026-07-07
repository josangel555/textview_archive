<!-- CLAUDE-HANDOFF v1 -->
# Handoff — batch-loop era begins (2026-07-07 ~06:00)

**cwd (canonical):** /Users/me/Documents/workspaces/claude/markdown_viewer — MOVED BACK
2026-07-07 (Desktop&Documents iCloud sync verified OFF; plain local folder). ⚠️ If that sync
is ever re-enabled, relocate out of ~/Documents first. main @ f12cc06e + B1 WIP uncommitted.

## Mission
Drain the ticket board via the owner's 2026-07-07 BATCH WORK-LOOP: 25 pre-sorted batches
(~175 tickets) in BACKLOG.md §THE BATCHES, executed 5–15 related items per batch, one gate +
one commit + one board-record pass PER BATCH. PURE AUTONOMY: no inline questions — every
decision/approval = task_park "Need me" gate with homework, then move on. After the batches:
drain review/fixed with fresh evidence, then the reported pool (BACKLOG §AFTER THE BATCHES).

## Current state
- **B1–B9 ✅ ALL CLOSED** (every ✅ block in BACKLOG §THE BATCHES carries commits + gate
  evidence). Day highlights: 8 Swift twins deleted (Stage A fully ON; Stage B done minus
  find TSK-1549 + hex TSK-810) · frame-cap blank-grid P1 found+fixed · CSV save flow
  shipped · mdv CLI + self-healing MCP bridge · remote-core groundwork (assets/WS/schema
  + daemon design, slices 1553–1558) · who_calls + the async MCP lane · LSP RCE guard
  ENFORCED · secret detector core · bounded test runner.
- **B10–B16 ✅ · B17 ⛔ AGENT-BLOCKED (AX-driven tier, the sole off-limits lane; ElementRef host
  cores done) · B18 ✅ AGENT-COMPLETE (IMG model ~166 tests; 1320 parked owner a/b/c) · B19 ✅
  (1442) · B20 ✅ (1196) · B21 ✅ AGENT-DONE (891 ScrollSweep prep e3c462db; rest VM-blocked on
  1550+1540 parked) · B22 ✅ · B23 ✅ (board honesty: 1514 umbrella reconcile + 1412 sweep; 379/538
  restated, 651 commented).** B24 ✅ (1169) · B25 ✅ AGENT-DONE (sanitizer-policy single-source
  89b02eee). ALL 25 BATCHES ✅✅✅ → the loop is now in §AFTER THE BATCHES: (1) drain review+fixed
  with fresh evidence [OWNER validates; agent surfaces fresh-evidence comments], (2) triage/work
  the reported pool, (3) re-curate. DRAIN TICK 1: reconciled 2 stale-reported-but-DONE items
  (955 RSS/Atom feed reader fully built incl. OPML import/export → fixed; 589 session-eviction
  SUPERSEDED by the B1 doc_registry EvictionBudget → fixed, value-default note 512/64-vs-1.5GB/200
  left for owner). FINDING: the reported pool's clean host cores are DRAINED after 25 batches —
  it's now dominated by owner-gated (810/831/835/852/508), epics/spikes (691/697/703/706/715/
  764/943-945/956), and VM-perf (598/838/837). Drain work = board-honesty reconciles + no-dep
  foundations under owner-gated decisions + host slices under render-tail features. DRAIN:
  T2 DotGraphOutline (cece2c21, no-dep .dot outline foundation; 508 owner-decision parked).
  T3 GalleryShape (a6908fb7, TSK-1085 Win7 shape-vertex geometry). T4 TerminalPanelEdgeBridge
  (0fc30672, TSK-1123 terminal↔panel edge bijection). T5 PaletteCandidates.merge + Candidate-
  Cache (160fb335, TSK-1179 per-keystroke merge dedup + generation memo). T6 ChangeClassifier
  (464e7c89, TSK-1195a — the host-vs-render "false-done killer": classify(paths:)→hostProvable|
  renderPath|needsVM + aggregate hostCertifiable flag; 11 tests). T7 MenuOrganizer (31b4ce13,
  TSK-1318 — flat command list → category-ordered menu sections; 8 tests). T8 NotebookOutputParser
  (54612246, TSK-1440 — parse .ipynb cell outputs to typed .stream/.text/.image/.error/.unknown;
  9 tests). T9 OutputNaming (25a73b37, TSK-1473 — reusable collision-safe "never overwrite; write
  a sibling" primitive; 8 tests). T10 SALVAGE INTEGRATION START (284aac73, TSK-1447 via TSK-1506):
  cherry-picked salvage commit 2b40e78e (HTTP history/save, HTTPRequestStore) — CLEAN, central gate
  GREEN (27 tests). KEY FINDING: the 9 worktree-wf_dadf7ab6-e88-* branches are REAPED but their
  commits SURVIVE in the object DB (cat-file resolves) — recipe = cherry-pick SHA→central gate→
  commit, ONE per tick. Remaining complete commits on TSK-1506: 56e5600e install-naming(1498),
  7684fd36 lens-table(1467), 4577ce95 feeds-loop(1446), f5c9d73f mermaid-err(1466,WebView), 58f0a775
  sqlite-export(1439), 05506d01 invisibles(1484) + 9 WIPs. Pattern: drain tick = extract one pure
  host core OR integrate one salvage commit, central-gate it, record. 1550/1334 = the two VM unlocks.
- VM-DEFERRED pool (all on TSK-1550): B7's 1527/1531/1532 · merge tails 1269/1165/1166 ·
  1203 trust-banner · B3's WV slice + TSK-1551 render suites · 1331 history-revert.
- NOTE for owner: the self-healing MCP bridge + RCE prompt take effect after the next
  INSTALL + Claude session restart. Shadow-net S5/S6 gate: MDV_RUST_DOCSTORE=shadow, div=0.
- Cron armed: job 12fe9636, every 5 min (2-57/5), SELF-SUFFICIENT prompt (survives compaction;
  DIES if this session exits — re-arm with the same prompt from BACKLOG mandates).
- Done this weekend (all recorded on board): S1 EditorSession 8e2771d8 (TSK-1516) · MCP-into-
  running-app TSK-1544 + NDJSON framing TSK-1545 (validated) + canvas font TSK-1546 + stale-link
  build guard TSK-1547 · fold gate ON · formula edit box TSK-1215 · four testing MANDATES +
  policy epic TSK-1524 + AX epic TSK-1543 · 200-queue curated · repo RELOCATED out of iCloud.
- Fresh app installed 2026-07-07 05:09 from THIS repo (socket listener + font fix linked).
  Owner still to relaunch TextView + run the validation look (list in BACKLOG §FOR THE OWNER).

## Key decisions
- Owner 2026-07-07: hyper-efficiency batching (no per-item gates/commits/validation);
  task_validate FORBIDDEN while batches remain; owner validates separately.
- Fable/XL window ends ~2026-07-08: [XL] batches (B1/B7/B25 + XL-flagged items) are
  XL-preferred; workers take non-XL batches.
- Repo location: canonical = ~/Documents/workspaces/claude/markdown_viewer (moved back after
  sync-off verification); backup copy at /Users/me/Local_Docs/local_workspace/markdown_viewer;
  icloud-backup remote = CloudDocs copy.

## Gotchas (full list LESSONS.md — tail has the fresh ones)
- Fresh clone lacks tmp/ + rust-core/link/*.a: `mkdir -p tmp` + `bash scripts/build-rust-core.sh`.
- ~/Documents is a plain LOCAL folder now (sync OFF, probe-verified); full-tree ops on the
  CloudDocs tree (~/Library/Mobile Documents/...) still wedge — clone/copy, don't traverse.
- Stale-rust-link class is now guarded (build deletes link products on .a change + bundle-time
  STALE LINK tooth) — trust the tooth, not `strings`.
- MCP framing: NDJSON per spec + Content-Length for tooling; validate protocols with
  spec-shaped clients.

## Tracker
All current. Fixed-this-weekend: 1215/1508/1516/1544/1546/1547 (+1545 validated). Queue
tickets carry worker-ready contracts. Owner gates: BACKLOG §OWNER ONE-WORD UNBLOCKS.

## How to resume (cold)
1. cd /Users/me/Documents/workspaces/claude/markdown_viewer && git log --oneline -5 && git status.
2. Read BACKLOG.md §WORK-LOOP MANDATE + §THE BATCHES; this file for the in-progress marker.
3. Continue the in-progress batch, else take the topmost eligible batch (XL rule above).
4. Per batch: implement all → one gate (scripts/test-headless-gate.sh; + rust gate if touched;
   TSK-1499 bench rule) → batched WV/T4/T5/AX; VM lane only if render changed → ONE commit
   (all TSK ids + Claude-Session trailer) → board to fixed as a batch → ✅ items in BACKLOG →
   update THIS file's "Batch in progress" line.
5. If the cron died (session restart): CronCreate every-5-min with the prompt mirrored from
   BACKLOG §WORK-LOOP MANDATE + §PURE AUTONOMY + §AFTER THE BATCHES.
