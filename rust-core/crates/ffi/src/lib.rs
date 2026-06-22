//! `mdvcore-ffi` — the `extern "C"` boundary for the Rust-Core PoC.
//!
//! This is the ONLY crate that contains `unsafe` and exports symbols. It wraps
//! the pure `mdvcore-core` logic in a C ABI that Swift (and any C consumer) calls.
//!
//! ## The contract, in one place
//!
//! - **Errors**: every fallible fn returns a [`MdvStatus`] (a `#[repr(C)]`
//!   integer enum). Payloads ride in OUT-PARAMS, never mixed with the status.
//!   Rich error detail (message + context) rides in the MessagePack wire body,
//!   not the C signature. Swift maps the status to a `throws`.
//!
//! - **Panic safety**: every `extern "C"` fn body runs inside
//!   [`std::panic::catch_unwind`] via the [`ffi_guard!`] macro. A caught panic
//!   becomes [`MdvStatus::Panic`] and the process keeps running.
//!   ⚠️ NOTE the build profile: the size-opt `release` profile sets
//!   `panic = "abort"`, under which `catch_unwind` is a no-op (the panic
//!   already aborted). The guard is still correct and load-bearing for the
//!   `dev`/`test` profile (default `panic = "unwind"`), and the SHIPPING macOS
//!   dylib for a GUI host would use `panic = "unwind"` so the guard keeps the
//!   app alive. This is the belt-and-suspenders split the PoC spec asked for.
//!
//! - **Opaque handles**: a [`SessionHandle`] crosses by pointer
//!   (`Box::into_raw`) and is freed exactly once via [`mdvcore_session_free`]
//!   (`Box::from_raw`). Allocate-and-free on the same side: Swift must call
//!   `mdvcore_session_free`, never libc `free`. Ordinary calls BORROW the handle;
//!   they never round-trip ownership.
//!
//! - **Threading**: the handle wraps the session in a `Mutex` and is declared
//!   `Send + Sync` so it is *sound* to touch from multiple threads — but the
//!   model is **single-writer**: the Mutex serializes concurrent calls, and a
//!   contended `try_lock` returns [`MdvStatus::Busy`] rather than blocking, so
//!   a misbehaving multi-threaded caller is *rejected*, not silently
//!   serialized into a deadlock risk. See [`handle`].
//!
//! - **Wire**: structured results (`Table`, `Snapshot`) leave as MessagePack
//!   in a length-prefixed frame via an out byte-buffer ([`MdvBuf`]), freed by
//!   [`mdvcore_buf_free`].

// This crate intentionally opts out of #![forbid(unsafe_code)] (it IS the
// unsafe edge). Lints are defined in Cargo.toml [lints.*] + below.
#![deny(unsafe_op_in_unsafe_fn)]
#![allow(
    clippy::missing_safety_doc,
    reason = "safety contracts are documented per-fn in prose above each extern fn"
)]

pub mod buf;
pub mod guard;
pub mod handle;
pub mod status;

use mdvcore_core::diff;
use mdvcore_core::dispatch;
use mdvcore_core::filter::{Query, Scope};
use mdvcore_core::hex;
use mdvcore_core::indent;
use mdvcore_core::session::{CsvSession, OpenError};
use mdvcore_core::wire;
use mdvcore_highlight::folds;
use mdvcore_highlight::runs as highlight_runs;

pub use buf::MdvBuf;
pub use handle::SessionHandle;
pub use status::MdvStatus;

/// Map a wire-layer fault to its C status (audit TSK-548 stopgap): an
/// encode-side `TooLarge` keeps its identity so the host can react (window the
/// request, fall back) instead of diagnosing a codec bug; every other fault
/// stays the generic [`MdvStatus::WireError`].
#[doc(hidden)] // pub only so `ffi_frame_body!` can name it via $crate::
pub fn wire_status(fault: &wire::WireFault) -> MdvStatus {
    match fault {
        wire::WireFault::TooLarge(_) => MdvStatus::TooLarge,
        wire::WireFault::Encode(_) | wire::WireFault::Decode(_) | wire::WireFault::Framing(_) => {
            MdvStatus::WireError
        }
    }
}

/// A short stable "kind" tag for a wire fault, carried in `WireError.data` so
/// the host can branch/telemetry on the failure class without string-matching
/// the message.
fn wire_fault_kind(fault: &wire::WireFault) -> &'static str {
    match fault {
        wire::WireFault::Encode(_) => "encode",
        wire::WireFault::Decode(_) => "decode",
        wire::WireFault::Framing(_) => "framing",
        wire::WireFault::TooLarge(_) => "too_large",
    }
}

/// Emit the documented rich-error channel (TSK-577): on a wire fault, encode a
/// `WireError {code, message, data}` frame into `out_buf` so the host can
/// decode real diagnostic context (the message + a `kind` tag) instead of only
/// the coarse status enum. Returns the same [`wire_status`] the caller would
/// have returned, so it is a drop-in for `Err(e) => wire_status(&e)`.
///
/// Backward-compatible: hosts that (today) throw on a non-OK status without
/// reading `out_buf` see no change; the frame is there for those that opt in.
/// On the (essentially impossible) encode failure for this tiny struct,
/// `out_buf` keeps its empty default and the status alone is still correct.
///
/// # Safety
/// `out_buf` must be non-null, valid & writable — every caller validates it and
/// writes the `MdvBuf::empty()` default before reaching an error arm.
#[doc(hidden)] // pub only so `ffi_frame_body!` can name it via $crate::
pub unsafe fn write_wire_error(out_buf: *mut MdvBuf, fault: &wire::WireFault) -> MdvStatus {
    let status = wire_status(fault);
    let err = wire::WireError {
        code: status as i32,
        message: fault.to_string(),
        data: vec![("kind".to_string(), wire_fault_kind(fault).to_string())],
    };
    if let Ok(frame) = wire::encode_frame(&err) {
        // SAFETY: caller guarantees out_buf is valid & writable; from_vec moves
        // ownership of the frame bytes into the buf for the host to free.
        unsafe { *out_buf = MdvBuf::from_vec(frame) };
    }
    status
}

