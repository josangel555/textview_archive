# architecture — rust-core audit 2026-06-09

## Proposals (critique-judged)

### Dismantle the TUI/web monoliths: extract a shared `mdvcore-app` state-machine crate + `mdvcore-host` IO crate  — verdict: **sound-with-caveats** (effort large)
- **Critique:** THE PROBLEM IS REAL BUT SMALLER THAN CLAIMED. I verified the duplication evidence and it checks out almost exactly: `read_capped` (rust-core/crates/tui/src/main.rs:2967 vs rust-core/crates/web/src/main.rs:1743), `human_size` (tui:2991 vs web:1771), `mtime_secs` (tui:2942 vs web:1764) are byte-identical; `config_path`/`load_config`/`save_config` scaffolding is duplicated (tui:482–500 vs web:113–131); the git subprocess invocation is duplicated (tui:2954 `git_status_for` vs web:821 `git_status_html`, same `git -C … --no-optional-locks status --porcelain=v1 --branch` incantation). The monolith si
- **Improvements:** 1. SPLIT THE PROPOSAL. Land `mdvcore-host` first as its own small/medium item: `read_capped`, `mtime_secs`, `human_size`, config IO, git-status spawn, and ONE dir/grep walker with explicit `confine_to: Option<&Path>` + symlink-loop guard, with tests asserting the web tier's confinement property survives (seed: web:545–600). This captures most of the verified dedup at low risk. Make `mdvcore-app` a

### Freeze the C ABI at a thin waist: one versioned envelope-dispatch entry point (+ `mdvcore_abi_version`), keep handles out-of-band  — verdict: **sound-with-caveats** (effort large)
- **Critique:** PROBLEM STATEMENT: VERIFIED, REAL. Every factual claim checks out against the tree:
- Exactly 14 `#[unsafe(no_mangle)]` extern fns in rust-core/crates/ffi/src/lib.rs (grep-confirmed).
- The three stateless slices ARE byte-for-byte structural clones differing only in the core fn called: `mdvcore_cm_apply` (lib.rs:119–149, calls `cm_edit::apply_wire`), `mdvcore_diff_parse` (lib.rs:164–195, `diff::parse_wire`), `mdvcore_diff_hunk_marks` (lib.rs:209–240, `diff::hunk_marks_wire`). The same null-check/empty-buf/slice/match boilerplate is repeated verbatim. The Swift side repeats the matching plumbin
- **Improvements:** 1. Resolve the 16 MiB cap before anything else: either (a) make the envelope framing cap per-method/configurable with the hex-render path sized explicitly (cap exists to bound hostile allocs — keep it, raise it per-payload-class), or (b) let large bin responses ride length-prefixed-raw with a response-envelope header that says so. Add a test that round-trips a >16 MiB hex render through the new en

### Implement the error contract the docs already promise: error frames in the out-buffer + a Rust-side dead-handle state  — verdict: **sound-with-caveats** (effort medium)
- **Critique:** PROBLEM VERIFICATION — all three contradictions are real, every citation checks out:

