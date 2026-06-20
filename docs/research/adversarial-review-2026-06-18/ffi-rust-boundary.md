# Adversarial review — FFI Rust↔Swift boundary (2026-06-18)

The boundary is unusually well-defended: every `extern "C"` body runs inside
`catch_unwind`, the opaque handle was rebuilt as an Arc-registry to close the
free-vs-call UAF (TSK-541), out-buf nulling on every error arm is disciplined,
and both sides cap frames at 16 MiB with end-of-stream strictness. The defects
below are the residue an adversary can still reach: an asymmetric frame-length
cap between the encoder (`u32`-truncated) and decoder (16 MiB), silent integer
truncation on the row-count/index decode paths that corrupts large tables, a
double-decode of the `MdvBuf` out-buffer on the snapshot-window error path, an
unbounded monotonically-growing registry leak under repeated open/free, a
`partial readExact` slicing bug that can busy-loop or mis-frame the remote
carrier, and a capability-mask/ABI-version story that lets a skewed *envelope*
method id slip past the version guard as a generic `Internal`. None are
hypothetical — each has a concrete triggering input described below.

### `MsgPackFraming.frame` truncates the length prefix to 32 bits while the body can be larger — silent frame corruption

**Severity:** high

**Location:** `Sources/RustCore/MessagePack.swift:295-303` (`MsgPackFraming.frame`); also `Sources/RustCore/RemoteTransport.swift:425` (`writeEnvelope`).

**Why:** The request framer computes the prefix as
`let n = UInt32(truncatingIfNeeded: body.count)`. If a request body is ≥ 4 GiB
(`body.count > UInt32.max`), the 4-byte LE prefix wraps and under-declares the
length. The Rust decoder (`wire::frame_body`, `crates/core/src/wire.rs:264`)
checks `declared != body.len()` — but on the FFI path Rust receives the body as
`(ptr, req_len)` where `req_len` is the *true* `usize` count, and the prefix is
re-read from the first 4 bytes of the body it was handed. The two lengths
disagree, so the inner MessagePack decode reads a truncated view and either
errors (best case) or, if the wrapped length happens to land on a valid
MessagePack value boundary, **decodes a different message than was sent** with no
fault raised. The request side has *no* `TooLarge` guard mirroring the
encode-side `encode_frame` cap — the encoder protects responses, nothing
protects requests. A 4 GiB+ `markdown_render`/`find_search`/`transcript_parse`
document (all of which frame the whole text) is the trigger; on a 64-bit Mac
that is a reachable input for a large file. The host should reject oversized
requests with a typed error, not silently wrap.

**Fix:** In `MsgPackFraming.frame` (and `writeEnvelope`), guard
`body.count <= 0xFFFF_FFFF` and throw a `CoreError.tooLarge` (make `frame`
throwing, or pre-check at each call site) instead of `truncatingIfNeeded`. Align
the request cap with `wire::MAX_FRAME_LEN` (16 MiB) for the framed methods, and
keep the aux/raw bulk channel as the only oversize path (it carries its own
explicit `usize` length and is frame-cap-exempt by design).

**REFUTED** — The "silent frame corruption / decodes a DIFFERENT message" claim
is the core of this high-severity rating, and it does not hold. The FFI path
passes the WHOLE framed buffer (`[prefix][body]`) as `req`/`req_len` (see
`mdvFrameCall`/`mdvEnvelopeCall`: `reqBytes = MsgPackFraming.frame(body)`,
`req_len = 4 + body.count`); Rust does NOT trust the prefix as the length — it
re-validates it in `wire::frame_body` (`crates/core/src/wire.rs:264`), which
checks `declared != body.len()` where `body.len() = req_len - 4` is the TRUE
large count. A wrapped 32-bit prefix vs a >4 GiB body therefore always
*disagrees* and is rejected as `WireFault::Framing` — never silently decoded.
Additionally the trigger is unreachable in-app: text loaders cap at 32 MiB
(`TextFileLoader`), the hex/binary loader at 4 MiB (`BinaryFileLoader`), and CSV
at 256 MiB scalars — none approach 4 GiB. Residual is at most "an oversize
request gets a Framing/decode error rather than a typed `tooLarge`," a low
quality nit, not high-severity silent corruption.

### Snapshot `total_rows` and every `u32Array`/`u64→Int` decode silently truncate, corrupting large tables

**Severity:** high

