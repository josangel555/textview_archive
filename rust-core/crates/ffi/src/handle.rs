//! Opaque session handle: the `Box::into_raw` / `Box::from_raw` pattern with a
//! single-writer concurrency model.
//!
//! ## Ownership (documented contract)
//!
//! - [`SessionHandle::new`] + [`SessionHandle::into_raw`] hand a `*mut` to the
//!   caller. Each `into_raw` MUST be balanced by EXACTLY ONE [`SessionHandle::free`]
//!   (which does `Box::from_raw` → drop). Allocate-and-free on the same side:
//!   Swift calls `mdvcore_session_free`, never libc `free` (Rust's allocator ≠
//!   libc's).
//! - Ordinary calls use [`SessionHandle::as_ref`] to BORROW the handle — they
//!   never round-trip ownership through `from_raw`/`into_raw` (that would
//!   double-free or leak).
//!
//! ## Threading / Send + Sync (the deliberate call)
//!
//! The inner [`CsvSession`] is `&mut self` and not internally synchronized, so
//! a raw `*mut CsvSession` is correctly `!Send`/`!Sync` by default. We do NOT
//! reflexively override that. Instead we wrap it in a `Mutex`, which makes
//! shared access genuinely sound — and only THEN is `unsafe impl Send + Sync`
//! justified (with the SAFETY note below).
//!
//! The model is **single-writer**: there should be one logical owner per
//! handle at a time. To make a contract violation LOUD rather than a silent
//! deadlock/serialization, [`SessionHandle::with`] uses `try_lock` and returns
//! `None` (→ [`crate::MdvStatus::Busy`]) if another thread holds the lock,
//! rather than blocking. That turns "two threads raced on one handle" into a
//! recoverable error the caller sees, which is exactly what we want to surface
//! in the concurrency test.

use mdvcore_core::session::CsvSession;
use std::sync::Mutex;

/// Opaque handle wrapping a [`CsvSession`] behind a `Mutex`. cbindgen emits
/// this as a forward-declared opaque C struct (it is not `#[repr(C)]`), so
/// Swift cannot inspect or fabricate one — it only ever holds the pointer.
pub struct SessionHandle {
    inner: Mutex<CsvSession>,
}

// SAFETY: all access to the inner CsvSession goes through the Mutex (see
// `with`); no `&CsvSession`/`&mut CsvSession` escapes the lock guard. The Mutex
// provides the synchronization that makes cross-thread access data-race-free,
// which is the precondition for Send + Sync. CsvSession itself is Send (plain
// owned data), so moving it under the Mutex across threads is sound.
unsafe impl Send for SessionHandle {}
// SAFETY: see the Send impl — shared access is mediated solely by the Mutex.
unsafe impl Sync for SessionHandle {}

impl SessionHandle {
    /// Wrap a session in a new handle.
    #[must_use]
    pub fn new(session: CsvSession) -> Self {
        Self {
            inner: Mutex::new(session),
        }
    }

    /// Consume the handle into a raw pointer to hand across the C ABI. Balance
    /// with exactly one [`SessionHandle::free`].
    #[must_use]
    pub fn into_raw(self) -> *mut SessionHandle {
        Box::into_raw(Box::new(self))
    }

    /// Borrow a handle from a raw pointer WITHOUT taking ownership. Returns
    /// `None` if the pointer is null.
    ///
    /// # Safety
    /// `ptr` must be either null or a live pointer previously produced by
    /// [`SessionHandle::into_raw`] and not yet freed. The returned reference
    /// must not outlive the handle.
    #[must_use]
    pub unsafe fn as_ref<'a>(ptr: *mut SessionHandle) -> Option<&'a SessionHandle> {
        // SAFETY: caller guarantees ptr is null or a live SessionHandle; we
        // hand back a shared borrow tied to caller-chosen lifetime 'a. Safe
        // because the handle is only freed via `free`, which the caller
        // contract says won't race a live borrow.
        unsafe { ptr.as_ref() }
    }

    /// Free a handle: reconstruct the `Box` and drop it. Null-tolerant.
    ///
    /// # Safety
    /// `ptr` must be null or a live pointer from [`SessionHandle::into_raw`]
    /// that has NOT already been freed (exactly-once).
    pub unsafe fn free(ptr: *mut SessionHandle) {
        if ptr.is_null() {
            return;
        }
        // SAFETY: caller guarantees exactly-once free of a live handle.
        drop(unsafe { Box::from_raw(ptr) });
    }

    /// Run `f` with exclusive access to the inner session, IF the lock is
    /// immediately available. Returns `None` if another thread currently holds
    /// the lock (single-writer contract violated) — the caller maps that to
    /// [`crate::MdvStatus::Busy`]. A poisoned lock (a previous panic while
    /// holding it) is recovered into-place so one caught panic doesn't wedge
    /// the handle forever.
    pub fn with<R>(&self, f: impl FnOnce(&mut CsvSession) -> R) -> Option<R> {
        match self.inner.try_lock() {
            Ok(mut guard) => Some(f(&mut guard)),
            Err(std::sync::TryLockError::Poisoned(p)) => {
                // Recover: the data is still structurally valid CSV state; the
                // poison only flags that a panic occurred under the lock.
                let mut guard = p.into_inner();
                Some(f(&mut guard))
            }
            Err(std::sync::TryLockError::WouldBlock) => None,
        }
    }
}
