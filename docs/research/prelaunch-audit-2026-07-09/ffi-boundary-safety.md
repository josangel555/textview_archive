# Pre-launch audit — Rust↔Swift FFI memory & panic safety

**Reviewer lens:** buffer ownership/lifetime across the FFI, panic unwinding across the
boundary (UB), null/dangling-handle handling, and stale ABI/type-layout traps.
**Date:** 2026-07-09 · **Scope:** `rust-core/crates/ffi/`, `Sources/RustCore/`,
`Sources/CMdvCore/`, and the direct-FFI consumer seam in `Sources/ViewerCore/`.

---

## Executive summary

**This boundary is, on the whole, exemplary — one of the most carefully-built FFI seams I
have reviewed in a production codebase.** The hard hazards this lens exists to catch are
already closed, several of them deliberately and with regression tests that prove teeth:

- Opaque handles are **registry tokens, not raw `Box` pointers** (`handle.rs` /
  `canvas_handle.rs`, TSK-541), so a free racing an in-flight call defers the real drop to
  an `Arc` clone — no use-after-free, no dropping a locked `Mutex`. `lookup`/`free` are
  *total* over any pointer value (null / freed / fabricated → `None`), so a stale or bogus
  handle never dereferences.
- **Every `extern "C"` entry point is wrapped in `catch_unwind`** (`guard.rs`), and the
  **shipping library links the `dist` profile with `panic = "unwind"`**
  (`rust-core/Cargo.toml` `[profile.dist]`, forced by `build-rust-core.sh` which *rejects*
  the `release`/`panic=abort` profile for the app-link path). So a core panic becomes
  `MdvStatus::Panic` and the host GUI survives — the guard is genuinely load-bearing, not
  decorative.
- **Buffer ownership is single-sided and disciplined:** `MdvBuf` carries its original `cap`
  so the `Vec` is reconstructed correctly; `free_in_place` nulls the fields so a double-free
  is a harmless no-op; every Swift call site copies the bytes into an owned `[UInt8]`/`String`
  *before* a `defer { mdvcore_buf_free(&buf) }` runs. Out-params are set to
  `MdvBuf::empty()` at function entry so every error path leaves a safe-to-free value.
- **ABI/layout skew is guarded at runtime:** `CoreABI.assertCompatible()` crash-fasts once
  per process if the linked staticlib's `mdvcore_abi_version()` disagrees with the
  compiled-in `MDV_WIRE_VERSION`; a capability bitmap negotiates features above the frozen
  wire. The three header copies (`Sources/CMdvCore/`, `rust-core/link/`,
  `rust-core/crates/ffi/include/`) are byte-identical today, and `MdvBuf`'s C layout
  matches the Rust `#[repr(C)]`.
- **The FFI edge denies panics as lints** (`unwrap_used`/`expect_used`/`indexing_slicing`/
  `string_slice`/`panic` = `deny` in `ffi/Cargo.toml`), and hostile-width hex render is
  clamped (`MAX_HEX_WIDTH`) precisely to avoid an alloc-failure `abort()` that
  `catch_unwind` could not intercept.

The findings below are **defense-in-depth and consistency gaps, not open UB.** The most
material one (F1) is a client-crash vector that exists **only on the opt-in remote-core
transport**, not the default in-process path — but it directly contradicts a hardening the
team already applied to a sibling decoder, so it reads as an oversight rather than a
considered trade-off.

No P0/P1 issues found under this lens.

---

## Methodology

Read in full: `ffi/src/{lib.rs (1602 lines), buf.rs, handle.rs, canvas_handle.rs,
guard.rs, status.rs, launchd.rs}`; `Sources/RustCore/{CoreClient.swift (1524 lines),
CanvasCore.swift, CoreDocStore.swift, CoreTransport.swift, RemoteTransport.swift}`;
`Sources/CMdvCore/mdvcore.h` (MdvBuf/MdvStatus layout). Diffed the three header copies.
Traced the cargo profile that the shipping app links (`build-app.sh` →
`build-rust-core.sh` → `[profile.dist]`). Grepped every direct `mdvcore_*` call site
across `Sources/` (all are inside `Sources/RustCore/`; no raw FFI leaks into ViewerCore/UI).
Traced session-wrapper concurrency usage (`CSVRowWindowSource`, `CanvasDocAdapter`,
`RustCSVAdapter`) and the remote-attach gate (`RemoteCoreAttach`). Enumerated every
integer-conversion site in the decoders. Reviewed the FFI test inventory
(`ffi/src/tests.rs`, ~60 tests). Did **not** run window-opening or heavy-tier tests
(static analysis only, per constraints).

