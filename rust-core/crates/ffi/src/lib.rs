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

use mdvcore_core::cm_edit;
use mdvcore_core::diff;
use mdvcore_core::filter::{Query, Scope};
use mdvcore_core::hex;
use mdvcore_core::indent;
use mdvcore_core::session::CsvSession;
use mdvcore_core::wire;

pub use buf::MdvBuf;
pub use handle::SessionHandle;
pub use status::MdvStatus;

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

/// Apply a CodeMirror edit batch (stateless). `req`/`req_len` is a
/// length-prefixed MessagePack request frame `{base, edits:[{from,to,insert}]}`;
/// the result is written to `out_buf` as a `{text: Option<String>}` response
/// frame (a `null` text means the batch was rejected — the caller full-resyncs).
/// Caller MUST call [`mdvcore_buf_free`] on `out_buf`.
///
/// # Returns
/// [`MdvStatus::Ok`], [`MdvStatus::NullArg`], [`MdvStatus::WireError`] (malformed
/// request frame / encode failure), or [`MdvStatus::Panic`].
///
/// # Safety
/// `req` must point to `req_len` valid bytes (or be null with `req_len == 0`).
/// `out_buf` must be a valid, writable pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdvcore_cm_apply(
    req: *const u8,
    req_len: usize,
    out_buf: *mut MdvBuf,
) -> MdvStatus {
    ffi_guard!({
        if out_buf.is_null() {
            return MdvStatus::NullArg;
        }
        // SAFETY: out_buf validated; empty default so error paths stay safe-to-free.
        unsafe { *out_buf = MdvBuf::empty() };

        if req.is_null() && req_len != 0 {
            return MdvStatus::NullArg;
        }
        let bytes: &[u8] = if req_len == 0 {
            &[]
        } else {
            // SAFETY: caller guarantees req/req_len describe valid bytes (len != 0).
            unsafe { core::slice::from_raw_parts(req, req_len) }
        };
        match cm_edit::apply_wire(bytes) {
            Ok(frame) => {
                // SAFETY: out_buf validated non-null above.
                unsafe { *out_buf = MdvBuf::from_vec(frame) };
                MdvStatus::Ok
            }
            Err(_) => MdvStatus::WireError,
        }
    })
}

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
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdvcore_diff_parse(
    req: *const u8,
    req_len: usize,
    out_buf: *mut MdvBuf,
) -> MdvStatus {
    ffi_guard!({
        if out_buf.is_null() {
            return MdvStatus::NullArg;
        }
        // SAFETY: out_buf validated; empty default so error paths stay safe-to-free.
        unsafe { *out_buf = MdvBuf::empty() };

        if req.is_null() && req_len != 0 {
            return MdvStatus::NullArg;
        }
        let bytes: &[u8] = if req_len == 0 {
            &[]
        } else {
            // SAFETY: caller guarantees req/req_len describe valid bytes (len != 0).
            unsafe { core::slice::from_raw_parts(req, req_len) }
        };
        match diff::parse_wire(bytes) {
            Ok(frame) => {
                // SAFETY: out_buf validated non-null above.
                unsafe { *out_buf = MdvBuf::from_vec(frame) };
                MdvStatus::Ok
            }
            Err(_) => MdvStatus::WireError,
        }
    })
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
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mdvcore_diff_hunk_marks(
    req: *const u8,
    req_len: usize,
    out_buf: *mut MdvBuf,
) -> MdvStatus {
    ffi_guard!({
        if out_buf.is_null() {
            return MdvStatus::NullArg;
        }
        // SAFETY: out_buf validated; empty default so error paths stay safe-to-free.
        unsafe { *out_buf = MdvBuf::empty() };

        if req.is_null() && req_len != 0 {
            return MdvStatus::NullArg;
        }
        let bytes: &[u8] = if req_len == 0 {
            &[]
        } else {
            // SAFETY: caller guarantees req/req_len describe valid bytes (len != 0).
            unsafe { core::slice::from_raw_parts(req, req_len) }
        };
        match diff::hunk_marks_wire(bytes) {
            Ok(frame) => {
                // SAFETY: out_buf validated non-null above.
                unsafe { *out_buf = MdvBuf::from_vec(frame) };
                MdvStatus::Ok
            }
            Err(_) => MdvStatus::WireError,
        }
    })
}

/// Render a HEX dump (stateless). `bytes`/`len` is the raw byte buffer to dump;
/// the rendered dump is written to `out_buf` as **raw UTF-8** (NOT a MessagePack
/// frame — a 4 MB file renders to ~18 MB of text, so wrapping it in a frame just
/// to immediately re-decode it on the Swift side would double the cost for no
/// benefit; the result is one opaque string). Caller MUST call
/// [`mdvcore_buf_free`] on `out_buf`.
///
/// `width` is bytes-per-row; `total_byte_count` / `is_truncated` drive the
/// "Showing first N of M bytes" header.
///
/// # Returns
/// [`MdvStatus::Ok`], [`MdvStatus::NullArg`], or [`MdvStatus::Panic`].
///
/// # Safety
/// `bytes` must point to `len` valid bytes (or be null with `len == 0`).
/// `out_buf` must be a valid, writable pointer.
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
        let width = usize::try_from(width).unwrap_or(usize::MAX);
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
            Err(_) => MdvStatus::WireError,
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
            Err(_) => MdvStatus::BadUtf8,
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

        // SAFETY: handle contract per fn docs.
        let Some(h) = (unsafe { SessionHandle::as_ref(handle) }) else {
            return MdvStatus::NullArg;
        };
        h.with(|session| {
            match wire::encode_frame(session.table()) {
                Ok(frame) => {
                    // SAFETY: out_buf validated non-null above.
                    unsafe { *out_buf = MdvBuf::from_vec(frame) };
                    MdvStatus::Ok
                }
                Err(_) => MdvStatus::WireError,
            }
        })
        .unwrap_or(MdvStatus::Busy)
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
        // SAFETY: handle contract per fn docs.
        let Some(h) = (unsafe { SessionHandle::as_ref(handle) }) else {
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
        .unwrap_or(MdvStatus::Busy)
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

        // SAFETY: handle contract per fn docs.
        let Some(h) = (unsafe { SessionHandle::as_ref(handle) }) else {
            return MdvStatus::NullArg;
        };
        h.with(|session| {
            let snap = session.snapshot();
            match wire::encode_frame(&snap) {
                Ok(frame) => {
                    // SAFETY: out_buf validated non-null above.
                    unsafe { *out_buf = MdvBuf::from_vec(frame) };
                    MdvStatus::Ok
                }
                Err(_) => MdvStatus::WireError,
            }
        })
        .unwrap_or(MdvStatus::Busy)
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
        // SAFETY: caller contract — exactly-once free of a live handle, or null.
        unsafe { SessionHandle::free(handle) };
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
