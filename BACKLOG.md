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
