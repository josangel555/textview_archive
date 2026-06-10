# api-contract — rust-core audit 2026-06-09

## Proposals (critique-judged)

### ABI + schema versioning handshake (version export, header pinning, frame envelope)  — verdict: **sound-with-caveats** (effort small)
- **Critique:** PROBLEM STATEMENT: verified, real, and accurately cited — with one factual nit and one mis-weighted threat model.

Verified facts:
- No version export anywhere: /Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/ffi/src/lib.rs has exactly 14 (not 16) `#[unsafe(no_mangle)]` exports (mdvcore_add … mdvcore_buf_free), none version-related. Workspace version is `0.0.0` (rust-core/Cargo.toml:28). No check on the Swift side (Sources/RustCore/CoreClient.swift — `CoreError.unknown(UInt32)` at line 33 is the only forward-compat concession).
- Header + staticlib are gitignored build 
- **Improvements:** 1. Fix the comparison target: put the expected ABI constant in git-tracked Swift source (`CoreClient.expectedABI`), assert it against `mdvcore_abi_version()` (the lib export). Keep the header macro as a bonus compile-visible value, but the header-vs-lib comparison alone is ~worthless since both come from the same staged pair (scripts/build-rust-core.sh:120-122).
2. Drop `after_includes`; declare `

### Registry-based handle model: generation-checked integer ids instead of raw Box pointers  — verdict: **sound-with-caveats** (effort medium)
- **Critique:** The technical core of the proposal is verified accurate: the Box::into_raw handle model (rust-core/crates/ffi/src/handle.rs:62-64, as_ref at 74-80, free at 87-93) has a real, undetectable use-after-free/double-free surface, and the free-vs-in-flight-call race is genuine UB — mdvcore_session_free (rust-core/crates/ffi/src/lib.rs:601-607) drops the box without any liveness coordination, and the inner try_lock→Busy model (handle.rs:101-112) protects data access only, not lifetime. The Swift ARC-wrapper-makes-common-path-safe claim also checks out (Sources/RustCore/CoreClient.swift:100-127). The p
- **Improvements:** 1. Fix the motivation: drop the TUI/web-consumer claim (they use mdvcore_core as a Rust dep, not the C ABI — crates/tui/src/main.rs, crates/web/src/main.rs). Ground it instead on: (a) UB reachable through the public C contract is below the stated production bar regardless of current callers, (b) WASM/plugin-host tiers and binary-RPC frames need pointer-free ids, (c) the current contract's failure 

### Status taxonomy v2 + activate the dead rich-error channel  — verdict: **sound-with-caveats** (effort medium)
- **Critique:** PROBLEM VERIFICATION — all three cited problems are real, with one overstatement.

(1) VERIFIED with a caveat: `crates/ffi/src/lib.rs:459` is exactly `Err(_) => MdvStatus::BadUtf8`. BUT `OpenError` (crates/core/src/session.rs:237-243) is a SINGLE-variant enum — `BadUtf8 { valid_up_to }` is the only error `CsvSession::open` can return today (session.rs:54-56), so nothing is currently misreported. The real losses today are (a) the `valid_up_to` byte offset (and the nice Display message at session.rs:248-253) being discarded, and (b) fragility: a future `OpenError` variant silently becomes BadUtf
- **Improvements:** 1. Close the session_open/set_filter gap explicitly — it's the flagship case. Best option: a thread-local last-error slot plus ONE new export `mdvcore_last_error(out_buf: *mut MdvBuf) -> MdvStatus` (libgit2 `git_error_last` / SQLite `sqlite3_errmsg` pattern). Every fallible export writes the WireError frame to the TLS slot on failure; calls are synchronous, so Swift reads it immediately on the sam

### Reconcile capacity contracts: parse limits vs MAX_FRAME_LEN  — verdict: **sound-with-caveats** (effort small)
- **Critique:** The factual core of the proposal verifies completely against the code. csv.rs:44-49 admits 32M total cells / 256M input scalars with `truncated=false` below the caps; wire.rs:73 pins MAX_FRAME_LEN at 16 MiB with the doc comment explicitly framing it as a DECODE-side guard ("Guards the decoder against a hostile / corrupt length prefix demanding a huge alloc"), yet encode_frame applies the same cap at wire.rs:163-167. The failure path is exactly as claimed: mdvcore_session_open (ffi/src/lib.rs:451) parses any size happily, then mdvcore_session_table (lib.rs:489→495) and mdvcore_session_snapshot 
- **Improvements:** 1. Lead with windowing as THE fix, not an independent add-on: it is the only option that resolves the contradiction while preserving the encode→decode round-trip invariant the wire tests pin. Snapshot gains {offset, limit} in the request and {total_rows (already present), window_offset} in the response; do it now while the only consumer is CoreClient.swift + tests. 2. Extend the problem statement 

### Typed C enums and validated scalars instead of magic ints/sentinels  — verdict: **sound-with-caveats** (effort small)
- **Critique:** EVIDENCE CHECK — all cited locations are real and accurately described:
- `rust-core/crates/ffi/src/lib.rs:340-344`: `let kind = if mode == 1 { Ascii } else { Hex }` — confirmed; mode=2/garbage silently becomes Hex.
- `rust-core/crates/ffi/src/lib.rs:534-540`: `scope < 0 → Scope::All`, else `Scope::Column(usize::try_from(scope).unwrap_or(usize::MAX))` — confirmed.
- `rust-core/crates/ffi/src/lib.rs:283-284`: `unwrap_or(usize::MAX)` on width/total — confirmed.
- `Sources/RustCore/CoreClient.swift:81-91` (`FilterScope.rawValue` = -1) and `:538-541` (`HexSearchKind: UInt32` hex=0/ascii=1) — confi
- **Improvements:** 1. State explicitly that the extern "C" signatures KEEP raw integer parameters (`mode: u32`, `scope: i64`); the `#[repr(C)]`/`#[repr(u32)]` enum is exported for header constants and Swift-side pinning only, and validation is `TryFrom` on the raw integer → `BadArg`. Never type an FFI parameter as a Rust enum — invalid discriminant = instant UB, which would convert today's silent coercion into somet