// ---------------------------------------------------------------------------
// Stage 0 smoke: a trivial extern fn proving the codegen/cbindgen/link path.
// ---------------------------------------------------------------------------

/// Stage 0 smoke test: add two integers. Wrapped in the panic guard for
/// uniformity even though it cannot panic.
#[unsafe(no_mangle)]
pub extern "C" fn mdvcore_add(a: i32, b: i32) -> i32 {
    ffi_guard_value!(0i32, { a.wrapping_add(b) })
}

// ---------------------------------------------------------------------------
// ABI version (TSK-579) — the runtime backstop for header↔staticlib skew.
// The VM links a prebuilt libmdvcore_ffi.a against rsync'd Swift sources, so
// the compiled-in header constant and the linked library can silently
// diverge. Swift asserts at bridge init that the LINKED library reports the
// same version the header it compiled against declares.
// ---------------------------------------------------------------------------

/// The wire/ABI contract version. Bump on ANY breaking change to the
/// extern "C" surface or the MessagePack frame layout. cbindgen emits this
/// into the header, so Swift compiles against the value; the function below
/// reports what the linked library was built with. Equal ⇒ no skew.
///
/// v2 (TSK-563): diff per-element records (files/hunks/lines, gutter marks)
/// went positional (MessagePack arrays) — named-map element decoding of
/// those frames mis-decodes, so skew must crash-fast.
pub const MDV_WIRE_VERSION: u32 = 2;

/// Runtime ABI version of the LINKED library. Returns 0 (never a valid
/// version) if the guard trips — callers must treat 0 as incompatible.
#[unsafe(no_mangle)]
pub extern "C" fn mdvcore_abi_version() -> u32 {
    ffi_guard_value!(0u32, { MDV_WIRE_VERSION })
}

// ---------------------------------------------------------------------------
// Capability bitmap (TSK-634) — feature negotiation ABOVE the frozen wire.
//
// The wire version above answers "can we talk at all"; the capability mask
// answers "which feature families does the linked core actually have". This
// lets new exports ship WITHOUT a wire-version bump, and lets a client built
// against a newer header degrade gracefully against an older library — the
// skew a remote `mdv-serve` deployment makes routine (owner constraint
// 2026-06-11: client and server WILL version independently).
//
// RULES: bits are ABI — assigned once, never renumbered, never reused.
// Reserved bits for the approved-but-unported engines are pre-assigned so
// both sides can compile gating code before the port lands.
// ---------------------------------------------------------------------------

/// CSV session family (`mdvcore_session_*`).
pub const MDV_CAP_CSV_SESSION: u64 = 1 << 0;
/// Structured diff + hunk gutter marks (`mdvcore_diff_*`).
pub const MDV_CAP_DIFF: u64 = 1 << 1;
/// HEX render + search (`mdvcore_hex_*`).
pub const MDV_CAP_HEX: u64 = 1 << 2;
/// Indent detection (`mdvcore_indent_*`).
pub const MDV_CAP_INDENT: u64 = 1 << 3;
/// Editor document apply (envelope `MDV_METHOD_CM_APPLY`).
pub const MDV_CAP_CM_APPLY: u64 = 1 << 4;
/// Whole-document find (envelope `MDV_METHOD_FIND_SEARCH`) — TSK-630.
pub const MDV_CAP_FIND: u64 = 1 << 5;
/// Markdown→HTML structural render (envelope `MDV_METHOD_MARKDOWN_RENDER`) — TSK-631.
pub const MDV_CAP_MARKDOWN: u64 = 1 << 6;
/// Claude transcript/JSONL parse (envelope `MDV_METHOD_TRANSCRIPT_PARSE`) — TSK-632.
pub const MDV_CAP_TRANSCRIPT: u64 = 1 << 7;
/// Fuzzy ranking (envelope `MDV_METHOD_FUZZY_RANK`) — TSK-633.
pub const MDV_CAP_FUZZY: u64 = 1 << 8;
/// SERVER-ONLY (TSK-657): the mdv-serve git family (head/status/branches/log).
/// Same posture as the fs bit: never set by the in-process library.
pub const MDV_CAP_GIT: u64 = 1 << 10;
/// SERVER-ONLY (TSK-658): mdv-serve transcript discovery (`transcript.list`).
pub const MDV_CAP_TRANSCRIPT_LIST: u64 = 1 << 11;
/// RESERVED (protocol §4): the LSP pipe family (TSK-659).
pub const MDV_CAP_LSP_PIPE: u64 = 1 << 12;
/// SERVER-ONLY (TSK-656): mdv-serve cross-file search (`search.files`).
pub const MDV_CAP_SEARCH: u64 = 1 << 13;
/// SERVER-ONLY (TSK-654): the mdv-serve fs family (stat/read/readdir).
/// NEVER set by the in-process library — there is no fs FFI export by
/// design (the host does its own IO locally); mdv-serve ORs this into its
/// hello mask when a served root is configured.
pub const MDV_CAP_FS: u64 = 1 << 9;
/// Tree-sitter highlight runs (`mdvcore_highlight_runs`) — TSK-660. (The
/// ticket pre-assigned 1<<9, but the fs family took it first; bits are
/// append-only, so highlight gets the next free bit.)
pub const MDV_CAP_HIGHLIGHT: u64 = 1 << 14;

