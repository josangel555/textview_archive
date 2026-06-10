//! The stable C status enum. `#[repr(C)]` with explicit discriminants so the
//! values never shift between builds — Swift switches on these.
//!
//! Discipline (playbook §5): NEVER renumber an existing variant; reserve an
//! `Internal`/`Unknown`-style arm (here [`MdvStatus::Internal`] = 99) so adding
//! variants later doesn't break a Swift `switch`'s `default`. The codes also
//! match the `WireError.code` carried in the MessagePack body, so the C status
//! and the rich wire error agree.

/// Stable C status code returned by every fallible FFI entry point.
///
/// Payloads are delivered via OUT-PARAMS, never mixed into this value, so
/// "succeeded with an empty result" (`Ok` + empty buffer) is unambiguous.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MdvStatus {
    /// Success.
    Ok = 0,
    /// A required pointer argument was null (or a length/pointer mismatch).
    NullArg = 1,
    /// Input bytes were not valid UTF-8.
    BadUtf8 = 2,
    /// The handle was locked by another in-flight call (single-writer model):
    /// the caller violated the one-writer-at-a-time contract. Retry after the
    /// other call completes; do NOT spin tightly.
    Busy = 3,
    /// A wire (MessagePack encode/decode or framing) error occurred.
    WireError = 4,
    /// The result is real but its encoded frame exceeds the wire cap (audit
    /// TSK-548 stopgap) — distinct from [`MdvStatus::WireError`] so the host
    /// can react (window / fall back) instead of diagnosing a codec bug.
    TooLarge = 5,
    /// A Rust panic was caught at the boundary (recoverable: the process did
    /// NOT crash, but the handle's state may be suspect — drop & recreate it).
    Panic = 98,
    /// Catch-all for any future/internal error. Reserved so adding variants is
    /// non-breaking for a Swift `switch`'s default arm.
    Internal = 99,
}
