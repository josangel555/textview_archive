<!-- CLAUDE-HANDOFF v1 -->
# Handoff — batch-loop era begins (2026-07-07 ~06:00)

**cwd (canonical):** /Users/me/Local_Docs/local_workspace/markdown_viewer · **main @ 6943cee1**
(gate-green) · session cwd may be the OLD iCloud husk — NEVER work there.

## Mission
Drain the ticket board via the owner's 2026-07-07 BATCH WORK-LOOP: 25 pre-sorted batches
(~175 tickets) in BACKLOG.md §THE BATCHES, executed 5–15 related items per batch, one gate +
one commit + one board-record pass PER BATCH. PURE AUTONOMY: no inline questions — every
decision/approval = task_park "Need me" gate with homework, then move on. After the batches:
drain review/fixed with fresh evidence, then the reported pool (BACKLOG §AFTER THE BATCHES).

## Current state
- **Batch in progress: NONE. Next: B1 [XL] stateful core (1517/1518/1519/543/fuzz)** — B1 is
  XL-tagged; a non-XL model takes B2 (CM6 P0 bugs — diagnoses on the tickets) instead.
- Cron armed: job 0b3ac1c3, every 5 min (2-57/5), SELF-SUFFICIENT prompt (survives compaction;
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
- Repo relocation: canonical = Local_Docs (non-iCloud); icloud-backup remote = CloudDocs copy.

## Gotchas (full list LESSONS.md — tail has the fresh ones)
- Fresh clone lacks tmp/ + rust-core/link/*.a: `mkdir -p tmp` + `bash scripts/build-rust-core.sh`.
- iCloud husk at ~/Documents/...: never work there; full-tree ops on CloudDocs wedge.
- Stale-rust-link class is now guarded (build deletes link products on .a change + bundle-time
  STALE LINK tooth) — trust the tooth, not `strings`.
- MCP framing: NDJSON per spec + Content-Length for tooling; validate protocols with
  spec-shaped clients.

## Tracker
All current. Fixed-this-weekend: 1215/1508/1516/1544/1546/1547 (+1545 validated). Queue
tickets carry worker-ready contracts. Owner gates: BACKLOG §OWNER ONE-WORD UNBLOCKS.

## How to resume (cold)
1. cd /Users/me/Local_Docs/local_workspace/markdown_viewer && git log --oneline -5 && git status.
2. Read BACKLOG.md §WORK-LOOP MANDATE + §THE BATCHES; this file for the in-progress marker.
3. Continue the in-progress batch, else take the topmost eligible batch (XL rule above).
4. Per batch: implement all → one gate (scripts/test-headless-gate.sh; + rust gate if touched;
   TSK-1499 bench rule) → batched WV/T4/T5/AX; VM lane only if render changed → ONE commit
   (all TSK ids + Claude-Session trailer) → board to fixed as a batch → ✅ items in BACKLOG →
   update THIS file's "Batch in progress" line.
5. If the cron died (session restart): CronCreate every-5-min with the prompt mirrored from
   BACKLOG §WORK-LOOP MANDATE + §PURE AUTONOMY + §AFTER THE BATCHES.