**Location:** `Sources/RustCore/CoreClient.swift:505` (`UInt32(truncatingIfNeeded: total_rows)`); `Sources/RustCore/MessagePack.swift:252` (`u32Array` → `UInt32(truncatingIfNeeded:)`); `CoreClient.swift:315` (`Int(clamping: count)`).

**Why:** `decodeSnapshot` reads `total_rows` as
`UInt32(truncatingIfNeeded: try map.require("total_rows").u64Value())`. The Rust
wire type `Snapshot.total_rows` is itself `u32` (`crates/core/src/wire.rs:49`),
so this particular field can't overflow today — but `u32Array()` (used for
`Snapshot.indices`, `hex_search` offsets, fuzzy `matchedIndices`, highlight
runs) does `UInt32(truncatingIfNeeded: u64Value())`, and offsets/indices into a
buffer are genuinely `usize`-sized on the Rust side. A hex search over a >4 GiB
`Data` buffer (the aux channel is explicitly frame-cap-exempt and sized to the
file) produces match offsets that exceed `u32::MAX`; `u32Array` wraps them to a
small wrong offset with **no error**, and the Swift caller (`mdvCoreHexSearch`
→ `.map(Int.init)`) then reports a match at the wrong place. Likewise
`Int(clamping: count)` in `filteredCount()` silently clamps a >`Int.max` count
rather than surfacing it. Truncation that produces a *plausible wrong number* is
worse than a thrown error because it corrupts the UI's coordinate math invisibly.

**Fix:** Use checked conversions on the decode boundary: `u64Value()` →
`Int(exactly:)` / `UInt32(exactly:)` and throw `CoreError.decode("value out of
range")` on `nil`, rather than `truncatingIfNeeded`. For genuinely large offset
spaces (hex search over multi-GiB buffers), widen the wire field to `u64` and the
Swift model to `Int`, and drop the `u32` cap on those arrays.

**REFUTED** — No reachable truncation. (1) The hex-search corruption hinges on
">4 GiB buffer" offsets exceeding `u32::MAX`, but the hex buffer is loaded by
`BinaryFileLoader` with `maxBytes = 4 MiB`, and the wire field is itself `u32`:
`hex_search_frame` already does `u32::try_from(o).unwrap_or(u32::MAX)`
(`crates/core/src/hex.rs:249-251`), so the Swift `u32Array` reads a value that is
*by construction* ≤ `u32::MAX` and never truncates further. (2) `total_rows` is a
`u32` wire field (`wire.rs:49`) — the reviewer concedes it can't overflow.
(3) `Snapshot.indices` is `Vec<u32>` on the wire (`wire.rs:44`); reading u32 into
u32 is lossless. (4) Highlight runs use `Int(a[1].u64Value())`, not `u32Array`.
(5) `filteredCount`'s `Int(clamping:)` clamps a count bounded by the u32 row
domain. Every cited site reads a field that is already u32 on the wire or is
gated by an input cap orders of magnitude below `u32::MAX`. Checked conversions
are reasonable defense-in-depth, but no present input yields a "plausible-but-
wrong number" — so this is not a confirmable defect.

### `snapshotWindow` ignores the rich-WireError out-buffer it was handed (double-standard with `callBuf`)

**Severity:** medium

**Location:** `Sources/RustCore/CoreClient.swift:293-307` (`snapshotWindow`).

**Why:** `snapshotWindow` calls the FFI, then on a non-OK status throws via
`check(status)` *without* calling `Self.logWireErrorIfPresent(buf)`. Every other
buf-returning path (`callBuf` at line 397, `CoreEnvelope.call` at line 98,
`mdvEnvelopeCall`/`mdvEnvelopeCallAux`) decodes and logs the rich WireError frame
the core writes into `out_buf` on a wire fault (TSK-577/669) before throwing the
coarse status. `snapshotWindow` is exactly the path most likely to hit
`TooLarge` (it exists *because* the full snapshot blows the 16 MiB cap), so the
one call site where the rich "frame body N exceeds max" diagnostic matters most
is the one that discards it. Not a memory-safety bug — the `defer
mdvcore_buf_free(&buf)` still frees it — but a real observability regression that
makes large-table failures undiagnosable in production triage, the precise thing
TSK-669 was built to fix.

**Fix:** Mirror `callBuf`: on `status != MDV_STATUS_OK` call
`Self.logWireErrorIfPresent(buf)` before `try check(status)`. Better, route
`snapshotWindow` through the shared `callBuf` helper (it already takes a
two-arg closure) so the diagnostic path can't be forgotten per-call again.