---

## Findings

### F1 — Untrusted-wire integers hard-crash the client (Swift trap), inconsistently hardened
**Severity: P2** · `Sources/RustCore/CoreClient.swift` (see lines below) ·
**fix size: S** · **fix risk: safe**

**Evidence.** The bridge decodes wire integers from a core response straight into `Int`
via the *trapping* `Int(UInt64)` / `Int(Double)` conversions:

- `decodeDiffHunk` — `CoreClient.swift:1014-1017` (`Int(try a[n].u64Value())` ×4)
- `decodeDiffHunkMarks` — `:1060`; `decodeOptInt` — `:1092`
- `mdvCoreApplyCMEditsDelta` — `:787, :795-797`
- `mdvCoreFuzzyRank` — `:1234-1235` (index, score)
- `mdvCoreFindSearch` — `:1289-1292` (location, length, line, column)
- `decodeFoldRegion` — `:987-988` (`Int(try a[n].doubleValue())`)

`u64Value()` returns a full `UInt64`; `Int(UInt64)` **traps** (aborts the process, not a
throw) on any value `> Int.max` (2^63−1). `decodeFoldRegion` is worse: `doubleValue()` can
yield `.double(NaN/∞)` from a wire float (MsgPack `0xca`/`0xcb`), and `Int(Double.nan)` /
`Int(1e300)` also **trap**.

The sibling decoder immediately below — `mdvCoreHighlightRuns`, `:1352-1353` — was
**explicitly hardened for exactly this** (TSK-978): it uses `Int(exactly:)` and drops an
out-of-range span, with a comment *"a remote producer can route a start/len of 2^63 here
and crash the app at DECODE time."* That reasoning applies verbatim to diff/find/fuzzy/
cm-delta/fold, which were left on the trapping path.

**Impact / failure scenario.** In-process (the default) the core produces bounded values
(diff coords clamped to ≤1e9, find offsets bounded by text length, fuzzy index bounded by
candidate count), so this is unreachable there. But when a user opts into a remote core
(`MDV_REMOTE_SOCKET` → `RemoteCoreAttach` installs `RemoteTransport`), diff/find/fuzzy/
fold are all remote-servable methods (`CoreTransport.swift:61-74`). A **buggy or
version-skewed `mdv-serve`** — precisely the case the graceful-decode-error + Swift-engine
fallback design exists to absorb — that emits a field `> 2^63` (or a NaN fold line) makes
the client **`abort()` at decode time** instead of throwing `CoreError.decode` and falling
back. A hard trap defeats the whole fallback architecture. (The stated trust boundary is
the ssh tunnel, so this is robustness/DoS, not a privilege issue — hence P2, not P1.)

