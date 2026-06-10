# api-contract — rust-core audit 2026-06-09 (final, post-resume)

## Proposals (critique-judged)

### ABI + schema versioning handshake (version export, header pinning, frame envelope) — verdict: **sound-with-caveats** (effort small)
- **Critique:** PROBLEM IS REAL — every factual claim checks out. (a) No version export anywhere: the FFI surface is 14 `#[unsafe(no_mangle)]` exports in rust-core/crates/ffi/src/lib.rs (proposal says 16 — that's the textual `extern "C"` count including doc prose; minor overcount, not load-bearing), none version-related; workspace version is `0.0.0` (rust-core/Cargo.toml:28). (b) The header is gitignored at all three staging sites (`git check-ignore` confirms Sources/CMdvCore/mdvcore.h, rust-core/link/mdvcore.h, rust-core/crates/ffi/include/mdvcore.h). (c) build.rs:61-64 warns-and-continues on cbindgen failur
- **Improvements:** 1. DERIVE the version instead of hand-bumping: in build.rs, after cbindgen generates, compute a hash over the NORMALIZED declaration surface (strip comments/whitespace from the generated header), append `#define MDVCORE_ABI_VERSION 0x<hash32>` to the header, and write the same value to `$OUT_DIR/abi_version.rs` (`pub const MDVCORE_ABI_VERSION: u32`) which lib.rs `include!`s and returns from `mdvco

### Registry-based handle model: generation-checked integer ids instead of raw Box pointers — verdict: **sound-with-caveats** (effort medium)
- **Critique:** PROBLEM STATEMENT — mostly verified, one real inaccuracy.

Verified accurate: `rust-core/crates/ffi/src/handle.rs:62-64` is `Box::into_raw`; `handle.rs:74-80` (`as_ref`) blindly trusts the pointer via `ptr.as_ref()`; `handle.rs:87-93` (`free`) does `Box::from_raw` with no liveness check. The free-races-in-flight-call claim is correct and is the sharpest point: `mdvcore_session_free` (`rust-core/crates/ffi/src/lib.rs:601-607`) drops the Box without ever touching the inner Mutex, and even if it did, dropping while another thread holds a `&SessionHandle` borrow is UB regardless — the single-write
- **Improvements:** 1. Drop the {slot,generation} packing; use `Mutex<HashMap<u64, Arc<SessionEntry>>>` keyed by a monotonic u64 (start at 1, reserve 0 = invalid). Simpler, no ABA ever. 2. Replace `typedef uint64_t` with a `#[repr(C)]` newtype struct so cbindgen emits a distinct C type and Swift can't pass a stray integer. 3. Centralize panic dead-flagging in the registry: tombstone the entry on a caught panic so all

### Status taxonomy v2 + activate the dead rich-error channel — verdict: **sound-with-caveats** (effort medium)
- **Critique:** **Problem reality — verified, with one overstatement.**

(1) VERIFIED but OVERSTATED: `rust-core/crates/ffi/src/lib.rs:459` is exactly `Err(_) => MdvStatus::BadUtf8`. However, `OpenError` (`rust-core/crates/core/src/session.rs:237-243`) has exactly ONE variant — `BadUtf8 { valid_up_to }` — so today's mapping is faithful, not a misreport. The real, present-tense losses are (a) the `valid_up_to` byte offset is discarded, and (b) the `Err(_)` wildcard means a future second variant silently misreports as BadUtf8 with no compiler nudge. A latent fragility + lost diagnostics, not a live bug. S4, not
- **Improvements:** 1. **Add the phase tag to the core first.** Either split `WireFault` into request/response halves (e.g. `enum CallFault { BadRequest(WireFault), EncodeFailed(WireFault), TooLarge { len: usize } }`) returned by `apply_wire`/`parse_wire`/`hunk_marks_wire`/`snapshot_frame`, or restructure those helpers as decode-then-apply-then-encode so the FFI sees which phase failed. Without this, `Framing` → BadR

### Reconcile capacity contracts: parse limits vs MAX_FRAME_LEN — verdict: **sound-with-caveats** (effort small)
- **Critique:** THE PROBLEM IS REAL AND ACCURATELY EVIDENCED. Verified every citation: csv.rs:44-49 defaults admit 32M total cells / 256M input scalars with `truncated=false` for anything under the caps; wire.rs:73 defines a single MAX_FRAME_LEN=16 MiB whose doc comment (wire.rs:71-72) explicitly states its rationale is "Guards the decoder against a hostile / corrupt length prefix demanding a huge alloc" — yet encode_frame applies it to our own output at wire.rs:163-167. The stateful path hits it exactly as claimed: mdvcore_session_table encodes the full Table at crates/ffi/src/lib.rs:489 (→ MdvStatus::WireEr
- **Improvements:** 1. Re-frame present-day impact: cite RustCSVAdapter.swift:43-47 — today the cliff manifests as silent Swift fallback (`usedRust=false`) on every >16 MiB CSV, defeating the Rust path and polluting the A/B exactly where Rust should win. That's the motivating evidence, not hypothetical future breakage.
2. Resolve the encode/decode asymmetry explicitly: define per-direction constants (e.g. MAX_REQUEST

### Typed C enums and validated scalars instead of magic ints/sentinels — verdict: **sound-with-caveats** (effort small)
- **Critique:** The factual claims all check out, and the problem is real but modest — this is defense-in-depth hardening of a contract, not an active bug.

VERIFIED EVIDENCE:
- `mdvcore_hex_search` mode coercion is exactly as described: `if mode == 1 { Ascii } else { Hex }` at rust-core/crates/ffi/src/lib.rs:340-344. Any value but 1 silently becomes Hex. The doc comment (lib.rs:293-294) promises only 0/1, so rejecting other values is consistent with the documented contract — the behavior-change risk is near zero since Swift only ever passes `HexSearchKind.rawValue` (0 or 1).
- `mdvcore_session_set_filter` se
- **Improvements:** 1. State explicitly that the extern "C" parameter type REMAINS `u32` (never the `#[repr(C)]` enum itself) — the enum is exported for header constants and used internally after `TryFrom` validation. Receiving an invalid value through an enum-typed param is UB; this must be a stated invariant of the design, plus a doc-comment rule in lib.rs so future entry points follow it.
2. Drop the hex_render wi

### Misuse-resistant buffer return: opaque buf or consume-on-read accessor — verdict: **sound-with-caveats** (effort medium)
- **Critique:** PROBLEM VERIFICATION — accurate; every citation checks out. `MdvBuf` is a public-field `#[repr(C)]` POD (rust-core/crates/ffi/src/buf.rs:13-22; emitted in include/mdvcore.h:47-55), `free_in_place` nulls only the struct instance it is handed (buf.rs:61-63), so a caller that copies the struct and frees both copies reconstructs the same Vec twice (buf.rs:59) — UB by construction, exactly as claimed. `cap` is protected only by a doc comment (buf.rs:19-21). The data-is-copied-immediately claim is true at ALL 7 call sites, not just the cited one: Sources/RustCore/CoreClient.swift:221 (callBuf) plus 
- **Improvements:** 1. Commit to the callback copy-out as the primary design: `MdvStatus mdvcore_*(args..., void (*sink)(const uint8_t*, size_t, void*), void* ctx)` — Rust computes, invokes sink exactly once on success, frees internally. Deletes MdvBuf/mdvcore_buf_free entirely (strict unsafe-surface shrink). Drop "two-call size-then-copy" from consideration: for computed results it forces recompute (18 MB hex dump t

### Drop the in-band u32 length prefix at the FFI tier (framing belongs to transports) — verdict: **sound-with-caveats** (effort medium)
- **Critique:** The problem is real and every factual claim checks out against the code. The framing rationale at rust-core/crates/core/src/wire.rs:9-12 ("a single FFI read may otherwise return a partial or coalesced payload") genuinely describes stream-socket semantics that do not exist at this tier: every out-buf export returns an owned, complete MdvBuf whose `len` field (written by Rust) is the authoritative boundary — the in-band u32 prefix is a second, redundant copy of the same information. The double copy is confirmed: Sources/RustCore/CoreClient.swift:221 copies the whole buffer (`Array(UnsafeBufferPo
- **Improvements:** 1. Extend the contract to BOTH directions: requests lose the prefix too (Swift MsgPackValue.frame() → plain encode at MessagePack.swift:250; core apply_wire/parse_wire/hunk_marks_wire switch decode_frame→decode at cm_edit.rs:131, diff.rs:432, diff.rs:547); update the per-export doc comments and cbindgen header to state the body-only contract per export (msgpack body vs raw UTF-8). 2. Split into tw

### Symbol + surface hygiene: prefix the opaque type, gate test hooks, audit exported symbols — verdict: **sound-with-caveats** (effort small)
- **Critique:** All three factual claims verify against the tree, but the severity framing is inflated and the test-hook gating design is underspecified for this repo's actual link flow.

VERIFIED:
- `rust-core/crates/ffi/include/mdvcore.h:43` is exactly `typedef struct SessionHandle SessionHandle;` — the only un-prefixed identifier in the header (everything else is `MdvStatus`/`MdvBuf`/`mdvcore_*`), and `rust-core/crates/ffi/cbindgen.toml:17` has `[export] prefix = ""`. Real, if minor, hygiene gap.
- `mdvcore_add` (`rust-core/crates/ffi/src/lib.rs:71-74`) and `mdvcore_force_panic` (`lib.rs:84-97`) are uncond
- **Improvements:** 1. Do the rename as a one-line cbindgen `[export.rename]` entry in `rust-core/crates/ffi/cbindgen.toml` — zero Rust/Swift edits (Swift only sees `OpaquePointer`). Cheapest possible win; ship it.
2. Pull the symbol audit forward to TODAY on the staticlib: add to `scripts/rust-core-gate.sh` a header↔binary parity check — extract the declared `mdvcore_*` fn set from the generated `mdvcore.h` and diff

### Contract-tier test hardening: ABI snapshot, Miri/sanitizer lane, cross-language golden frames — verdict: **sound-with-caveats** (effort medium)
- **Critique:** The four mechanisms are all real, cheap, and verified-feasible against this codebase — but the PROBLEM statement overstates the failure mode, and the design misses the two most dangerous drift channels it is nominally about.

WHAT CHECKS OUT (verified):
- Ok-with-empty-buf mask: confirmed at /Users/me/Documents/workspaces/claude/markdown_viewer/Sources/RustCore/CoreClient.swift:242-244 — `decodeTable` returns a silent empty Table on an empty frame, while `decodeSnapshot` (line 260-261) has no such branch and would throw via `unframe`. The inconsistency is real; `mdvcore_session_table` always 
- **Improvements:** 1. Re-scope the ABI check to the channel that's actually open: make the gate fail when the STAGED header is stale — either make cbindgen failure fatal in build.rs (or at least in the gate), or add a gate step diffing freshly-generated `$OUT_DIR/mdvcore.h` against both `rust-core/crates/ffi/include/mdvcore.h` AND the staged `Sources/CMdvCore/mdvcore.h` (the copy SwiftPM actually compiles against, b

### (Direction option) Uniform binary-RPC dispatch as the growth path for the C surface — verdict: **sound-with-caveats** (effort large)
- **Critique:** The design direction is legitimate, standard for FFI-heavy products, and commendably self-gated ("only if the multi-frontend RPC direction is confirmed"). But its motivating evidence is partly wrong about THIS codebase, and its amortization math doesn't hold up under inspection.

WHAT'S REAL: (1) The pointer-validation boilerplate is genuinely copy-pasted six times across the stateless block at rust-core/crates/ffi/src/lib.rs:119-400 (null-check + `from_raw_parts` + empty-`MdvBuf` init, near-identical each time). (2) Each export does add a cbindgen header entry and a modulemap-visible symbol. 
- **Improvements:** 1. Re-ground the motivation: drop the "shared with web/TUI transports" claim (those are direct Rust linkage and should stay that way) and re-justify on the two real benefits — a single audited unsafe choke point, and WASM-tier readiness. State explicitly that TUI/web are out of scope as registry consumers.
2. Add a bulk-bytes escape hatch to the design: either keep mdvcore_hex_render/mdvcore_hex_s

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