**CONFIRMED** — `snapshotWindow` (`CoreClient.swift:293-307`) calls
`try check(status)` with no `Self.logWireErrorIfPresent(buf)`, while every other
buf-returning path logs it (`callBuf:397`, `CoreEnvelope.call:98`,
`mdvEnvelopeCall:584`, `mdvEnvelopeCallAux:617`). The Rust export
`mdvcore_session_snapshot_window` DOES write a rich WireError into `out_buf` on
error (`crates/ffi/src/lib.rs:852`), so the diagnostic exists and is silently
dropped. Accurate, narrowly-scoped observability regression; not a memory bug
(the `defer mdvcore_buf_free` still frees the buf).

### The session registry grows monotonically and never recovers tokens — an unbounded leak under churn, plus a non-idempotent leak on a missed free

**Severity:** medium

**Location:** `rust-core/crates/ffi/src/handle.rs:77` (`NEXT_TOKEN`), `:92-103` (`into_raw`), `:135-140` (`free`).

**Why:** Two distinct leaks. (1) `NEXT_TOKEN` is a monotonic
`AtomicUsize` that is never reused ("Never reused → no ABA"). On a process that
opens and frees CSV sessions across a long session — e.g. the owner opening a
few thousand CSV files over days of uptime — the *registry HashMap* itself
recovers entries on `free`, so heap doesn't grow, but the token counter does
march toward `usize::MAX`. That is benign in practice (2^64), but it is the same
class of design that breaks at 32-bit; the `if token == 0` wrap-skip only handles
the *value* 0, not the structural assumption. (2) The real bite: every
`SessionHandle::into_raw` inserts into a *global* `Mutex<HashMap>`. If Swift's
`CsvSession` is ever leaked (a retain cycle, a crash before `deinit`, or a future
caller that opens a handle and drops the Swift wrapper on an error path), the
registry entry is **never** removed and the entire `CsvSession` (the whole parsed
CSV arena) stays alive for the life of the process — a much larger leak than the
old `Box` design, where a leaked pointer just leaked one box but a leaked
*wrapper* at least let the OS reclaim on exit. The registry turns a
wrapper-lifetime bug into a process-lifetime retention.

**Fix:** Keep the registry (it correctly solves the free-vs-call UAF) but add a
test/assert that the registry is empty at controlled teardown, and document that
`CsvSession` MUST NOT be leaked. Consider a `Weak`-backed registry or a periodic
reaper if long-running churn is real. At minimum, expose a debug-only
`registry_len()` so a leak shows up in tests rather than only as slow memory
growth in production.

**REFUTED** — No present defect; the central "strictly LARGER leak than the old
Box" reasoning is wrong. A leaked `CsvSession` wrapper retains the whole CSV
arena for process lifetime under BOTH designs — a leaked `Box` pointer was never
freed either, and the OS reclaims all process memory on exit in both cases. The
registry adds only one tiny `HashMap` entry (a `usize` key + an `Arc`) on top of
the arena that already leaks, so it does not meaningfully enlarge the leak. The
registry correctly removes the entry on `free` (called from `deinit`); a leaked
wrapper is a caller/ARC bug, not a registry bug. The token-counter (1) is
conceded benign at 64-bit. The only actionable residue is the suggestion to add
a debug `registry_len()`/teardown-empty assert (none exists) — useful hardening,
but not a confirmable defect.

### `readExact`/`writeEnvelope` slice from a growing offset on every iteration — O(n²) on partial IO and a latent correctness trap

**Severity:** medium

**Location:** `Sources/RustCore/RemoteTransport.swift:432-439` (`writeEnvelope`), `:442-454` (`readExact`).

**Why:** Both loops re-slice the whole buffer each iteration:
`frame[off...].withUnsafeBytes` / `out[off...].withUnsafeMutableBytes`. A Swift
`ArraySlice` over `[UInt8]` does not copy, so this is not an allocation bug per
se — but `read`/`write` on a UNIX socket routinely return short counts under
backpressure, and on a 16 MiB frame (the max) a pathological 1-byte-per-syscall
peer drives 16M slice-creations. More importantly, `readExact(fd, 0)` (a
zero-length body, which the wire permits — `len == 0` frames exist) enters the
`while off < n` loop zero times and returns `[]` correctly, but `read(fd,
baseAddress, 0)` is never called, so that edge is fine; the genuine latent trap
is that `readExact` treats `got > 0` as progress without bounding `got <= n -
off` — `read`/`write` cannot legally return more than requested, so it holds, but
the code has no assertion and a future refactor that passes a larger buffer
(e.g. a reusable scratch buffer) would silently let `off` overshoot `n` and the
loop exit with a half-filled or over-counted buffer, mis-framing every
subsequent read on the shared socket. Frame desync on a stream socket is
unrecoverable.

