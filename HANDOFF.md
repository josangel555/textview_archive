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
- **B1 ✅ · B2 ✅. Batch in progress: B3 twin deletions — fuzzy ✅ (55470d33), transcript ✅
  (2edb6291), find ⛔ PARKED (TSK-1549 Need-me). NEXT = CSV, recon DONE (map below) →
  CMEditApplier → markdown visitor → folds → B3's ONE full gate + board records.**
  CSV surgery map (verified this tick): CSVParser.Result TYPE survives (UI/adapter contract);
  CSVFilter struct = filter STATE + apply() still LIVE at CSVTableView.swift:160 (check
  whether the session/rust filter path supersedes before touching); two non-adapter parse
  callers to retarget: JSTransform.swift:117 (plain — adapter-ready) and
  ClipboardTableExtractor.swift:141 (FORCED delimiter "\t" + custom Limits — core HAS
  parse_arena_with(text,delimiter,limits) at csv.rs:158 but it is NOT wire-exposed: add an
  optional {delimiter,limits} to the csv parse wire first, then retarget, then delete
  CSVParser's algorithm). Pattern: keep TYPES, delete algorithm, adapter → runRustOnly
  (.degradedRustFault), retire A/B+differential suites, keep behavior pins.
  Shadow-net run gate for S5/S6: MDV_RUST_DOCSTORE=shadow; divergenceCount stays 0.
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
