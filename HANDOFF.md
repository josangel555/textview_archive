<!-- CLAUDE-HANDOFF v1 -->
# Handoff — priority pivot to user-facing bugs; Phase-0 security complete  (2026-06-10)

**Session:** claude-mdv (autonomous loop + owner-directed)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `c3525bb` (+ uncommitted LESSONS/BACKLOG handoff edits — commit them)

## Mission
**OWNER DIRECTIVE 2026-06-10: every firing now works USER-FACING bug fixes first** —
encoded in `docs/TASK_WORKFLOW.md` §3 rank 1 (the doc each cron tick reads in full).
The rust-core audit Phase 0 is effectively done (all security/S2 items fixed);
the audit's Phase 1+ and the hygiene trio now queue BEHIND the user-facing pool.

## Current state
- **Done this session (all gate-green, teeth-demonstrated, recorded `fixed` on board):**
  TSK-549/542/553/569/555 (batch 1) · TSK-550 workspace-wide gate (`7bc1c95`) ·
  TSK-540 hex clamp + TSK-578 OpenError (`2d4f7dd`) · TSK-576/565 hunk_marks
  parity-locked Rust+Swift (`730fc65`) · TSK-539 cbindgen+drift gate (`3f32676`) ·
  TSK-548 TooLarge end-to-end (`051eadf`) · TSK-551/556/558 web trio (`c10cf4b`) ·
  TSK-557 CSV heap cap (`575d148`). Epic TSK-538: 15 fixed / 36 open.
- **Docs de-staled** (`c3525bb`): CLAUDE.md SOP (board.py refs killed, board-tool
  names fixed, VM GUI-lane gotchas, new priority), TASK_WORKFLOW.md §1 tool list
  (+`task_retract`, `quiet:true`, retry-once) + §3 priority rewrite.
- **Owner bug-list reconciliation DONE:** all ~60 items mapped. New epic
  **TSK-590** (P1) + children **TSK-591..610** for the unmatched items; bumped to
  P1: TSK-266, 267, 313, 314, 327, 359, 363, 522, 523. Full mapping table is in
  the last big assistant message before this handoff (board state is canonical).
- **In flight:** nothing torn. Tree has only the LESSONS/BACKLOG/HANDOFF edits.
- **Next action:** commit the handoff docs, then start the user-facing pool —
  first targets: **TSK-599/600** (broken session-open flows), **TSK-609**
  (inert shoulder buttons 4/5/6), then felt-perf **TSK-266/267/591/592/598/601**.
  Most need the live app → headless-first wiring/model tests, VM lane for pixels.

## Key decisions & rationale
- **User-facing > internal severity** (owner): a P1 UI bug outranks an S2
  internal finding. `[PORT]` + test backfill stay last resorts.
- Reconciliation policy: items with completed UX-wave evidence were NOT re-filed
  (avoid duplicate noise); owner invited to flag any that still misbehave —
  those become P1 regressions.
- TSK-589 (eviction policy) parked to the owner with 4 options (a-d).
- Gate-flake hardening (PTY/LSP load-tolerance + retry-once) offered, not ticketed yet.

## Gotchas / lessons (full entries in LESSONS.md 2026-06-10 section)
- Cargo config discovery = CWD-based, NOT --manifest-path → repo-root
  `.cargo/config.toml` added; watch for `rust-core/target` regrowing.
- SwiftPM does NOT track the prebuilt `.a` (stale-link A/B false fails — script
  now touches `Sources/RustCore`) NOR recompile dependents on enum case-add
  (`.panic == .panic` was FALSE cross-module; `touch` the dependent).
- Host-gate flakes under build load (PTY, LSPPool): re-run the suite ALONE first.
- VM GUI lane: `MDV_VM_GUI_SESSION=1` needs `MDV_VM_SUDO_PASS=<vm-sudo-password>` (silent no-op
  without); `asuser` runs everything as root.

## Files that matter
- `docs/TASK_WORKFLOW.md` — THE SOP; §3 rank 1 = user-facing bugs (2026-06-10).
- `CLAUDE.md` — de-staled SOP summary + VM gotchas + refreshed quick refs.
- `rust-core/crates/core/src/{csv,diff,wire,hex}.rs`, `crates/ffi/src/{lib,status,tests}.rs`,
  `crates/web/src/main.rs` — this session's Phase-0 fixes (see commits above).
- `scripts/rust-core-gate.sh` — now workspace-wide + ABI header-drift step.
- `scripts/build-rust-core.sh` — touches RustCore sources after staging the .a.
- `Sources/RustCore/CoreClient.swift` — `CoreError.tooLarge` mapping.
- `docs/research/rust-core-audit-2026-06-09/synthesis.md` — audit verdict/roadmap.

## Open questions / blockers
- TSK-589 eviction policy — parked, waiting on owner (options a-d on the ticket).
- Audit dep approvals (cargo-fuzz, proptest, cargo-deny/audit, Miri, wasm32) —
  parked on their tickets; do NOT adopt without explicit owner OK.
- Owner to flag any "implemented in UX waves" item that still misbehaves → file
  as P1 regression under TSK-590.

## Tracker (tasked MCP @ :8787, project `tasked`, agent `claude-mdv`)
- Fixed this session: TSK-539, 540, 542, 548, 549, 550, 551, 553, 555, 556, 557,
  558, 565, 569, 576, 578 (commits attached on each).
- Filed: TSK-578..589 (audit roadmap gaps; 589 parked) · TSK-590 epic + 591..610
  (owner bug list). Bumped P1: TSK-266/267/313/314/327/359/363/522/523 + TSK-590.
- The work queue for next firings = TSK-590 children + the bumped P1 set.

## How to resume
1. `git -C /Users/me/Documents/workspaces/claude/markdown_viewer status` — commit the
   LESSONS/BACKLOG/HANDOFF edits if still dirty (`docs: handoff 2026-06-10`).
2. Read `docs/TASK_WORKFLOW.md` IN FULL (every firing — it has the new priority).
3. Pick from the P1 user-facing pool (epic TSK-590 children first): suggested order
   TSK-599 → TSK-600 → TSK-609 → TSK-266 → TSK-591. For each: `task_get` →
   advance through lanes → fix with headless-first tests (model/wiring layer per
   `feedback_verify_headless_before_asking`) → `scripts/test-headless-gate.sh` →
   commit per item → `task_record(to: fixed)` with SHA → log to
   `docs/AUTONOMOUS_PROGRESS.md`. UI-pixel claims need the VM lane
   (`MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> bash scripts/test-in-vm.sh`).
4. rust-core lane (only when no user-facing task is actionable): hygiene trio
   TSK-566/567/575, then Phase 1 starting TSK-579 (`mdvcore_abi_version`).
5. Board = `mcp__tasked__*` only; retry once on connection error (owner upgrades
   the server live). Built-in TaskList `#NNN` ≠ board `TSK-NNN`.