/// The capability mask THIS build was compiled with. Reserved bits stay OFF
/// until their engine's exports actually exist — turning a bit on is part of
/// landing the feature, pinned by tests on both sides.
pub const MDV_CAPABILITIES: u64 = MDV_CAP_CSV_SESSION
    | MDV_CAP_DIFF
    | MDV_CAP_HEX
    | MDV_CAP_INDENT
    | MDV_CAP_CM_APPLY
    | MDV_CAP_FUZZY
    | MDV_CAP_FIND
    | MDV_CAP_TRANSCRIPT
    | MDV_CAP_MARKDOWN
    | MDV_CAP_HIGHLIGHT;

/// Runtime capability mask of the LINKED library. Returns 0 (no capabilities
/// — every gated feature disabled, never UB) if the guard trips. Callers must
/// IGNORE bits they don't know (a newer library may set them) and gate each
/// feature on its own bit, never on equality of the whole mask.
#[unsafe(no_mangle)]
pub extern "C" fn mdvcore_capabilities() -> u64 {
    ffi_guard_value!(0u64, { MDV_CAPABILITIES })
}

// ---------------------------------------------------------------------------
// Thin-waist envelope (TSK-580). ONE versioned dispatch entry routing a u16
// method id + request frame (+ a reserved aux side-channel for bulk payloads)
// to the right stateless core method, via the safe-Rust `dispatch::call`
// (host-tested + reusable by TUI/web/WASM). The per-method extern symbols
// coexist during migration; new methods land HERE, not as new per-feature
// symbols.
// ---------------------------------------------------------------------------

// Method ids for `mdvcore_call`, the C/Swift-visible mirror of
// `dispatch::Method` (TSK-580 slice 2). cbindgen emits these as
// `#define MDV_METHOD_*`, so Swift shares them via CMdvCore — no hand-synced
// Swift table. `method_id_consts_match_the_dispatch_enum` pins each to its enum
// discriminant so the two can never drift. ABI: assign-once, never renumber.
pub const MDV_METHOD_CM_APPLY: u16 = 1;
pub const MDV_METHOD_DIFF_PARSE: u16 = 2;
pub const MDV_METHOD_DIFF_HUNK_MARKS: u16 = 3;
pub const MDV_METHOD_FUZZY_RANK: u16 = 4;
pub const MDV_METHOD_FIND_SEARCH: u16 = 5;
pub const MDV_METHOD_MARKDOWN_RENDER: u16 = 6;
pub const MDV_METHOD_TRANSCRIPT_PARSE: u16 = 7;
pub const MDV_METHOD_TRANSCRIPT_PARSE_FORCED_REDACTION: u16 = 8;
pub const MDV_METHOD_HIGHLIGHT_RUNS: u16 = 9;
pub const MDV_METHOD_HEX_SEARCH: u16 = 10;
/// Raw-output methods (TSK-580 slice 3): `mdvcore_call` writes the dispatch
/// result bytes to `out_buf` verbatim — for these two that's RAW bytes (a tiny
/// result string / a ~18 MB dump), not a MessagePack frame. The bulk input
/// rides `aux`; the small scalars ride `req`. Byte-identical to the dedicated
/// `mdvcore_indent_detect` / `mdvcore_hex_render` symbols (coexistence window).
pub const MDV_METHOD_INDENT_DETECT: u16 = 11;
pub const MDV_METHOD_HEX_RENDER: u16 = 12;
/// Formula evaluation (envelope `MDV_METHOD_FORMULA_EVALUATE`) — TSK-1213.
pub const MDV_METHOD_FORMULA_EVALUATE: u16 = 13;
/// Formula whole-grid recalc (envelope `MDV_METHOD_FORMULA_RECALC`) — TSK-1213.
pub const MDV_METHOD_FORMULA_RECALC: u16 = 14;
/// Code-fold regions (envelope `MDV_METHOD_FOLD_REGIONS`) — TSK-1202. Impl lives
/// in mdvcore-highlight; routed at the FFI layer like HIGHLIGHT_RUNS.
pub const MDV_METHOD_FOLD_REGIONS: u16 = 15;

