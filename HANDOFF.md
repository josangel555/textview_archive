<!-- CLAUDE-HANDOFF v1 -->
# Handoff — wishlist BUG BUCKET fully drained (14 fixes); minor-features + owner decisions next  (2026-06-13)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `41a9dca`

## Mission
Owner away until ~noon 2026-06-13; overnight autonomous chipping of the 2026-06-13 wishlist. USER-FACING
bugs first; validate across the pyramid (human not in loop); keep `main` headless-gate-green; land per item
via rebase+ff. Read `docs/TASK_WORKFLOW.md` every firing (esp. §0.5 spike+design autonomy + chipping order).

## Standing directives (2026-06-13)
- **Spike + design AUTO-APPROVED** (TASK_WORKFLOW §0.5 / memory `feedback_spike_design_autonomy`): never
  `task_park` just because something needs design/an-approach-decision. Re-surface ONLY a genuine dep
  approval / true undifferentiated ambiguity / hard blocker, post-spike.
- **Chipping order:** regressions → bugs → minor-features(no-design) → epics(spike→design→ship) → very-large.
- **Per-tick cadence:** land 1–2 items per tick with teeth; keep `main` green; commit + log each.

## DONE this overnight run — the WHOLE wishlist bug bucket (TSK-728..744), 14 fixes
All teeth-tested (mutation→red→restore), headless gate green on every commit. Two validation states:
- **VALIDATED (8, self-validated — model/pure-logic, host pixel-equivalent for the terminal cell grid):**
  739 Cmd+F toggle · 742 preview-slot stale buffer · 744 preview scroll-leak · 729 View-Only shows dirty
  buffer · 737 gutter last-line off-by-one · 740 terminal in-line edits DCH/ICH/ECH/IL/DL · 735 terminal
  DEC scroll region (DECSTBM) · 731 terminal emoji/CJK double-width.
- **REVIEW — VM-gated render/event/concurrency (6): the owner's noon VM queue:**
  734 StatusBar crash (git off the layout path) · 728 Enter→sidebar · 730 editor keys ·
  738 status-footer folder-gate · 736 hover-lag dedupe · 741 PTY write off-main.
- **FIXED, awaiting owner A/B (1):** 743 scroll "preserve" — independent-scroll done; "remember-on-return"
  needs a per-URL store (recommend confirming the interpretation). Filed: **TSK-806** (split-pane source
  sibling of 729).

## Earlier this session (pre-bug-bucket)
Owner wishlist intake via ultracode workflow (184 lines → 136 tickets, tag `wishlist-2026-06-13`,
`[WISH][P-tier][bucket]` titles; source/report in `docs/research/wishlist-2026-06-13/`). All 61 over-parks
converted to `spike`. VM FULLY UNBLOCKED (owner's 6GiB + Screen-Recording: headless 3098/0/no-hang →
TSK-451 closed; T5 pixel lane works). 3 spike docs (Rust migration plan, LSP/plugin boundary, test-stack)
under `docs/research/*-2026-06-13/`. rust-core: TSK-572/570 validated. Directives codified in TASK_WORKFLOW
§0.5 + CLAUDE.md + LESSONS + memory.

## How to resume
1. Read `docs/TASK_WORKFLOW.md`. `task_list {project:tasked}` for state.
2. **The bug bucket is DONE** — do NOT re-pick 728..744. Next per the chipping order = the
   **`[WISH][minor-feature]` bucket** (54 created items, ~TSK-745..760 + others). MOST are UI/menu wiring
   (live-gated): land the model layer host-tested, hold the on-screen part at `review` for the VM (as the
   6 bug-bucket review items were). Look for genuinely headless ones first (recents model, checksum engine,
   shortcut catalog = a research doc).
3. **Owner decisions waiting at noon** (`task_list {waiting:human}` + the items above): 743 A/B;
   spike §6 of `docs/research/rust-migration-plan-2026-06-13/PLAN.md` (3 calls); terminal Tier-D (781);
   dep approvals 584/585/587/399. Suggest the owner clear the VM review queue (734·728·730·738·736·741)
   + the 743 A/B before the minor-feature wave.
4. Gates: `bash scripts/test-headless-gate.sh` (host, one at a time) · `bash scripts/rust-core-gate.sh`.
   VM (now working): rsync + `bash scripts/test-in-vm.sh test --filter <Suite>` (headless) /
   `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> ... --filter <T5 suite>` (pixel).

## Gotchas / lessons (also in LESSONS.md)
- Terminal cell grid = the source of truth the view draws → cell-level XCTest assertions are the host
  pixel-equivalent (self-validatable, like the rust TUI TestBackend). Used for 740/735/731.
- Render/event/concurrency behavior (AppKit key routing, SwiftUI re-render observation, PTY off-main) →
  host-test the LOGIC, hold at `review` for VM (don't over-claim validated).
- A conservative widening table (default-1) can't regress un-tabled inputs — how 731 stayed safe.
- An agent `task_restate` (reported→ack) clears a `waiting:human` park; `task_record` needs `to` set or it
  stays in place; fixed→review needs `summary` (not `note`).
- Demonstrate teeth every fix: mutate→red (confirm the mutant COMPILED: grep `Compiling <module>`)→restore.