### Misuse-resistant buffer return: opaque buf or consume-on-read accessor  — verdict: **sound-with-caveats** (effort medium)
- **Critique:** PROBLEM VALIDITY — real but correctly scoped as hardening, not a live bug (S3). Every factual claim checks out: MdvBuf is a by-value #[repr(C)] POD with a public, load-bearing `cap` (rust-core/crates/ffi/src/buf.rs:13-22; rust-core/crates/ffi/include/mdvcore.h:47-55); `free_in_place` nulls fields only through the pointer it receives (buf.rs:52-64), so a bitwise struct copy freed twice double-frees via `Vec::from_raw_parts` (buf.rs:59) — UB by construction, and Swift's value-semantics import of C structs makes copying trivially easy. The in-tree consumer is verifiably correct today: all 8 buf-r
- **Improvements:** 1. COMMIT to the sink/callback shape as the v2 contract for all 8 buf-returning exports: `MdvStatus mdvcore_X(args..., void *ctx, void (*sink)(void *ctx, const uint8_t *data, size_t len))`. Rust calls the sink once with a borrowed slice inside the existing ffi_guard; Swift copies inside the callback exactly as it does today (CoreClient.swift:221). Delete `mdvcore_buf_free` and `MdvBuf` from the AB

### Drop the in-band u32 length prefix at the FFI tier (framing belongs to transports)  — verdict: **sound-with-caveats** (effort medium)
- **Critique:** THE PROBLEM IS REAL — every factual claim checks out against the tree:

