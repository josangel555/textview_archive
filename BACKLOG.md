# Backlog — the single curated worklist (next-50 pulled + reprioritized 2026-06-27)

> The ONE prioritized "what to work on" list. The `tasked` board (http://localhost:8787/) is the
> **system of record** for task STATE; this file is the human-scannable selector.
> **Verify any `TSK-###` against the live board before working it** (the board moves, this file lags).
> Full pre-reconcile history → `archive/BACKLOG_archive_2026-06-27.md`.
> Gating tags: **[host]** agent-completable now · **[render-VM]** host model done, needs an on-screen/T5 VM session ·
> **[engine]** needs a live LSP/process · **[owner]** needs an owner decision/flip · **[built→flip]** done, gated off awaiting owner.

## 📊 Current state (reconciled 2026-06-28)

Board (shared `tasked` board, ~all markdown_viewer): **1658 total** · **749 in-flight**
(`review` 329 · `fixed` 88 · `reported` 279 · `ack` 32 · `triaged` 9). **~417 await owner close** (review+fixed).
0 live leases / 0 progress. The host-completable surface is drained — the next-50 below is mostly **render-VM / owner / engine**-gated.

> ⚠️ **The `reported` pool is INFLATED + state-corrupted by the INT-126 stale-lease sweep** — it mass-reset ~70 in-flight
> tickets progress→reported, #NNN-corrupted their `understanding`, and dropped some owner-decision parks. So a `reported`
> ticket may actually be mid-flight OR a built→flip awaiting you (e.g. **TSK-838** shows `reported/waiting:agent` but is a
> built→flip). `task_get` before trusting any state; do NOT hand-mutate the reset tickets (tool-path fix filed: **INT-128**).

## 🎯 Drain order

1. **P0a (AX self-driving) + P0b (validate the pile)** — host work DONE; both now owner-bound (P0a executor = TCC grant; P0b = on-screen close of the ~410 queue). See §"Owner-side unblocks".
2. **Then the Next-50 below**, user-facing value first.

## ⚡ Actionable now — autonomous drain queue (no owner flip/decision needed)
The runtick loop pulls from HERE first. Each can be driven to `review`/`validated`
WITHOUT an owner flip/decision — via the host gate, the agent-runnable WebView lane,
or a VM UI test I author. Validation is NAMED per item; riskiness is resolved by
validation, never used to defer or ask.

**User-facing (build/fix → host or WebView/VM-lane test → review):**
- **TSK-1271** — find can't-scroll-past: DIAGNOSED (real cause = find bar holds first responder, scroll keys never reach the webview; the report's DOM-re-scroll theory is refuted). Fix = forward scroll keys to the rendered webview while find is focused. Validate: VM/T4 key-routing UI test.
- **TSK-463 / TSK-1136** — wire LSP completion into CM6 (host bridge testable; WebView/VM proof).
- **TSK-924** — CSV multi-cell select + copy render wiring (model done + tested).
- **TSK-1139** — CSV viewport paging — wire `CSVRowWindowSource`.
- **TSK-958 / TSK-1163** — Universal Paste dispatcher (host model) + UI.
- **TSK-1128** — Settings ▸ LSP panel view (`languageStatuses` model done + tested).
- **TSK-1119** — walkthrough illustration overlay (SwiftUI view rendering the diagram verb).
- **TSK-1146** — spell/grammar inline squiggles (model + render).

**Internal / quality (host gate = full confidence → validated):**
- **TSK-1110** — DocumentModel SRP: **cohesive-logic extraction COMPLETE** (5835→3346 lines, ~43%, 57 extensions — verified fresh 2026-06-29; the once-listed clusters CM6-LSP/Command-registry/Editable-HEX/view-mode-lock were all carved). Remaining 3346 = the irreducible open/close/select orchestrators + @Published state (NOT behavior-preserving-movable). **Recommend owner close/de-scope** — no more safe exact-move slices.
- **TSK-538** — rust-core audit follow-ups (host children).
- **TSK-764 / TSK-1165 / TSK-1166** — git reconciliation + edit-reconcile / disk-conflict wiring (host model).
- **TSK-698 / TSK-703 / TSK-722 / TSK-723** — host-engine epics (build engine, host-test; render at review).
- **TSK-382** — DocumentModel memory squeeze (host where measurable).
- ongoing: coverage backfill + audit-hardening of uncovered pure-logic.

**Excluded — need YOU (not in the autonomous queue):** 838 flip · 1215/1202 rust flips · 1138 ratify · 543/589/810/1045/1129 decisions · the ~417 review/fixed close-queue · TCC grant.

## 🔥 Next 50 — prioritized work list

