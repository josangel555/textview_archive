<!-- CLAUDE-HANDOFF v1 -->
# Handoff — DocumentModel SRP split: 15 slices, clean+grab-bag vein COMPLETE (TSK-1110); rust-core proptest vein done (TSK-585)  (2026-06-28)

**Session:** claude-mdv  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch:** `main` @ the git-diff-gutter SRP slice-15 commit (verify `git log -1`)

## Mission
Autonomous drain loop (5-min cron). Drain BACKLOG → board. Build inline, ONE item/firing: spike→implement→test→host-gate (`bash scripts/test-headless-gate.sh`) / rust-gate (`bash scripts/rust-core-gate.sh`)→commit per item. Land rebase+ff; keep main gate-green. Fold doc updates into the item's commit. Never idle/stop.

## Landed THIS session — two veins
### A. rust-core proptest lane (TSK-585) — 16 suites, the dominant productive vein
Each = a new `proptest!` block in an engine's test module, rust-gate-green, committed per item. The **EMPIRICAL-SWEEP DISCIPLINE is the key lesson**: before declaring "no proptest targets left," grep `^pub fn` + IO-markers across `rust-core/crates/core/src/*.rs` for un-proptested PURE-LOGIC engines — it corrected a premature "ceiling" call FOUR+ times (markdown security, image, mermaid, runtime, find_engine were all found AFTER I'd nearly stopped).

Suites this stretch (on top of pre-existing cm_edit/csv/diff/filter/hex/fuzzy/formula/html_patch/json/outline/session/wire):
find · nav (filter/sort/history) · format · indent · theme · view · meta · table_arena · markdown (SECURITY: safe_url XSS + escape) · image (no-panic byte parser) · mermaid (parse no-panic + render_host XSS-safe) · history (MRU) · runtime (eviction_plan — MEATY memory-eviction contract) · find_engine (UTF-16 position validity + literal count).
Recent commits: meta `c7a1b22f` · table_arena `1a08d43c` · markdown `739eb73d` · image `e4109259` · mermaid `842af055` · history `0e2ea84d` · runtime `e12e5f32` · find_engine `<this commit>`.

### B. DocumentModel SRP split (TSK-1110) — 15 slices, ~1904 lines out (clean+grab-bag vein COMPLETE; remainder is design-grade track-2)
DocumentModel.swift 7692→5788 (down ~25%). Extensions landed: folding/breadcrumb/scroll/view-mode-control/git-chip/HTML-JS/GoToPath/GitDiffGutter (+ earlier slices). The clean WHOLE-MARK slices AND the 3 viable grab-bag splits (HTML-JS opt-in/trust, GoToPath, git-diff-gutter diff/blame/split) are ALL DONE. **REMAINING is design-grade track-2 ONLY — do NOT force autonomously:** (a) **keybindings half** — LOW-ROI ~20L: the `commandRegistry` lazy-init itself calls `logKeybindingResult`, so the logger + lazy state MUST stay on the class; only loadKeybindings+invokeCommand cleanly move, which doesn't separate the real concern (the registry init IS the meat). (b) **git-diff-gutter REMAINDER** (editor-folds refreshEditorFolds/editorFoldsTask + sticky-scroll stickyScrollHeaders/recompute) — coupled via refreshEditorFolds→recompute→sticky + shared loadedText. (c) **rendered-HTML-cache remainder** of the raw-HTML MARK — shares `renderedHTMLCache` with the render path + purgeCaches. (d) **HEX/Opening/Tab** entangled core (see entangled-tail section). Each needs owner-grade judgment, not a mechanical move. KEY PATTERN (all 3 used, proven): move METHODS to a cross-file extension, LEAVE @Published/stored state on the class (an extension can read/call members but can't declare stored props or write a `private(set)` setter) — (a) VEND a setter for @Published private(set) contracts (e.g. setSourceDiffMarks); (b) WIDEN private→internal for impl-detail state (e.g. diffMarksTask); (c) MOVE a private helper with the group when all callers are in-set (e.g. resolveGutterRoot). The "clean slice" test is NOT "no @Published" — it's "doesn't call the PRIVATE core opening machinery" (controller/updateDerived/recordOpenedFile/purgeCaches/startWatchingCurrentFile). Verify each candidate's deps before extracting (Open-As LOOKED clean but is entangled via those private helpers → track-2). ALL 15 slices ZERO render risk + host-gate-green + committed per-slice.

