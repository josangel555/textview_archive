<!-- CLAUDE-HANDOFF v1 -->
# Handoff — validation-drain + review-lane reconciliation (post wishlist wave)  (2026-06-13 ~00:30)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ 3c95f3c

## Mission
Rust-core → Swift-core deprecation (epic TSK-651); USER-FACING bugs first; work the
`tasked` board; validate with automated tests; keep main gate-green. The wishlist feature
wave is DONE; current focus is the VALIDATION DRAIN (§1.5) — reconciling the stale
review/progress lanes against what later work changed, converting "fixed-but-unguarded"
limbo items into genuinely-guarded validated ones.

## Current state
- **This session's validation-drain closures (all VALIDATED with real teeth-guards):**
  - TSK-123 (session_table whole-Table clone, S2) — arena work made it structurally
    impossible; added an FFI hot-path pin forbidding a to_table() revert (4b3ec3e).
  - TSK-122 (HexView 50k-match repaint, S2) — added the render-path consumption pin
    proving applyHighlights uses the O(2) fast path (5daa3dd).
  - TSK-655 (fs.watch push protocol design, P1) — realized by TSK-662/663/664 (6b914cd).
- **TSK-333 (bookmark Delete-key + undo) — COMPLETED** end-to-end this session: the
  undo command was wired in TSK-330; added the Delete-key handler (53f2f51). Fixed.
- **TSK-329 (File New) — BUILT + landed (ec231bc, installed):** NewFileCreator had zero
  UI callers; wired File→New File (⌘N) + folder right-click "New File" + immediate
  tree refresh. Fixed (live glance).
- **In flight: NOTHING.** Tree clean at 3c95f3c, gate-green (clean single run).
- **Next action: continue the validation drain.** Remaining review-lane items: TSK-114
  (agent dogfood feedback — likely a note/dismiss), TSK-590 (the bug-list EPIC — all
  children validated, can close as the parent). Then board hygiene on the zombie
  `progress` lane (~20 tickets, many claimed by the retired `claude` agent with leases
  expired ~8 days — reconcile/dismiss-with-proof/finish per §3 hygiene). THEN big
  owner-shaped features if nothing else.

## Key decisions & rationale
- **The board is NOT input-bound** (corrected my own premature "hold" — the directive's
  named pools were all validated, but the review/progress lanes hold real drain work).
- **Validation-drain pattern**: re-run a review item's evidence FRESH against current
  code; if later work (e.g. the TSK-546 arena) changed the landscape, the fix may now be
  guardable — add the missing teeth-guard, then validate. This caught the unguarded perf
  properties the prior agent honestly refused to self-validate.
- **A design ticket is validated when its implementation works** (TSK-655 via 662/663/664).

## Gotchas / lessons (durable forms in LESSONS.md)
- **Two gate runs at once thrash the machine** → wall-clock-timing suites (FoldBench,
  RepoFocusTrackerTests) flake. Run ONE gate at a time; re-run timing/bench reds ISOLATED
  before chasing — they pass 5/5 isolated.
- A perf property that produces byte-identical output (clone vs borrow; full vs O(2)
  repaint) can't be caught behaviorally — needs a structural or source-wiring pin.
- Adding code that string-slices in rust-core trips the `string_slice` lint (TSK-566) —
  use split_once/split/.get(), not `&s[a..b]`.
- Same-second SwiftPM staleness: confirm a mutant COMPILED (grep `Compiling <module>`)
  before trusting a teeth result.

## Files that matter (this session's new surfaces)
- `Sources/ViewerUI/DocumentModel.swift` — `createNewFile(in:)` + `newFileTargetDirectory`
  (TSK-329); `undoLastBookmarkRemoval` (TSK-330).
- `Sources/ViewerUI/SidebarModel.swift` — `reloadChildren(of:)` (immediate tree refresh).
- `Sources/MarkdownViewer/main.swift` — `newFile(_:)` action + validateMenuItem gate.
- `rust-core/crates/ffi/src/tests.rs` — `session_table_ffi_encodes_from_spans_not_a_clone`.
- `Tests/ViewerUITests/HexHighlightFingerprintTests.swift` — render-path consumption pin.
- `docs/REMOTE_PROTOCOL.md` — the realized remote protocol (TSK-655).

## Open questions / blockers (owner)
- **3 parked product decisions** (costed options on each ticket): TSK-336 hook-event
  surfacing · TSK-338 plugins/MCP/walkthroughs consolidation · TSK-316 walkthrough mgmt.
- **TSK-649 stage B**: per-engine Swift-twin deletion sign-off (docs/STAGE_B_DELETION_PLAN.md).
- **Supervised MountedPanesLRU session** (TSK-598 family): the FPS strip (TSK-275) is its
  live before/after readout; needs you watching (WV race history).
- **The glance batch** (one relaunch, one sitting — now ~15 installed features incl. New
  File ⌘N, bookmark Delete-key, fonts, archives, fuzzy filter, theming, FPS strip, etc.).
- TSK-306 validation bar (carried).

## Tracker (project `tasked`, agent `claude-mdv`)
- `waiting:human`: TSK-649, TSK-336, TSK-338, TSK-316. Validated this session: 122, 123,
  655 (+ the wishlist wave earlier). Fixed (live glance): 327, 329, 330, 333, 637, 638,
  640, 641, 642, 259, 275, 282, 284, 311, 317, 666.

## How to resume
1. Read `docs/TASK_WORKFLOW.md`. `task_list {waiting:human}` FIRST (owner answers
   outrank). Then continue the validation drain: `task_list {state:review}` and
   `{state:progress}` — re-verify host-testable items against current code; close zombies.
2. Owner-answer playbook: glance-confirmed → task_validate citing held evidence; park
   answered → execute the chosen costed option.
3. Gates: `bash scripts/test-headless-gate.sh` (ONE at a time) + `scripts/rust-core-gate.sh`.
   Re-run any FoldBench/RepoFocusTracker red ISOLATED before believing it. After rust
   wire/serve changes rebuild `/private/tmp/mdv-rust-target` mdv-serve. Install after
   user-facing change: `bash scripts/build-app.sh debug --install`.
4. NEVER run two gate/test sweeps concurrently — it flakes the timing suites.