- Redundant prefix: `MdvBuf` carries an authoritative `len` (`rust-core/crates/ffi/src/buf.rs:14-22`), and the framing rationale at `rust-core/crates/core/src/wire.rs:9-12` ("a single FFI read may otherwise return a partial or coalesced payload") genuinely describes stream-socket semantics that cannot occur for an owned in-process out-buffer. The prefix is dead weight at this tier.
- Double copy: confirmed at `Sources/RustCore/CoreClient.swift:221` (`Array(UnsafeBufferPointer...)` — full copy 1) and `CoreClient.swift:234` 
- **Improvements:** To make the design land cleanly: (1) Restate the scope as a CORE-crate layering fix — `apply_wire`/`parse_wire`/`hunk_marks_wire`/`hex_search_frame`/`snapshot_frame` take and return BARE MessagePack bodies; framing becomes a transport-adapter concern (kept in `wire.rs` for the future socket tier). Update `snapshot_frame`'s direct-serialize path (drop the 4-byte placeholder at `session.rs:162-183`)

### Symbol + surface hygiene: prefix the opaque type, gate test hooks, audit exported symbols  — verdict: **sound-with-caveats** (effort small)
- **Critique:** All three factual claims verify against the tree, and the rename + symbol-audit halves are genuinely right; the test-hook-gating half underestimates its blast radius and overstates its payoff.

VERIFIED: (1) /Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/ffi/include/mdvcore.h:43 does emit bare `typedef struct SessionHandle SessionHandle;` and cbindgen.toml:17 has `prefix = ""` — every other identifier is Mdv/mdvcore_ prefixed, so the inconsistency is real. (2) `mdvcore_add` (lib.rs:71-74) and `mdvcore_force_panic` (lib.rs:84-97) are unconditionally exported and appear 
- **Improvements:** Reshape into three independently-landable pieces with corrected scope:

(a) LAND NOW, trivial: cbindgen rename (add `[export.rename]` SessionHandle = "MdvSession" in crates/ffi/cbindgen.toml, or rename the Rust type in handle.rs) — zero Swift changes since Swift holds it as OpaquePointer (CoreClient.swift:101). Regenerate header, done.

(b) LAND NOW, the real win: add an exported-symbol allowlist 

### Contract-tier test hardening: ABI snapshot, Miri/sanitizer lane, cross-language golden frames  — verdict: **sound-with-caveats** (effort medium)
- **Critique:** The four additions all target REAL, verified gaps, but the problem statement overstates the central one, which matters for prioritization.

VERIFIED CLAIMS (all check out):
- `scripts/rust-core-gate.sh:33-37` runs only clippy + cargo test — no Miri, no sanitizer, anywhere. The FFI tests (`rust-core/crates/ffi/src/tests.rs`) call the real extern fns directly from Rust, so `cargo miri test -p mdvcore-ffi` would interpret every `from_raw_parts`/`Box::into_raw`/`free_in_place` path as-is. The codebase even aspires to this: tests.rs:207-209 says a leak/double-free "would surface under Miri / ASan" 
- **Improvements:** 1. Reframe the problem statement honestly: the PR workflow already cross-checks Swift decode against freshly built Rust (pr.yml builds rust-core at line 91, Swift gate at line 107), so golden frames + ABI snapshot buy Rust-gate locality, crisp diagnostics, review-visible contract diffs, and protection for the version-skew future (prebuilt `.a` on the VM, dylib/WASM consumers) — not a prod-runtime-

### (Direction option) Uniform binary-RPC dispatch as the growth path for the C surface  — verdict: **sound-with-caveats** (effort large)
- **Critique:** **Problem is real but materially overstated, and the premise contains two factual errors.**

1) The boilerplate exists — but only 3 of the cited exports actually share the shape. The "identical bytes-in/frame-out pattern" holds for exactly three exports: `mdvcore_cm_apply` (crates/ffi/src/lib.rs:119), `mdvcore_diff_parse` (lib.rs:165), `mdvcore_diff_hunk_marks` (lib.rs:210). The others the proposal lumps in are deliberately NOT that shape: `mdvcore_hex_render` (lib.rs:259) takes a raw borrowed data buffer + scalars and returns **raw UTF-8, not a frame** — the doc at lib.rs:243-247 explains why
- **Improvements:** 1) Fix the premise before deciding: classify the surface into (a) frame-in/frame-out methods (3 today), (b) bulk-borrowed-bytes methods (hex_render, hex_search — cannot be framed without copies and the 16 MiB cap), (c) lifecycle/handle fns. Uniform dispatch applies cleanly only to (a). 2) If adopted, add a borrowed aux-bytes parameter to `mdvcore_call` (`const uint8_t* aux, size_t aux_len`) so bul

