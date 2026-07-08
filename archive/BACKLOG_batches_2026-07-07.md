# ARCHIVE — the 2026-07-07 batch ledger (B1–B25, all ✅) + drain notes

Moved out of BACKLOG.md 2026-07-07 (owner ask: BACKLOG = pending only). This is the
per-item disposition record of the hyper-efficiency batch run. Board state is authoritative;
these notes are the narrative ledger.

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
[POST-RUN OWNER CORRECTION: build-now is allowed; VM gates only validation.]

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

### B15 Dev tools usability ✅ DONE 2026-07-07 (1 host core shipped + 1 reconciled; rest render)
✅ TSK-1476 structural-search help layer (e487c0a4: StructuralSearchHelp — per-language examples
that ALL parse + validationError surfacing, 4 tests; popover/error-label = render tail) ·
✅ TSK-1493 run-configs RECONCILED (the npm/cargo/make parsers already exist as
RunnableTaskDiscovery, TSK-722, 18 tests; TaskRunner UI + visible-terminal launch = render tail).
RENDER/VM TAILS (host cores mostly pre-built): 1443 git panel · 1444 LSP status · 1445 code-review
journey · 1475 terminal favorites · 769 terminal UX residual · 1477 claude-monitor · 1470 dep-graph.

### B16 Reading surfaces & viewers ✅ DONE 2026-07-07 (1 host core shipped; rest render/VM tails)
✅ TSK-1495 archive→sidebar tree-expansion model (83824a84: ArchiveTree.build, flat entries →
nested read-only nodes + cap/truncate, 7 tests; sidebar wiring + preview = render tail). RENDER/VM
TAILS (host cores mostly pre-built): 1205 extracted-doc grid+lens-forcing (viewer read-only already
safe) · 1140 PDF reader · 1142 browser tab · 1145 DOCX/XLSX polish · 1147 dep-source fetch/browse
(network egress + sourceview) · 1172 notebooks · 1173 sticky-scroll overlay (model done TSK-719) ·
1469 archive explorers.

### B17 AX build-out + ElementRef ⛔ AGENT-BLOCKED (AX-DRIVEN TIER — the sole off-limits lane) 2026-07-07
RECON: the AGENT-WORKABLE host cores are ALREADY DONE — ElementRef serialize/parse/resolution +
ElementRefExecutor(target) all host-tested (slice 1a); TSK-1260 AXUIElement adapter host-part done
(711c8b65, at review). The REMAINDER is the off-limits AX-driven-tests tier: TSK-1543 AX interaction
matrix (OWNER MANDATE, real-event tests), TSK-1198 mac-computer-use MCP (AXUIElement+CGEvent
automation), 1261/1263 driver+harness, 1197/1199 uat-runner+journeys, 1264 live resolver, 1265
Copy-Reference (render). Per the standing directive (AX-driven = the sole off-limits tier): agent
portion complete, live AX/UAT = owner/VM lane. SKIPPED to B18.

### B18 Image editor epic wave ✅ AGENT-COMPLETE 2026-07-07 (model DONE ~166 tests; rest render/VM/owner)
The IMG epic (TSK-1048) MODEL+VIEWMODEL is comprehensively host-verified (~166 tests: paint/shapes/
selection/crop/resize/orientation/draw-ops). DISPOSITIONS: 1303 edit-state-on-switch VALIDATED ·
1302 pane-overlap + 1309 remove-Draw-Box at REVIEW (host-tested, on-screen=T5 tail) · 1320
annotations-vs-shapes PARKED Need-me (editability solved via TSK-1321; the 3-surface consolidation
= owner a/b/c taste call). RENDER/VM/ARCH TAILS: 1049 off-main render · 1055 undoable-paint (op
foundation exists; the buffer-shadows-ops rework is a corruption-trap arch slice, NOT a clean tick) ·
1114 selection UI · 1168 vector editing · 1304 hide-property-pane · 1307 canvas resize. No host gap.

### B19 Media & misc features ✅ DONE 2026-07-07 (1 host core; rest UAT/VM/review)
✅ TSK-1442 ffmpeg install-guidance consolidated (6a2eb9ea: FFmpegGuidance one source, 4 tests;
round-trip verify = UAT/VM tail). ALREADY DONE (recon): 1326 walkthrough authoring at REVIEW
(docs guide + in-app New-Walkthrough create both shipped, host-tested; button-click = AX tail).
UAT/VM/RENDER TAILS: 1474 video-loop verify (UAT) · 1091–1096 audio engine/AU (model host-tested,
live=VM) · 1119 walkthrough illustration overlay (render) · 377 illustrations residual (render).