/// Envelope dispatch. `method` is a `dispatch::Method` discriminant; `req` is the
/// request frame; `aux` is the bulk side-channel — the `req`-only methods ignore
/// it, `MDV_METHOD_HEX_SEARCH` consumes it as the (frame-cap-exempt) buffer to
/// search. The response frame (or a rich WireError frame on a wire fault,
/// TSK-577) is written to `out_buf`; caller MUST `mdvcore_buf_free` it.
///
/// Returns [`MdvStatus::Ok`], [`MdvStatus::NullArg`] (null out_buf, or a
/// null/len mismatch on req/aux), [`MdvStatus::UnknownMethod`] (unknown method
/// id — a forward-compat caller on a newer ABI; the host gates on capabilities
/// / falls back, distinct from a genuine fault), a wire status, or
/// [`MdvStatus::Panic`].
///
/// # Safety
/// `out_buf` valid & writable; `req`/`aux` each point to their `len` bytes (or
/// are null with `len == 0`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdvcore_call(
    method: u16,
    req: *const u8,
    req_len: usize,
    aux: *const u8,
    aux_len: usize,
    out_buf: *mut MdvBuf,
) -> MdvStatus {
    ffi_guard!({
        if out_buf.is_null() {
            return MdvStatus::NullArg;
        }
        // SAFETY: out_buf validated; empty default so error paths stay safe-to-free.
        unsafe { *out_buf = MdvBuf::empty() };

        if (req.is_null() && req_len != 0) || (aux.is_null() && aux_len != 0) {
            return MdvStatus::NullArg;
        }
        let Some(m) = dispatch::Method::from_u16(method) else {
            // Unknown method id: a caller on a newer ABI than this build — a
            // method-space SKEW, not a genuine fault (TSK-982). Return the
            // dedicated `UnknownMethod` so the host can DISTINGUISH this from
            // `Internal` (a real core fault that reads as a crash) and react —
            // gate on capabilities / fall back / surface an upgrade hint —
            // instead of diagnosing a phantom crash. The in-process wire
            // `assertCompatible()` crash-fast normally precludes reaching here;
            // it is the remote-skew path that this distinction serves.
            return MdvStatus::UnknownMethod;
        };
        let req_bytes: &[u8] = if req_len == 0 {
            &[]
        } else {
            // SAFETY: caller guarantees req/req_len describe valid bytes (len != 0).
            unsafe { core::slice::from_raw_parts(req, req_len) }
        };
        let aux_bytes: &[u8] = if aux_len == 0 {
            &[]
        } else {
            // SAFETY: caller guarantees aux/aux_len describe valid bytes (len != 0).
            unsafe { core::slice::from_raw_parts(aux, aux_len) }
        };
        // HighlightRuns lives in the mdvcore-highlight crate (core can't route
        // it); intercept it here. Everything else dispatches in safe-Rust core.
        let result = match m {
            dispatch::Method::HighlightRuns => highlight_runs::runs_wire(req_bytes),
            dispatch::Method::FoldRegions => folds::fold_regions_wire(req_bytes),
            other => dispatch::call(other, req_bytes, aux_bytes),
        };
        match result {
            Ok(frame) => {
                // SAFETY: out_buf validated non-null above.
                unsafe { *out_buf = MdvBuf::from_vec(frame) };
                MdvStatus::Ok
            }
            // SAFETY: out_buf validated non-null + empty-defaulted above.
            Err(e) => unsafe { write_wire_error(out_buf, &e) },
        }
    })
}

// ---------------------------------------------------------------------------
// A deliberate panic path, used by tests to prove catch_unwind converts a
// panic into MdvStatus::Panic and does NOT abort (under panic=unwind builds).
// ---------------------------------------------------------------------------

/// Test hook: forces a panic inside the guard. Returns [`MdvStatus::Panic`]
/// (under `panic=unwind`) instead of crashing. Exposed (not test-gated) so the
/// cross-language Swift harness can exercise the panic→error mapping too.
#[unsafe(no_mangle)]
pub extern "C" fn mdvcore_force_panic() -> MdvStatus {
    ffi_guard!({
        // The panic IS the test surface: this hook exists solely to force a
        // panic inside `ffi_guard!` so `catch_unwind`'s panic→MdvStatus::Panic
        // mapping can be proven (from Rust and the Swift harness). Allowed
        // explicitly — the no-panic deny lint can't tell this apart from a real
        // one.
        #[allow(clippy::panic)]
        {
            panic!("forced panic for FFI boundary test");
        }
    })
}

// ---------------------------------------------------------------------------
// Stateless slice (Type-1): bytes IN (a request frame) → bytes OUT (a response
// frame). No handle, no session lifetime. The CMEditApplier slice (#2) is the
// first; future pure transforms (diff, hex, fuzzy) follow this exact shape.
// ---------------------------------------------------------------------------

/// Parse a unified diff (stateless). `req`/`req_len` is a length-prefixed
/// MessagePack request frame `{text}`; the result is written to `out_buf` as a
/// `{files:[…]}` response frame (the full structured diff: per-file metadata +
/// hunks + per-line kind/line-numbers). Caller MUST call [`mdvcore_buf_free`]
/// on `out_buf`.
///
/// # Returns
/// [`MdvStatus::Ok`], [`MdvStatus::NullArg`], [`MdvStatus::WireError`] (malformed
/// request frame / encode failure), or [`MdvStatus::Panic`].
///
/// # Safety
/// `req` must point to `req_len` valid bytes (or be null with `req_len == 0`).
/// `out_buf` must be a valid, writable pointer.
// TSK-1015: legacy direct symbol — production routes diff parsing through the
// envelope (`mdvcore_call` → `diff::parse_wire`). Retained test-only as the
// envelope-parity oracle (`ffi/tests.rs`), kept OFF the production ABI surface.
#[cfg(test)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdvcore_diff_parse(
    req: *const u8,
    req_len: usize,
    out_buf: *mut MdvBuf,
) -> MdvStatus {
    ffi_frame_body!(req, req_len, out_buf, diff::parse_wire)
}