---

## Full reviewer report


# rust-core FFI boundary audit — API + contract design

Scope read: `rust-core/crates/ffi/src/{lib,buf,handle,status,guard,tests}.rs`, `rust-core/crates/ffi/{cbindgen.toml,build.rs,include/mdvcore.h,Cargo.toml}`, `rust-core/crates/core/src/wire.rs`, `rust-core/Cargo.toml` (profiles), `scripts/build-rust-core.sh`, Swift consumer `Sources/RustCore/CoreClient.swift` + `Sources/CMdvCore/module.modulemap`, `Tests/RustCoreTests/*`.

## What's already strong (credit where due)

- **Panic boundary is correct and honest**: every export wrapped in `catch_unwind` (`guard.rs`), the `dist` profile (`panic=unwind`) is the linked profile, and `build-rust-core.sh:32-48` actively REJECTS linking the `panic=abort` release profile. The guard's limits (abort/OOM/stack-overflow not catchable) are documented rather than hand-waved (guard.rs:11-15).
- **Out-params are zeroed before any early return** (e.g. lib.rs:129, 438) — no dangling out values on error paths.
- **Status enum discipline**: explicit discriminants, never-renumber rule, reserved `Internal=99` (status.rs), and Swift has a true forward-compat default arm (`CoreError.unknown(UInt32)`, CoreClient.swift:48).
- **Wire rigor**: `to_vec_named` map encoding pinned by a marker-byte test (wire.rs:342-353), trailing-garbage rejection in `decode` (wire.rs:118-134), decode-side length-prefix validation, byte-identity test for the single-alloc encoder.
- **Misuse tests exist and bite**: null args, bad UTF-8, null-handle calls, same-struct double-free, 8-thread contention (tests.rs:236-287), 1000× open/free.
- **Ownership story is documented in one place** (lib.rs:6-38) and the Swift `CsvSession` class makes the common path safe (ARC `deinit` frees exactly once; panic dead-flags the handle, CoreClient.swift:100-167).

## Findings

### S2 — No ABI/schema versioning of any kind
No `mdvcore_version()` export, no version constant in `include/mdvcore.h`, no schema version in any frame; workspace version is permanently `0.0.0` (rust-core/Cargo.toml:28). The header is a gitignored artifact (Sources/CMdvCore/.gitignore) regenerated by build.rs — which **tolerates cbindgen failure and silently leaves a stale header** (build.rs:61-64). The VM/app workflow links a pre-staged `rust-core/link/libmdvcore_ffi.a`, so binary↔header↔Swift drift is undetectable at build and runtime. For a "production, reusable core" this is the first gap to close. Fix: `mdvcore_abi_version()` + cbindgen-emitted `#define`, Swift startup assert, header/export-list snapshot test in the gate.

### S2 — Capacity contract mismatch: parse limits vs `MAX_FRAME_LEN`
CSV `Limits::default` admits up to 32M cells / 256M input scalars (csv.rs:44-49, `truncated=false` below caps), but `encode_frame` hard-fails any body > 16 MiB (wire.rs:73, 163-167). A ~20 MB CSV **opens fine** via `mdvcore_session_open` then `mdvcore_session_table`/`mdvcore_session_snapshot` (lib.rs:489; session.rs:183) fail forever with `WireError` — indistinguishable in Swift from a decode bug (CoreClient.swift:45), with no fallback on the stateful path. The 16 MiB guard protects the *decoder* from hostile prefixes; applying it to our own trusted *encoder* turns a security guard into a functional cliff. Fix: split decode-guard vs encode-cap, return a distinct `TooLarge` status, and/or window the Snapshot schema.

