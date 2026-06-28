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

## 🔥 Next 50 — prioritized work list

### P0 — user-facing bugs + perf the owner feels (1–13)
1. **TSK-838** — rendered-MD: persistent WKWebView + DOM-patch vs full `loadHTMLString` reload (kills the 2–9s reload storm). **[built→flip `MDV_DOM_PATCH`]**
2. **TSK-598** — opening MD files very laggy (re-reported). **[addressed by #1's flip]**
3. **TSK-1270** — rendered-MD Find: highlights remain after dismissing the bar. **[render-VM / JS]**
4. **TSK-891** — Page-Up janky / not smooth in the editor. **[render-VM / perf]**
5. **TSK-910** — commit diff: only one line selectable → enable multi-line. **[render-VM]**
6. **TSK-1182** — diff multi-line select (plain-diff mode; collapse hunk into one Text). **[render-VM / owner design]**
7. **TSK-463 + TSK-1136** — LSP completion built but never invoked → wire into CM6. **[render-VM + engine]**
8. **TSK-1279** — dark-mode genuine breaks (first audit done; needs VM dark-mode pixel survey). **[render-VM]**
9. **TSK-924** — CSV table: multi-cell (rows+cols) select + copy/paste. **[render-VM]**
10. **TSK-1141** — xlsx sheet UI + formula-recalc wiring (model done). **[render-VM]**
11. **TSK-377** — illustrations (PARTIAL). **[render-VM]**
12. **TSK-1151** — View↔Edit line-height + size-rounding mismatch (CM6 1.45 / Int-round). **[render-VM]** *(verify still open)*
13. **TSK-1110** — DocumentModel SRP split — **15 slices landed this session** (~1900 lines / ~25% carved out of the 7692-line monolith into `DocumentModel+X.swift` cross-file extensions); the clean vein is drained. Grab-bag clusters remain. **[host]**

### P1 — user-facing features (14–37)
14. **TSK-955** — RSS / Atom feed reader tool window. **[render-VM — host model+VM+view all built; mount tail is occlusion-class]**
15. **TSK-1048** — Image Editor → MS-Paint parity + perf overhaul (epic; owner flagged "clunky"). **[render-VM]**
16. **TSK-1049** — image editor: off-main render pipeline + cached CIContext + cancellation (do-first perf). **[host model / render-VM]**
17. **TSK-1055** — image editor: make paint strokes undoable + unify with the lossless op-list. **[host model / render-VM]**
18. **TSK-1114** — wire selection UI (marquee/lasso + fill-selection) into the image editor. **[render-VM]**
19. **TSK-343** — image History / Revert (PARTIAL). **[render-VM + model]**
20. **TSK-1104** — multi-window: open + mount a real 2nd NSWindow on the MultiWindowRegistry foundation. **[render-VM]**
21. **TSK-1111** — bookmarks: "open in new view/window" affordance. **[render-VM]**
22. **TSK-1119** — walkthrough illustration overlay (SwiftUI view that renders the diagram verb). **[render-VM]**
23. **TSK-1123** — unified tool-window placement UI (Settings matrix, drag-drop render). **[render-VM]**
24. **TSK-1128** — Settings ▸ LSP panel: discovered-vs-missing servers + install hints + binary picker. **[render-VM]**
25. **TSK-751** — organize the menu items properly. **[host/render]**
26. **TSK-283** — Enter-to-rename in the file nav. **[render-VM]**
27. **TSK-373** — New ▸ Code Review / Agent session / Project view (PARTIAL). **[render-VM]**
28. **TSK-942** — select lines → right-click → Reference/Comment-to-agent (+ shortcut). **[render-VM]**
29. **TSK-958** — Universal Paste: multi-type clipboard dispatcher. **[host model + render]**
30. **TSK-318 / TSK-1108** — call an agent to ask questions about a CR (Q&A UI + transport). **[render-VM + engine]**
31. **TSK-943** — share LSP/lint/diagnostics with the agent + live runtime access. **[engine]**
32. **TSK-944** — internal browser automation (MCP). **[engine]**
33. **TSK-945** — security-audit integration. **[engine]**
34. **TSK-698** — script command window: JQ-style query/transform over tab contents (epic). **[host engine + render]**
35. **TSK-703** — unified action history (all actions reversible) + history view (epic). **[host model + render]**
36. **TSK-722** — task/command runner: run tests & npm/package scripts from the app (epic). **[engine — sandbox design]**
37. **TSK-723** — structural search (epic). **[host engine + render]**

### P2 — internal / rust-core / build / test (38–50)
38. **TSK-379 / TSK-1117** — rust-core migration: stateful EditorBuffer + Tabs + DocumentModel projection in Rust. **[host]**
39. **TSK-400** — `mdvcore-rpcd`: expose core over compact binary RPC (remote SwiftUI/TUI). **[host spike]**
40. **TSK-382** — squeeze DocumentModel memory to bare-bones (measure-first). **[host / perf]**
41. **TSK-537** — Code Review feature epic (commit diffs, comments, export). **[render-VM + host]**
42. **TSK-538** — rust-core production-readiness audit follow-ups (epic). **[host]**
43. **TSK-836** — capture per-class swift-test timings, then split the slowest. **[host / CI]**
44. ~~**TSK-847**~~ — **✅ DONE 2026-06-28 (88b8f417)**: gate runs `--num-workers 18`, measured +7% (12w=101s → 18w=94s; 32w flakes under 2.7× oversubscription). **[fixed — awaiting owner close]**
45. **TSK-837** — unprimed-subagent sweep for app latency + test speed (measure-first). **[host / perf]**
46. **TSK-764** — Git: non-blocking merge-style reconciliation on local↔disk/remote conflict. **[host + render]**
47. **TSK-1138** — Tier-D PTY/socket plugin contract — **design DELIVERED (aa03d6fc · `docs/PLUGINS_TIER_D_DESIGN_2026-06-22.md`); re-parked for your RATIFICATION** (new security surface — persistent raw-bidi-IO process — needs sign-off before impl). **[owner — ratify]**
48. **TSK-794** — audit: are we using generous multi-threading/async + inlining/specialization. **[host audit]**
49. **TSK-584** — fuzzing lane (cargo-fuzz over highlight/web/wire). **[blocked — CDN; dep approved]**
50. **TSK-587** — wasm32 tier-1 shim + execution test (portable core). **[blocked — CDN; dep approved]**

## 🔓 Owner decisions (not "work" — your call unblocks them)
TSK-470 zoom-split model · TSK-683 app name · TSK-686 Developer-ID signing + notarization · TSK-276 debugger/DAP · TSK-293 encryption · TSK-296 markdown (scope?) · TSK-298 Java formatter ext-tool · TSK-775 rust-migration plan · TSK-781 LSP own-vs-external · TSK-1137 DIY mutation-tester option 1/2/3 · TSK-1287 crypto-hash for PM hash-chain · TSK-1182 diff-selection model.

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