/// Flatten a unified diff to per-line gutter marks (stateless). `req`/`req_len`
/// is a `{text}` MessagePack request frame; the result is written to `out_buf`
/// as a `{marks:[{line,mark}]}` response frame (`mark` ∈ added/modified/deleted,
/// `line` is the 1-based working-tree line). Caller MUST call [`mdvcore_buf_free`].
///
/// # Returns
/// [`MdvStatus::Ok`], [`MdvStatus::NullArg`], [`MdvStatus::WireError`], or
/// [`MdvStatus::Panic`].
///
/// # Safety
/// `req` must point to `req_len` valid bytes (or be null with `req_len == 0`).
/// `out_buf` must be a valid, writable pointer.
// TSK-1015: legacy direct symbol — production routes through the envelope
// (`mdvcore_call` → `diff::hunk_marks_wire`). Retained test-only as the
// envelope-parity oracle (`ffi/tests.rs`), kept OFF the production ABI surface.
#[cfg(test)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdvcore_diff_hunk_marks(
    req: *const u8,
    req_len: usize,
    out_buf: *mut MdvBuf,
) -> MdvStatus {
    ffi_frame_body!(req, req_len, out_buf, diff::hunk_marks_wire)
}

/// Tree-sitter highlight runs (stateless, TSK-660). `req`/`req_len` is a
/// `{text, lang}` MessagePack request frame (`lang` = the host's
/// `HighlightLanguage` rawValue); the result is written to `out_buf` as a
/// `{supported, runs:[{start, len, kind}]}` response frame — `start`/`len`
/// are UTF-16 code-unit offsets (NSRange's model), `kind` is the host
/// `TokenKind` rawValue, and `supported == false` means this build has no
/// grammar for `lang` (caller falls back; distinct from a real empty
/// result). Caller MUST call [`mdvcore_buf_free`] on `out_buf`.
///
/// # Returns
/// [`MdvStatus::Ok`], [`MdvStatus::NullArg`], [`MdvStatus::WireError`], or
/// [`MdvStatus::Panic`].
///
/// # Safety
/// `req` must point to `req_len` valid bytes (or be null with `req_len == 0`).
/// `out_buf` must be a valid, writable pointer.
// TSK-1015: legacy direct symbol — production routes through the envelope
// (`mdvcore_call` → `highlight_runs::runs_wire`). Retained test-only as the
// envelope-parity oracle (`ffi/tests.rs`), kept OFF the production ABI surface.
#[cfg(test)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdvcore_highlight_runs(
    req: *const u8,
    req_len: usize,
    out_buf: *mut MdvBuf,
) -> MdvStatus {
    ffi_frame_body!(req, req_len, out_buf, highlight_runs::runs_wire)
}

/// Render a HEX dump (stateless). `bytes`/`len` is the raw byte buffer to dump;
/// the rendered dump is written to `out_buf` as **raw UTF-8** (NOT a MessagePack
/// frame — a 4 MB file renders to ~18 MB of text, so wrapping it in a frame just
/// to immediately re-decode it on the Swift side would double the cost for no
/// benefit; the result is one opaque string). Caller MUST call
/// [`mdvcore_buf_free`] on `out_buf`.
///
/// `width` is bytes-per-row, clamped to [`MAX_HEX_WIDTH`]; `total_byte_count` /
/// `is_truncated` drive the "Showing first N of M bytes" header.
///
/// # Returns
/// [`MdvStatus::Ok`], [`MdvStatus::NullArg`], or [`MdvStatus::Panic`].
///
/// # Safety
/// `bytes` must point to `len` valid bytes (or be null with `len == 0`).
/// `out_buf` must be a valid, writable pointer.
/// Upper bound on `mdvcore_hex_render`'s bytes-per-row. Out-of-range widths
/// clamp rather than error so the render stays total for any input.
pub const MAX_HEX_WIDTH: u32 = 512;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdvcore_hex_render(
    bytes: *const u8,
    len: usize,
    width: u32,
    total_byte_count: u64,
    is_truncated: bool,
    out_buf: *mut MdvBuf,
) -> MdvStatus {
    ffi_guard!({
        if out_buf.is_null() {
            return MdvStatus::NullArg;
        }
        // SAFETY: out_buf validated; empty default so error paths stay safe-to-free.
        unsafe { *out_buf = MdvBuf::empty() };

        if bytes.is_null() && len != 0 {
            return MdvStatus::NullArg;
        }
        let slice: &[u8] = if len == 0 {
            &[]
        } else {
            // SAFETY: caller guarantees bytes/len describe valid bytes (len != 0).
            unsafe { core::slice::from_raw_parts(bytes, len) }
        };
        // Clamp width at the edge (audit TSK-540): the row buffer is
        // width-proportional, so a hostile/buggy u32 (u32::MAX → ~17 GiB for
        // ONE row) drives an allocation whose failure calls handle_alloc_error
        // → abort(), which ffi_guard!'s catch_unwind cannot intercept. 512
        // bytes-per-row is far beyond any real UI (Swift uses 16). width == 0
        // stays 0 → empty dump, per the render_all contract.
        let width = usize::try_from(width.min(MAX_HEX_WIDTH)).unwrap_or(0);
        let total = usize::try_from(total_byte_count).unwrap_or(usize::MAX);
        let dump = hex::render_all(slice, width, total, is_truncated);
        // SAFETY: out_buf validated non-null above.
        unsafe { *out_buf = MdvBuf::from_vec(dump.into_bytes()) };
        MdvStatus::Ok
    })
}