### P0 — user-facing bugs + perf the owner feels (1–12)
1. **TSK-838** — rendered-MD: persistent WKWebView + DOM-patch vs full `loadHTMLString` reload (kills the 2–9s reload storm). **[built→flip `MDV_DOM_PATCH`]**
2. **TSK-598** — opening MD files very laggy (re-reported). **[→ #1's flip]**
3. **TSK-1271** — rendered-MD Find: can't scroll past the currently-selected match. **[render-VM / JS]** *(NEW since last pull)*
4. **TSK-891** — Page-Up janky / not smooth in the editor. **[render-VM / perf]**
5. **TSK-910** — commit diff: only one line selectable → enable multi-line. **[render-VM]**
6. **TSK-1182** — diff multi-line select (plain-diff mode; collapse hunk into one Text). **[render-VM / owner design]**
7. **TSK-463 + TSK-1136** — LSP completion built but never invoked → wire into CM6. **[render-VM + engine]**
8. **TSK-924** — CSV table: multi-cell (rows+cols) select + copy/paste (model done — `CSVRectSelection`/`CSVCopy` tested). **[render-VM]**
9. **TSK-1141** — xlsx sheet UI + formula-recalc wiring (model done). **[render-VM]**
10. **TSK-377** — illustrations (PARTIAL). **[render-VM]**
11. **TSK-1032** — video-in-HEX-mode byte grid renders blank / doesn't mount. **[VM render bug]**
12. **TSK-1110** — DocumentModel SRP split — **cohesive-logic COMPLETE** (5835→3346, ~43%; Editable-HEX/view-mode-lock/CM6-LSP/Command-registry all carved this session). Remaining = irreducible open/close/select orchestrators + state; **recommend owner close/de-scope**. **[host DONE]**

### P1 — user-facing features (13–40)
13. **TSK-955** — RSS / Atom feed reader tool window. **[render-VM — host model+VM+view built; mount tail occlusion-class]**
14. **TSK-1149** — feed reader tool-window UI (list + WKWebView reader). **[render-VM]**
15. **TSK-1048** — Image Editor → MS-Paint parity + perf overhaul (epic; owner flagged "clunky"). **[render-VM]**
16. **TSK-1049** — image: off-main render pipeline + cached CIContext + cancellation (do-first perf). **[host model / render-VM]**
17. **TSK-1055** — image: make paint strokes undoable + unify with the lossless op-list. **[host model / render-VM]**
18. **TSK-1114** — image: wire selection UI (marquee/lasso + fill-selection). **[render-VM]**
19. **TSK-1168** — image: interactive on-canvas vector editing (create/drag/handles for VectorOverlayView). **[render-VM]**
20. **TSK-343** — image History / Revert (PARTIAL). **[render-VM + model]**
21. **TSK-1104** — multi-window: open + mount a real 2nd NSWindow on the MultiWindowRegistry foundation. **[render-VM]**
22. **TSK-1111** — bookmarks: "open in new view/window" affordance. **[render-VM]**
23. **TSK-1119** — walkthrough illustration overlay (SwiftUI view rendering the diagram verb). **[render-VM]**
24. **TSK-1123** — unified tool-window placement UI (Settings matrix, drag-drop render). **[render-VM]**
25. **TSK-1128** — Settings ▸ LSP panel: discovered-vs-missing servers + install hints + binary picker (model `languageStatuses` done+tested). **[render-VM]**
26. **TSK-751** — organize the menu items properly (spike+audit auto-approved). **[host/render]**
27. **TSK-283** — Enter-to-rename in the file nav. **[render-VM]**
28. **TSK-373** — New ▸ Code Review / Agent session / Project view (PARTIAL). **[render-VM]**
29. **TSK-942** — select lines → right-click → Reference/Comment-to-agent (+ shortcut). **[render-VM]**
30. **TSK-958 / TSK-1163** — Universal Paste: multi-type clipboard dispatcher + live UI wiring. **[host model + render]**
31. **TSK-318 / TSK-1108** — call an agent to ask questions about a CR (Q&A UI + transport). **[render-VM + engine]**
32. **TSK-769 / TSK-1176** — terminal UX bundle (open-in-pwd, tab rename, command history+favorites+search, colors). **[render-VM]**
33. **TSK-951 / TSK-1186** — ⌘K palette parity: ~40 menu-only / nil-verb commands missing from the palette. **[render-VM]**
34. **TSK-1139** — CSV viewport paging: wire the rendered table to `CSVRowWindowSource`. **[render-VM]**
35. **TSK-1146** — spell/grammar inline editor squiggles + LSP-diagnostics surfacing. **[render-VM]**
36. **TSK-1152** — rethink "View as" affordance — per-filename lock-icon control. **[render-VM]**
37. **TSK-1091–1096** — audio: AVAudioEngine graph + Audio-Unit browse/insert/host-UI/preset/MIDI (epic). **[render-VM]**
38. **TSK-1142** — in-app browser tab surface wired to `BrowserNavigationPolicy`. **[render-VM]**
39. **TSK-1145** — DOCX + multi-format viewer surface + XLSX-in-table rendering. **[render-VM]**
40. **TSK-1140** — PDF reader surface tail — find/tabs/sessions + PDFView live validation. **[render-VM]**

### P2 — internal / rust-core / build / test (41–50)
41. **TSK-379 / TSK-1117** — rust-core migration: stateful EditorBuffer + Tabs + DocumentModel projection in Rust. **[host / supervised]**
42. **TSK-543** — cm_apply stateful-delta redesign (kills ~10× doc-size FFI traffic per edit; the real typing-latency fix). **[owner decision]**
43. **TSK-382** — squeeze DocumentModel memory to bare-bones (measure-first — needs a VM memory profile). **[host / perf]**
44. **TSK-537** — Code Review feature epic (commit diffs, comments, export). **[render-VM + host]**
45. **TSK-538** — rust-core production-readiness audit follow-ups (epic; host children drained, deps + render-coupled tail remain). **[host]**
46. **TSK-764 / TSK-1165 / TSK-1166** — git reconciliation + ExternalEditReconciler / DiskConflict wiring (model done; render+data-safety tail). **[host + render]**
47. **TSK-1138** — Tier-D PTY/socket plugin contract — **design DELIVERED (aa03d6fc); re-parked for your RATIFICATION**. **[owner — ratify]**
48. **TSK-441–445** — board/CI infra: tests across v0.2–v0.5, check-validation path, deploy-snapshot footgun, commit-provenance. **[host / infra]**
49. **TSK-831 / TSK-852 / TSK-835** — CI/build perf: dedup SourceKit index tree (−1.7 GB), `.build` cache, cargo-nextest (dep). **[host / owner-dep]**
50. **TSK-698 / TSK-703 / TSK-722 / TSK-723** — host-engine epics: script-window (JQ), action-history, task-runner, structural-search. **[host engine + render]**

> **Done since the 2026-06-27 pull** (removed from the list): TSK-847 (gate +7%, `88b8f417`), TSK-1270 (find-highlights, validated), TSK-1151 (line-height, review), TSK-1202 (folds port, validated), TSK-400 (rpcd spike, validated), TSK-836/794 (timings/threading-audit, done). Coverage landed: RichTextSerializer, FileQuarantine, cspMeta, the Focus-shortcuts SRP slice.

## 🔓 Owner decisions (not "work" — your call unblocks them)
TSK-470 zoom-split model · TSK-683 app name · TSK-686 Developer-ID signing + notarization · TSK-276 debugger/DAP · TSK-293 encryption · TSK-296 markdown (scope?) · TSK-298 Java formatter ext-tool · TSK-781 LSP own-vs-external · TSK-1137 DIY mutation-tester option 1/2/3 · TSK-1287 crypto-hash for PM hash-chain · TSK-1182 diff-selection model · **TSK-1129 LSP workspace-binary RCE-guard enforcement (SECURITY)** · TSK-589 multi-doc session-eviction policy · TSK-810 hex/hexSearch Stage-B fallback model · TSK-1045 per-session DocumentModel sign-off · TSK-1138 Tier-D plugin ratification · TSK-508 digraph-render dep. *(TSK-775 rust-migration "do all" — RESOLVED 2026-06-12.)*

## 🌊 Wishlist epics (P6–P8 — slice when pulled, not yet prioritized)
TSK-687 deep agent integrations · TSK-688 walkthrough-as-presentation · TSK-689 PinBoard · TSK-690 tmux -CC attach (core done, TSK-1023) · TSK-691 own agent harness · TSK-693 tasks/worktrees/review surface · TSK-695 credential handling · TSK-697/699 Agent Services suite (TSK-1154 = remaining 4 MCP tools) · TSK-700 collaboration · TSK-701 SDLC workflow surface · TSK-702 Mac intelligence · TSK-706 RichText editor · TSK-713 more diagram formats · TSK-714 tab split · TSK-715 profiling/flame charts · TSK-725 inspections/intentions · TSK-772/773/777 plugin expansion + MCP + PDK · TSK-774 music · TSK-1083–1090 image-editor advanced tools (curve/polygon/shapes/brushes/text/layers).

## ⛔ Owner-side unblocks (the real bottleneck — I can't do these)
1. **Flip `MDV_DOM_PATCH`** — the #1/#2 perf win, built + VM-validated, gated off.
2. **Grant Accessibility + Automation TCC** — unblocks the P0a out-of-process AX executor (TSK-1254/1261/1263).
3. **Close the ~410 review/fixed queue** (`→ done`; render items by on-screen glance).
4. **Flip the rust ports** — formula `MDV_RUST_FORMULA` (TSK-1215, `waiting:human` + pending decision), folds `MDV_RUST_FOLD` (TSK-1202, port now **validated**); both parity-proven + render-safe-confirmed (2026-06-26). Plus **ratify TSK-1138** (Tier-D plugin design).
5. **Close TSK-590** (owner bug-list epic, 20/21 done; pending TSK-598 → the DOM-patch flip).

---
*Most of the Next-50 is render-VM / owner / engine-gated — the host-completable surface is drained. The autonomous loop drains this top-down, leaving render/VM validation at `review`; when no host work remains it validates / reconciles / audit-hardens and acts on the first new signal. Priority lives HERE + on the board; issues the agent must know live in CLAUDE.md / docs/TASK_WORKFLOW.md / memory.*