(1) Dead promise of rich errors: `rust-core/crates/ffi/src/lib.rs:10-11` ("Rich error detail (message + context) rides in the MessagePack wire body") and `rust-core/crates/ffi/src/status.rs:7-8` ("codes also match the WireError.code carried in the MessagePack body") both promise a contract the code never implements. `WireError` (`rust-core/crates/core/src/wire.rs:62-69`) is constructed exactly once — in its own byte-identity unit test (`wire.rs:264`). Every FFI error arm discards the `WireFault` detail: `Err(
- **Improvements:** 1. Fix (2) properly: replace `Err(_) => MdvStatus::BadUtf8` at lib.rs:459 with an exhaustive `match` on `OpenError` so a new variant is a compile error, not a silent mis-report — this is a 5-line fix independent of the dual-channel work and should land first. For the rich `valid_up_to` payload, either add an `out_err: *mut MdvBuf` param to `mdvcore_session_open` (ABI churn is cheap now; say so exp

### Wire protocol v1: explicit protocol version in the envelope, windowed snapshots, and a documented large-payload story  — verdict: **sound-with-caveats** (effort medium)
- **Critique:** VERIFIED CLAIMS — the load-bearing facts check out:

(a) No protocol version anywhere: confirmed. `rust-core/crates/core/src/wire.rs` carries no version in frames or envelopes (the `Snapshot.version` at wire.rs:52-54 is a *state* version, not protocol). The Swift decoder (`Sources/RustCore/CoreClient.swift:227-236, 260-272`) likewise has no version check.

(b) The snapshot scale wall is REAL and is the strongest part of the proposal: `snapshot_frame` (session.rs:162-184) serializes every surviving row per pull, and `encode_frame` hard-fails at `MAX_FRAME_LEN = 16 MiB` (wire.rs:73, enforced at 
- **Improvements:** 1. Extend windowing (or an explicit deprecation) to `mdvcore_session_table` (ffi/src/lib.rs:472-499) — it has the same 16 MiB wall as the snapshot path and is called on open; without it the "scale wall removed" claim is half-true. Simplest: make the windowed snapshot the only bulk-row surface and shrink `session_table` to header+metadata.
2. Restate the versioning motivation honestly: the hand-rol

### Multi-document core runtime: one runtime handle + integer document ids instead of one raw pointer per session  — verdict: **sound-with-caveats** (effort large)
- **Critique:** THE PROBLEM IS REAL BUT PROSPECTIVE, AND THE PROPOSAL IS HONEST ABOUT THAT. All cited evidence checks out: `Box::into_raw` per session at rust-core/crates/ffi/src/handle.rs:62-64, the caller-discipline safety contract at handle.rs:69-79 ("must be a live pointer... not yet freed" — pure prose, unenforceable), and per-handle try_lock→Busy at handle.rs:101-112. However, TODAY the hazard is well-contained: there is exactly ONE stateful session type (`CsvSession`), and the Swift side (Sources/RustCore/CoreClient.swift:100-126) wraps it in a single `final class` whose `deinit` frees exactly once, wi
- **Improvements:** 1. Add a bulk-bytes side channel to the envelope ABI (`mdvcore_call(runtime, req, req_len, bulk, bulk_len, out_buf)` or keep `doc.open` as a dedicated symbol taking ptr+len) so document payloads never ride inside a MessagePack frame — resolving the 16 MiB `MAX_FRAME_LEN` conflict (wire.rs:73) and avoiding a full extra copy per open. 2. Specify DocId = monotonically increasing u64, never reused (or

### Close the CI gate hole: workspace-wide clippy + tests, and make cbindgen header drift a hard failure  — verdict: **sound-with-caveats** (effort small)
- **Critique:** BOTH PROBLEMS ARE REAL AND VERIFIED.

(1) Gate hole — confirmed. `scripts/rust-core-gate.sh:33-37` runs `cargo clippy --all-targets` / `cargo test` with only `--manifest-path`, and `rust-core/Cargo.toml:23` sets `default-members = ["crates/core", "crates/ffi"]`, so the gate covers exactly those two crates. `crates/tui/src/main.rs:3055` and `crates/web/src/main.rs:1861` do have real `mod tests` (tui uses ratatui `TestBackend` — host-safe; web binds `TcpListener 127.0.0.1:0` — fine on CI) that no gate ever runs. `.github/workflows/pr.yml:91,98` runs only `build-rust-core.sh` + `rust-core-gate.sh
- **Improvements:** 1. Replace gate stage (3): drop `cargo check --target wasm32-unknown-unknown` as the sans-IO guard (it cannot catch std::fs/std::time — they compile on that target) and instead add clippy `disallowed-methods`/`disallowed-types` entries to the existing `rust-core/clippy.toml` (deny std::fs, std::net, std::time::Instant::now, std::thread, std::process in `mdvcore-core`). Keep the wasm check only if 

### WASM as the 4th front-end: ride the envelope, ship core-only first, keep highlight/tree-sitter out of tier 1  — verdict: **sound-with-caveats** (effort medium)
- **Critique:** FACTUAL CLAIMS — verified against the code. The proposal's premises hold: `mdvcore-core` is genuinely sans-IO and `#![forbid(unsafe_code)]` (crates/core/src/lib.rs:16–21), deps are exactly serde + rmp-serde with `default-features=false, features=["derive","alloc"]` (rust-core/Cargo.toml:32–35), and the cited std usage is wasm32-compatible (`std::io::Cursor` at crates/core/src/wire.rs:119, `std::sync::RwLock` at crates/core/src/trace.rs:88 — both work on wasm32-unknown-unknown). The transitive tree (rmp, byteorder, num-traits, paste) is wasm-clean; the `getrandom`/`libc` entries in Cargo.lock c
- **Improvements:** Split the proposal into three separately-shippable pieces with honest costing: (a) NOW, near-zero cost: add `cargo check -p mdvcore-core --target wasm32-unknown-unknown` to scripts/rust-core-gate.sh (plus `rustup target add` on host/CI — flag the toolchain component to the owner) — this alone locks in wasm-cleanliness, which is the proposal's real value today; (b) SPEC, folded into Proposal 2 as h

