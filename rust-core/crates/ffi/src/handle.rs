//! Opaque session handle: an Arc-backed global registry keyed by an opaque
//! token, NOT a raw `Box` pointer.
//!
//! ## Why a registry (TSK-541 — the free-vs-call soundness fix)
//!
//! The earlier design handed Swift a `Box::into_raw` pointer and freed it with
//! `Box::from_raw`. Concurrent *call*s were mediated by an inner `Mutex`
//! (`with` → `try_lock` → `Busy`), but `free` took NO lock — it just dropped
//! the `Box`. So the one misuse a real Swift app commits under ARC/deinit
//! timing — **freeing a handle while a background snapshot is in flight** — was
//! raw UB: the in-flight `with` borrow dangled (use-after-free) and `free`
//! dropped a *locked* `Mutex`. `try_lock` could never catch it because `free`
//! never went near the lock.
//!
//! The fix is indirection. The token Swift holds is now an opaque key into a
//! global `Mutex<HashMap<usize, Arc<SessionHandle>>>`:
//!
//! - A *call* ([`SessionHandle::lookup`]) CLONES the `Arc` out of the registry
//!   under the registry lock, then operates on its own clone. Even if `free`
//!   removes the registry entry concurrently, that clone keeps the inner
//!   `SessionHandle` (and its `Mutex`) alive until the call returns — so the
//!   inner is dropped strictly AFTER the call's lock guard is released. No UAF,
//!   no dropping a locked `Mutex`.
//! - [`SessionHandle::free`] just `remove`s the entry. Idempotent: a double
//!   free finds nothing → safe no-op (the old `Box::from_raw` twice was a
//!   double-free). A free racing a call defers the real drop to the `Arc`.
//! - A bogus / stale token isn't dereferenced — it's looked up. Absent → the
//!   call returns a status (the export maps `None` to `NullArg`/`HandleDead`),
//!   never UB. So `lookup`/`free` are now TOTAL and SAFE over any pointer
//!   value, which is why they shed their `unsafe`.
//!
//! ABI note: the token is still a `*mut SessionHandle` to cbindgen (an opaque
//! forward-declared struct) — Swift holds it verbatim and never inspects or
//! dereferences it, so this is byte-identical at the C boundary. We never
//! dereference it on the Rust side either; it round-trips through `as usize`
//! purely as a registry key (no provenance is required for a non-deref token).
//!
//! ## Single-writer model (unchanged)
//!
//! Within a live handle the inner [`CsvSession`] is still single-writer:
//! [`SessionHandle::with`] uses `try_lock` and returns
//! `Err(`[`crate::MdvStatus::Busy`]`)` if another thread holds the lock (loud,
//! recoverable — not a silent block), and `Err(`[`crate::MdvStatus::HandleDead`]`)`
//! on a POISONED lock (a prior panic under the lock; TSK-581).

use mdvcore_core::session::CsvSession;
use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

/// Opaque handle wrapping a [`CsvSession`] behind a `Mutex`. cbindgen emits
/// this as a forward-declared opaque C struct (it is not `#[repr(C)]`), so
/// Swift cannot inspect or fabricate one — it only ever holds the token.
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

/// Live handles keyed by their opaque token. An `Arc` so an in-flight call can
/// hold the inner alive past a concurrent `free` (the whole point of TSK-541).
fn registry() -> &'static Mutex<HashMap<usize, Arc<SessionHandle>>> {
    static REGISTRY: OnceLock<Mutex<HashMap<usize, Arc<SessionHandle>>>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Monotonic token allocator. 1-based so `0` stays distinct from a token (a
/// null `*mut SessionHandle` is `0`). Never reused → no ABA: a freed token can
/// never collide with a live one.
static NEXT_TOKEN: AtomicUsize = AtomicUsize::new(1);

impl SessionHandle {
    /// Wrap a session in a new handle.
    #[must_use]
    pub fn new(session: CsvSession) -> Self {
        Self {
            inner: Mutex::new(session),
        }
    }

    /// Register the handle and return its opaque token to hand across the C
    /// ABI. Balance with exactly one [`SessionHandle::free`] (a missed free
    /// leaks one registry entry; a double free is a safe no-op).
    #[must_use]
    pub fn into_raw(self) -> *mut SessionHandle {
        let mut token = NEXT_TOKEN.fetch_add(1, Ordering::Relaxed);
        // Skip the reserved 0 on the (astronomically unlikely) wrap.
        if token == 0 {
            token = NEXT_TOKEN.fetch_add(1, Ordering::Relaxed);
        }
        registry()
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(token, Arc::new(self));
        token as *mut SessionHandle
    }

    /// Look up a live handle by its token, returning an owned `Arc` clone (so
    /// it stays alive for the duration of the call even if `free` races).
    /// `None` for null, a freed token, or any value never produced by
    /// [`SessionHandle::into_raw`] — total and panic-free, never a deref.
    #[must_use]
    pub fn lookup(ptr: *mut SessionHandle) -> Option<Arc<SessionHandle>> {
        if ptr.is_null() {
            return None;
        }
        let token = ptr as usize;
        registry()
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&token)
            .cloned()
    }

    /// Free a handle: drop its registry entry. Null-tolerant and idempotent (a
    /// second free, or a free of a bogus token, is a no-op). If a call is
    /// in flight, the `Arc` it holds defers the real drop until that call
    /// returns — closing the free-vs-call UAF.
    pub fn free(ptr: *mut SessionHandle) {
        if ptr.is_null() {
            return;
        }
        let token = ptr as usize;
        // Take the entry out UNDER the lock, then drop the Arc AFTER releasing
        // the registry lock — so a (possibly large) CsvSession drop doesn't
        // serialize other frees/lookups, and so the last-ref drop can't run
        // inner Drop code while we hold the registry mutex.
        let removed = registry()
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&token);
        drop(removed);
    }

    /// Run `f` with exclusive access to the inner session, IF the lock is
    /// immediately available. Tri-state (audit TSK-581):
    ///
    /// - `Ok(R)` — lock acquired, `f` ran.
    /// - `Err(Busy)` — another thread holds the lock (single-writer contract
    ///   violated); retryable.
    /// - `Err(HandleDead)` — the lock is POISONED: a previous call panicked
    ///   while holding it, so the session may be half-mutated. Serving that
    ///   state would contradict the documented drop-&-recreate contract, so
    ///   the handle is permanently dead.
    pub fn with<R>(
        &self,
        f: impl FnOnce(&mut CsvSession) -> R,
    ) -> Result<R, crate::MdvStatus> {
        match self.inner.try_lock() {
            Ok(mut guard) => Ok(f(&mut guard)),
            Err(std::sync::TryLockError::Poisoned(_)) => Err(crate::MdvStatus::HandleDead),
            Err(std::sync::TryLockError::WouldBlock) => Err(crate::MdvStatus::Busy),
        }
    }
}