### B20 Agent tools & code review epic ✅ DONE 2026-07-07 (1 host core; rest render/MCP)
✅ TSK-1196 cross-agent worktree overlap-detection core (f8e91e83: WorktreeOverlap who_touches/
overlaps/report, merged-exclusion, 6 tests; git-scan + dashboard surfacing = thin shell tail).
ALREADY DONE (recon): 942 select-lines→reference at REVIEW (line-range mdv:// ref via
palette/menu/⌘⌥⇧C shipped; right-click editor menu + comment-to-agent = render tail). RENDER/MCP
TAILS: 943 diagnostics→agent sharing · 944 internal browser automation · 945 security-audit
integration · 318/1108 CR Q&A UI + transport · 537 comments/cumulative-diffs · 373 New▸CR/Agent/Project.

### B21 QoL / VM / test-infra ✅ AGENT-DONE 2026-07-07 (1 host prep core; rest VM-blocked/owner)
✅ TSK-891 ScrollSweep page-jump schedule (e3c462db: the measure-prep the ticket asks for, 5
tests; jank itself UNFIXED — verb+vm-profile mode+trace+mitigation = VM tail, stays at progress
per measure-don't-guess). PARKED: TSK-1540 WV-on-host audit = approval Need-me (executing runs
WKWebViews on the host — the no-UI-on-host directive forbids without sign-off). VM-BLOCKED on
TSK-1550 (VM down): 1542 Sequoia nag (VM plist) · 1239 fd exhaustion · 1247 webview-blank · 1365
WebContent hardening · 1336 walkthrough-T5 · perf traces 1184/1180/1179/1185 (measure-first, need
the VM profiler). 1541 rust coverage = coverage.sh exists (Swift); a rust number needs llvm-cov tooling.

### B22 Perf & memory ✅ DONE 2026-07-07 (1 host slice + 1 reconcile; rest VM/render/XL)
✅ TSK-1490 memory footprint in the diagnostics dump (9559514b: ProcessMemorySample summary +
DiagnosticDump memory section, 6 tests; caches verified already-bounded; measurement RUN = VM tail)
· ✅ TSK-1428 outline false-headings RECONCILED (fixed on main 03d5e658+00dde184, 23 tests;
indented-code + HTML-comment `#` no longer false headings). VM/RENDER/XL TAILS: 838 DOM-patch
persistent page (render, closes 598) · 1382 DocumentModel squeeze + 1490's retained-block
attribution (measure-first, VM) · 1214 lazy grammars [XL design] · 1423 hex unsaved-edit search
(engine done; fix = @State plumbing + AX-tier hex-keyboard-edit).

### B23 Board/docs hygiene ✅ DONE 2026-07-07 (board honesty; no code)
✅ TSK-1514 umbrella reconcile: 379 restated (live horizon-B umbrella, Stage A + stateful core done),
538 rolled up (49/54 done; 5 open = dep-gated tooling + superseded cm_apply), 651 evidence-commented
(fresh rust-core-gate GREEN, serve+loopback suites; left for owner validate) · ✅ TSK-1412 board↔code
sweep agent-half done (BACKLOG↔code 9291260f + 20+ tick reconciles; ~417 board-close = owner).
REMAINING (owner/doc-churn, low-value): 1513 roadmap revision · 590 owner bug-list re-verify ·
FEATURE_INVENTORY refresh · dated-design-docs archive (~35 files) · LESSONS→SOP distillation · 441-445
board/CI nits — doc maintenance, best folded into a doc-focused pass, not blocking.

### B24 Wishes/epics kickoff ✅ DONE 2026-07-07 (1 host core; rest render/XL/design)
✅ TSK-1169 ~/.textview settings-relocation migration model (408bef70: SettingsRelocation
migrationPlan+readPath, 5 tests; file-move + store wiring = data-safety live tail). RENDER/XL/
DESIGN TAILS: 703/1155 action-history view · 706/1156 richtext WYSIWYG [XL] · 1157 PlantUML/D2
(render-gated WebView markdown path) · 1158/715 profiling viewers · 697 agent-services search ·
1164 per-language coverage matrix · 1171 3-way merge UI · 1488 FPS instrumentation · 1500/1503
resurrect-from-history (#NNN mismatch noted — verify id first).

### B25 [XL] 1507 WebUI single-sourcing ✅ AGENT-DONE 2026-07-07 (1 host slice; rest rust-port/render)
✅ Sanitizer POLICY single-sourced (89b02eee: HTMLSanitizerPolicy + schemas/html-sanitizer-policy.json
+ HTMLSanitizerPolicyGuardTests — the "byte-identical native vs web" security surface pinned; 3 guard
+ 38 sanitizer tests green). REMAINING (rust-port/render tails of TSK-1507 s4/s5): sanitizer ALGORITHM
port to rust reading the contract · RenderedBlockDiff/BlockPatchJS→html_patch.rs collapse · assist-
policy→core · serve-backed WUI v1 page (render) · canvas-in-WebUI (render) · s5 sandboxed-iframe
strategy (browser security). The enforced contract makes the eventual rust port divergence-safe.

## T37 replenishment (drain phase — since completed)
The TSK-697 Agent-Services spike filed TSK-1560–1564 (+1565); ALL were built and driven to
`fixed` during drain ticks T38–T43 (census 32→39 MCP tools). See the board records.