**Suggested fix.** Mirror the highlight fix everywhere: replace `Int(try x.u64Value())`
with `guard let v = Int(exactly: try x.u64Value()) else { throw CoreError.decode(...) }`
(throw, don't silently drop, for these structural fields), and gate `decodeFoldRegion`'s
doubles through `Int(exactly:)` after a `isFinite` check. Add a one-shot decoder test that
feeds a `2^63` / NaN frame and asserts a thrown `CoreError.decode` rather than a crash.

---

### F2 — Swift session wrappers are non-`Sendable` and mutate `dead`/`handle` unsynchronized
**Severity: P3** · `Sources/RustCore/CoreClient.swift:259-287` (`CsvSession`),
`Sources/RustCore/CanvasCore.swift:140-158` (`CanvasDocSession`) · **fix size: S** ·
**fix risk: safe**

**Evidence.** Both wrappers are `final class` holding `private var handle: OpaquePointer?`
and `private var dead: Bool`, mutated in `check()`/`liveHandle()` with **no lock and no
actor isolation**, and neither is `Sendable`. `CanvasDocAdapter` is `@MainActor`
(`CanvasDocAdapter.swift:96`) so its session is main-thread-confined and safe; but
`CSVRowWindowSource` (`Sources/ViewerCore/CSVRowWindowSource.swift:32`) is a plain
`public final class` with no isolation, and `RustCSVAdapter` constructs sessions freely.

**Impact.** The **Rust side is bulletproof** against concurrent handle use — the registry
+ `try_lock` returns `Busy` on contention, never UB, and `deinit` frees exactly once — so
the worst case is a Swift-level data race on the `dead` `Bool`/`handle` pointer if one
instance is touched from two threads. That is technically UB in the Swift memory model but
benign in practice (torn read of a pointer-or-Bool that is only ever set true→stays-true,
never freed twice). Latent, not currently exploited, but it is the kind of thing that bites
later when someone moves CSV windowing to a background queue.

**Suggested fix.** Either mark the wrappers `@unchecked Sendable` and guard `dead`/`handle`
with a small `NSLock` (matching `RemoteTransport`'s pattern), or document + enforce
single-thread/actor confinement (e.g. make `CSVRowWindowSource` `@MainActor` or hand it an
`os_unfair_lock`). Cheapest correct option: a lock around the two fields.

---

### F3 — Canvas exports skip the `len == 0 → &[]` guard, so empty input returns `NullArg`
**Severity: P3** · `ffi/src/lib.rs:1145-1151` (`mdvcore_canvas_dsl_apply`),
`:1222-1228` (`mdvcore_canvas_load`), `:1439-1445` (`render_dsl_node`),
`:1479-1485` (`render_fragment`) · **fix size: S** · **fix risk: safe**

**Evidence.** Every *other* export uses the pattern `if ptr.is_null() && len != 0 {
NullArg }` then `let s = if len == 0 { &[] } else { from_raw_parts(ptr, len) }`. These four
canvas exports instead require the pointer non-null unconditionally
(`if handle.is_null() || dsl.is_null() || out_buf.is_null()`) and then call
`from_raw_parts(dsl, dsl_len)` directly.

**Impact.** **Not UB** — the null-check makes `from_raw_parts(non_null, 0)` well-defined
(`u8` align = 1). But it is a behavior quirk: Swift passes a **nil `baseAddress` for an
empty array** (`Array("".utf8).withUnsafeBufferPointer` → nil), so an *empty* DSL fragment
(`applyDSL(baseRev, "")`) returns `MdvStatus::NullArg` and throws `.nullArg` instead of
being treated as an empty/no-op input. `canvas_load`/`render_*` with empty input are
invalid anyway, so the practical exposure is the empty-DSL no-op case. Mostly a
consistency/robustness nit — the divergence from the house pattern is the real smell.

**Suggested fix.** Adopt the standard `len == 0 → &[]` guard in these four functions so
they behave like the rest of the surface and empty input is a defined no-op, not `NullArg`.

---

### F4 — Handle-registry entries leak permanently if a Swift session's `deinit` never runs
**Severity: P3** · `ffi/src/handle.rs:69-103`, `canvas_handle.rs:29-59` ·
**fix size: M** · **fix risk: careful**

**Evidence.** Live handles live in a process-global `Mutex<HashMap<usize, Arc<…>>>`,
keyed by a **monotonic, never-reused** token (`NEXT_TOKEN`). The only thing that removes an
entry is `SessionHandle::free`, driven by the Swift wrapper's `deinit`. If a wrapper is
kept alive forever (retain cycle) or its `deinit` is skipped (process teardown aside), the
registry entry — and the whole `CsvSession`/`CanvasDoc` behind it — is retained for the
process lifetime, and the map never shrinks.

**Impact.** Ordinary memory leak, **not UB and not a double-free risk** (never-reused
tokens preclude ABA). Low likelihood in a document viewer where sessions are short-lived
and ARC-owned. Flagged for completeness because the map is unbounded and there is no
eviction/telemetry on it (unlike the doc-store family, which has TSK-589 eviction).

**Suggested fix.** Low-effort: add a debug-only registry-size gauge / assertion in tests to
catch a leak regression (there is already a `handle_lifecycle_many_open_free_no_leak_smoke`
test — extend it to assert the map returns to empty). A structural fix (weak registry) is
not warranted given ARC already drives lifetime correctly in the common path.

---

## Positive observations

- **`handle.rs` / `canvas_handle.rs` (TSK-541/581):** the registry indirection is the
  correct fix for the free-vs-call UAF, and the rationale is documented at the point of
  use. `with()` is a genuine tri-state (`Ok` / `Busy` / `HandleDead`-on-poison), so a panic
  under the lock permanently and *loudly* dead-flags the handle instead of serving
  half-mutated state. Swift mirrors this: `check()` latches `dead` on `.panic`/`.handleDead`
  and every subsequent call throws `.handleDead`.
- **Panic profile is correct where it counts.** The subtle trap here — `panic = "abort"`
  making `catch_unwind` a silent no-op — is explicitly avoided: the shipping link uses
  `[profile.dist]` `panic = "unwind"`, and `build-rust-core.sh` hard-*rejects* the
  `release` profile for the app path. This is the single most important thing to get right
  in this dimension and it is right.
- **Out-param safety is uniform:** `*out_buf = MdvBuf::empty()` / `*out_handle = null` /
  `*out_count = 0` is written immediately after the null-check, before any fallible work, so
  every early-return and every caught panic leaves a defined, safe-to-free out value. Swift
  additionally pre-initializes `var buf = MdvBuf(data: nil, len: 0, cap: 0)`, so the buffer
  is double-safe even if Rust never touched it.
- **`mdvcore_hex_render` width clamp (`MAX_HEX_WIDTH`, TSK-540)** is a genuinely
  sophisticated catch: a hostile `u32::MAX` width would drive a ~17 GiB row allocation whose
  failure is `abort()`, which `catch_unwind` *cannot* intercept — so it is clamped at the
  edge. `usize::try_from(...).unwrap_or(...)` is used consistently for all u64→usize
  narrowing (saturating, never trapping).
- **Rich error channel without ABI churn:** wire faults ride a `WireError` frame in the
  out-buf (`write_wire_error`), decoded/logged on the Swift error path
  (`logWireErrorIfPresent` + the TSK-995 `.undecodable` case that refuses to silently drop a
  non-empty error buffer). The coarse C status and the rich frame agree by construction.
- **Frame receive is single-copy** (`copyFrameBody`, TSK-826) and validates the LE length
  prefix against the actual buffer length before trusting it — no copy of a body larger than
  the declared length.
- **`RemoteTransport` is hardened** well beyond what this lens requires: `SO_NOSIGPIPE`
  (no process-killing SIGPIPE on a dead server), a 16 MiB frame cap on *both* the reader and
  hello paths (bounded allocation), a three-axis-bounded `OrphanStore` (key/byte/list caps)
  against an OOM from a misbehaving server, EINTR retry on read/write, and per-call
  deadlines so a silent server can't wedge an adapter thread.
- **Test teeth exist and are real:** `ffi/src/tests.rs` covers double-free-is-safe,
  null-tolerance, poisoned-handle→`HandleDead`, concurrent-calls-serialized-never-UB,
  free-invalidates-token-but-inflight-clone-survives, ABI/capability skew, envelope↔symbol
  byte-parity, and hostile-width clamp. The no-panic clippy restriction lints are re-declared
  on the FFI crate (it opts out of workspace inheritance, cargo #13157 — a correct and
  easily-missed detail).

---

## Coverage gaps (what I did NOT examine)

- **Runtime/dynamic verification.** Static analysis only — I did not run Miri, ASan/TSan, a
  fuzz harness against `mdvcore_call`, or the FFI test suite. TSan on the session wrappers
  (F2) and a Miri run over `handle.rs`'s registry race would be the highest-value dynamic
  follow-ups.
- **`launchd.rs` unsafe FFI** (`launch_activate_socket` fd ownership) was read but not
  exercised; its `from_raw_fd` ownership-transfer reasoning looks correct but is macOS/
  launchd-runtime-specific and untested here.
- **The `mdv-serve` server side** of the wire (Rust `serve` crate): I reviewed the Swift
  *client's* trust of server-supplied frames (F1), not the server's own encode/bounds. The
  server is where the bounded values F1 relies on are actually produced/clamped.
- **MessagePack decoder internals** (`MessagePack.swift` recursion depth, length-prefix
  trust for str/bin/array/map): I confirmed the accessor trap semantics (`u64Value`,
  `doubleValue`) but did not audit the reader's own bounds/recursion limits against a
  hostile frame — relevant to the same remote threat model as F1.
- **Canvas op/DSL wire surface** beyond the FFI signatures — the `canvas::wire` shapes and
  the apply/reject state machine are a large surface reviewed only at the boundary.
- **ViewerCore adapter concurrency** beyond the two session consumers traced
  (`CSVRowWindowSource`, `CanvasDocAdapter`); a full pass on which queues call which
  adapters would firm up F2's severity.
