//! `MdvBuf` — an owned byte buffer handed OUT across the C ABI (for the
//! length-prefixed MessagePack frames). `#[repr(C)]` so Swift can read the
//! pointer + length directly, then must hand it back to `mdvcore_buf_free`.
//!
//! Allocate-and-free on the same side: the bytes are a Rust `Vec` whose raw
//! parts we expose. Swift reads `data[0..len]`, copies what it needs, then
//! calls `mdvcore_buf_free` so Rust reconstitutes and drops the `Vec` with the
//! correct (Rust) allocator and the ORIGINAL capacity (storing `cap` is
//! essential — `Vec::from_raw_parts` needs the true capacity, not the length).

/// A Rust-owned byte buffer crossing the C boundary. After reading, the C side
/// MUST call `mdvcore_buf_free` exactly once.
#[repr(C)]
pub struct MdvBuf {
    /// Pointer to the bytes (null when `len == 0`).
    pub data: *mut u8,
    /// Number of valid bytes.
    pub len: usize,
    /// Original allocation capacity — needed to reconstruct the `Vec` for a
    /// correct free. Opaque to the C side; do not modify.
    pub cap: usize,
}

impl MdvBuf {
    /// An empty buffer (safe to `mdvcore_buf_free`).
    #[must_use]
    pub fn empty() -> Self {
        Self {
            data: core::ptr::null_mut(),
            len: 0,
            cap: 0,
        }
    }

    /// Take ownership of `v`'s allocation and expose it as a `MdvBuf`. The
    /// `Vec` is forgotten; ownership transfers to whoever calls `free`.
    #[must_use]
    pub fn from_vec(mut v: Vec<u8>) -> Self {
        let data = v.as_mut_ptr();
        let len = v.len();
        let cap = v.capacity();
        core::mem::forget(v);
        Self { data, len, cap }
    }

    /// Free the buffer in place (reconstruct the `Vec` and drop it), then null
    /// the fields so a (buggy) double-free is a harmless no-op.
    ///
    /// # Safety
    /// `ptr` must point to a `MdvBuf` previously produced by [`MdvBuf::from_vec`]
    /// / [`MdvBuf::empty`] by this library and not already freed.
    pub unsafe fn free_in_place(ptr: *mut MdvBuf) {
        // SAFETY: caller guarantees ptr points to a valid MdvBuf we produced.
        let buf = unsafe { &mut *ptr };
        if !buf.data.is_null() && buf.cap != 0 {
            // SAFETY: data/len/cap are the exact raw parts of a Vec<u8> we
            // forgot in `from_vec`; reconstructing with the SAME cap is the
            // documented inverse. Dropping frees with Rust's allocator.
            drop(unsafe { Vec::from_raw_parts(buf.data, buf.len, buf.cap) });
        }
        buf.data = core::ptr::null_mut();
        buf.len = 0;
        buf.cap = 0;
    }

    /// View the buffer's bytes as a slice (test/helper convenience).
    ///
    /// # Safety
    /// The buffer must be live (not freed) and `data`/`len` consistent.
    #[must_use]
    pub unsafe fn as_slice(&self) -> &[u8] {
        if self.data.is_null() || self.len == 0 {
            return &[];
        }
        // SAFETY: caller guarantees data points to len initialized bytes.
        unsafe { core::slice::from_raw_parts(self.data, self.len) }
    }
}
