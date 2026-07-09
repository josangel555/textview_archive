# Backlog — CHUNKED WORKLIST · reorganized 2026-07-09 (owner ask)

> Board (http://localhost:8787/) is the system of record for STATE; this file is the pre-sorted
> selector, grouped into CHUNKS meant to be worked TOGETHER in one tick. `task_get` any TSK before
> working it — the board moves, this file lags; a ticket already `fixed`/`review`/`done` is a skip.
> DONE history: `archive/BACKLOG_batches_2026-07-07.md` + `archive/BACKLOG_archive_2026-07-07.md`.
> Repo (canonical): `/Users/me/Documents/workspaces/claude/markdown_viewer`.
> ⚠️ If Desktop&Documents iCloud sync is EVER re-enabled, relocate the repo out of ~/Documents FIRST.

## ★ WORK-LOOP MANDATE (owner, 2026-07-09 — OVERLOADED TICKS)

Each tick takes ONE **CHUNK** below (a group of 3–5 related tickets) and ships the WHOLE chunk in
one pass. Related-by-design so context is shared and the tests overlap.

1. **Pick the next chunk** top-down from §1 (skip owner-gated/[dep]/[XL]-not-your-model items — take
   the next actionable one). Don't re-plan mid-tick.
2. **Implement ALL tickets in the chunk** — code + the full test pyramid per ticket (see below) +
   any evals — in ONE go. Only targeted `swift test --filter` checks BETWEEN tickets, not a gate.
3. **ONE full gate at the END of the whole chunk** — `bash scripts/test-headless-gate.sh` (+
   `scripts/rust-core-gate.sh` if rust touched). Read the `GATE_DONE` rc marker in `tmp/`, not the
   wrapper exit. Bench-only failures: re-run isolated (TSK-1499). NOT a gate per ticket.
4. **ONE commit for the whole chunk** — list EVERY TSK id in the subject/body + the
   `Claude-Session:` trailer. Fold the CHANGELOG/HANDOFF/LESSONS updates into it.
5. **VM/AX rung** (only if render behaviour changed AND the VM lane is up, TSK-1550): batch the
   higher-order tests for the chunk in one VM run; attach the shared evidence.
6. **Board**: walk each ticket in the chunk reported→ack→triaged→progress→fixed→review with ONE
   shared `checks` artifact for the chunk. **NEVER `task_validate`** (owner validates). Blocked
   ticket ⇒ `task_park` it (Need-me if owner), keep the rest of the chunk moving.
7. HANDOFF ≤12KB current-state; rsync backup to `/Users/me/Local_Docs/local_workspace/markdown_viewer/`.

**PURE AUTONOMY — NO INLINE QUESTIONS.** Every question/decision/approval = a BOARD "Need me" gate
(`task_park` with homework + recommendation), then MOVE ON.

### TEST PYRAMID PER TICKET (mandatory — full map in `docs/TEST_PYRAMID.md`)

Every ticket names + builds its required evidence classes; the gate refuses `fixed` without them:
- **Pure logic / model / parser / FFI** → a HOST unit test (Swift Testing for new pure-logic;
  XCTest for tier-based/existing). This tier is ALWAYS required and is the floor.
- **Wiring / command-path / state outcome** → a HOST integration/behavior test that pins the
  select/close/toggle/commit OUTCOME (so a logic regression fails the host gate).
- **Render / view (SwiftUI/WebView pixels)** → host model test PLUS a VM rung: in-process WebView
  DOM (`webview`), T4 `LiveAppTestCase`, or a `MDV_UI_SCENE` window-id capture (READ the PNG). If a
  surface is genuinely un-drivable (view-local `@StateObject`, T5-TCC-gated) flag "on-screen
  UNVERIFIED — needs VM" + file the enabler; don't fake a green.
- **Interaction (click/drag/keypress)** → an AX real-event test (VM) OR exercise the exact wired
  action closure. A faithful pointer-drag is NOT synthesizable in-process (TSK-1188) → that rung is
  VM/AX; the model closures it calls are host-tested.
- **Perf** → MEASURE on the VM (PerfSignpost/xctrace, `scripts/vm-profile.sh`); gate absolute
  budgets, skip wall-clock-ratio asserts under the parallel gate (TSK-1499).

---

## §1 — BUILD CHUNKS (take one whole chunk per tick)

Each line is `TSK — one-liner`. Confirm state with `task_get` first; skip anything not `reported`.

### CH-A · Image editor — paint & shape tools  [parent 1048/1455]
- 1055 — make paint strokes undoable + unify with the lossless op-list (P0 do-first)
- 1114 — wire selection UI (marquee/lasso tool + fill-selection action)
- 1088 — zoom tool + grid + rulers + status-bar coords/selection-size
- 1441 — image-editor FEEL: tool/cursor feedback, save-vs-copy clarity, in-editor zoom/pan
- 1574 — shape gallery freeform members (heart / lightning / callouts) + on-screen UAT

### CH-B · Image editor — advanced tools (2nd image chunk)  [parent 1048]
- 1083 curve tool · 1084 polygon tool · 1089 real text tool (draggable box) · 1086 AA shapes ·
  1087 brush gallery · 1090 layers panel + compositing

### CH-C · Editor & markdown power tools  [parent 1450/1453]
- 1170 — snippets: CM6 tab-stop nav wiring + management UI
- 1173 — sticky scroll: pinned-header overlay over CM6
- 1570 — markdown outline panel: scroll-highlight + preview-mode jump
- 1505 — widespread spelling verb + UI integration
- 1504 — cheap editor assists: off-main visible-range spell + cached word-index completion

### CH-D · Devtools & code review  [parent 1456]
- 1571 — mount the Claude Session Monitor as a menu item (CLI-flag-only today)
- 1577 — git-panel RENDER scene (VM-capture the Status tab on a fixture repo)
- 1482 — menu-bar audit (naming, order, enablement, no orphan items)
- 1191 — migrate Git File-History/GitLogTab onto UnifiedHistoryView
- 318 / 1108 — code-review agent Q&A UI + transport

### CH-E · Data & format viewers  [parent 1454]
- 1205 — extracted-doc viewer: read-only spreadsheet GRID + lens-forcing
- 1423 — hex search ignores UNSAVED edits (searches file.data, not the buffer) — bug
- 1269 — wire ExternalEditReconciler (3-way auto-merge) into the dirty-reload flow (data-safety)
- 1165 — external-edit reconciler into the editor external-edit flow (non-blocking merge UX)
- 1203 — trust-mode slice 3b: failure surfacing + consent-gated network

### CH-F · Chrome, first-run & file-nav  [parent 1460/1451]
- 1572 — new-tab launchpad: recent-folders/bookmarks sections + arrow-nav + git-clone/paste
- 1575 — first-run: Help ▸ Capabilities rendered page + walkthrough launch points
- 1573 — recover-deleted-file: full enumeration (path manifest) + version picker
- 1104 — multi-window: mount a real second NSWindow on the MultiWindowRegistry foundation
- 1111 — bookmarks "open in new view/window"

### CH-G · Viewing & felt-perf  [parent 1452]
- 1488 — render-FPS / jank instrumentation: flag <60fps + a felt-perf harness
- 891 — Page-Up jank trace + fix
- 1047 — extend warm-WebView cache to the CM6 editor pane (session-switch retention)
- 1180 / 1184 / 1185 — perf traces (result-scroll · hover-synth mode · commit-menu latency)
- 838 — rendered-MD persistent page + DOM patch (closes 598; owner re-feels the flip)

### CH-H · Notebooks, diagrams & dynamic content  [parent 1453/1157]
- 1172 — notebooks: wire NotebookCellListView + kernel execution/storage
- 1171 — 3-way merge conflict-resolution 3-pane UI
- 1157 — real PlantUML/D2 renderers wired into the markdown render path
- 1158 — profiling / flame-charts / memory-diffs viewer UI
- 1319 — dynamic content-specific menu (per-visible-tab actions)

### CH-I · Web-migrate — CM6 / web grids  [parent 1524]  (M1/M2 need @codemirror/merge → §2)
- 1530 M6 read-only source view → CM6 read-only (kills the NSTextView 1MB choke)
- 1527 M3 CSV grid → virtualized web grid (rust windowed snapshot)
- 1531 M7 hex view → virtualized web monospace grid
- 1532 M8 transcript/monitor + Logs → web streaming lists
- 1533 M9 git log / unified history / blame → web (CM6 blame gutter)
- (2nd web chunk: 1528 M4 xlsx · 1529 M5 docx)

### CH-J · Test-pyramid gaps & host-safe infra  [mandate]
- 1551 — real-render suites for the 4 uncovered lenses (formatted / hex / table-CSV / diff)
- 1567 — fix the EditorAssistToggleTests --parallel flake (shared UserDefaults race)
- 1538 — dark-theme scene paints zero pixel-diff vs light (T5 dark-chrome guard RED)
- 441–445 — tasked-tool/CI items · 1329 / 1330 — INT tracker-feedback tickets

### CH-K · Rust-core H-B ports (SPIKE 1117 FIRST, then slice)  [parent 1117/1524]
- 1509 LSP domain · 1510 Git domain · 1511 Sessions/persistence · 1512 Automation verb registry ·
  1513 roadmap doc revise. Spike-gated: run the 1117 stateful-core spike before slicing.

---

## §2 — OWNER-GATED (Need-me cards; do NOT build — `task_park` if surfaced)
Decisions: 470 zoom-split · 508 digraph-render · 810 hex carve-out · 1322 paste-repro · 1349 canvas
M7+ · 1414 finish-or-cut spikes · 1418 orphaned WIP views · 1426 paint persistence · 1449 surface
consolidation · 1468 spreadsheet formula-flip · 1471 log-patterns finish-or-cut · 1491 sessions-model
· 1492 git visualizer · 1497 far-future · 1540 WV-on-host · 1549 find-regex expressiveness · 1200
editor-scroll-verb.  Deps: 835 nextest · 852 CI cache · 831 index-dedup · 1137 cargo-mutants · 1287
crypto-hash · 1138 Tier-D plugin · 1525/1526 @codemirror/merge (M1/M2).  Supervised: 1520/1521 (S5/S6
cutovers). **MASTER UNLOCK still open: 1334 T5 Screen-Recording grant** (blocks ALL T5-pixel).

## §3 — DESIGN-FIRST EPICS (spike auto-approved; several XL/Fable-class)
590 owner bug-list · 537 CR epic · 691 agent-harness · 703/1155 action-history · 706/1156 richtext
[XL] · 713/1157 diagram renderers · 715/1158 profiling · 764 git-reconcile · 956 + 1091–1096 AU
hosting (live-val) · 1048 image-parity epic · 1164 language-coverage matrix · 1311 session
independence · 1342 canvas spike · 1450–1460 usability-epic umbrellas · 1523 S8 remote parity ·
1524 rendering-stack policy.

## §4 — INFRA / AX / FOREIGN
AX tier (owner-declared off-limits): 1197–1199 UAT framework · 1261/1263–1266 ElementRef · 1543 AX
matrix.  VM infra (agent-workable, VM up): 1239 fd exhaustion · 1247 webview-blank · 1336 mermaid
occlusion T5 · 1365 WebContent hardening · 1541 rust coverage · 1542 Sequoia nag.  Reconcile: 1503
(SHIPPED 92dec034 — board-reconcile, not build) · 1506 salvage-branch integration (verify vs main).

## Living analyses (pointers)
WebUI surface-sharing → 1507 · rendering-stack policy → 1524 · whole-core migration → 1117 +
`docs/research/stateful-core-spike-2026-07-04/DESIGN.md` · agent services →
`docs/AGENT_SERVICES_DESIGN_2026-07-07.md` · meta-analysis →
`docs/research/project-meta-analysis-2026-07-04/SYNTHESIS.md` · usability →
`docs/FEATURE_INVENTORY.md` · test pyramid → `docs/TEST_PYRAMID.md`.
