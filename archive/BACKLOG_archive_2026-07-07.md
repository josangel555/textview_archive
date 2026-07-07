# Backlog — the single curated worklist · reorg 2026-06-29 (VM available; done → bottom)

> The ONE prioritized "what to work on" list. The `tasked` board (http://localhost:8787/) is the
> **system of record** for task STATE; this file is the human-scannable selector.
> **Verify any `TSK-###` against the live board before working it** (`task_get`) — the board moves, this file lags.
> Gating tags: **[render-VM]** build + validate ON THE VM (now OPEN — see state) · **[host]** host-gate-completable ·
> **[engine]** needs a live LSP/process · **[owner]** needs an owner decision/flip · **[built→flip]** done, gated off awaiting owner.

## 📊 State (2026-06-29)

**THE VM IS AVAILABLE FOR WORK** (owner correction, 2026-06-29) — *"there is no such restriction that work
needs to be only in host. VM is up and running, except the brand-new AX-based testing (blocked on permissions);
everything else is open."* So the **[render-VM]** items below are the **ACTIVE work queue**, NOT a held tail:
build them + validate ON THE VM (`MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_RUN_WEBVIEW_TESTS=1 bash
scripts/test-in-vm.sh all` — `all` rebuilds dist/ first). The ONLY blocked lane is the new AX-testing executor (TCC).

Board (shared, ~all markdown_viewer): **1658 total** · ~**417 await owner close** (review+fixed). Agent-complete
items are now in **§✅ DONE (bottom)**. `reported` is still INT-126-inflated (~70 mass-reset; `task_get` before trusting; do NOT hand-mutate — INT-128 tooling fix).

## ✅ Completed since the 2026-06-29 curation (2026-07-02 usability run — verified vs CODE; close on the board)
> This file lagged; several items listed as pending below are DONE. Reconcile (TSK-1412). Each verified
> by the code + tests this session (not commit messages), host-gate-green, teeth on every fix.
- **Image-editor undo — TSK-1305 "full Undo" DONE** (was P1 render-VM): paint strokes undoable (TSK-1416),
  geometry-after-paint no longer swallowed (1419), tonal-after-paint gated (1420), interleaved undo ordering
  unified (1421), **overlay annotations undoable + a unified op/paint/overlay undo timeline** (1424). ⌘Z now
  covers every edit layer. (host-tested + teeth)
- **Image-editor data-loss fixes:** vector annotations were silently dropped on Export/Save-a-Copy — now
  composited (1422); CSV empty-state placeholder (1415).
- **New ▸ Image — TSK-1306 DONE + UI-drive-CONFIRMED** on the real app (EmptyStateNewImageHostingTests, VM).
- **Overlay text/shape editing — TSK-1310 / TSK-1321** exist (setText/rotation/frame/style) + now undoable (1424).
- **Menu reorg — TSK-1318 / TSK-751 DONE** (TSK-1413): new Tools + File▸Export/Share + Format menus; View
  decluttered to see-the-doc only; standard App/File/Edit/Format/View/Tools order.
- **⌘K palette parity — TSK-951 / TSK-1186 (largely)** (TSK-1413/1425): hosted-view tools (HTTP/feed/treemap/
  dep-graph/walkthroughs) + clipboard-export conversions now palette-discoverable; commands recategorized to
  match the new menus; a command↔verb cohesion regression guard added.
- **RSS feed reader — TSK-955 / TSK-1149 DONE** (TSK-1417): was built but ORPHANED (unreachable) — wired to
  File ▸ Feed Reader + a show-feed-reader verb; UI-drive-confirmed on the VM.
- **Finish-or-cut spikes (TSK-1414):** SQLite browser + folder treemap + HTTP client all code-verified +
  UI-drive-confirmed BUILT & working (not spikes). RSS reader was the one true orphan → finished.
- Still-open highest-value (unchanged, mostly OWNER-gated): the P0 render-VM CM6 bugs (1200/1188/1271/891/
  910/1032), **TSK-1334** Screen-Recording grant (unblocks pixel/AX validation — menu appearance, hex-edit
  search 1423, CM6 internals), and the owner flips (838 DOM-patch, 1215 formula, 1202 fold).

## 🆕 Owner intake 2026-06-29 (filed TSK-1302–1327) — fresh owner-reported bugs + features
Mostly user-facing render-VM (image-editor / panes / terminal / menus); host-model where applicable, render at review. Grouped:
- **Image editor (cluster — relates the TSK-1048 overhaul):** TSK-1302 editor pane covered by file-property pane (layout/overflow) · TSK-1303 edit state reset on session-switch · TSK-1304 hide file-property pane · TSK-1305 full Undo for image edits · TSK-1306 New▸Image → blank-canvas editor · TSK-1307 canvas size-adjust (MS-Paint) · TSK-1309 remove the Draw Box button · TSK-1310 edit Draw Text element (text/pos/color/font) · TSK-1320 Annotations: clarify-vs-Shapes/editability · TSK-1321 selectable+editable overlay elements (resize/rotate/move/props; latest-first→all) · TSK-1325 image format+quality convert.
- **Terminal / layout / panes:** TSK-1312 colors off running claude code in Terminal · TSK-1313 remove ALL H/V size restrictions on every pane (Terminal h-expand cap) · TSK-1317 drag Terminal icon + remove its position Setting.
- **Nav / shoulder / key-events:** TSK-1314 Side nav shows File-nav even when toggle off · TSK-1315 **key-event routing audit** (keystrokes leaking to wrong recipient) · TSK-1316 empty shoulder bars only-on-drag.
- **Menus:** TSK-1318 reorganize/group menus (cf TSK-751) · TSK-1319 dynamic content-specific (per-tab) menu.
- **Session:** TSK-1311 session state independent/persistent/online (umbrella) · TSK-1308 switching session stops music (keep sessions live).
- **Paste:** TSK-1322 paste is buggy · TSK-1327 smart text-paste formatting (rich→markdown) — cf TSK-958/1163.
- **Media features:** TSK-1323 extract audio from video · TSK-1324 audio format+quality convert (both via host ffmpeg TSK-528) · (TSK-1325 image convert above).
- **Walkthrough:** TSK-1326 authoring path + sample walkthroughs.

## ⚡ ACTIVE — render-VM work queue (NOW workable on the VM). Drain top-down, build + validate on the VM.

### P0 — bugs + perf the user feels
1. **TSK-1200** — CM6 editor `scroll-to-line` verb is a no-op on the live app (blocks editor-scroll UAT). DIAGNOSED: keep the raw `scrollDOM.scrollTop` (drives the scroll-emit) but wrap in `view.requestMeasure({read,write})`; do NOT switch to scrollIntoView. **[render-VM/JS]**
2. **TSK-1188** — CM6 plain-click after scroll extends a selection + jumps viewport back. DIAGNOSED: defer the re-entrant `view.dispatch` off the TSK-894/890 mouse handlers; needs an in-process WebViewTestCase. **[render-VM/JS]**
3. **TSK-1271** — rendered-MD Find can't scroll past the current match. DIAGNOSED: forward scroll keys to the webview while find holds first responder. **[render-VM/JS]**
4. **TSK-891** — Page-Up janky / not smooth in the editor. **[render-VM/perf]**
5. **TSK-910** — commit diff: only one line selectable → multi-line selection. **[render-VM]**
6. **TSK-1032** — video-in-HEX-mode byte grid renders blank / doesn't mount. **[render-VM]**
7. **TSK-598** — opening MD files very laggy → resolved by the **TSK-838** DOM-patch flip (owner). **[→ flip]**

### P1 — features (host models BUILT; build/validate the views on the VM)
8. **TSK-1176** — terminal command palette: models DONE (history + favorites + `TerminalCommandSearch.unified`, all validated). Build the palette VIEW + trigger + PTY-insert; iterate on the VM. **[render-VM]**
9. **TSK-1128** — Settings ▸ LSP panel binary-picker (`languageStatuses` + install-hints + lsp.json write-back all done). Picker UI gated on the **TSK-1129** security decision. **[render-VM + owner]**
10. **TSK-924** — CSV multi-cell (rows+cols) select + copy/paste (`CSVRectSelection`/`CSVCopy` done). **[render-VM]**
11. **TSK-1139** — CSV viewport paging: wire the rendered table to `CSVRowWindowSource` (`CSVViewportPager` done). **[render-VM]**
12. **TSK-1141** — xlsx sheet UI + formula-recalc wiring (model done). **[render-VM]**
13. **TSK-1146** — spell/grammar inline editor squiggles + LSP-diagnostics surfacing (model done). **[render-VM]**
14. **TSK-958 / TSK-1163** — Universal Paste: multi-type clipboard dispatcher UI (model done). **[render-VM]**
15. **TSK-463 / TSK-1136** — wire LSP completion into CM6 (bridge done; invoke + render). **[render-VM + engine]**
16. **TSK-1119** — walkthrough illustration overlay (SwiftUI view rendering the diagram verb). **[render-VM]**
17. **TSK-343** — image/file History → **Revert** UX (delta-store + history view DONE; the destructive restore-over-current is the gap — data-safety: handle unsaved edits). **[render-VM]**
18. **TSK-955 / TSK-1149** — RSS/Atom feed reader UI (model + viewmodel + view BUILT; mount-tail occlusion-class). **[render-VM]**
19. **TSK-1048 / 1049 / 1055 / 1114 / 1168** — image editor: MS-Paint parity + off-main render/cached-CIContext + undoable strokes + selection UI (marquee/lasso) + on-canvas vector editing. **[render-VM]**
20. **TSK-769** — terminal UX bundle: open-in-pwd, tab rename, colors, tab-shoulder border (favorites + history shipped). **[render-VM]**
21. **TSK-951 / TSK-1186** — ⌘K palette parity: remaining menu-only commands (host-verbs done — encoding-prompt / align-tables / render-panels remain). **[render-VM]**
22. **TSK-1104 / TSK-1111** — multi-window: mount a 2nd NSWindow + bookmarks "open in new view". **[render-VM]**
23. **TSK-283** — Enter-to-rename in the file nav · **TSK-373** New ▸ Code-Review/Agent/Project · **TSK-942** select-lines → reference/comment-to-agent · **TSK-1152** per-filename View-as lock · **TSK-1123** tool-window placement UI · **TSK-377** illustrations · **TSK-318/1108** CR Q&A. **[render-VM]**
24. **TSK-1142** browser tab (→ `BrowserNavigationPolicy`) · **TSK-1145** DOCX/XLSX viewer · **TSK-1140** PDF reader tail · **TSK-1091–1096** audio (AVAudioEngine + AU host) · **TSK-751** organize menus. **[render-VM]**

### P2 — internal / rust-core / build / test
25. **TSK-382** — squeeze DocumentModel memory (VM `phys_footprint` profile — measure-first). **[host/perf]**
26. **TSK-538** — rust-core audit follow-ups (host children mostly drained; deps + render tail). **[host]**
27. **TSK-764 / TSK-1165 / TSK-1166** — git reconciliation + ExternalEditReconciler / DiskConflict wiring (model done; render + data-safety tail). **[host + render]**
28. **TSK-537** — Code Review feature epic (commit diffs, comments, export). **[render-VM + host]**
29. **TSK-698 / TSK-703 / TSK-722 / TSK-723** — host-engine epics: script-window (JQ/`JSTransform` done), action-history, task-runner, structural-search. **[host engine + render]**
30. **TSK-379 / TSK-1117** — rust-core: stateful EditorBuffer + Tabs projection in Rust. **[host/supervised]**
31. **TSK-441–445** board/CI infra · **TSK-831 / 852 / 835** CI/build perf (dedup index −1.7 GB, `.build` cache, cargo-nextest[dep]). **[host/infra]**

## 🔓 Owner decisions / flips — your call unblocks them (NOT agent work)
- **TSK-838** — flip `MDV_DOM_PATCH` (the #1 perf win; built + VM-validated, gated off). Closes TSK-598/590.
- **TSK-1215** formula flip (`MDV_RUST_FORMULA`) · **TSK-1202** fold flip (`MDV_RUST_FOLD`) — both parity-proven (34 tests, re-verified 2026-06-29); pick to enable.
- **TSK-1129** — LSP workspace-binary RCE-guard enforcement: (a) prompt-first-then-block [rec] / (b) block-by-default / (c) warn-only. Model+store BUILT, spawn warns. **SECURITY** — unblocks the TSK-1128 picker.
- **TSK-543** — cm_apply stateful-delta redesign (the real typing-latency fix; ~10× FFI traffic). **[design call]**
- **TSK-1138** — Tier-D PTY/socket plugin contract (design delivered `aa03d6fc`) — **ratify**.
- **TSK-1182** diff-selection model · **TSK-589** session-eviction · **TSK-810** hex Stage-B fallback · **TSK-1045** per-session DocumentModel sign-off.
- **TSK-470** zoom-split · **683** app name · **686** Developer-ID signing · **276** debugger/DAP · **293** encryption · **296** markdown scope · **298** Java ext-tool · **781** LSP own-vs-external · **1137** mutation-tester · **1287** crypto-hash dep · **508** digraph dep.
- **Close the ~417 review/fixed queue** (`→ done`, render items by on-screen glance) · **Grant Accessibility/Automation TCC** (unblocks the AX executor, the one blocked lane).

## 🌊 Wishlist epics (P6–P8 — slice when pulled, not yet prioritized)
TSK-687 deep agent integrations · 688 walkthrough-as-presentation · 689 PinBoard · 690 tmux -CC (core done) · 691 own agent harness · 693 tasks/worktrees/review surface · 695 credential handling · 697/699 Agent Services (1154 = 4 MCP tools) · 700 collaboration · 701 SDLC surface · 702 Mac intelligence · 706 RichText editor · 713 more diagram formats · 714 tab split · 715 profiling/flame charts · 725 inspections/intentions · 772/773/777 plugin expansion + MCP + PDK · 774 music · 1083–1090 image-editor advanced tools.

---

## ✅ DONE — agent-complete, awaiting owner-close (moved to bottom 2026-06-29)
*These need no more agent work; the owner closes them (`→ done` / a flip).*
- **TSK-1110** — DocumentModel SRP: **cohesive-logic extraction COMPLETE** (5835→3346 lines, ~43%, 57 extensions; CM6-LSP / Command-registry / Editable-HEX / view-mode-lock all carved). Remaining 3346 = the irreducible open/close/select orchestrators + @Published state (not behavior-preserving-movable). → owner **close/de-scope**.
- **TSK-1300** — CSV convert commands routed off the Swift twin onto `RustCSVAdapter` (~2.5× faster, output-preserving). **validated** `e24d23fd`.
- **TSK-1301** — unified favorites+history terminal command-search model. **validated** `009cc573`.
- **TSK-1202** — code-fold-region rust port. **validated** (the FLIP is the owner item above).
- This session also landed (host-tested, on `main`): **TSK-1176** host-half (populate `43fac093` + search models) · **TSK-1128** lsp.json write-back model `6a3e6ac0` · transcript contract proptest `24df4a65` · 8 render features + spell-check (→review) · 40 SRP slices · 3 validated subprocess-crash fixes (SIGPIPE/ffmpeg) · 2 gate-flake fixes.
- Earlier (since 2026-06-27): TSK-847 (gate), 1270 (find-highlights), 1151 (line-height), 400 (rpcd spike), 836/794 (timings/threading audit). Coverage landed: RichTextSerializer, FileQuarantine, cspMeta, Focus-shortcuts.

*Coverage now (2026-06-29): 69.74% region / 64.72% line (host) — the uncovered is render UI [VM-tested]; pure-logic is comprehensively covered. Full archive → `archive/BACKLOG_archive_2026-06-27.md`.*

- **Image editor: non-destructive paint layer** (enh) — paint is currently a DESTRUCTIVE baked buffer, so tone-after-paint can't be re-derived (TSK-1420 gates the Tone controls once painting starts as the honest interim). A real fix = keep paint as a separate compositing layer over the live tonal/geometry render, so tone/paint are independently editable. Larger architecture change.

## WebUI surface-sharing — analysis captured (2026-07-04)

**Finding:** the CM6 editor / rendered-markdown / mermaid / Canvas surfaces are already browser-native
JS (3.6MB of bundles in `Sources/ViewerUI/Resources/`) on an already-core-side HTML pipeline
(`markdown.rs`/`html_patch.rs`/`mermaid.rs`/`theme.rs`/`canvas/`) — a WebUI reuses them, it doesn't
port them. Hosted as full WKWebView documents, NOT iframes (iframes are sanitizer-dropped).
- **Epic: TSK-1507** — mdv-serve serves the bundles + cmDispatch-over-WebSocket (TSK-662/664 duplex
  infra); bridge schema into the wire contract (TSK-634 codegen precedent); single-source into core:
  `HTMLSanitizer`/`HTMLDocumentPolicy` (security parity — top candidate), `RenderedBlockDiff`/
  `BlockPatchJS` (twin of `html_patch.rs`), editor-assist policy (NSSpellChecker stays a native provider).
- **Buffer-authority fork:** until TSK-1117 (stateful EditorBuffer/DocumentModel in Rust), a WebUI
  editor is a separate instance, not a live view of the same document. Slices 1-4 of 1507 don't wait on it.
- Blank-slate split verdict (for orientation): only OS-inherent stays Swift (WKWebView hosting,
  TCC/Keychain, PTY, NSSpellChecker, AX, menus, ~15-20k LOC); the rest of the 161.6k-vs-50.2k
  host/core skew is migration economics, not capability.

## Rust-core hygiene + front-end delivery (owner asks, 2026-07-04)

- **TSK-1535 — doc-warning burn-down + FAIL THE BUILD ON WARNS:** backfill the 188 `missing_docs`
  in `mdvcore-core` (+ 1 web, 2 serve warnings), fix the 2 cosmetic code warnings, then promote to
  DENY in `rust-core-gate.sh` so warn-level lints can never rot silently again.
- **Build dirs (done 2026-07-04):** cargo target-dir moved `/private/tmp` → `~/Library/Caches/`
  `mdv-rust-target` (durable, survives reboot, still outside the iCloud tree per TSK-555);
  `scripts/stage-frontends.sh` builds + stages `mdv-tui`/`mdv-web`/`mdv-serve` into **`dist/bin/`**.
- **TSK-1536 — `mdv` CLI opener** (open files/folders/sessions in the running app from the shell);
  **TSK-1537 — daemon-vs-instances design** (mdv-serve lifecycle, launchd agent, one backend for
  WUI/TUI/App per TSK-1507/1523).

## Rendering-stack policy — "web for content, native for chrome, brain in Rust" (owner-ratified 2026-07-04)

Epic **TSK-1524** + children: owner-critical migrations M1-M5 (git diff **1525** [dep: @codemirror/merge],
file diff/merge **1526**, CSV grid **1527** (consumes the rust windowed snapshot; also serves SQLite
browser), XLSX **1528**, Word/.docx **1529**) + scan-found M6-M9 (read-only source→CM6 **1530** — the
NSTextView-1MB-choke killer, likely FIRST as pattern-prover; hex **1531**; transcript/monitor/logs
**1532**; git history/blame **1533**) + the anti-Electron allowlist guard **1534**. Rationale recorded
in the epic (SwiftUI cross-element selection is structural; browser text stack already paid for;
webviews = renderers, never chrome, never the app).

## Rust migration — plan-gap tickets filed (2026-07-04)

Plan-vs-board-vs-code walk found the whole-core commitment ("do all", TSK-775) had no breakdown.
Filed: **TSK-1508** (the 1117 stateful-core spike — design + slices + supervised-cutover schedule;
THE entry point) · TSK-1509/1510/1511/1512 (H-B domain placeholders under TSK-379: LSP, Git,
Sessions, Automation verbs — re-scope from the spike, don't start independently) · TSK-1513
(roadmap revision) · TSK-1514 (umbrella reconcile 379/538/651). Owner gates on the critical path:
TSK-649 soak-window number (D1 + horizon already resolved — see the 2026-07-04 reconcile comment),
TSK-1215 formula-display product call, TSK-589 eviction policy.

## Usability-drain effort — PARKED (owner, 2026-07-04)

The app-wide usability push (TSK-1411 tree) is parked mid-drain. Everything is persisted:
- **State of record:** board tickets TSK-1434..1505 (epics 1450-1460; each child = a self-contained
  subagent brief) + `docs/FEATURE_INVENTORY.md` + `docs/USABILITY_VALIDATION_PROTOCOL.md` (batch queue)
  + `docs/WISHLIST_RECONCILE_2026-07-02.md`.
- **Landed on main (verified):** batches 1-2 (11 tickets: 1483/1435/1436/1479/1437 + 1461/1462+1331/
  1463/1464/1465) + tool-results panel (1434) + spell/autocomplete footer toggles (92dec034).
- **SALVAGED, NOT INTEGRATED:** branches `worktree-wf_dadf7ab6-e88-{1..9}` — 7 complete per-ticket
  commits (1439-export, 1466, 1467, 1446, 1447, 1498, 1484) + 9 `wip(salvage)` commits (NOT
  gate-verified). Integration ticket: TSK-1506 (branch↔ticket map + rebase→gate→ff recipe).
  Worktree DIRS reaped; branches kept.
- **Resume =** work TSK-1506 first, then continue the protocol batch queue inline.

## THE 200-QUEUE (owner-ratified 2026-07-07) — batch work-loop edition

**WORK-LOOP MANDATE (owner, 2026-07-07 — hyper-efficiency round):** pull 5–15 RELATED items
as ONE batch → implement code+unit tests in one go (minimal interleaved checks, targeted
tests only) → ONE full gate pass for the batch → THEN batch the higher-order tests (WV/AX/
T4/T5) for the whole batch — run the VM UI lane ONLY if the batch genuinely changed render
behavior → ONE commit per batch (all TSK ids in the message + Claude-Session trailer) →
board records to `fixed` as a batch with evidence. Do NOT babysit one change per gate/commit.
Do NOT pull from review/validated lanes (owner runs the validation look separately). Blocked
item ⇒ park it, take the next. Mark finished items ✅ in this list each tick.

### TIER 0 — Fable/XL only (get-right-first-time; do NOT hand to workers)
F1. ✅ TSK-1516 S1 EditorSession core (shipped 8e2771d8)
F2. TSK-1517 S2 stateful FFI family + eviction wiring (the forever-ABI)
F3. TSK-1518 S3 shadow-mode differential net (gates the supervised cutovers)
F4. TSK-1530 M6 TextDisplayView→CM6 read-only (pattern-prover for all M-migrations)
F5. TSK-1539 surface catalog + matrix guard semantics (mandate enforcement design)
F6. TSK-1537 daemon-vs-instances design (lifecycle/activation/skew)
F7. TSK-1507 slice-3 bridge schema → wire-contract codegen
F8. TSK-1538 dark-theme diagnosis (product-vs-test judgment)
F9. TSK-1214 lazy-grammar architecture (dlopen × hardened-runtime/codesign)
F10. v4 DLD gap-closure inputs (6 gaps from the meta-analysis synthesis)

### #1–10 finish-in-flight
1. TSK-1544 live-app MCP E2E (after owner relaunches TextView) · 2. TSK-1546 close ·
3. TSK-1547 close · 4. fold UAT journey slice (VM) · 5. TSK-1513 roadmap revision ·
6. TSK-1514 umbrella reconcile 379/538/651 · 7. TSK-1412 board↔code sweep ·
8. Canvas fixed-slice validation batch A (1372/1374/1375) · 9. batch B (1376/1377/1378/1379/1360/1392) ·
10. TSK-1365 WebContent-termination hardening

### #11–19 Stage-B twin deletions (per docs/STAGE_B_DELETION_UAT_2026-07-04.md, agent-driven)
11. FuzzyMatcher · 12. FindEngine · 13. ClaudeLogParser · 14. hex pair [needs TSK-810 call] ·
15. CSVParser/CSVFilter · 16. CMEditApplier · 17. markdown structural visitor ·
18. TreeSitterEngine folds · 19. formula: flip → UAT → delete FormulaEngine

### #20–27 stateful core (S-slices; S5/S6 SUPERVISED — schedule with owner)
20. TSK-1516 ✅ · 21. TSK-1517 · 22. TSK-1518 · 23. TSK-1519 · 24. TSK-1522 · 25. TSK-1523 ·
26. TSK-1520 [supervised] · 27. TSK-1521 [supervised]

### #28–36 mandate guards + AX lane
28. TSK-1539 · 29. TSK-1534 webview allowlist · 30. TSK-1260/1261 native AXUIElement adapter ·
31. TSK-1263 agent AX harness · 32. TSK-1543 slice: top-20 verbs interaction tests ·
33. slice: footer/statusbar chips · 34. slice: menu-bar sweep · 35. TSK-1197/1199 uat-runner ·
36. TSK-1198 reconcile/close (superseded by native adapter)

### #37–45 web-for-content migrations (TSK-1524 epic)
37. TSK-1530 M6 (first) · 38. TSK-1527 M3 CSV grid · 39. TSK-1528 M4 XLSX · 40. TSK-1531 M7 hex ·
41. TSK-1532 M8 transcripts/logs · 42. TSK-1533 M9 git history/blame · 43. TSK-1529 M5 docx ·
44. TSK-1525 M1 git diff [dep: @codemirror/merge] · 45. TSK-1526 M2 merge UX [same dep]

### #46–52 MCP / remote tail
46. TSK-1536 mdv CLI opener · 47. MCP reconnect loop (file + fix; TSK-665 recorded follow-up) ·
48. TSK-1507 s1 serve static assets · 49. s2 cmDispatch-over-WebSocket · 50. s3 schema codegen ·
51. TSK-1537 daemon design · 52. TSK-1192 semantic code-nav MCP

### #53–68 high-value bugs & felt perf
53. TSK-1538 · 54. TSK-1423 hex unsaved-edit search · 55. TSK-1428 outline false headings ·
56. TSK-1499 fold-bench budget · 57. TSK-598 MD-open lag · 58. TSK-838 DOM-patch persistent page ·
59. TSK-891 Page-Up jank · 60. TSK-1490 memory-release audit · 61. TSK-1318 menu reorg ·
62. TSK-1322 paste repro+fix · 63. TSK-1311 session-state independence · 64. TSK-1200 scroll-to-line verb ·
65. TSK-1214 lazy grammars · 66. TSK-543 reconcile-vs-1124 · 67. TSK-1179 palette trace · 68. TSK-1185 git menu latency

### #69–90 usability drain (self-contained briefs on each ticket)
69. TSK-1481 · 70. TSK-1482 · 71. TSK-1472 · 72. TSK-1486 · 73. TSK-1515 · 74. TSK-1438 ·
75. TSK-1440 · 76. TSK-1443 · 77. TSK-1444 · 78. TSK-1445 · 79. TSK-1475 · 80. TSK-1476 ·
81. TSK-1477 · 82. TSK-1478 · 83. TSK-1480 · 84. TSK-1473 · 85. TSK-1474 · 86. TSK-1469 ·
87. TSK-1495 · 88. TSK-1485 · 89. TSK-1448 · 90. TSK-1489

### #91–100 QoL / test-infra
91. TSK-1542 nag storm · 92. TSK-1548 progress rotation · 93. TSK-1535 warnings→deny ·
94. TSK-1540 WV-on-host · 95. TSK-1541 rust coverage · 96. TSK-1239 VM fd exhaustion ·
97. TSK-1247 VM webview-blank · 98. TSK-1504 cheap editor assists · 99. TSK-1505 spelling verbs ·
100. TSK-1501 color-literal sweep

### #101–200 the next hundred
**Security & data safety (101–108):** 101. TSK-1129 LSP spawn confirm · 102. TSK-1269 ExternalEditReconciler
into dirty-reload · 103. TSK-1165 external-edit merge UX wiring · 104. TSK-1496 secret masking ·
105. TSK-1203 trust-mode failure-surfacing · 106. TSK-628-class advisory sweep refresh ·
107. TSK-1194 resource-bounded test exec · 108. TSK-945 security-audit integration
**Agent tools (109–114):** 109. TSK-1192 (dup of 52 — skip if done) · 110. TSK-1196 file-ownership
dashboard · 111. TSK-943 LSP/diagnostics→Claude sharing · 112. TSK-944 internal browser automation ·
113. TSK-1108 CR Q&A UI + transport · 114. TSK-1340 palette param-input step
**Feature tails — reading surfaces (115–126):** 115. TSK-1140 PDF reader tail · 116. TSK-1142 browser tab ·
117. TSK-1149 feeds UI · 118. TSK-1147 dep-source browse · 119. TSK-1172 notebooks kernel/UI ·
120. TSK-1440 (dup of 75) · 121. TSK-1173 sticky scroll · 122. TSK-1170 snippets tab-stops ·
123. TSK-1156 richtext WYSIWYG v1 · 124. TSK-1157 PlantUML/D2 renderers · 125. TSK-1158 profiling viewers ·
126. TSK-1205 extracted-doc grid polish
**Editor & UI tails (127–140):** 127. TSK-1111 bookmark open-in-new · 128. TSK-1123 tool-window placement tail ·
129. TSK-1249 terminal header row · 130. TSK-1252 vim Esc beep · 131. TSK-1319 dynamic per-tab menu ·
132. TSK-1114 paint selection UI · 133. TSK-1168 vector overlay editing · 134. TSK-1427 rich-paste tables/nested lists ·
135. TSK-1164 per-language coverage matrix · 136. TSK-1169 ~/.textview settings relocation ·
137. TSK-1171 3-way merge 3-pane UI · 138. TSK-1155 unified action history wiring ·
139. TSK-1494 cursor mode (view-only surfaces) · 140. TSK-1502 lens memory decision-prep
**AX epic build-out (141–148):** 141. TSK-1543 slice: file-nav tree · 142. slice: palette + dialogs ·
143. slice: editor chrome (find bar, gutter) · 144. slice: tool windows/panels · 145. slice: CSV grid ·
146. TSK-1264 ElementRef resolver · 147. TSK-1265 Copy-Reference surfaces · 148. TSK-1266 element picker
**1507 WebUI build-out (149–154):** 149. sanitizer→core single-source · 150. RenderedBlockDiff/BlockPatchJS
collapse into html_patch.rs · 151. assist-policy→core (ties TSK-1504) · 152. WebUI auth/session hardening pass ·
153. WebUI serve-backed WUI v1 page · 154. canvas-in-WebUI slice
**Code review & image editor epics (155–166):** 155–158. TSK-537 slices: diff viewer→comments→cumulative
diffs→export · 159–163. TSK-1048 slices: brush engine perf → shapes/arrows → selection tools → layers v1 →
save-format · 164. TSK-1441 image editor UX pass · 165. TSK-1442 audio round-trip verify · 166. TSK-1426 prep
(paint persistence options doc for owner)
**Test-infra & perf traces (167–178):** 167. TSK-1336 walkthrough T5 · 168. TSK-1184 hover-synth trace mode ·
169. TSK-1180 search result-scroll trace · 170. TSK-1244 coverage CI wire (reconcile) · 171. TSK-1130-class
Swift-Testing expansion batch · 172. TSK-1195 render-classifier prep doc · 173. per-engine consumption-guard
extension to new adapters · 174. TSK-1223-class fuzz for editor_session + new FFI · 175. FoldBench/MsgPack
bench re-budget (with 1499) · 176. VM lane parallel-split investigation (WV shards) · 177. mem-profile
scenario refresh post-relocation · 178. giga-uat smoke catalog refresh
**Board & docs hygiene (179–186):** 179. TSK-1411/1450–1460 epic-state reconcile after drain ·
180. TSK-1413 entry-point cohesion audit · 181. TSK-1449 consolidate overlapping surfaces ·
182. TSK-590 owner bug-list re-verify sweep · 183. FEATURE_INVENTORY refresh · 184. LESSONS→SOP distillation
(for v4 policy rows) · 185. archive dated design docs pass (~35 files) · 186. TSK-1329/1330 tracker-nit
INT tickets
**Wishes worth pulling when reached (187–200):** 187. TSK-955 RSS reader epic v1 · 188. TSK-1157 (dup guard) ·
189. TSK-703/1155 action-history view · 190. TSK-706/1156 richtext (dup guard) · 191. TSK-715 profiling epic
kickoff · 192. TSK-1147 (dup guard) · 193. TSK-697 agent-services search slice · 194. TSK-1493 run
configurations · 195. TSK-1470 dep-graph interactive · 196. TSK-1487 age coloring · 197. TSK-1488 FPS
instrumentation · 198. TSK-1500 resurrect deleted from history · 199. TSK-891 (dup guard) ·
200. TSK-1497-prep: debugger scoping doc for the owner decision

### Owner one-word unblocks (not in the queue until decided)
@codemirror/merge (→44/45) · TSK-810 hex carve-out (→14) · Canvas M0–M6 review + TSK-1349 ·
TSK-1506 salvage resume · finish-or-cut: 1414/1418/1471/1491/1426 · formula gate 1468/788 ·
TSK-831/852 build opt-ins · TSK-1287 crypto dep · supervised sessions for #26/27.
