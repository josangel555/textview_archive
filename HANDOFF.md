<!-- CLAUDE-HANDOFF v1 -->
# Handoff — rust-core audit Phase 0 + VM lane forensics  (2026-06-09)

**Session:** claude-mdv (autonomous loop + owner-directed)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `5bcfedf`

## Mission
Owner-directed arc this session: (1) fix all VM infrastructure issues, (2) run a
"sky-is-the-limit" multi-agent production-readiness audit of `rust-core/` (all Fable 5,
ultracode workflows), (3) ticket every finding under a new tag, (4) **implement the
priority (Phase 0) fixes from the audit** — that last one is the active work stream.
The standing autonomous-loop SOP (cron, `docs/TASK_WORKFLOW.md`) continues underneath.

## Current state
- **Done — audit (complete):** 9-dimension Fable-5 review fleet + 2 blank-slate explorers
  over `rust-core/`; every S1–S3 finding adversarially verified (43 confirmed / 0 refuted),
  27 proposals critique-judged. Reports in `docs/research/rust-core-audit-2026-06-09/`
  (read `synthesis.md` first — verdict: **build on it, do not rewrite, fix the FFI
  contract before freezing**; Phase 0–3 roadmap inside). All findings ticketed: epic
  **TSK-538**, children TSK-539..577, tag `rust-core-audit`.
- **Done — Phase 0 batch 1 (5 of ~16):** TSK-549 (git `core.fsmonitor`/`core.hooksPath`
  neutralization in BOTH front-end spawns + teeth-demonstrated hostile-repo test),
  TSK-542 (web serve-root canonicalize fails closed, no `/` fallback), TSK-553 (true
  MSRV `rust-version = "1.88"`), TSK-569 (unused `serde`/`rmp-serde` removed from ffi
  manifest), TSK-555 (self-enforcing `rust-core/.cargo/config.toml` →
  `target-dir = /private/tmp/mdv-rust-target`; 2.8 GB in-tree `target/` deleted).
  Commits `02a10e7`, `dd6d345`, `5bcfedf` (lockfile). `bash scripts/rust-core-gate.sh`
  GREEN. All five recorded `fixed` on the board with commits.
