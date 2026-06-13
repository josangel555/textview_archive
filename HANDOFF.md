<!-- CLAUDE-HANDOFF v1 -->
# Handoff — wishlist intake done · VM unblocked · spike-autonomy directive  (2026-06-13)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `213b73f`

## Mission
Rust-core production-readiness + Swift→Rust migration (epics TSK-538/651); USER-FACING bugs first;
work the `tasked` board; validate across the pyramid (human not in loop); keep `main` headless-gate-green;
land per item via rebase+ff. Read `docs/TASK_WORKFLOW.md` every firing — **now including the new §0.5**.

## NEW standing directives (2026-06-13 — read these)
- **Spike + design are AUTO-APPROVED** (TASK_WORKFLOW §0.5 / CLAUDE.md / memory
  `feedback_spike_design_autonomy`). For any non-trivial ticket the agent runs the spike
  (scope/what-exists/feasibility/options) AND produces the design + breakdown AUTONOMOUSLY, then
  implements. NEVER `task_park` just because something "needs design / a decision on approach."
  Re-surface to the owner ONLY (post-spike) for: a genuine **dep approval**, a **true
  undifferentiated ambiguity**, or a hard **blocker**.
- **Chipping order:** regressions → bug fixes → minor-features(no-design) → epics(spike→design→
  breakdown→ship in slices) → very-large(file-and-forget).

## Current state
- **VM fully unblocked** (owner bumped 4→6GiB + granted Screen-Recording). Headless sweep: 3098/0/no-hang
  (TSK-451 closed). T5 pixel lane passes in the GUI session (TSK-492 Track B done). Both lanes usable now —
  recipes in `scripts/test-in-vm.sh test --filter ...` (headless) and `MDV_VM_GUI_SESSION=1
  MDV_VM_SUDO_PASS=<vm-sudo-password> ... --filter <T5 suite>` (pixel). The ~25 live-validation fixed-lane items can now
  be drained on the VM.
- **Wishlist intake complete:** 184 lines → 136 tickets (TSK-670..TSK-805), tag `wishlist-2026-06-13`,
  `[WISH][P-tier][bucket]` titles. Source/report in `docs/research/wishlist-2026-06-13/`. All 61 over-parked
  items converted to `type:spike`/`ack`/waiting:agent (gates cleared).
- **Landed+validated this session:** TSK-572 (trace atomic fast-path), TSK-570 (helper dedup + git
  sandbox-argv single-source). Triaged: 573 (web palette, conservative no-visible-change), 575 (clippy
  cast-truncations), 492 (UI self-validation harness — Track A nightly-wiring still to do).

## In flight (background agents — will notify)
- **Dedup agent:** reconcile [WISH] tickets vs the pre-existing backlog, dismiss clear dups (auto-approved).
- **3 spike agents:** TSK-775 (Rust migration plan → `docs/research/rust-migration-plan-2026-06-13/`),
  TSK-781+779 (LSP own-vs-external + plugin/core boundary → `docs/research/lsp-and-plugin-boundary-2026-06-13/`),
  TSK-787+788 (test-stack audit → `docs/research/test-stack-audit-2026-06-13/`). Each writes a findings/design
  doc + advances its ticket ack→triaged, re-parking only on a real blocker.

## How to resume
1. Read `docs/TASK_WORKFLOW.md` (esp. §0.5). Check the in-flight agents' results landed on the board +
   their docs under `docs/research/*-2026-06-13/`.
2. **Chip the bug bucket first:** `task_list {project:tasked, q:"WISH", state:reported}` → the `[WISH][bug]`
   tickets (TSK-728..744) are concrete user-facing defects, no gate. Several are headless-actionable
   (state/model bugs: 729/733/738/742/743/744; terminal 740/735 via the TUI TestBackend pixel-teeth). Fix,
   teeth-test, gate, commit, then VM-validate the rendered ones (VM now works).
3. Then the 54 created minor-features, then work the `spike` tickets (spike→design→implement, autonomous).
4. Drain the ~25 live-validation `fixed` items on the now-working VM (the original reason they were stuck).
5. Gates: `bash scripts/test-headless-gate.sh` (Swift, one at a time) · `bash scripts/rust-core-gate.sh`
   (rust-core). After rust changes: `bash scripts/build-rust-core.sh` (header + .a). VM: rsync +
   `test-in-vm.sh`.

## Gotchas / lessons (also in LESSONS.md / memory)
- An agent `task_restate` (reported→ack) CLEARS a `waiting:human` park gate — the unpark mechanism.
- `core` is sans-IO by design (no fs/process) — load-bearing for the WASM tier; do NOT hoist IO into it.
- VM hang was memory-pressure (6GiB fixes it), NOT a code bug. `pkill -9` deny-ruled; macOS lacks
  `timeout`/`setsid`.
- task_advance/restate garble: pass ONE long-text param per call; don't batch multiple board mutations with
  long text in one tool block.
