# architecture — rust-core audit 2026-06-09 (final, post-resume)

## Proposals (critique-judged)

### Dismantle the TUI/web monoliths: extract a shared `mdvcore-app` state-machine crate + `mdvcore-host` IO crate — verdict: **sound-with-caveats** (effort large)
- **Critique:** THE PROBLEM IS REAL AND THE EVIDENCE CHECKS OUT. Every citation verified: tui/main.rs is 4,666 lines with `impl App` at rust-core/crates/tui/src/main.rs:632 running to ~2923; web/main.rs is 3,079 lines. `read_capped` (tui:2968 vs web:1743) and `human_size` (tui:2991 vs web:1771) are byte-identical; `mtime_secs` (tui:2942 / web:1764), config load/save (tui:482–495 / web:114–126, two separate hand-rolled key=value codecs), git subprocess invocation (tui:2954 / web:821, both shelling git and feeding core `git::parse_status`), and the grep walk (tui `run_grep` at tui:1322 vs web `grep_walk` at web
- **Improvements:** 1. PHASE IT — host first, app second. Extract `mdvcore-host` (read_capped, mtime_secs, human_size, one shared key=value config codec, git subprocess, bounded grep walk) as its own mechanical PR gated by the existing 135 front-end tests plus new host unit tests; this captures most of the verified duplication at a fraction of the risk. Then build `mdvcore-app` for the TUI only; let the web tier adop

### Freeze the C ABI at a thin waist: one versioned envelope-dispatch entry point (+ `mdvcore_abi_version`), keep handles out-of-band — verdict: **sound-with-caveats** (effort large)
- **Critique:** PROBLEM IS REAL — every factual claim verified against the tree. (1) Exactly 14 `#[unsafe(no_mangle)]` extern fns in rust-core/crates/ffi/src/lib.rs (grep count = 14). (2) The three stateless slices ARE byte-for-byte copy-paste differing only in the dispatched core fn: `mdvcore_cm_apply` lib.rs:119–149, `mdvcore_diff_parse` lib.rs:164–195, `mdvcore_diff_hunk_marks` lib.rs:209–240 — identical out_buf-null-check / from_raw_parts / match scaffolding. (3) No ABI/protocol version symbol exists anywhere (grep `version` over lib.rs + cbindgen.toml: zero hits) — Swift genuinely cannot detect staticlib
- **Improvements:** 1. Resolve the MAX_FRAME_LEN conflict explicitly (this is currently a latent breakage): either (a) cap only the structured envelope portion and exempt/separately-cap `bin` payloads with a per-method byte budget, or (b) keep big-output methods' responses as today's unframed MdvBuf with the envelope carrying a "body follows raw" marker. Pick one and write it into the wire spec — "one convention" as 

### Implement the error contract the docs already promise: error frames in the out-buffer + a Rust-side dead-handle state — verdict: **sound-with-caveats** (effort medium)
- **Critique:** The problem statement is fully accurate — I verified every citation. (1) The docs at rust-core/crates/ffi/src/lib.rs:10-11 and status.rs:7-8 do promise rich error detail in the MessagePack body, and WireError (crates/core/src/wire.rs:62-69) is constructed nowhere except its own unit test (wire.rs:264); all six `Err(_) => MdvStatus::WireError` arms are at exactly lib.rs:146, 192, 237, 351, 495, 587, discarding the WireFault Display strings that wire.rs:87-95 carefully builds. (2) lib.rs:459 is `Err(_) => MdvStatus::BadUtf8` and OpenError (session.rs:237-243) has exactly one variant, so the mis-
- **Improvements:** 1. Replace the AtomicBool + ffi_guard! wiring with Mutex-poison detection: make SessionHandle::with (rust-core/crates/ffi/src/handle.rs:101-112) return an enum {Ok(R), Busy, Poisoned} and stop recovering at handle.rs:104-109; map Poisoned → MdvStatus::HandleDead at the four call sites (lib.rs:488, 545, 575 + any future). Poison is set automatically and exactly when a panic occurred under the lock 

### Wire protocol v1: explicit protocol version in the envelope, windowed snapshots, and a documented large-payload story — verdict: **sound-with-caveats** (effort medium)
- **Critique:** Evidence check: every factual claim in the proposal holds up against the code, with one overstatement and one mis-attribution.

VERIFIED: (1) No protocol version exists anywhere on the boundary — `rust-core/crates/core/src/wire.rs` carries no version field or constant (the `version: u64` at wire.rs:54 is the session *state* stamp, not a protocol version), and nothing in `rust-core/crates/ffi/src/lib.rs` exports one. Evolution today rests entirely on named-map key tolerance, exactly as claimed. (2) The full-snapshot scale wall is real and is a FUNCTIONAL failure, not just perf: `snapshot_frame`
- **Improvements:** 1. Extend the windowing story to cover `mdvcore_session_table` (lib.rs:471–500; live caller at Sources/RustCore/CoreClient.swift:131) — window it, or deprecate it for large files in favor of `snapshot{offset,limit}` with an explicit migration note for the Swift adapter. Without this the "scale wall removed" claim is untrue.
2. Replace the startup handshake with a passive scheme: export `MDV_WIRE_V

### Multi-document core runtime: one runtime handle + integer document ids instead of one raw pointer per session — verdict: **sound-with-caveats** (effort large)
- **Critique:** FACT-CHECK: the proposal's evidence is accurate. `Box::into_raw` per session is real (rust-core/crates/ffi/src/handle.rs:62-64), the UAF/double-free guard is purely a documented caller contract (handle.rs:69-93), and the per-handle `try_lock → Busy` single-writer model is as described (handle.rs:101-112, mapped to `MdvStatus::Busy` at lib.rs:498/549/590). The registry/handle-table design (one runtime, monotonic integer ids, stale id → recoverable `DocNotFound`) is the canonical production pattern for exactly this hazard class — it is how fds, JNI handle tables, and Vulkan-style dispatchable ha
- **Improvements:** 1. State explicitly: DocIds are monotonic u64, NEVER reused (kills ABA without generation counters).
2. Specify the lock shape: `RwLock<HashMap<DocId, Arc<Mutex<DocumentSession>>>>`, clone-Arc then drop map lock then `try_lock` the doc (preserving Busy semantics); skip sharding until contention is measured. Define `doc.close` on a busy doc (recommend: remove from map immediately, in-flight call co

### Close the CI gate hole: workspace-wide clippy + tests, and make cbindgen header drift a hard failure — verdict: **sound-with-caveats** (effort small)
- **Critique:** PROBLEM VERIFICATION — the core problem is real and accurately evidenced.

(1) Gate hole: CONFIRMED. `scripts/rust-core-gate.sh:34` runs `cargo clippy --manifest-path "$RUST_DIR/Cargo.toml" --all-targets` and `:37` runs `cargo test --manifest-path ...` — no `--workspace`/`-p`, so in this virtual workspace both operate on `default-members = ["crates/core", "crates/ffi"]` (rust-core/Cargo.toml:23). The tui (`mod tests` at crates/tui/src/main.rs:3055) and web (`mod tests` at crates/web/src/main.rs:1861) test suites never run in any gate, and both crates deliberately skip `lints.workspace = true` 
- **Improvements:** 1. Drop the temp-dir header diff. Replace with: build.rs fails hard on cbindgen error — preferably unconditionally rather than MDV_CI-gated (cbindgen is exact-pinned; the build.rs:10-13 tolerance rationale doesn't hold, and env-gating needs `cargo:rerun-if-env-changed` which churns the shared target-dir cache). Keep dropping the success-path `cargo:warning` (build.rs:56-59) — that part is right.
2

### WASM as the 4th front-end: ride the envelope, ship core-only first, keep highlight/tree-sitter out of tier 1 — verdict: **sound-with-caveats** (effort medium)
- **Critique:** The proposal's factual premises are almost entirely accurate against the code, and the tiering instinct (core-only WASM now, tree-sitter never in tier 1) is correct for this codebase. Verified: mdvcore-core is genuinely wasm-shaped — `#![forbid(unsafe_code)]` + sans-IO contract (crates/core/src/lib.rs:16–21), zero std::fs/time/thread/net/process usage (grep clean), deps exactly serde+rmp-serde whose transitives (byteorder, rmp, num-traits) are all pure-Rust wasm32-compatible, `std::io::Cursor` at wire.rs:119 and the `RwLock` sink at trace.rs:88 both fine on wasm32-unknown-unknown. Also verifie
- **Improvements:** 1. Split the proposal: land the `cargo check --target wasm32-unknown-unknown -p mdvcore-core` gate line immediately (one-time `rustup target add` on host + CI; note CI's pr.yml has network, this sandbox didn't); defer the mdvcore-wasm shim until Proposal 2's envelope exists and a wasm test runtime is approved. 2. Add a trap-recovery contract to the design: panics trap on wasm32-unknown-unknown (ca

### One highlighter for all front-ends: expose mdvcore-highlight through the core RPC to the Swift app (owner-gated) — verdict: **weak** (effort epic)
- **Critique:** The duplication is real, but the proposal misstates the problem, overstates the unification win, and contains one technically incoherent design element. Verified against the code:

1. STALE PROBLEM STATEMENT (the headline motivator is fixed). The proposal calls the Swift TreeSitter integration "known-buggy: predicates #match?/#eq? never evaluated — TSK-410". That bug was fixed in commit b0866a1 ("fix(highlight): evaluate tree-sitter query predicates (TSK-410)") with regression tests (b8eae92, c399bf7). Sources/ViewerCore/Highlight/TreeSitterEngine.swift:83-100 now resolves predicates via `curs
- **Improvements:** 1. Re-ground the problem statement post-TSK-410: the honest pitch is "eliminate dual grammar/query maintenance and version skew", not "fix the buggy Swift highlighter". Quantify actual divergence today (grammar versions: Swift pins tree-sitter-* 0.23.x via SwiftPM, Rust pins 0.24/0.25; query sources: hand-vendored .scm vs crate-bundled).

2. Scope it as "one PARSING stack", not "one highlighter": 

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
