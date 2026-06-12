//! The panic boundary.
//!
//! ⚠️ Currency note (corrects the stale playbook line): since **Rust 1.81**, an
//! unwind reaching an `extern "C"` boundary is DEFINED behavior — it aborts the
//! process (`panic_cannot_unwind` → `abort`). It is no longer UB. So the reason
//! we wrap every entry point in [`std::panic::catch_unwind`] is NOT soundness;
//! it is **host survival**: a bare abort would kill the embedding Swift GUI app.
//! Catching the unwind lets us convert it into [`crate::MdvStatus::Panic`] and
//! keep the app alive.
//!
//! `catch_unwind` catches *unwinding* panics only. It does NOT catch aborts
//! (`panic=abort`, double-panic, `abort()`, stack overflow, OOM). Under the
//! size-opt `release` profile (`panic="abort"`) these macros compile to a
//! straight call — correct, just a no-op catch. They are load-bearing under the
//! default `dev`/`test` profile and a future `panic="unwind"` shipping dylib.
//!
//! `AssertUnwindSafe` is required because the closures capture `&mut` session
//! state / raw pointers, which are not `UnwindSafe`. That is fine: we catch
//! precisely to STOP the unwind and discard the payload. On a caught panic we
//! return an error and the documented contract is that the caller drops &
//! recreates the handle rather than reusing possibly-half-mutated state.

/// Wrap an `extern "C"` fn body that returns [`crate::MdvStatus`]. A caught
/// panic becomes [`crate::MdvStatus::Panic`].
#[macro_export]
macro_rules! ffi_guard {
    ($body:block) => {{
        let result = ::std::panic::catch_unwind(::std::panic::AssertUnwindSafe(|| $body));
        match result {
            Ok(status) => status,
            Err(_) => $crate::MdvStatus::Panic,
        }
    }};
}

/// Wrap an `extern "C"` fn body that returns an arbitrary value. On a caught
/// panic, returns the supplied `$fallback`. Use for non-status returns (e.g.
/// [`crate::mdvcore_add`]).
#[macro_export]
macro_rules! ffi_guard_value {
    ($fallback:expr, $body:block) => {{
        let result = ::std::panic::catch_unwind(::std::panic::AssertUnwindSafe(|| $body));
        match result {
            Ok(value) => value,
            Err(_) => $fallback,
        }
    }};
}

/// The canonical STATELESS export body (TSK-634 stage 2): a length-prefixed
/// MessagePack request frame in (`req`/`req_len`), a response frame out
/// (`out_buf`), produced by `$core_fn: fn(&[u8]) -> Result<Vec<u8>, WireFault>`.
///
/// Generates the body ONLY — the `extern "C"` signature stays hand-written at
/// the call site because cbindgen does not expand `macro_rules!`, and the
/// header generator must see the symbol. The macro owns the entire safety
/// ritual (out-buf validation + safe-to-free default, null/len argument
/// guard, the raw-parts slice, status mapping) so a new export cannot get it
/// subtly wrong; the guard semantics are pinned once by the shared
/// misuse-matrix macro in `tests.rs` and apply to every adopter.
///
/// Call shape:
/// ```ignore
/// pub unsafe extern "C" fn mdvcore_thing(
///     req: *const u8, req_len: usize, out_buf: *mut MdvBuf,
/// ) -> MdvStatus {
///     ffi_frame_body!(req, req_len, out_buf, thing::thing_wire)
/// }
/// ```
#[macro_export]
macro_rules! ffi_frame_body {
    ($req:ident, $req_len:ident, $out_buf:ident, $core_fn:path) => {{
        $crate::ffi_guard!({
            if $out_buf.is_null() {
                return $crate::MdvStatus::NullArg;
            }
            // SAFETY: out_buf validated; empty default so error paths stay safe-to-free.
            unsafe { *$out_buf = $crate::MdvBuf::empty() };

            if $req.is_null() && $req_len != 0 {
                return $crate::MdvStatus::NullArg;
            }
            let bytes: &[u8] = if $req_len == 0 {
                &[]
            } else {
                // SAFETY: caller guarantees req/req_len describe valid bytes (len != 0).
                unsafe { core::slice::from_raw_parts($req, $req_len) }
            };
            match $core_fn(bytes) {
                Ok(frame) => {
                    // SAFETY: out_buf validated non-null above.
                    unsafe { *$out_buf = $crate::MdvBuf::from_vec(frame) };
                    $crate::MdvStatus::Ok
                }
                Err(e) => $crate::wire_status(&e),
            }
        })
    }};
}
