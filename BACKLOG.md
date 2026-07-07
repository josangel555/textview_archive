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

### B3 Stage-B twin deletions ✅ DONE 2026-07-07 (~−3,300 lines; gate green 9,544 tests)
✅ fuzzy (55470d33) · ✅ transcript projection (2edb6291) · ✅ CSV parser + CsvParseWith wire
id 24 (c32b3480) · ✅ CMEditApplier (ee6f0712) · ✅ markdown visitor + rust `diagram` chunk
closing TSK-713's dot/plantuml gap (4a95b00a) · ✅ folds + queries + cache (78c8e973) ·
✅ TSK-1499 fixed as side effect. KEPT (not twins): CSVFilter, SystemRecords statics,
HTMLVisitor utility surface. ⛔ find PARKED (TSK-1549 Need-me) · hex waits TSK-810 [owner] ·
formula waits B6. RESIDUAL: VM WV/render slice blocked (TSK-1550 VM ssh down) — runs on
lane restore, attaches to TSK-649.

### B4 Mandate guards + hygiene teeth ✅ DONE 2026-07-07 (gate green incl. deny flip)
✅ TSK-1539 matrix guard (+ gap ticket TSK-1551: formatted/hex/CSV-table/diff lack real-render
suites) · ✅ TSK-1534 webview allowlist · ✅ consumption-guard + no-resurrection tooth ·
✅ TSK-1548 progress log rotated 1.46MB→10KB + 64KB budget tooth · ✅ TSK-1499 (via B3) ·
✅ TSK-1501 color ratchet (28-match shrink-only baseline). ✅ TSK-1535 missing_docs 188→0 + #![deny] flip (6cd5210c).

### B5 Data-grid views ✅ DONE 2026-07-07 (gate green)
✅ TSK-1472 SAVE FLOW (edits could never reach disk! dirty bar + saveCSVEdits via the editor
chokepoint; row-ops = follow-up, overlay-rebase design needed) · ✅ TSK-1515 ƒ marker ·
✅ TSK-1139 measured per owner resolution → paging DENIED for perf; the measurement CAUGHT +
FIXED a P1 (frame-cap → blank grid for >4MB CSVs post-Stage-B; windowed assembly ed5e9689) ·
✅ TSK-1486 reconciled (all asks already built: 1102/1187/925) · 924 review + 1141 validated
(owner lane) · TSK-1205 → moved to B16 (extracted-doc = reading surface). Render tails ride
TSK-1551 (CSV lens real-render suite, needs VM).

### B6 Formula finish ✅ DONE 2026-07-07 (gates green; the 7th twin deleted)
✅ FLIP: MDV_RUST_FORMULA default ON (ed0b43c8; owner's 2026-07-04 chain complete; ALL
capabilities now ship ON — Stage A closed) · ✅ UAT-slice pin (grid→recalc→display→ƒ→box) ·
✅ FormulaEngine + FormulaParser deleted (f734db72, 1089→148 lines; PROPER ported to rust
with .capitalized parity — the last tendon; 77 contract tests retargeted to the engine) ·
1468 = owner hands-on audit (commented, stays owner-gated).

### B7 [XL] Web-migrate wave 1 — v1 ✅ / rest DEFERRED-ON-VM (2026-07-07)
✅ TSK-1530 M6 v1 gated route (4f3be49e — MDV_WEB_SOURCE=1 → read-only CM6; default flip
needs VM + parity slices). DEFERRED pending TSK-1550 (VM ssh): TSK-1527 M3 CSV grid ·
TSK-1531 M7 hex grid · TSK-1532 M8 transcript streaming — from-scratch WEB SURFACES; building
three of them with NO render lane stacks unverified surface (built≠usable). They resume the
moment the lane is back, validation interleaved. Loop continues at B8.

### B8 MCP/CLI/remote tail ✅ DONE 2026-07-07 (7 landings, all gates green)
✅ TSK-1536 mdv CLI (920d0d20: files/folders + `mdv session` via the hardened URL scheme) ·
✅ TSK-1552 self-healing MCP bridge (ca2a114a: reconnect loop + 3 hardening finds incl. the
availableData uncatchable-exception landmine) · ✅ TSK-1507 s1 assets+scaffold (069d49d4) +
s2 WS bridge /ws/editor (ca429655, RFC-pinned, real-socket E2E) + s3 schema contract
(acbd4c28: 42-msg cm-bridge.json + two-sided drift pins; day-one catch = scrollToLine raw
dispatch, $rawDispatchDebt) — s3b codegen/s4/s5 stay on the epic · ✅ TSK-1537 daemon design
(a09fcd67: DAEMON_LIFECYCLE_DESIGN.md D1-D8; slices TSK-1553..1558 filed) · ✅ TSK-1192
who_calls + the ASYNC MCP tool lane (62d3ec0f; family verbs remain on ticket).

### B9 Security & data safety ✅ DONE 2026-07-07 (3 shipped / 4 VM-deferred / 1 review-lane)
✅ TSK-1129 LSP RCE guard ENFORCED (e7f02825, owner's (a): block+one-time-confirm, fail-closed
headless; spawn-site tests) · ✅ TSK-1496 secret detector core (a95b0f40: 6 shapes + entropy
guard, corpus pins both directions; badge/mask = render tail) · ✅ TSK-1194 bounded test runner
(a95b0f40, scripts/test-bounded.sh, teeth via --self-test). DEFERRED on TSK-1550 (VM):
1269/1165/1166 (buffer-mutating merge tails; decision cores done) + 1203 (WKWebView failure
banner + consent-net — render through and through). TSK-343: at REVIEW (main scope verified
done; revert = child TSK-1331, also VM-gated) — owner lane, untouched per mandate.