**Fix:** Use `UnsafeMutableRawBufferPointer(rebasing:)` on a fixed base pointer
with an explicit `count: n - off` rather than re-slicing the Array each time, and
add `precondition(got <= n - off)` so a contract violation fails loud instead of
desyncing the stream. The same applies to `writeEnvelope`'s
`frame[off...].withUnsafeBytes`.

**REFUTED** — Every present-tense claim is self-conceded false; only a
speculative future-refactor risk remains. The O(n²) framing is refuted by the
reviewer's own note that `ArraySlice` is non-copying (the slice's
`withUnsafeBytes` yields a pointer to its existing storage — no per-iteration
allocation/copy). The `got <= n - off` correctness trap is also conceded to
"hold today": `frame[off...]`/`out[off...]` produce a buffer of EXACTLY `n - off`
bytes, and `read`/`write` cannot legally return more than the requested
`raw.count`, so `off` can never overshoot `n`. The "future refactor passes a
larger buffer" scenario does not exist in the code — the buffer is re-sliced to
the remaining bytes each iteration, never oversized. A `precondition` is harmless
defensive hardening, but there is no current defect to confirm.

### A skewed *envelope* method id reports `Internal`, indistinguishable from a real internal fault — the version guard only covers the wire, not the method space

**Severity:** medium

**Location:** `rust-core/crates/ffi/src/lib.rs:298-302` (unknown method → `MdvStatus::Internal`); `Sources/RustCore/CoreClient.swift:54-66` (`CoreError(status:)` maps `Internal` → `.internalError`).

**Why:** The design splits "can we talk at all" (wire version, crash-fast) from
"which features exist" (capability mask, soft fallback). But the *envelope*
method dispatch has a third axis the guard doesn't cover: `mdvcore_call` with an
unknown `method` id returns `MdvStatus::Internal` (lib.rs:301), and Swift maps
`MDV_STATUS_INTERNAL` to `CoreError.internalError` — the *same* error a genuine
core bug would produce. A client built against a newer header (more
`MDV_METHOD_*` ids) talking to an older linked library (the exact remote-skew
scenario the capability mask exists to handle) cannot distinguish "this method
doesn't exist here, fall back to Swift" from "the core blew up." The header
comment claims "the host gates on capabilities/version first," but nothing in
`CoreEnvelope.call` / `mdvEnvelopeCall` actually checks the capability bit for
the method before dispatching — it just calls and maps the status. So the
graceful-degradation contract is documented but not enforced at this layer.

