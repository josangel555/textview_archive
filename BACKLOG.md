# Backlog — THE BATCH QUEUE · rewritten 2026-07-07 (hyper-efficiency round)

> Board (http://localhost:8787/) is the system of record for STATE; this file is the pre-sorted
> selector. `task_get` any TSK before working it — the board moves, this file lags.
> Prior curations: `archive/BACKLOG_archive_2026-07-07.md` (+ 2026-06-27). Repo (canonical):
> `/Users/me/Documents/workspaces/claude/markdown_viewer` — MOVED BACK 2026-07-07 after
> verifying Desktop&Documents iCloud sync is OFF (plain local folder now; probe-tested).
> ⚠️ If that sync is EVER re-enabled, relocate the repo out of ~/Documents FIRST.

## WORK-LOOP MANDATE (owner, 2026-07-07)

Work BATCHES top-down, exactly as pre-sorted below — no loop-time re-prioritizing.
Per batch: implement ALL items (code + unit tests) in one go with only targeted checks between
items → ONE full gate pass (headless + rust gate if touched; TSK-1499 bench rule) → batch the
higher-order tests (WV/T4/T5/AX) for the whole batch — VM UI lane ONLY if render behavior
changed → ONE commit (all TSK ids + Claude-Session trailer) → board to `fixed` as a batch with
one shared checks artifact. NO per-item gates/commits/validation ceremony; NEVER `task_validate`
this round (owner's validation look is separate). Blocked ⇒ park, next. Mark items ✅ here.
[XL] batches = Fable/XL-model preferred (get-right-first-time). [dep]/[owner] = skip until word.

**PURE AUTONOMY — NO INLINE QUESTIONS (owner reinforcement, 2026-07-07).** The agent NEVER asks
the owner a question in chat/inline during autonomous work. Every question, decision, approval,
or ambiguity becomes a BOARD ITEM with a "Need me" gate: `task_park(kind: decision/approval,
question, context, options)` on the relevant ticket (or a new ticket), then MOVE ON to the next
item. Asking inline = a mandate violation. Do the homework first (spike/compare/recommend in the
park context) so the owner decides in one glance.

## FOR THE OWNER'S VALIDATION LOOK (excluded from the work queue)
TSK-1544 live-app MCP E2E (relaunch TextView, then `/mcp`-driven session) · TSK-1546 font
eyeball · TSK-1547 close · Canvas fixed-slices 1372/1374–1379/1360/1392 · the review-pile
(~284) + validated-awaiting-done (~735) · fold/deletion UAT slices as batches land.

## THE BATCHES (execution order)

### B1 [XL] Stateful core S2–S4 + hardening — the forever-ABI (5) ✅ DONE 2026-07-07
✅ TSK-1517 S2 FFI family (doc_registry + ids 18-23 + MDV_CAP_DOC_STORE + eviction 1.5GB/200 +
pinned-dirty law) · ✅ TSK-1518 S3 shadow net (CoreDocStore + CoreDocShadow + CM tap) ·
✅ TSK-1519 S4 verified-snapshot mechanism (snapshot-site wiring = noted follow-up) ·
✅ TSK-543 closed-by-design (1124+1517) · ✅ adversarial no-panic proptest. Both gates green.

### B2 CM6 editor P0 bugs ✅ DONE 2026-07-07 (batch collapsed on recon)
✅ TSK-1252 vim Esc-beep swallowed (keymap after vim() consumes no-op normal-mode Esc; bundle
pin test) · ✅ TSK-598 reconciled → rides TSK-838 (B22; ~334ms CA-commit root on record) ·
TSK-891 → moved to B21 (measure-first per its own diagnoses) · 910 was already validated ·
1200 owner-parked · 1188/1271 review lane · 1032 validated.

### B3 Stage-B twin deletions (7) — per docs/STAGE_B_DELETION_UAT_2026-07-04.md
FuzzyMatcher · FindEngine · ClaudeLogParser · CSVParser/CSVFilter · CMEditApplier · markdown
structural visitor · TreeSitterEngine folds. (hex pair waits on TSK-810 [owner]; formula waits
on the flip after B6.) One deletion-batch commit + one UAT batch.

### B4 Mandate guards + hygiene teeth (7)
TSK-1539 surface catalog + matrix guard [XL semantics] · TSK-1534 webview allowlist guard ·
consumption-guard extension to RustFoldAdapter-class adapters · TSK-1535 warnings burn-down →
missing_docs DENY · TSK-1548 progress-log rotation + budget · TSK-1499 fold-bench re-budget ·
TSK-1501 hard-coded color sweep (dark-mode teeth).

### B5 Data-grid views — models DONE, wire the views (7)
TSK-924 CSV multi-cell select/copy view · TSK-1139 CSV viewport paging (CSVViewportPager→view;
pre-work for M3) · TSK-1141 xlsx sheet UI + recalc wiring · TSK-1486 grid keyboard nav ·
TSK-1472 CSV edit affordances + save flow · TSK-1515 computed-cell marker · TSK-1205
extracted-doc grid polish. WV/render batch at end.

### B6 Formula finish + spreadsheet (4)
Formula gate flip prep + TSK-1468 editing-UX audit [owner formula-gate word] · TSK-788/1215
spreadsheet-view consumption check · formula UAT batch slice · FormulaEngine deletion (closes B3).

### B7 [XL] Web-migrate wave 1 (4)
TSK-1530 M6 TextDisplayView→CM6 read-only (pattern-prover) · TSK-1527 M3 CSV web grid (rides
B5's paging) · TSK-1531 M7 hex web grid · TSK-1532 M8 transcript/logs streaming lists.

### B8 MCP/CLI/remote tail (7)
TSK-1536 mdv CLI opener · MCP reconnect loop (file the TSK-665 follow-up + fix) · TSK-1507 s1
serve static assets · s2 cmDispatch-over-WebSocket · s3 bridge-schema codegen [XL] · TSK-1537
daemon design doc [XL] · TSK-1192 semantic code-nav MCP tool.

### B9 Security & data safety (7)
TSK-1129 LSP spawn confirm (prompt-first) · TSK-1269 ExternalEditReconciler into dirty-reload ·
TSK-1165/1166 external-edit merge UX + DiskConflict wiring · TSK-343 history Revert data-safety
(unsaved-edit handling) · TSK-1496 secret masking v1 · TSK-1203 trust-mode failure surfacing ·
TSK-1194 resource-bounded test exec.

### B10 Paste & convert cluster (6)
TSK-1322 paste-buggy repro+fix · TSK-1327 smart rich→markdown paste (with 958/1163 dispatcher
UI) · TSK-1427 rich-paste tables/nested lists (IR extension) · TSK-1480 converters show current
state · TSK-1323 extract-audio-from-video · TSK-1324/1325 audio+image format/quality convert
(host ffmpeg per TSK-528; +TSK-1473 presets).

### B11 Chrome/menus/first-run usability (8)
TSK-1319 dynamic per-tab menu · TSK-1481 Settings IA · TSK-1482 menu-bar audit (residual after
the DONE 1318 reorg) · TSK-1489 new-tab omnibox · TSK-1448 first-run tour · TSK-1449 consolidate
overlapping surfaces · TSK-1413 entry-point cohesion residual · TSK-1340 palette param-input.

### B12 Panes/nav/key-routing intake cluster (7)
TSK-1315 key-event routing audit (leaking keystrokes) · TSK-1314 side-nav shows file-nav when
toggled off · TSK-1316 shoulder bars only-on-drag · TSK-1313 remove pane size restrictions ·
TSK-1317 terminal icon drag + setting removal · TSK-1312 terminal colors under claude-code ·
TSK-1249 terminal header row.

### B13 Sessions & windows (6)
TSK-1311 session state independent/persistent/online · TSK-1308 session-switch keeps music ·
TSK-1104 second NSWindow mount · TSK-1111 bookmarks open-in-new · TSK-1152 per-filename view-as
lock · TSK-1502 lens-memory prep.

### B14 Editor features & polish (8)
TSK-1504 cheap editor assists (off-main spell + cached word index) · TSK-1505 spelling verbs
everywhere · TSK-1146 spell/grammar squiggles + LSP diagnostics surfacing · TSK-463/1136 LSP
completion into CM6 [engine] · TSK-1485 edit-location history · TSK-1487 age coloring ·
TSK-1494 cursor mode for view surfaces · TSK-1170 snippets tab-stop nav.

### B15 Dev tools usability (9)
TSK-1443 git panel core loop · TSK-1444 LSP status affordance · TSK-1445 code-review journey ·
TSK-1475 terminal favorites mgmt · TSK-769 terminal UX bundle residual · TSK-1476 structural-
search help · TSK-1477 claude-monitor polish · TSK-1493 run configurations · TSK-1470
dep-graph interactive.

### B16 Reading surfaces & viewers (8)
TSK-1140 PDF reader tail · TSK-1142 browser tab surface · TSK-1145 DOCX/XLSX viewer polish ·
TSK-1147 dep-source browse · TSK-1172 notebooks (1440 outputs first) · TSK-1173 sticky scroll ·
TSK-1469 archive explorers · TSK-1495 archive-as-folder in tree.

### B17 AX build-out + ElementRef (8)
TSK-1260/1261 native AXUIElement adapter + driver · TSK-1263 agent AX harness entry · TSK-1543
verb-slice (top-20) · chips/menu-bar slices · TSK-1264 ElementRef resolver · TSK-1265 Copy-
Reference · TSK-1197/1199 uat-runner + journeys · TSK-1198 close-as-superseded.

### B18 Image editor epic wave (9)
TSK-1048/1049/1055 perf foundation (off-main render, cached CIContext) · TSK-1114 selection UI
(marquee/lasso) · TSK-1168 on-canvas vector editing · TSK-1302 pane-overlap layout · TSK-1303
edit-state reset on session-switch · TSK-1304 hide file-property pane · TSK-1307 canvas resize ·
TSK-1309 remove Draw Box button · TSK-1320 annotations-vs-shapes clarify (+1441 UX pass rides).

### B19 Media & misc features (6)
TSK-1442 audio round-trip verify · TSK-1474 video loop verify · TSK-1091–1096 audio engine/AU
slices (pull 2–3) · TSK-1326 walkthrough authoring path · TSK-1119 walkthrough illustration
overlay · TSK-377 illustrations residual.

### B20 Agent tools & code review epic (8)
TSK-1196 file-ownership dashboard · TSK-943 diagnostics→agent sharing · TSK-944 internal
browser automation · TSK-945 security-audit integration · TSK-318/1108 CR Q&A UI + transport ·
TSK-537 slices ×2 (comments, cumulative diffs) · TSK-373 New▸CR/Agent/Project · TSK-942
select-lines→agent-comment.

### B21 QoL / VM / test-infra (11)
TSK-1542 Sequoia nag storm · TSK-1540 WV-on-host audit · TSK-1541 rust coverage number ·
TSK-1239 VM fd exhaustion · TSK-1247 VM webview-blank · TSK-1365 WebContent-termination
hardening · TSK-1336 walkthrough T5 · TSK-1184 hover-synth trace · TSK-1180 search-scroll trace ·
TSK-1185 git menu latency (+1179 palette trace rides) · TSK-891 Page-Up jank (add vm-profile
scroll mode → trace → measured mitigation; moved from B2).

### B22 Perf & memory (5)
TSK-838 DOM-patch persistent page (build to flip-ready; closes 598) · TSK-1490/382 memory-
release audit + DocumentModel squeeze (mem-profile skill) · TSK-1214 lazy grammars [XL design] ·
TSK-1423 hex unsaved-edit search · TSK-1428 outline false headings.

### B23 Board/docs hygiene (8)
TSK-1513 roadmap revision · TSK-1514 umbrella reconcile (379/538/651) · TSK-1412 board↔code
sweep · TSK-590 owner bug-list re-verify · FEATURE_INVENTORY refresh · dated-design-docs archive
pass (~35 files) · LESSONS→SOP distillation (v4 policy rows) · TSK-441–445 board/CI infra nits.

### B24 Wishes/epics kickoff — pull when B1–B23 drain (8)
TSK-703/1155 action-history view · TSK-706/1156 richtext WYSIWYG v1 · TSK-1157 PlantUML/D2 ·
TSK-1158/715 profiling viewers · TSK-697 agent-services search slice · TSK-1164 per-language
coverage matrix · TSK-1169 ~/.textview relocation · TSK-1171 3-way merge UI · TSK-1488 FPS
instrumentation · TSK-1500 resurrect-deleted-from-history.

### B25 [XL] 1507 WebUI single-sourcing (5)
Sanitizer→core (HTMLSanitizer/HTMLDocumentPolicy parity) · RenderedBlockDiff/BlockPatchJS
collapse into html_patch.rs · assist-policy→core · serve-backed WUI v1 page · canvas-in-WebUI.

## OWNER ONE-WORD UNBLOCKS (not workable until decided)
@codemirror/merge (→ M1/M2 git diff+merge) · TSK-810 hex carve-out (→ hex deletion) · Canvas
M0–M6 review + TSK-1349 M7 scope · TSK-1506 salvage-branch integration resume · TSK-1426 paint
persistence · TSK-1471 log-patterns finish-or-cut · TSK-1491 sessions-model decisions · TSK-1182
diff-selection model ratify · TSK-1138 Tier-D plugin contract ratify · TSK-1137 cargo-mutants /
TSK-835 nextest / TSK-852 CI cache / TSK-831 index-dedup [build opt-ins] · TSK-1287 crypto dep ·
TSK-1129 enforcement mode pick (prompt-first recommended) · supervised sessions for TSK-1520/1521
(S5/S6, ≈2.5–3.5h total, after B1 shadow runs quiet) · TSK-683 app name · TSK-686 Developer-ID ·
TSK-470 zoom split · TSK-1497 far-future scope.

## Living analyses (pointers — full text in git history + tickets)
WebUI surface-sharing → TSK-1507 · rendering-stack policy → TSK-1524 · whole-core migration →
TSK-1117 + docs/research/stateful-core-spike-2026-07-04/DESIGN.md · meta-analysis →
docs/research/project-meta-analysis-2026-07-04/SYNTHESIS.md · usability inventory →
docs/FEATURE_INVENTORY.md · Stage-B UAT → docs/STAGE_B_DELETION_UAT_2026-07-04.md.
DONE history: archive/BACKLOG_archive_2026-07-07.md §✅.

## AFTER THE BATCHES — the loop does not stop
Once every batch above is ✅: the standing goal is unchanged — **DRAIN THE TICKETS**; the
batches were only the curated front of the queue. Continue, in order: (1) the `review` + `fixed`
lanes — re-verify each with FRESH evidence on current main and drain to validated/done per the
standing self-validation policy (checks artifact that would fail on regression; render claims
need their VM/journey slice); (2) the remaining `reported` pool — triage stale/superseded items
closed, work the rest as new batches of related items under the same work-loop mandate;
(3) re-curate: rebuild THE BATCHES from whatever is left and keep going.
