//! launchd socket activation (DAEMON_LIFECYCLE_DESIGN.md D2, TSK-1553).
//!
//! `mdv-serve` under a LaunchAgent doesn't bind its own socket — launchd owns
//! the socket (the plist's `Sockets` key) and hands the already-listening fd
//! to the process on demand via `launch_activate_socket(3)`. This module is
//! the SAFE wrapper over that C call; it lives in the ffi crate because the
//! workspace forbids `unsafe_code` everywhere else (this crate is the one
//! sanctioned opt-out). Non-macOS builds (dev/Linux) compile to a stub that
//! returns no listeners, so callers fall back to self-binding — today's path.

#[cfg(target_os = "macos")]
mod imp {
    use std::ffi::{CString, c_char, c_int, c_void};
    use std::os::fd::FromRawFd;
    use std::os::unix::net::UnixListener;

    unsafe extern "C" {
        /// libSystem: writes a malloc'd array of listening fds registered
        /// under `name` in the job's `Sockets` dictionary. Returns 0 on
        /// success; the caller frees the array (NOT the fds — those are ours
        /// to own/close individually).
        fn launch_activate_socket(
            name: *const c_char,
            fds: *mut *mut c_int,
            cnt: *mut usize,
        ) -> c_int;
        fn free(ptr: *mut c_void);
    }

    pub fn listeners(name: &str) -> Vec<UnixListener> {
        let Ok(cname) = CString::new(name) else {
            return Vec::new();
        };
        let mut fds: *mut c_int = std::ptr::null_mut();
        let mut cnt: usize = 0;
        // SAFETY: cname outlives the call; fds/cnt are valid out-pointers.
        let rc = unsafe { launch_activate_socket(cname.as_ptr(), &mut fds, &mut cnt) };
        if rc != 0 || fds.is_null() || cnt == 0 {
            if !fds.is_null() {
                // SAFETY: a non-null array from launchd is malloc'd; free it.
                unsafe { free(fds.cast()) };
            }
            return Vec::new();
        }
        let out = (0..cnt)
            .map(|i| {
                // SAFETY: `i < cnt`, so the offset stays inside the array
                // launchd allocated.
                let slot = unsafe { fds.add(i) };
                // SAFETY: `slot` points at a valid, initialized c_int entry.
                let fd = unsafe { *slot };
                // SAFETY: launchd transfers ownership of each listening
                // descriptor to us; `from_raw_fd` takes exactly that
                // ownership (the listener's Drop closes it).
                unsafe { UnixListener::from_raw_fd(fd) }
            })
            .collect();
        // SAFETY: free the malloc'd array (fd ownership already transferred).
        unsafe { free(fds.cast()) };
        out
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use std::os::unix::net::UnixListener;
    pub fn listeners(_name: &str) -> Vec<UnixListener> {
        Vec::new()
    }
}

/// The listening sockets launchd inherited to this process under `name`
/// (the key in the LaunchAgent plist's `Sockets` dictionary). Empty when the
/// process wasn't launchd-activated (a plain CLI run), the name is unknown,
/// or the platform isn't macOS — callers treat empty as "self-bind instead".
pub fn launchd_activation_listeners(name: &str) -> Vec<std::os::unix::net::UnixListener> {
    imp::listeners(name)
}