### B10 Paste & convert cluster ✅ DONE 2026-07-07 (mostly PRE-DONE; recon-first paid off)
✅ TSK-1480 format-state detectors (711bb101: IndentStyleDetector + FileFormatState footer chip,
7 host tests; footer/menu = render tail) · ✅ TSK-1427 rich-paste tables+nested-lists RECONCILED
(all 3 gaps already fixed on main a2024d9b/a1abab17/f695857b; ticket was stuck at reported).
ALREADY DONE (recon): 1323/1324/1325 VALIDATED (audio extract/convert + image convert, full
end-to-end incl. VM webview lane) · 1327 at REVIEW (rich→md host+universalPaste done; CM6-editor
paste = render tail) · 1322 OWNER-PARKED (Need-me: which paste surface + repro). 1473 presets =
not yet filed as its own actionable; folds into the convert panels when the owner wants presets.

### B11 Chrome/menus/first-run usability ✅ DONE 2026-07-07 (2 host cores shipped; rest render/design/owner)
✅ TSK-1340 palette param-input flow (68ba6b33: PaletteParamFlow — Go to Line/jq/encoding
validation+dispatch, 6 tests) · ✅ TSK-1489 omnibox resolution table (68ba6b33: OmniResolver
input→action, 8 tests incl. path-miss/C:\/‌.git edges). RECON DISPOSITION: TSK-1413 entry-point
cohesion = substantially DONE (palette parity + env audit + full menu reorg all landed prior;
PARKED Need-me for owner pixel-eyeball → validated). TSK-1319/1481/1482/1448/1449 = render/
design-heavy tails (settings-catalog/menu-model/omnibox-view/first-run-tour/surface-consolidation
spike) — their host cores are these two + future slices; VM/owner-gated for the on-screen work.

### B12 Panes/nav/key-routing intake cluster ✅ DONE 2026-07-07 (mostly pre-done; 1 new host core)
✅ TSK-1249 terminal header-string formatter (1265cb6a: TerminalHeader.format + home-abbrev, 3
tests; header row = render tail). ALREADY VALIDATED (recon): 1314 side-nav file-nav toggle ·
1316 shoulder-bars-only-on-drag · 1313 pane size caps lifted · 1312 terminal colors (Classic
xterm picker). 1317 terminal-icon drag = REVIEW (drop-action host-done; literal drag = AX tier;
Settings-picker removal deferred). 1315 key-routing = audit DONE (root: fragmented focus, monitors
ruled out) → PARKED Need-me: coordinator-refactor vs targeted patches + repro-flow confirm (fix
is render-VM, risky blind).

### B13 Sessions & windows ✅ DONE 2026-07-07 (1 gated mechanism + 1 Need-me; rest pre-done/render)
✅ TSK-1502 remembered-lens mechanism behind a default-OFF gate (8ba740ab: RememberedLensStore
+ precedence resolver + RememberedLensGate, 7 tests) → PARKED Need-me for the auto-vs-explicit
flip (Hex-trap trade-off). ALREADY DONE (recon): 1308 music-survives-session-switch VALIDATED;
1152 per-file view-as lock at REVIEW (slices 1+2 built, badge/menu render tail). RENDER TAILS on
the done MultiWindowRegistry model: 1104 second-NSWindow mount + 1111 bookmark open-in-new-window
(openInNewWindow host-tested; window/button = VM). 1311 session-state independence = architecture
umbrella (music symptom fixed; multi-stream/full-independence = render architecture, deferred).

### B14 Editor features & polish ✅ DONE 2026-07-07 (2 host cores shipped; rest validated/render)
✅ TSK-1485 edit-location history ring (0666e891: EditLocationHistory, browser back/forward over
edit sites, coalesce+snapshot, 8 tests) · ✅ TSK-1487 line-age coloring model (0666e891:
LineAgeColoring age→ramp + blame-porcelain parse, 6 tests). ALREADY VALIDATED (recon): 1146
spell squiggles + LSP-diagnostic surfacing · 463/1136 LSP completion into CM6. RENDER TAILS:
1170 snippets tab-stop (model done TSK-705) · 1504 cheap-assists word-index (perf lane) · 1505
spelling verbs (NSSpellChecker main-affine + verb catalog) · 1494 cursor mode (WKWebView caret).

### B15 Dev tools usability (9)
TSK-1443 git panel core loop · TSK-1444 LSP status affordance · TSK-1445 code-review journey ·
TSK-1475 terminal favorites mgmt · TSK-769 terminal UX bundle residual · TSK-1476 structural-
search help · TSK-1477 claude-monitor polish · TSK-1493 run configurations · TSK-1470
dep-graph interactive.

### B16 Reading surfaces & viewers (9)
TSK-1205 extracted-doc grid polish (from B5) · TSK-1140 PDF reader tail · TSK-1142 browser
tab surface · TSK-1145 DOCX/XLSX viewer polish ·
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