## Next action (post-compaction — fresh context)
1. `git log -1` (expect the git-diff-gutter SRP slice-15 commit); host gate = `bash scripts/test-headless-gate.sh`; rust gate = `bash scripts/rust-core-gate.sh`.
2. **Both big autonomous host veins are COMPLETE**: (a) rust-core proptest lane (TSK-585) — DONE (grep BOTH `proptest!` AND `*_fuzz_*` before assuming any gap; a dup was reverted e604296b); (b) DocumentModel SRP split (TSK-1110) — the clean/mechanical + viable grab-bag slices are ALL extracted (15 slices, 7692→5788, ~25%). What remains of SRP is design-grade track-2 ONLY (§B + entangled-tail) — do NOT force it autonomously; it needs owner-grade judgment.
3. So the host-completable autonomous work is genuinely spent. Remaining options, in order:
   - **board hygiene**: `mcp__tasked__task_next` — reconcile the NEXT clear high-value stale `review`/`fixed` head toward the owner-close queue (don't churn the ~410 pool); validate a `fixed` pure-logic item with teeth if one surfaces.
   - **owner-gated** (already parked, don't re-block): TSK-590, TSK-649, rust flips (1215/1202), TSK-838 DOM-patch flip.
   - **empirical re-sweep** for OTHER work kinds (a newly-uncovered pure-logic engine, a backlog P0) — but the two named veins are exhausted.
   - SRP track-2 (keybindings / git-diff-gutter-remainder / rendered-HTML-cache / HEX / Opening / Tab) ONLY if the owner asks.

## SRP split — track ACTIVE (clean clusters remain); the entangled tail (track-2, design-grade)
- **Editable HEX (~273L)**: 3 stored vars + DisplayedText struct + the GENERAL displayedText/displayText dispatchers (used widely — they STAY) are interleaved between HEX-edit clusters; saveHexEdits touches watcher/lspPool/repoFocus/tabCoordinator. ~5 error-prone interleaved edits, modest payoff.
- **Opening files (~1000L) / Tab management (~850L)**: huge, core, entangled. Careful-only.

## Gotchas / lessons (also LESSONS.md + memory)
- **Empirical-sweep before "no targets left"** — grep for un-proptested pure-logic engines; it found 5 genuine targets after I'd nearly called a ceiling (the cron's "there's always work", vindicated).
- **rust proptest gotchas**: avoid bare `as` casts + `.unwrap()` (rust-gate ratchets them) — use `u64::try_from(i).unwrap_or(0)` + `if let Ok(..)`. prop_assert! uses POSITIONAL format args (`{:?}`, x), not inline captures. Match arms of different array sizes don't unify — use `(Vec<u8>, …)` tuples. Bind a temp before `.as_deref()` (E0716).
- **Compaction resets Read-tracking** — re-Read a file (Read tool, not grep) before Edit even if you edited it pre-compaction.
- **Background gate exit gotcha**: a backgrounded `gate; echo` reports the ECHO's 0. Run the gate as the whole bg command; ALWAYS grep `==> Rust-core gate green.` / `==> headless gate PASSED` before committing.
- **Extraction deletions MUST start at the `///` doc, not the `func`** (SRP) — else the doc orphans (compiles → gate blind).
- **Cron context does NOT reset between firings** (only at auto-compaction).

## Tracker (board `tasked`, agent `claude-mdv`, ids `TSK-###`)
~740 in-flight, ~410 await owner close (the bottleneck). TSK-585 = the proptest lane (board ticket stays open; the per-suite log is in CHANGELOG/AP). TSK-1110 = SRP (15 slices, clean+grab-bag vein complete; stays `reported` — self-directed multi-slice; remainder is design-grade track-2). TSK-590/649 parked → owner. Agent ceiling = review (render) / validated-with-teeth (pure logic).

## How to resume
Zero memory of this conversation. `cd /Users/me/Documents/workspaces/claude/markdown_viewer`; `git log -1` (expect git-diff-gutter slice-15); read this + `docs/TASK_WORKFLOW.md` + `BACKLOG.md`. Both big host veins (rust proptest TSK-585, SRP split TSK-1110) are COMPLETE — the remaining SRP is design-grade track-2 (owner-grade). Fall to board hygiene (`mcp__tasked__task_next`) / an empirical re-sweep for other work kinds / check whether the owner answered the parked decisions (TSK-590/649/flips). Host gate: `bash scripts/test-headless-gate.sh` (grep `==> headless gate PASSED`).