/// Search a byte buffer for a query (stateless). `data`/`data_len` is the buffer
/// to search; `query`/`query_len` is the UTF-8 query string; `mode` is `0` for
/// hex-byte-pair parsing or `1` for raw ASCII/UTF-8 bytes. Match offsets are
/// written to `out_buf` as a `{offsets:[u32]}` MessagePack frame (non-overlapping,
/// Sublime/VSCode convention). An invalid/empty query yields an empty offset
/// list, not an error. Caller MUST call [`mdvcore_buf_free`] on `out_buf`.
///
/// # Returns
/// [`MdvStatus::Ok`], [`MdvStatus::NullArg`], [`MdvStatus::BadUtf8`] (query not
/// UTF-8), [`MdvStatus::WireError`] (encode failure), or [`MdvStatus::Panic`].
///
/// # Safety
/// `data`/`query` must point to their respective `*_len` valid bytes (or be null
/// with a zero length). `out_buf` must be a valid, writable pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdvcore_hex_search(
    data: *const u8,
    data_len: usize,
    query: *const u8,
    query_len: usize,
    mode: u32,
    out_buf: *mut MdvBuf,
) -> MdvStatus {
    ffi_guard!({
        if out_buf.is_null() {
            return MdvStatus::NullArg;
        }
        // SAFETY: out_buf validated; empty default so error paths stay safe-to-free.
        unsafe { *out_buf = MdvBuf::empty() };

        if (data.is_null() && data_len != 0) || (query.is_null() && query_len != 0) {
            return MdvStatus::NullArg;
        }
        let data_slice: &[u8] = if data_len == 0 {
            &[]
        } else {
            // SAFETY: caller guarantees data/data_len describe valid bytes.
            unsafe { core::slice::from_raw_parts(data, data_len) }
        };
        let query_slice: &[u8] = if query_len == 0 {
            &[]
        } else {
            // SAFETY: caller guarantees query/query_len describe valid bytes.
            unsafe { core::slice::from_raw_parts(query, query_len) }
        };
        let Ok(query_str) = core::str::from_utf8(query_slice) else {
            return MdvStatus::BadUtf8;
        };
        let kind = if mode == 1 {
            hex::HexSearchMode::Ascii
        } else {
            hex::HexSearchMode::Hex
        };
        match hex::hex_search_frame(data_slice, query_str, kind) {
            Ok(frame) => {
                // SAFETY: out_buf validated non-null above.
                unsafe { *out_buf = MdvBuf::from_vec(frame) };
                MdvStatus::Ok
            }
            Err(e) => {
                // SAFETY: out_buf validated non-null + empty-defaulted above.
                unsafe { write_wire_error(out_buf, &e) }
            }
        }
    })
}

/// Detect indentation style (stateless). `text`/`text_len` is the UTF-8 source;
/// `sample_lines` bounds how many indented lines are sampled. The result string
/// (`"Tabs"`, `"Spaces (N)"`, `"Mixed"`, `"—"`, …) is written to `out_buf` as
/// **raw UTF-8** (it's tiny — no framing). Caller MUST call [`mdvcore_buf_free`].
///
/// # Returns
/// [`MdvStatus::Ok`], [`MdvStatus::NullArg`], [`MdvStatus::BadUtf8`] (text not
/// UTF-8), or [`MdvStatus::Panic`].
///
/// # Safety
/// `text` must point to `text_len` valid bytes (or be null with `text_len == 0`).
/// `out_buf` must be a valid, writable pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdvcore_indent_detect(
    text: *const u8,
    text_len: usize,
    sample_lines: u32,
    out_buf: *mut MdvBuf,
) -> MdvStatus {
    ffi_guard!({
        if out_buf.is_null() {
            return MdvStatus::NullArg;
        }
        // SAFETY: out_buf validated; empty default so error paths stay safe-to-free.
        unsafe { *out_buf = MdvBuf::empty() };

        if text.is_null() && text_len != 0 {
            return MdvStatus::NullArg;
        }
        let slice: &[u8] = if text_len == 0 {
            &[]
        } else {
            // SAFETY: caller guarantees text/text_len describe valid bytes.
            unsafe { core::slice::from_raw_parts(text, text_len) }
        };
        let Ok(text_str) = core::str::from_utf8(slice) else {
            return MdvStatus::BadUtf8;
        };
        let sample = usize::try_from(sample_lines).unwrap_or(usize::MAX);
        let result = indent::detect(text_str, sample);
        // SAFETY: out_buf validated non-null above.
        unsafe { *out_buf = MdvBuf::from_vec(result.into_bytes()) };
        MdvStatus::Ok
    })
}

// ---------------------------------------------------------------------------
// Stage 1/2 feature surface: open → parse → setFilter → snapshot → free.
//
// Bytes cross IN by pointer+len (never owned by Rust beyond the call); handles
// and structured results cross OUT by opaque pointer / framed byte buffer.
// ---------------------------------------------------------------------------