### One highlighter for all front-ends: expose mdvcore-highlight through the core RPC to the Swift app (owner-gated)  — verdict: **weak** (effort epic)
- **Critique:** The proposal's kernel (two tree-sitter integrations, fixes landing twice) is real, but its headline motivation is STALE, its design does not achieve "one highlighter," and as specced it would *increase* both the number of in-process highlight engines and bundle duplication.

**1. The motivating bug is already fixed.** The proposal leans on "known-buggy: predicates never evaluated — TSK-410." That landed: commit `5e840b3` "fix(highlight): evaluate tree-sitter query predicates (TSK-410)", and `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerCore/Highlight/TreeSitterEngine.sw
- **Improvements:** 1. **Re-validate the problem first.** TSK-410 is fixed (commit `5e840b3`); restate the problem as "three divergent highlight stacks (Lezer editor, Swift TS, Rust TS) with divergent queries" and decide whether app-visible recoloring is even wanted before any engine work.
2. **Do query-level unification before engine-level.** Share one set of vendored `.scm` highlight queries between `Sources/Viewer

---

## Full reviewer report

# rust-core ARCHITECTURE audit — PoC → production core

Scope: `rust-core/` workspace only. Dimension: architecture (decomposition, FFI surface, wire protocol, error model, state/session, WASM path, build/release). All paths relative to `/Users/me/Documents/workspaces/claude/markdown_viewer/`.

## Verdict in one paragraph

The PoC's *core* discipline is genuinely production-grade already — the `forbid(unsafe_code)` core / single-unsafe-FFI-crate split, the no-panic deny lints with a gate that actually runs clippy, the panic-profile guard in `scripts/build-rust-core.sh`, byte-identity tests for the frame encoder, and trailing-garbage-rejecting decode are all the right instincts, executed. The gaps are at the **edges**: the FFI surface grows a hand-written C symbol + hand-rolled Swift codec per feature with **no ABI/protocol version anywhere**; the documented rich-error contract is **unimplemented dead code**; the two front-end binaries are untested, unlinted 7.7k-line monoliths duplicating an application layer that should be one shared crate; and the level-triggered snapshot re-encodes every visible row per pull, which hits the 16 MiB frame cap before real-world CSV sizes do.

## Ranked findings

