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
  the reported pool, (3) re-curate.
- **DRAIN PHASE (T1-T24), all committed + gated — compact log:** T1 reconciles (955 feed-reader
  DONE, 589 eviction SUPERSEDED). Host cores: T2 DotGraphOutline(508 parked) · T3 GalleryShape
  (1085) · T4 TerminalPanelEdgeBridge(1123) · T5 PaletteCandidates+Cache(1179) · T6
  ChangeClassifier(1195a) · T7 MenuOrganizer(1318) · T8 NotebookOutputParser(1440) · T9
  OutputNaming(1473) · T14 changed_region_between(1522 S7 reload-diff). SALVAGE (TSK-1506,
  T10-12): 4 landed verified (1447 HTTP-history 284aac73 · 1467 lens-table · 1498 install-naming ·
  1439 SQLite-export 96984d9e); 1446 feeds ABORTED-SUPERSEDED (main evolved — CHECK MAIN before
  cherry-picking); remaining: f5c9d73f mermaid(1466, VM-only) + 05506d01 invisibles(1484) + 9 WIPs
  (verb-adders conflict on ScriptVerbCatalog/Dispatch/CommandRegistry — keep-both). ✅ TSK-1559 MCP
  gate-wedge FIXED T13+T17+T18 (reader fd-cache + send raw-write(2) + 25→8&loud-fail watchdog;
  full gate GREEN; production win: both FileHandle close-race crashes killed; recurrence now FAILS
  LOUDLY not hangs). DAEMON EPIC T15-T24 — ALL SIX slices have cores + key wiring: s1 socket-
  activation+plist+--with-daemon (6c083f95+4b702938; mdv-serve NOT bundle-embedded — 30MB vs 80MB
  cap — installs to ~/Library/Application Support/MarkdownViewer/bin/) · s2 idle-exit core+ticker
  (3b4a5402+e90e6593, launchd-gated, CLOCK-FREE ACTIVITY_GEN) · s3 retire arbiter (c0ae3043) · s4
  ReconnectBackoff (f32d6c5c) · s5 CoreTransport lib+bin split (fbb81053, both-arm contract tests)
  · s6 web markdown-via-seam slice1 (ffafcc73). T25: retire WIRING done
  (ed9ff36a — skewed-NEWER client gets a one-frame retire grace; older keeps the immediate hard
  close; attached-client registry + exit watcher; 2-connection socketpair integration test; 66
  serve tests; gate GREEN). Daemon tails left: TUI consumer refactor · web per-family WIRE
  METHODS (multi-slice) · launchctl bootstrap live smoke. T26: FileResurrection (05b01c4b,
  TSK-1500 — resurrect-a-deleted-file from Local History: O_CREAT|O_EXCL never-overwrite,
  workspace-fenced incl. sibling/../ traversal, parent recreation; 8 tests; entry-point UI =
  render tail). Gate ran GREEN one-pass again (1559 fix holding). T27: ArchiveEntryPreview (0c1b067a, TSK-1469 —
  bytes→preview classification: magic-sniffed images, 2MiB peek cap w/ truncated text peeks +
  torn-UTF-8 trim, binary guard, corrupt→unreadable mapping; 10 tests incl. real-zip e2e; pane +
  Extract-via-OutputNaming = render tail). T28: SettingsCatalog (8ff19739, TSK-1481 — the Settings
  IA as a host-tested model: 22 rows, canonical 8 sections, filter(); DRIFT GUARD parses the live
  SettingsView AX ids so a new row can't skip the catalog; view re-render = tail). T29:
  favorites-editor CRUD (8c659632, TSK-1475 — rename+move added to TerminalFavoritesStore,
  completing add/rename/reorder/delete; 3 tests appended to the EXISTING suite; editor UI = tail). T30: ClaudeMonitorListState (fe8d5e2b,
  TSK-1477 — empty-state classification rootMissing/notAClaudeDir/noTranscripts + refresh
  fingerprint w/ no-op-poll guard; 6 tests incl. e2e vs the real index scan; pane/timer = tail). T31: VideoPlayability (f7d065f9,
  TSK-1474 — native-vs-fallback second gate after FileCategory.video routing, failure-asymmetry
  design, drift guard vs the live extension set; view branch = VM tail) + TSK-1471 LogPatterns
  spiked+PARKED (premise stale — engine done; recommended FINISH ~S click-to-filter). Need-me
  queue now 8. T32: PluginLifecycle (09fd4be3, TSK-1478 — install validate-before-copy + dup
  refusals; remove w/ injectable Trash-default remover; 6 tests incl. full cycle vs the real
  registry; pane UI + trust prompt = render tail). T33: DependencyGraphInteraction (d5600a26,
  TSK-1470 — hit-test nearest-wins, zoom/pan Transform w/ anchor-fixed pinch contract + clamps,
  fit-to-view, >300 cap; 11 tests incl. composed click-through-transform; gestures = render tail). T34: OutlineNavigation
  (490a2a97, TSK-1438 — scroll-highlight binary search + keyboard stepping w/ edge semantics +
  diacritic filter w/ preserved indices; 7 tests; panel binding = VM tail) + TSK-1449 surfaces
  spiked+PARKED (pair-1 FALSE overlap→rename; pair-2 unify entry keep engines; pair-3 ratify
  existing 1191/1533 plan). Need-me queue now 9. T35: FirstRunExperience (dc6950d9, TSK-1448 —
  one-shot offer + self-demonstrating sample doc (feeds the real outline extractor) + writeSample
  via OutputNaming never-overwrite; 4 tests; launch wiring + Help entries = render tail).
- RUST GOTCHAS: cargo needs --manifest-path rust-core/Cargo.toml · clippy denies indexing_slicing/
  Instant::now (Clock-port; iterators+saturating_sub) · one-unsafe-op-per-block · `gen` RESERVED in
  edition 2024 · new ffi module trips the cbindgen staleness check (build-rust-core.sh restages) ·
  TSK-1541 rust-coverage BLOCKED on llvm-tools download timeout (wire when network/VM allows).
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