### S3 — Status taxonomy collapses distinct failure classes; the promised rich-error channel is dead code
- `CsvSession::open` errors map unconditionally to `BadUtf8`, discarding the error value (lib.rs:459).
- `WireError` conflates caller-bug (malformed request frame), core-bug (response encode failure), and capacity overflow (lib.rs:146, 192, 237; wire.rs:163).
- The module doc promises "Rich error detail (message + context) rides in the MessagePack wire body" (lib.rs:10-11) and `wire::WireError {code, message, data}` exists (wire.rs:62-69) — but **no export ever returns it**. A documented contract that is not implemented. Swift sees only the bare integer status.

### S3 — Handle lifetime safety is convention-only; `free` can race in-flight calls
`mdvcore_session_free` does an unconditional `Box::from_raw` (handle.rs:87-93) and `as_ref` blindly trusts the pointer (handle.rs:74-80). The internal Mutex serializes *data* access but does not protect the free path: free-while-another-thread-is-mid-call is UB the API can neither detect nor reject — documented away ("caller contract says won't race a live borrow", handle.rs:76-79) rather than designed away. Also, the poison-recovery in `with()` (handle.rs:104-111) lets post-panic, possibly half-mutated state keep serving any caller that ignores the `Panic` status — the "drop & recreate" rule (status.rs:29-31) is enforced only by the in-tree Swift wrapper, not by the contract. Fix: generation-checked id registry (see proposals) makes UAF/double-free unrepresentable and lets Rust dead-flag a panicked session itself.

### S3 — `MdvBuf` POD allows double-free by struct copy
`free_in_place` nulls the fields of the *pointed-to* struct (buf.rs:61-63), so the much-advertised double-free safety (tests.rs:191-204) holds only for re-free through the same instance. The struct is a value type in C/Swift; copy it, free both → two `Vec::from_raw_parts` on one allocation = UB. `cap` is also caller-mutable but load-bearing for the free (buf.rs:19-21 says "do not modify" — a comment, not an enforcement). In-tree usage is safe (single local + `defer`), but the contract is not misuse-resistant by construction.

### S3 — Unprefixed `SessionHandle` pollutes the global C namespace
`typedef struct SessionHandle SessionHandle;` (mdvcore.h:43) — every other identifier is `Mdv`/`mdvcore_`-prefixed; this one will collide with any other lib defining the same generic name. cbindgen export prefix is empty (cbindgen.toml:17).

### S3 — `Busy` contract has no consumer story
`try_lock`→`Busy` (handle.rs:101-112) is a sound single-writer design, but the only consumer turns it into a thrown `CoreError.busy` (CoreClient.swift:26-27) that nothing retries — a transient scheduling artifact surfaces as a user-visible failure. The header says "retry after the other call completes; do NOT spin tightly" (mdvcore.h:26-29) yet the API offers neither a blocking variant nor a backoff hint, and the thread-affinity expectation (effectively: one logical owner, calls from one queue) is documented only in Rust-side prose, not in the header the Swift consumer reads.

### S4 — Silent coercion of invalid scalar args
- `mode: u32` in `mdvcore_hex_search`: anything ≠ 1 silently means Hex (lib.rs:340-344) — unknown modes should be `BadArg`, or the header should carry a `#[repr(C)]` enum (cbindgen enum config already exists).
- `scope: i64` sentinel (-1=all) with out-of-range columns clamped to `usize::MAX` (lib.rs:534-540) — a buggy column index silently filters everything out instead of erroring.
- Swift re-hardcodes the magic numbers by hand (`FilterScope.rawValue`, CoreClient.swift:85-90; `HexSearchKind`, CoreClient.swift:538-541) with no parity test against the header.

