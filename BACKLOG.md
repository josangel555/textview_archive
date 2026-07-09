# Backlog — PENDING ONLY · cleaned 2026-07-07 post-run (owner ask)

> Board (http://localhost:8787/) is the system of record for STATE; this file is the pre-sorted
> selector. `task_get` any TSK before working it — the board moves, this file lags.
> DONE history: `archive/BACKLOG_batches_2026-07-07.md` (the B1–B25 ledger) +
> `archive/BACKLOG_archive_2026-07-07.md` (+ 2026-06-27). Repo (canonical):
> `/Users/me/Documents/workspaces/claude/markdown_viewer`.
> ⚠️ If Desktop&Documents iCloud sync is EVER re-enabled, relocate the repo out of ~/Documents FIRST.

## WORK-LOOP MANDATE (owner, 2026-07-07 — standing)

Work the queue top-down in BATCHES of related items — no loop-time re-prioritizing. Per batch:
implement ALL items (code + unit tests) with only targeted checks between items → ONE full gate
pass (headless + rust gate if touched; TSK-1499 bench rule) → batch the higher-order tests →
ONE commit (all TSK ids + Claude-Session trailer) → board records as a batch with one shared
checks artifact. NEVER `task_validate` (owner validates). Blocked ⇒ park, take next.

**PURE AUTONOMY — NO INLINE QUESTIONS.** Every question/decision/approval/ambiguity becomes a
BOARD "Need me" gate (`task_park` with homework + recommendation), then MOVE ON.

**★ VM LANE RESTORED (2026-07-09, TSK-1550 fixed).** The macOS15 test VM is reachable again
(host lost its ssh key in the relocation incident; re-enrolled ~/.ssh/id_ed25519, re-pointed
~/.ssh/config). The render/UAT/T5 validation lane is OPEN. The 7 render tails stacked at `review`
this session — 1438 outline · 1474 video · 1469 archive · 1477 monitor · 1478 plugins · 1470
dep-graph · 1475 favorites — can now be UAT-validated: `test-in-vm.sh all` (build_all rebuilds
dist — vm-smoke ships a STALE dist, see LESSONS), then drive each ticket's UAT cases + attach
screenshots. Leave at `review` (owner validates) per the cron mandate.

**OWNER CORRECTIONS (2026-07-07, post-run):**
- Host-workability was a PRIORITY, not a mandate. Render/view code is BUILD-NOW on the host;
  each lands at `review` as "model-fixed, on-screen UNVERIFIED — needs VM". TSK-1550 gates only
  the VALIDATION rung (now OPEN — the VM is back), never the build.
- **UAT CASES ARE ON THE TICKETS** (stamped 2026-07-07): every render-tail ticket carries
  agent-executable UAT cases (MCP/AX/screenshot-driven). The agent MUST execute them (VM lane,
  or AX where applicable) and attach the evidence BEFORE claiming the ticket complete.

## THE PENDING QUEUE

### 1 — RENDER/VIEW TAILS: BUILD NOW (models tested; UAT cases on each ticket)
Work top-down; land at `review` flagged UNVERIFIED; VM-validate as one batched sweep later.
- Fresh models (this run): 1438 outline panel binding · 1477 monitor pane · 1478 plugins pane ·
  1481 settings re-render · 1475 favorites editor UI · 1469 archive preview + Extract · 1474
  video fallback branch · 1470 dep-graph gestures · 1448 first-run wiring + Help entries · 1500
  resurrection entry point · 1085 Win7 shape picker · 1123 terminal Settings row · 1440 notebook
  outputs render · 1318 menu-bar-from-catalog tail · 1496 secret badge/mask · 1480 footer chip ·
  1489 omnibox view · 1340 palette param UI · 1249 terminal header row · 1476 help popover ·
  1495 archive sidebar wiring · 1158 flame-chart canvas.
- Older pool: 1104 second window · 1111 bookmarks-window · 1114 paint selection UI · 1165
  external-edit merge UX · 1168 vector editing · 1170 snippets tab-stop · 1171 3-way merge UI ·
  1172 notebooks kernel · 1173 sticky scroll · 1203 trust-mode banner · 1205 extracted-doc grid ·
  1443 git panel · 1444 LSP status · 1445 CR journey · 1441 image-editor feel · 1319 dynamic
  menu · 1482 menu audit · 1488 FPS instrumentation · 1494 cursor mode · 1466 mermaid errors
  (salvage f5c9d73f) · 1484 invisibles residue (05506d01).
- Web surfaces: 1527 M3 CSV grid · 1531 M7 hex grid · 1532 M8 transcript streaming · 1530 M6
  default-flip parity · 1528 M4 xlsx · 1529 M5 docx · 1533 M9 history (rides 1191).
- Perf traces (measure on VM): 838 DOM-patch page (closes 598) · 891 Page-Up jank · 1180/1184/
  1185/1047 · 1382/1490 attribution runs.

### 2 — OWNER-GATED (one-read decisions; homework attached on each)
Need-me cards: 508 dot-view · 1149 feeds UI · 1155 action-history architecture · 1200
editor-scroll real-vs-harness · 1315 key-routing approach · 1322 paste repro · 1413 menu
eyeball · 1426 paint persistence · 1449 surface consolidation · 1471 log-patterns finish-or-cut
· 1502 remember-lens flip · 1540 WV-on-host · 1549 find-regex expressiveness.
Deps/opt-ins: @codemirror/merge (M1/M2) · 810 hex carve-out · 835 nextest · 852 CI cache ·
831 index-dedup · 1137 cargo-mutants · 1287 crypto dep · 1138 Tier-D ratify · 1182 diff-selection
ratify. Supervised sessions: 1520/1521 (S5/S6 cutovers, ≈2.5–3.5h). Product/scope: Canvas M0–M6
review + 1349 · 1468 formula audit · 1491 sessions model · 1492 git visualizer · 1497 far-future
· 683 app name · 686 Developer-ID · 470 zoom split. MASTER UNLOCKS: **1550 VM restore** ·
**1334 T5 Screen-Recording grant**.

### 3 — EPICS / DESIGN-FIRST (spike auto-approved; several XL)
691 agent-harness · 703/1155 action-history · 706/1156 richtext WYSIWYG [XL] · 713/1157
PlantUML/D2 renderers · 715/1158 profiling remainder (memory diffs, composition charts) · 764
git-reconcile · 956 + 1091–1096 AU hosting · 1048 children image-parity P5/P6 (1055 undoable-
paint arch slice) · 1108/318 CR Q&A · 1117 + 1509–1512 rust H-B ports (spike-gated) · 943–945
agent integrations · 1147 dep-source · 1214 lazy grammars [XL] · 1164 language matrix ·
1523 S8 remote parity · 1507 s4/s5 rust-port tails · 1524 policy umbrella.

### 4 — INFRA / FOREIGN / AX
AX tier (owner-declared off-limits to the agent): 1543 matrix · 1197/1198/1199 UAT framework ·
1261/1263/1264/1265/1266 ElementRef live slices · 1200. VM infra (needs 1550 first): 1542
Sequoia nag · 1239 fd exhaustion · 1247 webview-blank · 1365 WebContent hardening · 1336.
tasked-tool/CI: 441–445 · 1329/1330 INT items. Docs: 1513 roadmap · 590 owner bug-list ·
FEATURE_INVENTORY refresh · design-docs archive sweep. Salvage remainder: 1506 (wf-1/2/3/4/8/9
WIPs — verify vs main first; wf-5/6/7 SUPERSEDED, do not integrate). 1541 rust coverage
(llvm-tools download blocked twice — retry on network).

## FOR THE OWNER'S VALIDATION LOOK (excluded from the agent work queue)
The `fixed` lane (123 items, checks attached) · TSK-1544 live-app MCP E2E · TSK-1546 font
eyeball · Canvas fixed-slices 1372/1374–1379/1360/1392 · the review pile (~216) · 924/1141/
1152/1327/1331 review-lane items.

## Living analyses (pointers)
WebUI surface-sharing → TSK-1507 · rendering-stack policy → TSK-1524 · whole-core migration →
TSK-1117 + docs/research/stateful-core-spike-2026-07-04/DESIGN.md · agent services →
docs/AGENT_SERVICES_DESIGN_2026-07-07.md · daemon lifecycle → docs/DAEMON_LIFECYCLE_DESIGN.md ·
meta-analysis → docs/research/project-meta-analysis-2026-07-04/SYNTHESIS.md · usability →
docs/FEATURE_INVENTORY.md · Stage-B UAT → docs/STAGE_B_DELETION_UAT_2026-07-04.md.