/// Open a CSV session from raw bytes. The bytes are COPIED into the session;
/// the caller retains ownership of its buffer and may free it immediately
/// after this returns.
///
/// # Parameters
/// - `bytes`: pointer to the CSV bytes (may be null only if `len == 0`).
/// - `len`: number of bytes.
/// - `out_handle`: receives the new session handle on success; set to null on
///   error. Caller MUST eventually call [`mdvcore_session_free`].
///
/// # Returns
/// [`MdvStatus::Ok`], [`MdvStatus::NullArg`], [`MdvStatus::BadUtf8`], or
/// [`MdvStatus::Panic`].
///
/// # Safety
/// `bytes` must point to `len` valid, initialized bytes (or be null with
/// `len == 0`). `out_handle` must be a valid, writable pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdvcore_session_open(
    bytes: *const u8,
    len: usize,
    out_handle: *mut *mut SessionHandle,
) -> MdvStatus {
    ffi_guard!({
        if out_handle.is_null() {
            return MdvStatus::NullArg;
        }
        // SAFETY: caller contract — out_handle is valid & writable; we null it
        // up front so an early-return error never leaves a dangling out value.
        unsafe { *out_handle = core::ptr::null_mut() };

        if bytes.is_null() && len != 0 {
            return MdvStatus::NullArg;
        }
        let slice: &[u8] = if len == 0 {
            &[]
        } else {
            // SAFETY: caller guarantees `bytes` points to `len` initialized
            // bytes when len != 0; the len == 0 branch never dereferences.
            unsafe { core::slice::from_raw_parts(bytes, len) }
        };

        match CsvSession::open(slice) {
            Ok(session) => {
                let handle = SessionHandle::new(session);
                let raw = handle.into_raw();
                // SAFETY: out_handle validated non-null above.
                unsafe { *out_handle = raw };
                MdvStatus::Ok
            }
            // Exhaustive on purpose (audit TSK-578): a future OpenError
            // variant must force a decision here at compile time instead of
            // silently mis-reporting as BadUtf8.
            Err(OpenError::BadUtf8 { .. }) => MdvStatus::BadUtf8,
        }
    })
}

/// Encode the session's parsed table (Stage 1 result) into a length-prefixed
/// MessagePack frame, returned via `out_buf`. The frame is `u32` LE length +
/// `to_vec_named` MessagePack body. Caller MUST call [`mdvcore_buf_free`].
///
/// # Safety
/// `handle` must be a valid pointer returned by [`mdvcore_session_open`] and not
/// yet freed. `out_buf` must be valid & writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdvcore_session_table(
    handle: *mut SessionHandle,
    out_buf: *mut MdvBuf,
) -> MdvStatus {
    ffi_guard!({
        if out_buf.is_null() {
            return MdvStatus::NullArg;
        }
        // SAFETY: out_buf validated; write an empty buf so error paths leave a
        // safe-to-free value.
        unsafe { *out_buf = MdvBuf::empty() };

        // TSK-541: registry lookup — total over any token (absent → None),
        // and the Arc clone keeps the handle alive past a concurrent free.
        let Some(h) = SessionHandle::lookup(handle) else {
            return MdvStatus::NullArg;
        };
        h.with(|session| {
            // TSK-546: encode straight from the arena's spans — byte-identical
            // to encoding the owned Table, without materializing it.
            match session.table_frame() {
                Ok(frame) => {
                    // SAFETY: out_buf validated non-null above.
                    unsafe { *out_buf = MdvBuf::from_vec(frame) };
                    MdvStatus::Ok
                }
                Err(e) => {
                    // SAFETY: out_buf validated non-null + empty-defaulted above.
                    unsafe { write_wire_error(out_buf, &e) }
                }
            }
        })
        .unwrap_or_else(|contended_or_dead| contended_or_dead)
    })
}

/// Set the active filter on the session. `query` is a UTF-8 string of `qlen`
/// bytes. `scope` selects the search scope: `< 0` → all columns; `>= 0` → that
/// column index.
///
/// # Safety
/// `handle` valid & live; `query` points to `qlen` valid bytes (or null with
/// `qlen == 0`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdvcore_session_set_filter(
    handle: *mut SessionHandle,
    query: *const u8,
    qlen: usize,
    scope: i64,
) -> MdvStatus {
    ffi_guard!({
        if query.is_null() && qlen != 0 {
            return MdvStatus::NullArg;
        }
        // TSK-541: registry lookup — total over any token (absent → None),
        // and the Arc clone keeps the handle alive past a concurrent free.
        let Some(h) = SessionHandle::lookup(handle) else {
            return MdvStatus::NullArg;
        };
        let qbytes: &[u8] = if qlen == 0 {
            &[]
        } else {
            // SAFETY: caller guarantees query/qlen describe valid bytes when
            // qlen != 0; the qlen == 0 branch never dereferences.
            unsafe { core::slice::from_raw_parts(query, qlen) }
        };
        let Ok(text) = core::str::from_utf8(qbytes) else {
            return MdvStatus::BadUtf8;
        };
        let scope = if scope < 0 {
            Scope::All
        } else {
            // i64 -> usize: non-negative branch; clamp on platforms where
            // usize < 64 bits (won't happen on the Mac target, but be safe).
            Scope::Column(usize::try_from(scope).unwrap_or(usize::MAX))
        };
        let q = Query {
            text: text.to_string(),
            scope,
        };
        h.with(|session| {
            session.set_filter(q);
            MdvStatus::Ok
        })
        .unwrap_or_else(|contended_or_dead| contended_or_dead)
    })
}