### S4 — Redundant in-band length prefix at the FFI tier; double-copy on the Swift side
`MdvBuf.len` already delimits the payload; the u32 LE prefix inside the buffer re-states it, justified by stream semantics ("a single FFI read may otherwise return a partial payload", wire.rs:9-12) that don't apply to an in-process owned-buffer return. Swift pays the tax: full copy out of the buf (CoreClient.swift:221) then a second full copy to strip 4 bytes (`Array(frame[4...])`, CoreClient.swift:234). The contract isn't even uniform — `hex_render` and `indent_detect` deliberately return raw unframed UTF-8 (lib.rs:243-247, 356-359). Framing belongs to the socket transports (web/TUI), not the FFI buffer.

### S4 — Swift masks a contract violation: `Ok` + empty buf decodes as an empty Table
`decodeTable` returns a default empty `Table` when the frame is empty (CoreClient.swift:242-244). Per the contract, `session_table` on success always writes a frame; an empty buf with `Ok` is a core bug that should throw, not silently produce an empty table. (`decodeSnapshot` correctly has no such mask.)

### S4 — Test hooks in the production symbol surface
`mdvcore_add` and `mdvcore_force_panic` are unconditional exports (lib.rs:71-97). `force_panic` is a deliberate crash lever shipping in the app binary (an app-killer if a `panic=abort` build ever slips through despite the script guard). Gate behind a cargo feature enabled only for test/harness builds.

### S4 — Minor header/codegen nits
Generated header has stray leading spaces on single-line prototypes (mdvcore.h:63, 68, 83…), `[export] include` lists only `MdvStatus` (cbindgen.toml:19) with `MdvBuf`/`SessionHandle` picked up implicitly via signatures — works, but fragile if a type ever stops being referenced by a fn; `#include <stdlib.h>` is emitted but unused.

## Contract-testing assessment

Behavioral coverage is good (Rust: tests.rs misuse matrix + contention; Swift: `Tests/RustCoreTests/` A/B suites, `BridgeTests`, panic dead-flag state machine test). Gaps: nothing pins the **artifact** contract — no header/export-signature snapshot, no committed golden wire frames asserted from *both* languages (a field rename today fails only at Swift runtime), no Miri/ASan lane over the ffi tests (they drive real extern fns, so Miri would verify every `from_raw_parts`/`Box` round-trip), no test of `Ok`+empty-buf or of the `.unknown` status arm.

## Proposed production contract (summary — details in proposals)

1. **Version handshake** (small): `mdvcore_abi_version()` + header `#define` + Swift startup assert; build fails on cbindgen error in the app-link path; header/export snapshot in the gate.
2. **Registry handle model** (medium): generation-checked u64 ids replace `Box` pointers — UAF/double-free become `NotFound`, free-during-call becomes safe, Rust can self-dead-flag panicked sessions.
3. **Status v2 + live rich errors** (medium): append `BadRequestFrame/EncodeFailed/TooLarge/BadArg/NotFound`; on failure, the out-buf carries the framed `WireError` detail the docs already promise.
4. **Capacity reconciliation** (small): encode-side cap split from the decode guard; `TooLarge` status; windowed snapshot schema for the RPC future.
5. **Typed C enums, validated scalars** (small): `MdvHexSearchMode` et al. exported via cbindgen; reject unknowns with `BadArg`; Swift uses the imported constants, deleting hand-mirrored magic numbers.
6. **Opaque/linear buffers** (medium): opaque buf handle or Swift `~Copyable` wrapper; kill the copy-the-struct double-free class.
7. **De-frame the FFI tier** (medium): `MdvBuf.len` is the frame; prefix moves to stream transports; Swift decodes zero-copy off the borrowed buffer (removes 2 full copies per snapshot).
8. **Hygiene** (small): `MdvSession` rename, feature-gate test hooks, exported-symbols list for the future dylib.
9. **Contract test hardening** (medium): ABI snapshot, cross-language golden frames, nightly Miri/ASan lane, negative-path Swift tests.
10. **Direction option** (large): single `mdvcore_call(session, method_id, req, out)` dispatch shared with the web/TUI transports if the multi-frontend binary-RPC direction is confirmed — otherwise keep the per-fn surface.

All proposals are additive to the existing discipline (append-only status codes, named-map wire, panic guard, dist-profile guard), which is worth keeping verbatim.
