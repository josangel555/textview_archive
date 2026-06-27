<!-- CLAUDE-HANDOFF v1 -->
# Handoff — PM store host-complete + autonomous surface drained  (2026-06-27)

**Session:** claude-mdv  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch:** `main` @ `c2a82157` (verify `git log -1`)

## Mission
Autonomous drain loop (5-min cron). Drain BACKLOG.md top-down by the owner priority order: P0a (AX self-driving) + P0b (validation) interleaved, then P1 wave-12, then P2 board. Build inline, one item/tick, gate-green, commit per item.

## Current state
- **DONE this run — the owner's 5 dep approvals all built to concrete work:**
  - **memchr** (TSK-399/1285) — `hex_search_find` + `format::find_after` on `memchr::memmem`. Validated.
  - **proptest** (TSK-585) — 5 differential/round-trip suites (filter, diff, csv ×2, formula-arith). **Found + fixed TSK-1286** (CSV single-column trailing-empty-value row drop).
  - **rusqlite / PM store** (TSK-345) — **14 gate-green slices, ~52 host tests, HOST-SIDE COMPLETE.** A full event-sourced project-management store in `rust-core/crates/pm/`: event-sourcing+replay (work_item AND edges rebuild from the log) · §2.2 lifecycle state machine · enforced actor-kind + §1.4 doer≠verifier safety boundary · on-disk persistence · §1.7 dependency graph (cycle-safe edges + finish-to-start dispatch + impact-analysis + consumes-reverse-ripple cascade) · the FFI/remote **wire protocol** (`PmRequest`/`PmResponse`/`dispatch`/`dispatch_bytes`).
  - **wasm32 (TSK-587) + cargo-fuzz (TSK-584)** — ⛔ blocked: the CDN HEAD-responds (200) but the large rust-std-wasm32 tarball + nightly downloads time out (large-download link failure; re-checked repeatedly across ticks). The wasm INVARIANT is guarded host-side instead via the strengthened `wasm_shape` static scan.
  - **Post-compaction P0b + hardening (all rust, gate-green):** validated **TSK-1106** (session-tab action MODEL behaviors — `SessionsCoordinatorTests` 30/0, teeth) + **TSK-585** (proptest lane named scope) → `validated`; completed TSK-585's wire/session proptests; extended the lane to hex + fuzzy differentials (8 engines now, all 12 fuzz-covered); hardened the `wasm_shape` guard with `std::time`. The 4 rust-core ports + both memchr tickets were ALREADY validated. NOTE: swift host validation works via `swift test --skip-update` (SwiftPM resolution is network-hung; cached deps resolve fine).
- **Autonomous host-completable surface is DRAINED** — BACKLOG.md (line 60) + my own vetting agree. Remaining everywhere is owner/VM/TCC-gated.
- **In flight:** nothing half-done. All work committed, `main` headless-green.
- **Next action:** each tick, genuine fresh check (rustup CDN for wasm; `task_next`); build immediately if a clean host item appears or the owner answers a decision. Do NOT manufacture marginal/speculative work past this vetted boundary.

## Key decisions & rationale
- **PM built slice-by-slice per the auto-approved v2 design** (`docs/PROJECT_MANAGEMENT_DESIGN_v2.md`) — genuine sanctioned work (rusqlite was owner-approved), not manufacturing.
- **Stopped at the host boundary on purpose.** The only remaining PM work is genuinely cross-cutting/blocked (see below) — verified technically, not fatigue.
- **`PmRequest`/`PmResponse` mirror the typed API**; `dispatch` maps every `PmError` → `PmResponse::Error` (the wire never panics on a domain error). The bytes codec is `dispatch_bytes` (msgpack).

## Gotchas / lessons
- **PM slice 5b (FFI exposure) is genuinely owner/VM-coupled, NOT host-completable:** adding `mdvcore-pm` to the ffi staticlib pulls rusqlite/libsqlite3 into `libmdvcore_ffi.a`, so the Swift link must add `-lsqlite3` (build-app.sh) — host-only it breaks the Swift headless gate. Feature-gating it default-off makes it speculative unused surface (not in the default header, no consumer). So 5b needs the owner's PM-direction answer + a Swift consumer.
- **`mdvcore-pm` is in `members` but NOT `default-members`** (rust-core/Cargo.toml:16,23) — so rusqlite never enters the Swift staticlib/app build, but the `--workspace` gate still tests it.
- The PM crate uses **let-chains** (edition 2024 / rust 1.88) — collapse `if let { if }` to `if let … && …` (clippy `collapsible_if`).
- `add_edge` now takes `(conn: &mut, ts, actor_id, actor_kind, from, to, kind)` — edges are event-sourced (slice 4h). Test helper `edge(&mut conn, from, to, kind)` absorbs the provenance args.
- **A new untracked `OwnerWishlist.md`** appeared this session — a large historical brain-dump (Jun 20), mostly already done or board-tracked. It is NOT the authoritative worklist (BACKLOG.md is, per the cron); do not re-triage it wholesale (duplicate/spam risk).

## Files that matter
- `rust-core/crates/pm/src/lib.rs` (1433 lines) — the entire PM store + wire layer + ~52 tests.
- `rust-core/Cargo.toml:62-73` — memchr/proptest/rusqlite workspace deps (default-features=false + pinned + minimal features).
- `docs/PROJECT_MANAGEMENT_DESIGN_v2.md` — the auto-approved design the slices follow.
- `BACKLOG.md` (lines 20-60) — the authoritative OWNER PRIORITY ORDER + the DRAINED status.

## Open questions / blockers (owner)
- **TSK-1287** — crypto-hash dep for PM slice 2b (tamper-evident hash-chain): sha2 (recommended) / blake3 / reject.
- **PM epic direction** — continue autonomously (5b Swift-link + a consumer/UI) vs a supervised session. 5b is the natural next step but needs owner-coupling.
- **wasm32 / cargo-fuzz** — resume when the rustup CDN recovers (env, not code).
- Everything else: BACKLOG's owner/VM/TCC-gated pile (render passes, on-screen close of the ~400 review+fixed, AX-execution TCC grant).

## Tracker
- **tasked / TSK-345** (project management) — at `review`; detailed "PM HOST-SIDE COMPLETE — 14 slices" comment recorded (commits `6719e348..bd8b7b4a`). NOT validated (epic is partial — 5b/2b remain).
- TSK-1286 — fixed (CSV row-drop), folded into the proptest-suite commit.

## How to resume
1. `git -C /Users/me/Documents/workspaces/claude/markdown_viewer log --oneline -15` — confirm HEAD `bd8b7b4a` + the PM slice commits.
2. Read `BACKLOG.md` lines 20-60 (authoritative priority + the DRAINED status) and the cron prompt.
3. `rustup target list --installed | grep wasm32` — if now present, the wasm32 build probe (TSK-587) is unblocked → genuine new work.
4. `mcp__tasked__task_next {agent: claude-mdv, project: tasked}` — if a clean pure-logic/host item appears, build it (spike→implement→test→`bash scripts/rust-core-gate.sh`→commit).
5. Otherwise: the surface is drained — do a genuine fresh check, surface the two owner decisions (TSK-1287 + PM direction), and do NOT manufacture marginal work. The boundary is real and BACKLOG-confirmed.