/// Produce the level-triggered visible-rows snapshot (Stage 2) as a
/// length-prefixed MessagePack frame via `out_buf`. Caller MUST call
/// [`mdvcore_buf_free`].
///
/// # Safety
/// `handle` valid & live; `out_buf` valid & writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdvcore_session_snapshot(
    handle: *mut SessionHandle,
    out_buf: *mut MdvBuf,
) -> MdvStatus {
    ffi_guard!({
        if out_buf.is_null() {
            return MdvStatus::NullArg;
        }
        // SAFETY: out_buf validated; safe empty default for error paths.
        unsafe { *out_buf = MdvBuf::empty() };

        // TSK-541: registry lookup — total over any token (absent → None),
        // and the Arc clone keeps the handle alive past a concurrent free.
        let Some(h) = SessionHandle::lookup(handle) else {
            return MdvStatus::NullArg;
        };
        h.with(|session| {
            // Borrow-based, already-framed path: serializes the visible rows
            // straight from borrows of the table (no per-pull owned-row clone).
            // Byte-identical to `wire::encode_frame(&session.snapshot())` — the
            // owned `snapshot()` is retained for non-FFI callers/tests; parity
            // is pinned by `crates/core/tests/…_snapshot_frame.rs`.
            match session.snapshot_frame() {
                Ok(frame) => {
                    // SAFETY: out_buf validated non-null above.
                    unsafe { *out_buf = MdvBuf::from_vec(frame) };
                    MdvStatus::Ok
                }
                Err(e) => {
                    // SAFETY: out_buf validated non-null + empty-defaulted above.
                    unsafe { write_wire_error(out_buf, &e) }
                }
            }
        })
        .unwrap_or_else(|contended_or_dead| contended_or_dead)
    })
}

/// Snapshot a WINDOW of the current visible rows — `[offset, offset+limit)`
/// of the surviving (post-filter) set — into `out_buf` as a length-prefixed
/// MessagePack frame, instead of the whole set (TSK-559). Same wire shape as
/// [`mdvcore_session_snapshot`]; `indices` carry the absolute row ids of the
/// window and `total_rows` is the table total. Pair with
/// [`mdvcore_session_filtered_count`] to size the scrollbar. `offset` past the
/// surviving end yields an empty window (valid); `limit` saturates at the end.
/// Caller MUST call [`mdvcore_buf_free`].
///
/// # Safety
/// `handle` valid & live; `out_buf` valid & writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdvcore_session_snapshot_window(
    handle: *mut SessionHandle,
    offset: u64,
    limit: u64,
    out_buf: *mut MdvBuf,
) -> MdvStatus {
    ffi_guard!({
        if out_buf.is_null() {
            return MdvStatus::NullArg;
        }
        // SAFETY: out_buf validated; safe empty default for error paths.
        unsafe { *out_buf = MdvBuf::empty() };

        // TSK-541: registry lookup keeps the handle alive past a concurrent free.
        let Some(h) = SessionHandle::lookup(handle) else {
            return MdvStatus::NullArg;
        };
        h.with(|session| {
            // u64→usize: on 64-bit this is exact; a 32-bit overflow clamps to
            // usize::MAX, which the core then clamps to the surviving end (an
            // empty window) — never UB.
            let off = usize::try_from(offset).unwrap_or(usize::MAX);
            let lim = usize::try_from(limit).unwrap_or(usize::MAX);
            match session.snapshot_window_frame(off, lim) {
                Ok(frame) => {
                    // SAFETY: out_buf validated non-null above.
                    unsafe { *out_buf = MdvBuf::from_vec(frame) };
                    MdvStatus::Ok
                }
                Err(e) => {
                    // SAFETY: out_buf validated non-null + empty-defaulted above.
                    unsafe { write_wire_error(out_buf, &e) }
                }
            }
        })
        .unwrap_or_else(|contended_or_dead| contended_or_dead)
    })
}

/// Write the number of rows surviving the current filter (the windowable set
/// size) to `*out_count` (TSK-559). Cheap — counts cached indices, projects no
/// rows. The scalar a windowed consumer needs to size its scrollbar without
/// pulling the whole table.
///
/// # Safety
/// `handle` valid & live; `out_count` valid & writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdvcore_session_filtered_count(
    handle: *mut SessionHandle,
    out_count: *mut u64,
) -> MdvStatus {
    ffi_guard!({
        if out_count.is_null() {
            return MdvStatus::NullArg;
        }
        // SAFETY: out_count validated; safe default for error paths.
        unsafe { *out_count = 0 };

        let Some(h) = SessionHandle::lookup(handle) else {
            return MdvStatus::NullArg;
        };
        h.with(|session| {
            let n = u64::try_from(session.filtered_row_count()).unwrap_or(u64::MAX);
            // SAFETY: out_count validated non-null above.
            unsafe { *out_count = n };
            MdvStatus::Ok
        })
        .unwrap_or_else(|contended_or_dead| contended_or_dead)
    })
}

/// Free a session handle. Null-tolerant (matches C `free`). After this call the
/// pointer is dangling and must not be used again.
///
/// # Safety
/// `handle` must be a pointer returned by [`mdvcore_session_open`] that has not
/// already been freed, or null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdvcore_session_free(handle: *mut SessionHandle) {
    // No status to return; still guard so a Drop panic can't unwind across C.
    let _ = std::panic::catch_unwind(|| {
        // TSK-541: registry remove — null-tolerant + idempotent (double free
        // and bogus-token free are safe no-ops; a free racing a call defers
        // the drop to the in-flight Arc).
        SessionHandle::free(handle);
    });
}

/// Free a [`MdvBuf`] returned by an out-param. Null-data-tolerant.
///
/// # Safety
/// `buf` must be a pointer to a `MdvBuf` previously written by this library,
/// not already freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdvcore_buf_free(buf: *mut MdvBuf) {
    let _ = std::panic::catch_unwind(|| {
        if buf.is_null() {
            return;
        }
        // SAFETY: caller contract — buf points to a MdvBuf we wrote.
        unsafe { MdvBuf::free_in_place(buf) };
    });
}

#[cfg(test)]
mod tests;
