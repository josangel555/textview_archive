<!-- CLAUDE-HANDOFF v1 -->
# Handoff — rust-core Phase-1 contract complete; clean pool exhausted, owner-gated  (2026-06-13 ~03:40)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `0bedb0f`

## Mission
Rust-core production-readiness + the Swift→Rust migration (epic TSK-538/651); USER-FACING bugs first;
work the `tasked` board; validate with automated tests (human not in loop); keep main headless-gate-green;
land per item via rebase+ff. Read `docs/TASK_WORKFLOW.md` every firing.

## What this session shipped (all gate-green, validated unless noted)
- **TSK-541** — FFI handle free-vs-call UAF closed via an Arc-backed registry (never-reused token; lookup/free total + safe). `df250db`.
- **TSK-559** — windowed snapshot (`snapshot_window_frame` + `filtered_count`), additive, no wire-version bump — the O(window) filter pull. `8762a58`. Consumer follow-up filed **TSK-668** (live-gated CSV viewport paging).
- **TSK-577** — the WireError {code,message,kind} channel now EMITS on error (was dead). `02161cb`.
- **TSK-669** — host-side consumer: `CsvSession.decodeWireError` + `callBuf` logs it. `4c7dbc1`.
- **TSK-580 (thin-waist FFI envelope, P1, the LAST §2.5 Phase-1 item)** — slices 1/2/4/5 landed:
  safe-Rust `dispatch::call` + `mdvcore_call` envelope + `MDV_METHOD_*` ids (cbindgen→header→Swift) +
  the FULL 8/8 stateless-seam migration (`InProcessTransport` routes everything through the envelope;
  `exports` symbol table empty). `7d092ee`/`1900606`/`d1b5a35`/`56560f9`. STILL `progress` — see below.
- **Validated (fixed→validated):** TSK-642 (VS Code theme import), TSK-637 (md outline), TSK-306
  (preview-tab), TSK-571 (HEX_WIDTH single source). Earlier wishlist wave + 122/123/655 also validated.
- **TSK-451 (VM-sweep hang) reproduced + triaged** with an executable plan (see below).

## Current state — clean autonomous pool is EXHAUSTED; remaining work is GATED
Nothing in flight. Tree clean @ `0bedb0f`, host headless gate green on every commit. Confirmed across
several firings that no cleanly-autonomous high-value work remains; each remaining item is gated:

- **TSK-580 remaining:** slice 3 (aux bulk side-channel for hex render ~18 MB) is BLOCKED — hex isn't
  framed/on the envelope yet (raw-byte signature); the symbol cleanup is soak-gated. Stays `progress`.
- **TSK-451 (VM hang):** triaged with the plan (1: wall-clock cap in `test-in-vm.sh` swift_test so a
  hang fails-fast naming the prime suspect — macOS-compatible plain `pkill`, NO setsid/timeout/`pkill -9`
  which are unavailable/deny-ruled; 2: re-run on VM under the cap to ID + seam the hanging test). IMPL is
  VM-validation-gated (can't safely modify the load-bearing VM script without confirming on the VM, which
  hangs). **This also BLOCKS draining the ~20 live-validation fixed items** (the VM GUI lane would hit the
  same hang).
- **Host-validation drain:** exhausted (the clean ones validated; the rest — TSK-468 live-gated, 626
  build-process, 456/457 interaction-render — need the VM/owner glance).

## Owner decisions parked (the real unblocks — `task_list {waiting:human}`)
- **TSK-543** (cm_apply ships full doc per keystroke → stateful Rust editor; typing perf, owner's #1
  class). Parked: (a) hand-roll gap-buffer vs approve a rope dep; (b) build behind a flag autonomously
  vs supervised. NOTE: slice 1 (a String-backed stateful doc, additive, behind a flag, host-tested) is
  arguably autonomous-safe with the conservative defaults — I left it parked rather than reverse my own
  escalation, but a "go conservative" answer unblocks it immediately.
- **TSK-302** (CSV cell-nav/find — live-gated twin features; CSV copy already works). Go/defer.
- **TSK-649** (flip MDV_RUST_* defaults + delete the Swift twins) — `fixed`/waiting:human.
- **TSK-316/336/338** (walkthroughs / hooks / plugins consolidation).

## Gotchas / lessons (also in LESSONS.md)
- `pkill -9 -f` is DENY-RULED in this env (incl. via ssh) — clean up VM procs with plain `pkill -f`.
- macOS/VM lack `timeout` and `setsid` — use background + watchdog + plain `pkill` of the test bundle
  (`MarkdownViewerPackageTests`) + `swiftpm-testing-helper` for process cleanup.
- VM headless lane (`test-in-vm.sh test`) HANGS (TSK-451) partway — a frozen log mid-test is a stdout
  BUFFERING artifact, not the hang site. The ~44k-line/0-failure partial run shows the bulk is VM-clean.
- Adding an FFI export → cbindgen regen via `build-rust-core.sh` (restages header + rebuilds the .a);
  additive exports need no MDV_WIRE_VERSION bump. The header + .a are NOT git-tracked.
- Envelope method ids are ABI (assign-once); the `method_id_consts_match_the_dispatch_enum` drift-pin
  guards core enum ↔ FFI consts ↔ Swift (via the header).

## Files that matter (this session's new surfaces)
- `rust-core/crates/core/src/dispatch.rs` — the safe-Rust method dispatch + `Method` u16 enum (TSK-580).
- `rust-core/crates/ffi/src/lib.rs` — `mdvcore_call` envelope + `MDV_METHOD_*` + `write_wire_error`.
- `rust-core/crates/ffi/src/handle.rs` — the Arc registry (TSK-541).
- `rust-core/crates/core/src/session.rs` — `snapshot_window_frame`/`filtered_row_count` (TSK-559).
- `Sources/RustCore/CoreClient.swift` — `CoreEnvelope.call`, `mdvEnvelopeCall`, `WireErrorDetail`/decode.
- `Sources/RustCore/CoreTransport.swift` — `InProcessTransport.methodIds` (all 8 via the envelope).

## How to resume
1. Read `docs/TASK_WORKFLOW.md`. `task_list {project:tasked, waiting:human}` FIRST — owner answers to
   the parked decisions (TSK-543/302/649/316/336/338) are the highest-leverage unblocks.
2. If owner answered TSK-543 → execute the chosen approach (slice 1 = stateful editor doc model; can
   reuse the TSK-541 handle-registry pattern + cm_edit's existing apply logic; behind a flag, host-tested).
3. TSK-451: needs a VM session + (ideally) a `pkill -9` allowance — implement the test-in-vm.sh cap
   (host-test the watchdog mechanism), then re-run on VM to ID + seam the hanging test; then the VM GUI
   lane can drain the ~20 live-validation fixed items.
4. Else (no owner steer, no VM): the clean pool is genuinely exhausted — prefer a documented hold over
   marginal paper cuts (§5). Gates: `bash scripts/test-headless-gate.sh` (host, ONE at a time) +
   `bash scripts/rust-core-gate.sh`. After rust changes: `bash scripts/build-rust-core.sh` (header + .a).