| # | Sev | Finding | Evidence |
|---|-----|---------|----------|
| 1 | S2 | **Merge gate covers core+ffi only; tui (4,666 LoC) + web (3,079 LoC) get zero clippy and their tests never run in CI.** `rust-core-gate.sh` invokes `cargo clippy/test` with `--manifest-path` only → `default-members = [core, ffi]` applies. Both binaries also opt out of workspace lints entirely. | `scripts/rust-core-gate.sh:36-40`; `rust-core/Cargo.toml` (`default-members`); `rust-core/crates/tui/Cargo.toml` + `crates/web/Cargo.toml` lint-opt-out notes; tests exist but un-run in gate: `crates/tui/src/main.rs:3055`, `crates/web/src/main.rs:1861` |
| 2 | S2 | **No ABI or wire-protocol version exists.** No `mdvcore_*version*` export (grep of `crates/ffi/src/lib.rs` + `cbindgen.toml`: none of the 14 `#[unsafe(no_mangle)]` fns), no version field in any frame. A skewed staticlib vs Swift decoder fails by silent mis-decode, not by detection. | `crates/ffi/src/lib.rs` (14 exports, none version); `crates/core/src/wire.rs:136-178` (frame = len+body only) |
| 3 | S2 | **Snapshot pulls serialize ALL visible rows every time** — O(matches) encode per filter keystroke, colliding with `MAX_FRAME_LEN = 16 MiB` on large CSVs. The hex path already had to bypass framing for the same scale reason (4 MB file → ~18 MB dump). | `crates/core/src/session.rs:162-184` (`snapshot_frame`); `crates/core/src/wire.rs:73`; `crates/ffi/src/lib.rs:243-247` (hex raw-bypass rationale) |
| 4 | S3 | **The rich-error contract is documented but unimplemented.** `WireError {code,message,data}` is never constructed outside its own unit test; every FFI error arm is `Err(_) => MdvStatus::…`, discarding the `WireFault` message. Docs claim otherwise. | type: `crates/core/src/wire.rs:62-69`; only construction: `wire.rs:264` (test); discard sites: `crates/ffi/src/lib.rs:146,192,237,351,495,587`; contract claim: `lib.rs:10-11`, `crates/ffi/src/status.rs:7-8` |
| 5 | S3 | **Poisoned-lock recovery contradicts the drop-&-recreate panic contract.** After a caught panic, `SessionHandle::with` recovers the poisoned Mutex and keeps operating on possibly half-mutated state; dead-flagging exists only on the Swift side, so non-Swift consumers are unprotected. | `crates/ffi/src/handle.rs:104-109` vs `crates/ffi/src/status.rs:31` and `crates/ffi/src/guard.rs:20-22`; Swift-only mitigation: `Sources/RustCore/CoreClient.swift` (`dead` flag) |
| 6 | S3 | **cbindgen failure is warn-only → stale-header drift risk.** A header-gen regression leaves the previous `include/mdvcore.h` in place and the build proceeds; the SwiftPM systemLibrary compiles against stale declarations. Also emits `cargo:warning` noise on every successful build. | `crates/ffi/build.rs:61-64` (tolerate failure), `:56-59` (success warning) |
| 7 | S3 | **FFI-fn-per-feature doesn't scale.** The three stateless slices are copy-paste bodies differing in one call (`mdvcore_cm_apply`/`mdvcore_diff_parse`/`mdvcore_diff_hunk_marks`), and Swift hand-rolls a MessagePack encoder/decoder per method. | `crates/ffi/src/lib.rs:119-149` vs `:164-195` vs `:209-240`; `Sources/RustCore/CoreClient.swift:296-336` |
| 8 | S3 | **Application-layer duplication across tui/web** despite the shared `view.rs` view-model: `read_capped` (tui:2968 / web:1743), `human_size` (tui:2991 / web:1771), `mtime_secs` (tui:2942 / web:1764), config persistence (tui:482-495 / web:114-126), git status (tui:2954 / web:821), grep (tui:223 / web:545). | `crates/tui/src/main.rs`, `crates/web/src/main.rs`; shared model that proves the pattern works: `crates/core/src/view.rs:1-10` |
| 9 | S4 | `mdvcore_session_open` collapses every `OpenError` to `BadUtf8` (correct today only because one variant exists). | `crates/ffi/src/lib.rs:459`; `crates/core/src/session.rs:236-243` |
| 10 | S4 | Inconsistent response shapes: framed MessagePack for most methods, raw UTF-8 for `hex_render`/`indent_detect` — per-method special cases the caller must memorize. | `crates/ffi/src/lib.rs:243-247`, `:358-359` |
| 11 | S4 | Stage-0 smoke `mdvcore_add` ships in the production export surface; workspace version is `0.0.0`. | `crates/ffi/src/lib.rs:71-74`; `rust-core/Cargo.toml` (`[workspace.package] version`) |

## What is RIGHT and must be preserved

