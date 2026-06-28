<!-- CLAUDE-HANDOFF v1 -->
# Handoff — rust-core proptest vein: 16 suites (TSK-585) + DocumentModel SRP split at its pause  (2026-06-28)

**Session:** claude-mdv  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch:** `main` @ the find_engine proptest commit (verify `git log -1`)

## Mission
Autonomous drain loop (5-min cron). Drain BACKLOG → board. Build inline, ONE item/firing: spike→implement→test→host-gate (`bash scripts/test-headless-gate.sh`) / rust-gate (`bash scripts/rust-core-gate.sh`)→commit per item. Land rebase+ff; keep main gate-green. Fold doc updates into the item's commit. Never idle/stop.

## Landed THIS session — two veins
### A. rust-core proptest lane (TSK-585) — 16 suites, the dominant productive vein
Each = a new `proptest!` block in an engine's test module, rust-gate-green, committed per item. The **EMPIRICAL-SWEEP DISCIPLINE is the key lesson**: before declaring "no proptest targets left," grep `^pub fn` + IO-markers across `rust-core/crates/core/src/*.rs` for un-proptested PURE-LOGIC engines — it corrected a premature "ceiling" call FOUR+ times (markdown security, image, mermaid, runtime, find_engine were all found AFTER I'd nearly stopped).

Suites this stretch (on top of pre-existing cm_edit/csv/diff/filter/hex/fuzzy/formula/html_patch/json/outline/session/wire):
find · nav (filter/sort/history) · format · indent · theme · view · meta · table_arena · markdown (SECURITY: safe_url XSS + escape) · image (no-panic byte parser) · mermaid (parse no-panic + render_host XSS-safe) · history (MRU) · runtime (eviction_plan — MEATY memory-eviction contract) · find_engine (UTF-16 position validity + literal count).
Recent commits: meta `c7a1b22f` · table_arena `1a08d43c` · markdown `739eb73d` · image `e4109259` · mermaid `842af055` · history `0e2ea84d` · runtime `e12e5f32` · find_engine `<this commit>`.

### B. DocumentModel SRP split (TSK-1110) — 14 clean slices, ~1754 lines out (track ACTIVE; whole-MARK vein done, now grab-bag splits)
DocumentModel.swift 7692→5938. The clean WHOLE-MARK slices are extracted (folding/breadcrumb/scroll/view-mode-control/git-chip/HTML-JS). REMAINING = grab-bag MARKs needing mid-MARK sub-cluster splits (command-registry: keybindings + GoToPath, GoToPath's @Published lives outside the MARK; git-diff-gutter: 3 @Published + 3 Task handles + sticky-scroll + the shared loadedText; the rendered-HTML-cache remainder of the raw-HTML MARK) or entangled core (HEX/Opening/Tab). Each needs its own careful spike — extract the cohesive sub-cluster, leave the rest. Proven pattern: widen private stored state private→internal, move funcs; purgeCaches/etc. stay on the class + read internal. The "clean slice" test is NOT "no @Published" — it's "doesn't call the PRIVATE core opening machinery" (controller/updateDerived/recordOpenedFile/purgeCaches/startWatchingCurrentFile are all private). Breadcrumb passed (pure derivation from currentURL + a public revealInSidebar); Open-As LOOKED clean but is entangled via those private helpers (6 widens → leaks the core → that's track-2). Verify each candidate's deps before extracting. The slice-8 (code-folding) re-entry DISPROVED the "only HEX/Opening/Tab remain" claim — a fresh MARK scan found several cohesive clusters still cleanly extractable: git-diff-gutter (~299L), scroll-persistence (~428L), CM6-completion-bridge (~638L), view-mode-control (~166L), raw-HTML-JS (~240L). Re-scan, don't assume. Moved cohesive method groups to `DocumentModel+X.swift` extensions. KEY PATTERN: move the METHODS to a cross-file extension, LEAVE @Published/stored state on the main class (an extension can read/call members; it can't declare stored props or write a private(set) setter). Three sub-patterns for private state the moved methods touch: (a) VEND a setter for public-API private(set) contracts; (b) WIDEN private→internal for pure impl details; (c) MOVE the private helper with the group when all callers are in-set. All ZERO render risk.

## Next action (post-compaction — fresh context)
1. `git log -1` (expect the find_engine proptest commit); rust gate = `bash scripts/rust-core-gate.sh`; host gate = `bash scripts/test-headless-gate.sh`.
2. The rust property-test vein is **DONE** (dispatch::call landed `2df05f10` was the last genuine pure-logic target). rust-core has TWO equivalent property-test styles — the newer `proptest!` macro AND a long-standing DIY xorshift fuzz lane (`*_fuzz_*`, seed 0x9E37…) — and EVERY pure-logic engine now has one or the other. Do NOT add more rust property tests without first grepping for BOTH (a runs_utf16 proptest dup of `highlight_runs_fuzz` was reverted, e604296b). whitespace is trivial; git/trace/wasm_shape/bench/lib are IO/wire.
3. After the vein: the clean host-completable veins are spent (host features, 7 SRP slices, ~16 rust proptests). Remaining options:
   - **HEX / Opening-files / Tab-management SRP track-2** — entangled core, design-grade (see below); only if the owner wants it.
   - **owner-gated** (already parked, don't re-block): TSK-590, TSK-649, rust flips (1215/1202), TSK-838 DOM-patch flip.
   - **board hygiene**: reconcile the NEXT clear high-value stale `review` head if `task_next` surfaces one (don't churn the ~410 pool).
   - Re-run the empirical sweep for OTHER kinds of work — but the rust property-test vein is exhausted (grep both `proptest!` AND `*_fuzz_*` before assuming a gap).

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
~740 in-flight, ~410 await owner close (the bottleneck). TSK-585 = the proptest lane (board ticket stays open; the per-suite log is in CHANGELOG/AP). TSK-1110 = SRP (7 slices, stays `reported` — self-directed multi-slice). TSK-590/649 parked → owner. Agent ceiling = review (render) / validated-with-teeth (pure logic).

## How to resume
Zero memory of this conversation. `cd /Users/me/Documents/workspaces/claude/markdown_viewer`; `git log -1`; read this + `docs/TASK_WORKFLOW.md` + `BACKLOG.md`. The productive vein is the rust-core proptest lane — `dispatch::call` is the last genuine target; do it, then re-run the empirical sweep / check whether the owner answered the parked decisions (TSK-590/649/flips). Rust gate: `bash scripts/rust-core-gate.sh` (grep `==> Rust-core gate green.`).
