<!-- CLAUDE-HANDOFF v1 -->
# Handoff — DocumentModel SRP split: 7 clean slices (~803 lines out), now at its natural pause  (2026-06-28)

**Session:** claude-mdv  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch:** `main` @ `c2248788` (verify `git log -1`)

## Mission
Autonomous drain loop (5-min cron). Drain BACKLOG → board. Build inline, ONE item/firing: spike→implement→test→host-gate (`bash scripts/test-headless-gate.sh`)→commit per item. Land rebase+ff; keep main gate-green. Fold doc updates into the item's commit. Never idle/stop.

## Landed THIS session — the DocumentModel SRP split (TSK-1110), 7 clean slices
DocumentModel.swift **7692→6889** (~803 lines out). Each slice moved a cohesive method group to a new `DocumentModel+X.swift` extension, host-gate-green, committed per item.

**KEY PATTERN (corrects the prior handoff's "needs a child @ObservableObject coordinator" framing — that was WRONG/over-cautious):** you do NOT need a coordinator. Move the METHODS to a cross-file extension and LEAVE the @Published/stored state on the main class. An extension CAN read/call the class's members; it just can't declare stored props or write a `private(set)` setter. Three sub-patterns for the private state the moved methods touch:
  - **(a) VEND** when it's a public-API `private(set)` contract — bookmarks (`bookmarks`/`lastBookmarkOpenWarning` → route writes through `publishBookmarksChange()` + a vended `setBookmarkOpenWarning(_:)`).
  - **(b) WIDEN** `private`→`internal` when it's a pure impl detail with no public contract — cross-search's `crossSearchGeneration`, HEX's `hexDirtyBytes`/`hexEditArmedTabs`.
  - **(c) MOVE** the private helper WITH the group when every caller is in it — active-doc's `activeTextFile`, git-log's `presentGitLogFailure`.
All 7 slices are ZERO render risk (no @Published moved → no observation change) — fully host-gate-validated.

Slices (commit): Format `b3251de2` · Save-a-Copy `83786b78` · Bookmarks `fc8d451f` · Cross-search `031b811b` · Active-doc-actions `38eefbc4` (+ doc-orphan FIX `78558aa7`) · File-history launchers `1bb9c1ee` · Git-log legacy `c2248788`.

Earlier this session: rust-core proptest vein (TSK-585) — find/nav×3/format/indent/theme (7 suites); TSK-1269 slice 1 (`19c251b2`); TSK-1210/1248/1294. Full detail in `docs/AUTONOMOUS_PROGRESS.md` + `CHANGELOG.md`.

## Key finding — the SRP split is at its NATURAL PAUSE
The clean-cohesive sections are all extracted. The REMAINING sections are ENTANGLED CORE, not clean slices:
- **Editable HEX (~273L, MARK ~3470)**: deeply interleaved — 3 stored vars (`hexDirtyBytes`/`hexEditArmedTabs`/`hexSavedNotifier`) + the `DisplayedText` struct + the GENERAL `displayedText`/`displayText` dispatchers (used by SplitPaneView/ContentView + many tests — they STAY) are wedged between the HEX-edit method clusters; `saveHexEdits` touches cross-cutting members (watcher / lspPool / repoFocus / tabCoordinator). Extraction = ~5 error-prone interleaved edits for a modest payoff. Defer unless an owner asks.
- **Opening files (~1000L) / Tab management (~850L)**: huge, core, entangled. Defer / careful-only.
Further SRP is design-grade track-2 (or skip). The mechanical clean wins are DONE.

## Board reconciliation this session
`task_next` surfaces a pool of MY stale-claimed `review` items mis-stated `waiting:agent` (the known ~410 "await owner close" bottleneck). Reconciled the top-2 prio-1 to `waiting:human` (owner-close queue): **TSK-590** (2026-06-10 bug-list epic — 20/21 children resolved; only TSK-598 WebKit-umbrella open, tracked on 838/839/840) and **TSK-649** (rust-core default-ON flip + Swift-twin delete — the migration payoff). Do NOT churn the whole stale pool (memory: the bulk/tool path is correct) — reconcile only clear high-value heads.

## Next action (post-compaction — fresh context)
1. `git log -1` (expect `c2248788`); host gate = `bash scripts/test-headless-gate.sh`; rust gate = `bash scripts/rust-core-gate.sh`.
2. The clean host-completable veins are spent (host features, 7 SRP clean slices, the meaty rust proptests). Remaining, rough preference:
   - **rust-core proptest — thin engines** (clean host-completable): `meta.text_metrics`, `view.clamp_line`/`table_col_widths`/`gutter_width` — LOW value but genuine. `whitespace.reveal`/`human_size` trivial (skip).
   - **render-VM host-model increments** (build model, leave render at review) — but most host models are ALREADY built (BACKLOG); verify before assuming work exists.
   - **HEX / core SRP track-2** — only if the owner wants the entangled design-grade extraction (see Key finding).
   - **owner-gated** (already parked, don't re-block): TSK-590, TSK-649, rust flips (1215/1202), TSK-838 DOM-patch flip.
   - **board hygiene**: reconcile the NEXT clear high-value stale `review` head if `task_next` surfaces one.

## Gotchas / lessons (also LESSONS.md + memory)
- **Extraction deletions MUST start at the `///` doc, not the `func`** — else the doc orphans + re-attaches to the next decl (compiles → host-gate is BLIND). Live miss this session (slice 5), fixed `78558aa7`.
- **Background gate exit gotcha**: a backgrounded `gate; echo` reports the ECHO's 0, not the gate's. Run the gate as the whole bg command; ALWAYS grep `==> headless gate PASSED` + `tier enforcement: OK` before committing.
- **Comments/docs-only change** → `swift build` is the relevant check (the headless-gate test surface is provably unaffected); still keep main green.
- **Cron context does NOT reset between firings** (only at auto-compaction).

## Tracker (board `tasked`, agent `claude-mdv`, ids `TSK-###`)
~740 in-flight, ~410 await owner close (the bottleneck). This session: TSK-1110 driven through 7 slices (board ticket stays `reported` — it's a self-directed multi-slice; the slice log lives in its comments); TSK-585 proptests; TSK-590/649 parked → owner. Agent ceiling = review (render) / validated-with-teeth (pure logic).

## How to resume
Zero memory of this conversation. `cd /Users/me/Documents/workspaces/claude/markdown_viewer`; `git log -1` (c2248788); read this + `docs/TASK_WORKFLOW.md` + `BACKLOG.md`. The mechanical clean host wins are spent (7 SRP slices; SRP at natural pause — HEX/core entangled track-2). Pull from the live board; cleanest remaining host drain is a thin rust-core proptest (low value) — or check whether the owner answered the parked decisions (TSK-590/649/flips), which would unblock closes. Gate: `bash scripts/test-headless-gate.sh` (verify real rc + PASSED markers).
