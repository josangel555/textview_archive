<!-- CLAUDE-HANDOFF v1 -->
# Handoff — rust-core port wave: find port landed; markdown + transcript ports next  (2026-06-12)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ db30ecb (+ docs commits follow)

## Mission
Rust-core migration / Swift-core deprecation (OWNER PRIORITY 2026-06-12, SOP §2.5:
port-targeted Swift engines are bugfix-only). Drive the owner-greenlit pools on the
tasked board; the loop cron (`3,13,23,33,43,53 * * * *`, session-only — RECREATE in a
fresh session) fires the ticks.

## Current state
- **Done & validated this session:** TSK-635 (egress, corrected scope), TSK-554
  (supply-chain lane: deny+audit split, nightly workflow, teeth), TSK-634 (FFI velocity,
  3 stages: capability bitmap / `ffi_frame_body!`+misuse-matrix macros / `mdvFrameCall`
  Swift helper), TSK-633 (fuzzy port, zero deps), TSK-630 (find port on regex-lite
  =0.1.8, features-off, 0 transitive). TSK-505/TSK-261/268/331 validated earlier in
  session. TSK-643 filed (the owner-observed outbound connection is UNEXPLAINED —
  markdown CSP ruled out). TSK-256 un-gated (dep decision = pulldown-cmark via TSK-629),
  linked + blocked_by TSK-631.
- **In flight:** nothing torn — find port committed (db30ecb), both gates green, board
  reconciled. LOG +236 may still need appending if the docs commit below didn't happen.
- **Next action:** TSK-632 (transcript/JSONL port, hand-rolled JSON subset ~500-800
  lines, NO serde_json) or TSK-631 (markdown port on pulldown-cmark — add dep per the
  features-off rider exactly as regex-lite was added in `rust-core/Cargo.toml`). Then the
  remaining pools: TSK-628, TSK-636, parity fruits TSK-637-640, theming TSK-641→642.

## Key decisions & rationale
- **Stage 3 of TSK-634 redesigned** from "generate Swift stubs" to the shared
  `mdvFrameCall` helper — stage 2's uniform C signature made a generator pure machinery.
- **Adapter flips deliberately deferred** (BACKLOG): fuzzy/find are validated but no UI
  routes through them; flip + Swift-twin deletion is a collective, reviewed change.
- **deny/audit duty split** because cargo-deny 0.18.x can't parse CVSS-4.0 advisories.
- **Capability bits are ABI**: pre-assigned for unported engines (markdown 1<<6,
  transcript 1<<7), flipped atomically with each port's exports — both sides' reserved-bit
  tests edit in the SAME change (they go red otherwise, by design).

## Gotchas / lessons (full entries in LESSONS.md 2026-06-12)
- **Stale test-target objects after a cross-module enum layout change SIGSEGV** like an
  FFI bug (pure-Swift `throw CoreError.panic` crashed). `touch` Tests/ referents too —
  CLAUDE.md rule added; TSK-626 commented (second instance of the class).
- cbindgen does NOT expand macro_rules — extern signatures stay hand-written; macros
  generate bodies/tests only.
- cargo-deny unions all platforms' graphs — `[graph] targets` pin is load-bearing.
- regex-lite: ASCII-only case-insensitivity, no lookaround → `.invalidPattern` typed
  channel = the Swift-fallback path.

## Files that matter
- `rust-core/crates/core/src/find_engine.rs` — the find port (UTF-16 sweep, S2-E/CORR-6).
- `rust-core/crates/core/src/fuzzy.rs` — the fuzzy port (scoring constants = parity contract).
- `rust-core/crates/ffi/src/guard.rs` — `ffi_frame_body!`; `tests.rs` —
  `frame_export_misuse_matrix!` + capability pins (edit reserved-bits tests when porting).
- `Sources/RustCore/CoreClient.swift` — `mdvFrameCall` (~line 380), `CoreCapabilities`,
  wrappers; `CoreError.invalidPattern`.
- `Tests/RustCoreTests/{FuzzyRank,FindSearch}ABTests.swift` — the parity oracles.
- `scripts/rust-supply-chain-audit.sh` + `.github/workflows/nightly-supply-chain.yml`.
- `docs/EGRESS.md` — egress inventory (answer firewall prompts from it).

## Open questions / blockers (owner queue)
- TSK-643: needs the firewall's full flow record (port + process path) next occurrence.
- Miri/ASan nightly step: behind nightly-toolchain approval (audit ask #5).
- Owner parks unchanged: TSK-322 zoom, TSK-598 MountedPanesLRU (do NOT start), TSK-608,
  TSK-270/372; validated pile awaits owner one-click done.

## Tracker
All live on the tasked board (project `tasked`, agent `claude-mdv`): validated this
session — 635, 554, 634, 633, 630, 505, 261, 268, 331; commented — 626 (staleness class),
256 (un-gated, blocked_by 631); filed — 643 (egress investigation), 628/636-642 pools
untouched; 644 self-dismissed (misfile).

## How to resume
1. Read `docs/TASK_WORKFLOW.md` IN FULL (per-firing mandate; §2.5 = migration policy).
2. `git status` — tree should be clean except `.profiling/`; `git log --oneline -5`.
3. Recreate the loop cron if the session restarted (10-min cadence, prompt = the
   "Autonomous loop tick" text in AUTONOMOUS_PROGRESS LOG +230 context or CLAUDE.md SOP).
4. Pick up TSK-632 or TSK-631 (claim → port engine → export via the ceremony: 1-line
   `ffi_frame_body!`, 2-line misuse matrix, flip the reserved capability bit + BOTH
   reserved-bit tests, 1-line Swift wrapper via `mdvFrameCall`, A/B parity suite, teeth,
   both gates: `bash scripts/rust-core-gate.sh` + `bash scripts/test-headless-gate.sh`).
5. After enum/header changes: `touch` referencing files in Sources/ AND Tests/ (see
   CLAUDE.md staleness rule) before believing any SIGSEGV.
