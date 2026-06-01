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
