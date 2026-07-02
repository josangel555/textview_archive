//! Opaque canvas-document handle — the [`crate::handle`] registry pattern
//! applied to the M0 canvas spike's [`mdvcore_core::canvas::Doc`].
//!
//! All soundness rationale (registry-not-Box, Arc-outlives-free, total
//! lookup/free, single-writer `try_lock` tri-state) is documented ONCE in
//! [`crate::handle`] (TSK-541/581) and applies verbatim here. M1's real
//! engine should generalize the two registries into one generic — tracked in
//! the M1 plan; duplicating ~80 lines is the M0-lean choice (a premature
//! generic in a spike is scope creep).

use mdvcore_core::canvas::Doc;
use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

/// Opaque handle wrapping a canvas [`Doc`] behind a `Mutex`. cbindgen emits a
/// forward-declared opaque C struct; Swift only ever holds the token.
pub struct CanvasHandle {
    inner: Mutex<Doc>,
}

// SAFETY: all access to the inner Doc goes through the Mutex (`with`); no
// reference escapes the guard. Doc is plain owned data (Send).
unsafe impl Send for CanvasHandle {}
// SAFETY: see Send — shared access is mediated solely by the Mutex.
unsafe impl Sync for CanvasHandle {}

/// Live canvas handles keyed by opaque token (see [`crate::handle`]).
fn registry() -> &'static Mutex<HashMap<usize, Arc<CanvasHandle>>> {
    static REGISTRY: OnceLock<Mutex<HashMap<usize, Arc<CanvasHandle>>>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Monotonic 1-based token allocator (0 reserved ≙ null; never reused).
static NEXT_TOKEN: AtomicUsize = AtomicUsize::new(1);

impl CanvasHandle {
    /// Wrap a document in a new handle.
    #[must_use]
    pub fn new(doc: Doc) -> Self {
        Self {
            inner: Mutex::new(doc),
        }
    }

    /// Register and return the opaque token. Balance with one
    /// [`CanvasHandle::free`].
    #[must_use]
    pub fn into_raw(self) -> *mut CanvasHandle {
        let mut token = NEXT_TOKEN.fetch_add(1, Ordering::Relaxed);
        if token == 0 {
            token = NEXT_TOKEN.fetch_add(1, Ordering::Relaxed);
        }
        registry()
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(token, Arc::new(self));
        token as *mut CanvasHandle
    }

    /// Total, panic-free lookup (None for null/freed/bogus tokens).
    #[must_use]
    pub fn lookup(ptr: *mut CanvasHandle) -> Option<Arc<CanvasHandle>> {
        if ptr.is_null() {
            return None;
        }
        registry()
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(&(ptr as usize))
            .cloned()
    }

    /// Idempotent, null-tolerant free; a racing in-flight call's Arc defers
    /// the real drop.
    pub fn free(ptr: *mut CanvasHandle) {
        if ptr.is_null() {
            return;
        }
        let removed = registry()
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&(ptr as usize));
        drop(removed);
    }

    /// Run `f` with exclusive access — `Ok(R)`, `Err(Busy)` on contention,
    /// `Err(HandleDead)` on a poisoned lock (see [`crate::handle`]).
    pub fn with<R>(&self, f: impl FnOnce(&mut Doc) -> R) -> Result<R, crate::MdvStatus> {
        match self.inner.try_lock() {
            Ok(mut guard) => Ok(f(&mut guard)),
            Err(std::sync::TryLockError::Poisoned(_)) => Err(crate::MdvStatus::HandleDead),
            Err(std::sync::TryLockError::WouldBlock) => Err(crate::MdvStatus::Busy),
        }
    }
}