- **Crate split**: `#![forbid(unsafe_code)]` core (`crates/core/src/lib.rs:21`) / unsafe-only-in-ffi, with `multiple_unsafe_ops_per_block` + `undocumented_unsafe_blocks` denied in ffi (`crates/ffi/Cargo.toml`). Highlight's unsafe grammar C correctly quarantined in its own non-default-member crate.
- **Panic semantics are actually thought through**: `release` (panic=abort, size figure) vs `dist` (panic=unwind, the GUI-linked profile), with the build script **rejecting** abort profiles on the app-link path (`scripts/build-rust-core.sh` profile guard). Most projects get this wrong; this one documents *why* (`crates/ffi/src/guard.rs:1-15` even corrects the stale UB folklore — post-1.81 it's defined abort).
- **Wire hygiene**: `to_vec_named` for Swift Codable interop, end-of-stream check rejecting trailing bytes (`wire.rs:108-134`), framing length validation + 16 MiB hostile-prefix guard, and a byte-identity oracle test pinning the single-alloc encoder to the legacy path (`wire.rs:228-283`).
- **Ownership conventions**: out-params pre-nulled/pre-emptied so error paths are safe-to-free (`lib.rs:129` et al.), `MdvBuf` carrying `cap` for correct `Vec::from_raw_parts` (`crates/ffi/src/buf.rs:19-22`), free fns null-tolerant and double-free-hardened (`buf.rs:52-64`), ARC-driven exactly-once free on the Swift side.
- **Level-triggered snapshot semantics** with version stamps and idempotent `set_filter` (`session.rs:101-119`) — the reconciliation model is correct; only its *granularity* (full vs windowed) needs to change.
- **`trace.rs`** is the right seam for host observability (pluggable sink, no clock in core, deterministic) — production work is wiring it across the FFI to the Swift `ObservabilitySink`, not redesigning it.
- **Exact-pinned deps**, serde+rmp-serde only in the gate path.

## Target architecture (proposed)

```
                       ┌─────────────────────────────────────────────┐
                       │              mdvcore-core (sans-IO)         │
                       │  csv diff hex find … + wire(envelope v1)    │
                       │  + dispatch (method registry, safe Rust)    │
                       └──────────────▲──────────────▲───────────────┘
            ┌─────────────────┐      │              │       ┌────────────────┐
            │  mdvcore-app    │──────┘              └───────│ mdvcore-       │
            │  (Elm-style     │   pure                      │ highlight      │
            │  Model/Msg/     │                             │ (unsafe C,     │
            │  update+Effect) │                             │  quarantined)  │
            └───▲────────▲────┘                             └────────────────┘
                │        │ effects (data only)
   ┌────────────┴──┐  ┌──┴───────────────┐
   │ tui (render   │  │ web (render      │     mdvcore-host: read_capped,
   │ only, ~800 ln)│  │ only)            │ ◄── config IO, git subprocess
   └───────────────┘  └──────────────────┘     (the ONE std-IO crate)

   FFI thin waist (frozen ~7 symbols):
     mdvcore_abi_version()
     mdvcore_call(req, len, out)                 ← stateless envelope
     mdvcore_runtime_new/free                    ← ONE handle per app
     mdvcore_call_rt(rt, req, len, out)          ← doc_id rides IN the envelope
     mdvcore_buf_free, mdvcore_force_panic
   WASM tier-1 = same envelope over linear memory (no new deps).
```

**Error contract:** status enum stays the coarse transport code; on non-Ok, `out_buf` carries an encoded `WireError{code,message,data}` (codes: 1–99 transport, 100+ domain). New `HandleDead`/`DocNotFound` codes replace silent poisoned-lock recovery and raw-pointer-per-session UAF risk respectively.

**Wire:** MessagePack named-maps is the right call (owner mandate: binary, no JSON; Swift decoder exists; field-name maps = free additive evolution). Add `v` to the envelope; windowed snapshots (`{offset,limit}`) keep level-triggered semantics at O(viewport) cost. Flatbuffers/Cap'n Proto rejected: new deps, owner approval needed, and Swift copies into native String/Array regardless — the zero-copy win doesn't materialize on this host. The existing borrow-serializing `SnapshotView` (`session.rs:224-233`) is the right kind of optimization.

**Bindings:** keep cbindgen — with the surface frozen at ~7 symbols it is trivially sufficient. uniffi / swift-bridge are flagged as dep PROPOSALS only and recommended **against**: heavy transitive surface, their own serialization conventions conflict with the owner's compact-binary mandate, and the envelope makes generated bindings unnecessary.

## Sequencing recommendation

1. **Proposal 6** (gate: workspace lane + cbindgen drift check + wasm check) — small, makes everything after regression-guarded.
2. **Proposal 3** (error frames + Rust-side dead-handle) — medium, closes the doc/code contradiction while the surface is small.
3. **Proposal 2** (envelope dispatch + `mdvcore_abi_version`) — the keystone; do before more per-method symbols accrete.
4. **Proposal 4** (wire v1 + windowed snapshots) — rides on 2's envelope.
5. **Proposal 5** (CoreRuntime + doc ids) — before the Swift adapter grows more per-pointer session classes.
6. **Proposal 1** (app-model extraction) — large; can proceed in parallel after 1's gate coverage exists.
7. **Proposal 7** (WASM tier-1) — nearly free once 3–4 land.
8. **Proposal 8** (unified highlighting) — owner-gated (bundle size + unsafe-C blast radius); severable.