- **Done — VM infra (earlier):** ssh flakiness root-caused (4 GiB memory-pressure
  bufferbloat), disk reclaimed (~6.1 GB free after owner deleted the redundant 6.1.2
  toolchain), `ulimit -n 8192` fd fix, full-suite verdict (4489 tests, 17 fails — 15 are
  virtual-GPU Core Image deltas, host-green). T5 windowid root cause PROVEN: under
  `sudo launchctl asuser` everything runs as **root** (temp dir = root's `/var/folders`),
  apps publish the windowid but slower than the 2.5 s timeout.
- **In flight:** nothing torn — tree clean, gate green, every touched task at a terminal
  or honest intermediate state.
- **Next action:** continue Phase 0 in roadmap order (see Tracker below / the epic
  comment on TSK-538): **TSK-550** (workspace-wide gate lane — currently the gate only
  covers default-members) is first.

## Key decisions & rationale
- **Audit verdict adopted: evolve the PoC, don't rewrite.** The sans-IO core +
  single-unsafe-crate layering is sound; the gaps are contract hardening (FFI header
  drift, frame caps), web-tier robustness, and missing fuzz/property lanes.
- **Dep adoptions from the audit are ALL owner-gated** (memchr, cargo-fuzz, proptest,
  cargo-deny, cargo-audit, Miri CI lane) — parked on their tickets; do NOT adopt without
  explicit approval (standing minimal-deps rule).
- **`-c core.fsmonitor= -c core.hooksPath=/dev/null` as args, not env** — keeps the
  neutralization visible at the spawn site and unaffected by inherited env.
- **MSRV bump piggybacked the let-chain collapses** — clippy's MSRV-aware
  `collapsible_if` made them mandatory once `rust-version` said 1.88 (gate denies).
- **TSK-549 left at `fixed`, not self-validated to `done`** — policy allows
  self-validation with the teeth-proven test artifact; deferred to do remaining Phase-0
  security items as one validation sweep.

## Gotchas / lessons (full entries in LESSONS.md, 2026-06-09 section)
- `git checkout -- <file>` during a teeth check **wiped uncommitted fix+test** once —
  undo deliberate test mutations with the inverse Edit until work is committed.
- Bumping `rust-version` re-arms MSRV-gated clippy lints → gate goes red on a
  "manifest-only" change; `cargo clippy --fix` is the mechanical cure.
- `sudo launchctl asuser` payloads run as **root** (uid stays 0) — windowid/temp
  artifacts land in root's `/var/folders/zz/...`; T5's 2.5 s `waitForWindowID` is too
  short on the VM.
- `MDV_VM_GUI_SESSION=1` without `MDV_VM_SUDO_PASS=<vm-sudo-password>` silently runs **nothing**.
- iCloud `rm -rf` can fail "Directory not empty" — run it twice.
- Workflow died at usage limit: verdict-null = unprocessed (not refuted); resume with
  `resumeFromRunId` reuses the cached prefix.

## Files that matter
- `docs/research/rust-core-audit-2026-06-09/synthesis.md` — roadmap + verdict; per-dimension reports beside it.
- `rust-core/crates/web/src/main.rs` — `git_status_html` neutralized spawn (TSK-549) + fail-closed serve root (TSK-542).
- `rust-core/crates/tui/src/main.rs` (~line 2954) — `git_status_for` neutralized spawn + teeth test `git_status_never_executes_repo_local_fsmonitor_command`.
- `rust-core/Cargo.toml` — `rust-version = "1.88"`; `rust-core/crates/ffi/Cargo.toml` — deps now `mdvcore-core` only.
- `rust-core/.cargo/config.toml` — out-of-tree target dir (NEW, self-enforcing).
- `docs/TASK_WORKFLOW.md` — the cron-read SOP incl. §3.5 lane goals (owner directive 2026-06-09).
- `docs/AUTONOMOUS_PROGRESS.md` — narrative log (+122..+124); `docs/TRACKER_FEEDBACK.md` — tasked-tool feedback (INT-106/107/108 open).

## Open questions / blockers
- **Owner-gated dep adoptions** (above) — each parked on its ticket.
- **VM RAM 4→8 GiB** UTM bump still recommended (owner-side, cures the ssh bufferbloat).
- T5 pixel lane needs the `waitForWindowID(timeout:)` bump (~20 s) in
  `Tests/ViewerUITests/*VisualRegressionTests.swift` — small, unticketed-as-of-handoff;
  listed in BACKLOG.md 2026-06-09 block.

## Tracker (tasked MCP @ :8787, project `tasked`, agent `claude-mdv`)
- Epic **TSK-538** (rollup 5 fixed / 34 reported); Phase-0 status comment left on it 2026-06-09.
- Fixed this session: **TSK-549, TSK-542, TSK-553, TSK-569, TSK-555** (commits attached).
- Remaining Phase 0 order: TSK-550 → TSK-576/565 → TSK-540 → TSK-539 → TSK-551/556/558/557 → TSK-566/567/575.
- Other open earlier threads: TSK-529 (waveform — needs VM pixel evidence), TSK-535
  (Save-As sheet), board-hygiene work done (epics/parents/dismissals landed).
- Internal tracker-feedback project: INT-106/107/108 filed.

## How to resume
1. `git -C /Users/me/Documents/workspaces/claude/markdown_viewer log --oneline -5` — confirm `5bcfedf` HEAD, tree clean.
2. Read `docs/research/rust-core-audit-2026-06-09/synthesis.md` §roadmap, then `mcp__tasked__task_get TSK-550`.
3. Loop per ticket: restate → triage → claim → implement → test (teeth where security/behavioral) → `bash scripts/rust-core-gate.sh` (must end `==> Rust-core gate green.`) → commit (one-line subject, TSK id) → `task_record(to: fixed)` with commit. Cargo runs build to `/private/tmp/mdv-rust-target` now.
4. Board = `mcp__tasked__*` ONLY (never the built-in TaskList numbering, never board.py). Cron SOP = `docs/TASK_WORKFLOW.md` — read it every firing.
5. VM runs: rsync recipe in CLAUDE.md; GUI lane needs `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password>`; never `rm -rf .build` on the VM.