**Fix:** Give unknown-method its own status (`MdvStatus::UnknownMethod`, a new
reserved discriminant) so Swift can map it to a fallback signal distinct from
`.internalError`. Or, enforce the documented gate: have `mdvEnvelopeCall` consult
`CoreABI.capabilities` for the method's capability bit and throw a typed
"unsupported" before issuing the FFI call. The remote transport already does the
right thing (its `default:` arm in `callInner:150` produces a decode error with
the server's code text); the in-process envelope should be equally distinguishable.

**CONFIRMED** — Factually verified. `mdvcore_call` with an unknown method returns
`MdvStatus::Internal` (`crates/ffi/src/lib.rs:301`); `MdvStatus` has no
`UnknownMethod` variant (`status.rs`: `Internal = 99` is the catch-all), and
`CoreError(status:)` maps `MDV_STATUS_INTERNAL → .internalError`
(`CoreClient.swift:63`) — identical to a genuine core fault. `CoreEnvelope.call`
/ `mdvEnvelopeCall` / `mdvEnvelopeCallAux` issue the FFI call WITHOUT consulting
`CoreABI.capabilities` first, so the documented "host gates on capabilities first"
contract is unenforced at this layer. (Caveat lowering practical impact in-process:
`CoreABI.assertCompatible()` crash-fasts on a header/lib wire-version skew before
any dispatch, so the forward-compat case is mainly reachable on the remote skew
path — but the indistinguishability and the unenforced gate are real.)

### `as_slice` / out-buf reads trust `len` without a `len`-vs-`cap` sanity check; a corrupted `MdvBuf` reads out of bounds

**Severity:** low

**Location:** `rust-core/crates/ffi/src/buf.rs:52-64` (`free_in_place`), `:71-77` (`as_slice`); `Sources/RustCore/CoreClient.swift:101-102`, `:400-401` (out-buf copy-out).

**Why:** `free_in_place` reconstructs the `Vec` as
`Vec::from_raw_parts(buf.data, buf.len, buf.cap)`. This is correct *only* if
`len <= cap`. The fields are `pub` and the header documents `cap` as "opaque to
the C side; do not modify" — but nothing enforces it. If a Swift bug (or a future
remote-transport path that builds an `MdvBuf` by hand) ever writes `len > cap`,
`from_raw_parts` is instant UB (it constructs a `Vec` claiming a length past its
allocation, and the subsequent drop frees a region it doesn't own). Similarly the
Swift copy-out `Array(UnsafeBufferPointer(start: data, count: Int(buf.len)))`
trusts `buf.len` blindly; a library/header skew that changed `MdvBuf`'s layout
(e.g. field reordering — `cap` and `len` are both `uintptr_t`, so a swap is
type-compatible and silent) would read a wrong number of bytes. The ABI-version
guard catches a *declared* skew but not a struct-layout mismatch within the same
declared version.

**Fix:** In `free_in_place`, add `debug_assert!(buf.len <= buf.cap)` and treat
`len > cap` as a no-op-and-null (drop nothing, clear fields) in release so a
corrupt buf can't drive `from_raw_parts` UB. Pin `MemoryLayout<MdvBuf>` field
offsets in a Swift test against the documented C layout so a cbindgen/struct
reorder fails the host gate, not production.

**REFUTED** — Correct code today; the trigger is unreachable. `MdvBuf` is only
ever produced by `MdvBuf::from_vec`, where `len = v.len() <= v.capacity() = cap`
by construction, and Swift only ever READS `buf.len`/`buf.data` — it never
mutates `buf.len` (verified: all out-buf sites copy out, none write the struct's
fields). The "future remote-transport path that builds an MdvBuf by hand" does
not exist — `RemoteTransport` works in `[UInt8]`, never `MdvBuf`. So `len > cap`
is not reachable through any current path; `from_raw_parts` always sees a valid
inverse. The `debug_assert!` + a `MemoryLayout<MdvBuf>` pin test (confirmed: none
exists today) are sound defense-in-depth for a `#[repr(C)]` struct, but there is
no present defect or reachable UB to confirm.

### `decodeWireError` is non-throwing by design but swallows a malformed rich-error frame, masking the real fault class

**Severity:** low

**Location:** `Sources/RustCore/CoreClient.swift:459-477` (`decodeWireError`), called from `logWireErrorIfPresent` (`:406-413`).

**Why:** `decodeWireError` returns `nil` on any decode failure ("total and
non-throwing, since this runs on the ERROR path and must not mask the original
status"). Correct intent — but it means a *corrupted* WireError frame (the case
where the wire itself is broken, i.e. exactly when diagnosis matters most) logs
nothing at all. The status still throws, so it's not a correctness bug, but the
diagnostic black hole defeats the purpose: a `WireError` whose body is itself
mis-framed (version skew on the WireError shape, the `code:i32`/`message:str`/
`data:[(str,str)]` layout) produces a silent `nil` and the operator sees only
the bare enum — the pre-TSK-669 state this code exists to escape.

**Fix:** When `unframe`/decode of a non-empty error buf *fails*, log at debug a
"could not decode WireError frame (N bytes, first byte 0xNN)" line rather than
silently returning `nil`. It keeps the no-throw contract while preserving a
breadcrumb for the skew case.

**CONFIRMED** — Factually accurate. `decodeWireError` (`CoreClient.swift:459-477`)
returns `nil` on any `unframe`/decode failure, and `logWireErrorIfPresent`
(`:406-413`) logs nothing when it gets `nil` — so a NON-EMPTY-but-malformed
WireError frame (the version-skew case TSK-669 exists to diagnose) produces zero
breadcrumb, exactly when diagnosis matters most. Correctly scoped as an
observability gap, not a correctness bug (the coarse status still throws). Low
severity, but a real and accurate defect; the proposed breadcrumb keeps the
no-throw contract intact.
