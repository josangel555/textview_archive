<!-- CLAUDE-HANDOFF v1 -->
# Handoff — rust-core Formatted mode + autonomous PORT lane  (2026-06-07)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `dd4cf17`

## Mission
Autonomous steward run: pull `tasked` board work, drive it to `validated` with teeth-bearing
tests, keep `main` gate-green, commit per item. SwiftUI app FIRST per SOP; fall back to the
Rust TUI/web `[PORT]` lane when no SwiftUI task is actionable (which is the current state).

## Current state
- **Done + validated this session:** TUI hex-byte search (TSK-205); theme-override
  persistence test-gap closed (TSK-101); audit-cluster verify-and-validate sweep — 15
  findings (TSK-118/119/120/121/124/125/126/127/128/129/131/132/133 + 101/127); JSON
  **Formatted** view mode end-to-end (core `format::pretty_json` + `ViewMode::Formatted` +
  `FileKind::Structured`, TUI TSK-217 + web TSK-218); TUI **reload-current-file** `r` key
  (TSK-239). Plus a real crash fix: `pretty_json` recursion depth cap (commit `f47c7d3`).
- **Held (honest non-validation), commented on board:** TSK-122 (HexView O(2) repaint —
  live render path, no host coverage) and TSK-123 (session_table borrow — perf-only, no
  teeth). Need a VM test / perf assert respectively.
- **In flight:** nothing. Every task touched is at its terminal state. Tree clean.
- **Next action:** none forced. If resuming autonomously, pick the next clean front-end-only
  `[PORT]` feature (TSK-241 whitespace markers, TSK-247 keyboard-help overlay) OR start
  **TSK-496** (XML pretty-print — the deferred half of Formatted). BUT see Blockers: the
  high-value/owner-prioritised work is input-bound.

## Key decisions & rationale
- **Self-validate only with a teeth-proven host test.** For each `fixed→validated` I ran the
  regression test AND (for the ones I authored) demonstrated it goes red without the fix.
- **Reused `ViewBody::Text` for `Formatted`** instead of a new body variant — renderers draw
  it identically; only `View.mode` distinguishes. Less surface, no new match arms in bodies.
- **`.json`→Structured but `.xml` left Plain** — don't offer a Formatted mode that no-ops;
  `.xml` joins when `pretty_xml` lands (TSK-496).
- **Tapered the PORT lane.** After ~10 productive ticks the remaining PORT work is marginal
  polish and the SwiftUI lane is owner-blocked; flagged 3× and now holding rather than
  manufacturing low-value work.

## Gotchas / lessons (also in LESSONS.md)
- **Recursive core parsers MUST bound depth** — `pretty_json` was unbounded → balanced
  deep JSON (`[[[…]]]`) stack-overflows → `panic=abort` process crash. Fixed with
  `MAX_DEPTH=128`. Same class as cmark TSK-126.
- **Adding a `ViewMode`/`FileKind` variant breaks exhaustive matches in ALL THREE
  front-ends** (TUI label, web `mode_str`/`parse_mode`). Run `cargo build --workspace`.
- **Stale incremental `cargo build` can print a false "Finished … 0.13s" green** while a
  downstream crate still has E0004 — `touch <file>` or `--workspace` to force a real recompile.
- **rust-core gate** = `bash scripts/rust-core-gate.sh` (clippy no-panic denies + all crate
  tests + ffi no_panic gate + doctests).

## Files that matter
- `rust-core/crates/core/src/format.rs` — `pretty_json` (no-dep JSON reformatter, depth-capped). XML = TSK-496.
- `rust-core/crates/core/src/view.rs` — `ViewMode::Formatted`, `FileKind::Structured`, `classify`/`available_modes`/`default_mode`/`build` + `formatted_lines`.
- `rust-core/crates/tui/src/main.rs` — `Preview.path` + `reload_current()` (`r` key); hex-search branch in `commit_find`/`jump_to_current_match`; mode-label match (~line 1332).
- `rust-core/crates/web/src/main.rs` — `parse_mode`/`mode_str` formatted arms; mode switcher built from `available_modes` (~line 503).
- `docs/AUTONOMOUS_PROGRESS.md` — per-tick narrative (latest = +58). `LESSONS.md` / `BACKLOG.md` — updated this handoff.

## Open questions / blockers
- **Autonomous queue is `[PORT]`-only; SwiftUI lane input-bound.** To redirect to the
  owner-prioritised SwiftUI app work, the owner must: approve/steer **TSK-202** (Sessions
  god-object split, owner-decision), OR authorize a VM UI-test lane for **TSK-252/253/254**
  (live-blocked PoCs), OR say "keep draining PORT". (Also in BACKLOG.md.)

## Tracker (tasked MCP @ :8787, project "tasked", agent claude-mdv)
- Validated this session: TSK-101, 118, 119, 120, 121, 124, 125, 126, 127, 128, 129, 131, 132, 133, 205, 217, 218, 239.
- Held at review w/ comment: TSK-122, TSK-123. Created: TSK-496 (XML pretty-print, reported).
- Owner-gated/blocked (not actionable autonomously): TSK-202, TSK-252, TSK-253, TSK-254.

## How to resume
1. `git -C /Users/me/Documents/workspaces/claude/markdown_viewer log --oneline -5` — confirm `dd4cf17` is HEAD, tree clean.
2. Read `docs/AUTONOMOUS_PROGRESS.md` top (LOG +58 down) for the per-tick story.
3. If the owner steered the blocker → do that. Else, for a PORT feature: `cargo test -p mdvcore-tui` / `-p mdvcore-web` for the fast loop, implement front-end-only over existing core, then `bash scripts/rust-core-gate.sh`, commit, drive the board task reported→…→validated (agent path: task_restate → task_triage → task_claim → task_record(to fixed) → task_validate; validated needs a `checks` hard artifact).
4. Board tools are `mcp__tasked__*` (NOT the built-in Claude Code TaskList — different numbering, NOT the system of record). The board is shared across projects — skip foreign `forge`/`wx_site` tasks.
