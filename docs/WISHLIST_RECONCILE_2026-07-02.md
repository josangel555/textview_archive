# OwnerWishlist ↔ Board ↔ Feature-Inventory Reconciliation (2026-07-02)

**Owner ask:** full scan of the board + `OwnerWishlist.md`, reconcile against
`docs/FEATURE_INVENTORY.md`, identify gaps + how to fill them.

**Inputs scanned:** `OwnerWishlist.md` (1,302 lines incl. the DONE-verified section),
the tasked board's open lanes (~170 open tickets read title-by-title), and the
feature inventory (12 domains). **Method:** every open (`>` / `-`) wishlist item was
classified: ✅ DONE (in the wishlist's own verified-done section or verified in code),
🎫 COVERED (existing board ticket — cited), 🆕 GAP (no coverage → ticket filed today),
🧭 OWNER (product decision needed).

---

## 1. The headline numbers

- The wishlist's own DONE section verifies **~340 items** landed and not regressed.
- Of the open wishes, **~80%** map to existing board tickets (many pre-dating this
  pass: image-paint parity epic TSK-1048+children, AU/MIDI audio TSK-956/1091-1096,
  notebooks TSK-1172, sticky-scroll TSK-1173, multi-window TSK-1104, menu reorg
  TSK-1318/1319, 3-way merge TSK-1171, `~/.textview` TSK-1169, MD-open lag
  TSK-598/838, feeds TSK-955/1149, browser TSK-1142, PDF tail TSK-1140,
  action-history TSK-703/1155, RichText TSK-706/1156, agent-services TSK-697,
  flame-charts TSK-715/1158) — plus the new usability tree (TSK-1411 → 1434-1482).
- **15 genuine gaps** had NO coverage → filed today as TSK-1483..1497 (see §3).

## 2. Coverage map (wishlist theme → where it's tracked)

| Wishlist theme | Status |
|---|---|
| TextEdit/NotePad++/Sublime parity core | ✅ largely done (P0/P8 parity items verified) + FEATURE_INVENTORY families |
| Editor bugs (key nav, selection, lag) | 🎫 598/838/891/1179/1180 + 🆕 key-event-leak audit (1483) |
| Find (scroll-past-match, stale highlights) | 🎫 owner-intake range; verify-first before new work |
| CSV (cells/arrows/copy/sort) | 🎫 1472 + 🆕 grid navigation (1486) |
| Image editing (paint/layers/vector) | 🎫 epic 1048 + 1055/1083-1090/1114/1168/1426/1441 |
| Audio (record/EQ/AU/MIDI) | 🎫 956 + 1091-1096 + 1442 |
| Git (visualizer, gutter/blame, merge, history) | 🎫 764/1171/1185/1191/1443 + 🆕 repo visualizer (1492) |
| Code review (comments flow, agent Q&A) | 🎫 537/1108/1445 + intake "Posted" bugs |
| LSP (status, manager, runner, rename) | 🎫 1444/697 + settings-status wish folded into 1444 |
| Terminal (pwd/rename/history/colors/tmux) | 🎫 1249/1252/1475 + tmux = FEATURE_EXPLORATION owner call |
| Walkthrough (catalog, versioning, presentation) | 🎫 walkthrough epics + 1448 entry-points |
| Plugins (lifecycle, AWS-style, MCP-exposing) | 🎫 1478 + 1138 (Tier D) |
| Sessions (independence, saved, scroll state) | 🎫 1311/1045/1047 + 🆕 sessions-model decisions (1491) |
| Notebooks / omnibox / new-tab | 🎫 1172/1440 + 🆕 omnibox new-tab (1489) |
| Automation/agent (references, CDP, canvas) | 🎫 1192-1199/1264-1267 + Canvas (parked) |
| Perf-felt (palette, search, JSON, navigation) | 🎫 598/838/887/888/1179/1180/837 + 🆕 FPS instrumentation (1488) + 🆕 memory release (1490) |
| Theme/darkmode/fonts | 🆕 theme readiness audit (1484) |
| Instrumentation (status-bar memory, profiling) | 🎫 715/1158 + 🆕 1488 |
| DevTools (hash/encrypt utils, package explore) | ✅ partial (SHA/BASE64/UUID done) + 1147 + 🆕 run-configs (1493) |
| Headless/TUI/Web/remote core | 🎫 651 (remote-core epic) + rust migration 379/1117 |
| iOS/music-player/debugger/bytecode | 🆕 far-future epic (1497, parked) |

## 3. The 15 new gap tickets (TSK-1483..1497)

Cross-cutting/systemic (direct under TSK-1411):
- **1483 [P1][SYSTEMIC] Key-event / focus routing audit** — Enter-in-editor leaking to
  file-nav, snippets inserting at wrong focus, ⌘F misrouting. Owner: "root-cause and
  fix now itself."
- **1484 Theme-readiness audit** — dark-mode broken borders/text, Edit↔View font
  mismatch, grey special-chars.
- **1488 Render-FPS / jank instrumentation** (<60fps flagging + felt-perf harness).
- **1490 Memory-release audit** — ~200MB retained after tab close; doc-model squeeze.

Family children:
- **1485 Edit-location history + jump-back shortcut** (editor).
- **1486 CSV grid navigation** — arrow-key cell nav, multi-cell select/copy, column
  sort (data; sibling of 1472).
- **1487 Source-view per-line modification-age coloring** (viewing; the
  DarkBlue→LightBlue/green wish).
- **1489 New-tab omnibox / rich new-tab page** (chrome).
- **1493 Run configurations** — npm scripts / build-system runs in the task runner
  (devtools).
- **1494 Cursor mode** for view-only surfaces (viewing).
- **1495 Compressed-file-as-folder in the file tree** (data; extends 1469).

Owner-scoped (parked/flagged):
- **1491 Sessions-model product decisions** — sessions optional? hide single session
  tab? close window with last session?
- **1492 Git repository visualizer epic** (the "Windows Git visualizer" wish).
- **1496 Credential recognition/obscuring** (security).
- **1497 Far-future epic** — debugger (Java/Chrome), bytecode/assembly views, music
  player, iOS companion.

## 4. How the gaps get filled (the standing answer)

1. **Order:** cross-cutting first (1483 systemic bug + 1434-1437 components), then
   family children per epic — every ticket carries CONTEXT/FILES/BUILD/VALIDATE/
   DONE-WHEN for minimal-context subagent execution.
2. **Verify-first rule:** items from older wishlist sections may already be fixed
   (the intake TSK-13xx wave + the DONE section prove heavy drift) — every ticket
   says "dedupe/verify against code first" where uncertainty exists.
3. **Owner unlocks stay the multipliers:** TSK-1334 (pixels/AX → polish lane),
   flip TSK-838 (THE felt-latency fix, explicitly re-wished as "Very laggy when
   opening MD files"), finish-or-cut calls (1414/1418/1471), formula gate (788/1215).

*Companion docs: `FEATURE_INVENTORY.md` (the hierarchy + production-grade paths),
`USABILITY_AUDIT_2026-07-02.md` (the code-verification log).*
