//! The fs capability family (TSK-654) — host-layer IO with ROOT
//! CONTAINMENT. Deliberately in the server, not the sans-IO core.
//!
//! Methods (protocol §6): `fs.stat`, `fs.read` (WINDOWED-ONLY — no
//! whole-file convenience by design), `fs.readdir` (listing-capped).
//! Every path canonicalizes and must remain inside the canonical served
//! root; symlink escapes die at `canonicalize`. Without a served root the
//! family answers `unauthorized` (engine-only mode is the default).

use std::path::{Path, PathBuf};

use mdvcore_core::wire;

use crate::envelope::WireError;

/// Per-window read ceiling: 4 MiB (a window, not a file — the client
/// composes windows; the frame ceiling stays far away).
pub const MAX_READ_WINDOW: usize = 4 * 1024 * 1024;
/// Directory-listing cap (the mdv-web TSK-558 discipline).
pub const MAX_DIR_ENTRIES: usize = 4096;

/// Served-root context. `None` = fs family disabled.
#[derive(Debug, Clone)]
pub struct FsCtx {
    root: Option<PathBuf>,
}

impl FsCtx {
    /// Build from the `--root` flag; canonicalizes once at startup.
    pub fn new(root: Option<&str>) -> std::io::Result<Self> {
        let root = match root {
            Some(r) => Some(Path::new(r).canonicalize()?),
            None => None,
        };
        Ok(Self { root })
    }

    /// Is the family enabled (drives the hello capability bit)?
    #[must_use]
    pub fn enabled(&self) -> bool {
        self.root.is_some()
    }

    /// Resolve + contain `path`. Errors are the protocol's `unauthorized`.
    fn contained(&self, path: &str) -> Result<PathBuf, WireError> {
        let Some(root) = &self.root else {
            return Err(unauthorized("no served root"));
        };
        let joined = if Path::new(path).is_absolute() {
            PathBuf::from(path)
        } else {
            root.join(path)
        };
        // canonicalize resolves `..` and symlinks — an escape either fails
        // to resolve or lands outside the root prefix.
        let canon = joined
            .canonicalize()
            .map_err(|_| unauthorized("path does not resolve inside the served root"))?;
        if !canon.starts_with(root) {
            return Err(unauthorized("path escapes the served root"));
        }
        Ok(canon)
    }

    /// Dispatch an fs.* method. Returns the UNFRAMED response body.
    pub fn dispatch(&self, method: &str, body: &[u8]) -> Result<Vec<u8>, WireError> {
        match method {
            "fs.stat" => self.stat(body),
            "fs.read" => self.read(body),
            "fs.readdir" => self.readdir(body),
            _ => Err(WireError {
                code: "unknown_method".into(),
                text: format!("no fs method '{method}'"),
            }),
        }
    }

    fn stat(&self, body: &[u8]) -> Result<Vec<u8>, WireError> {
        #[derive(serde::Deserialize)]
        struct Req {
            path: String,
        }
        #[derive(serde::Serialize)]
        struct Resp {
            exists: bool,
            is_dir: bool,
            size: u64,
            modified_ms: i64,
        }
        let req: Req = decode_body(body)?;
        // stat is the one method where "not found" is an ANSWER, not an
        // error — but only for contained paths. Containment first; a path
        // that cannot canonicalize because it does not EXIST inside the
        // root still answers exists=false (check the parent).
        match self.contained(&req.path) {
            Ok(p) => {
                let meta = std::fs::metadata(&p)
                    .map_err(|e| io_error(&format!("stat: {e}")))?;
                encode_body(&Resp {
                    exists: true,
                    is_dir: meta.is_dir(),
                    size: meta.len(),
                    modified_ms: modified_ms(&meta),
                })
            }
            Err(e) => {
                // Distinguish "doesn't exist under the root" (answerable)
                // from a genuine escape (unauthorized): re-check the parent.
                if let Some(root) = &self.root {
                    let joined = if Path::new(&req.path).is_absolute() {
                        PathBuf::from(&req.path)
                    } else {
                        root.join(&req.path)
                    };
                    if let Some(parent) = joined.parent()
                        && let Ok(canon_parent) = parent.canonicalize()
                        && canon_parent.starts_with(root)
                        && !joined.exists()
                    {
                        return encode_body(&Resp {
                            exists: false,
                            is_dir: false,
                            size: 0,
                            modified_ms: 0,
                        });
                    }
                }
                Err(e)
            }
        }
    }

    fn read(&self, body: &[u8]) -> Result<Vec<u8>, WireError> {
        #[derive(serde::Deserialize)]
        struct Req {
            path: String,
            offset: u64,
            len: u64,
        }
        let req: Req = decode_body(body)?;
        let p = self.contained(&req.path)?;
        let want = usize::try_from(req.len).unwrap_or(usize::MAX);
        if want > MAX_READ_WINDOW {
            return Err(WireError {
                code: "too_large".into(),
                text: format!("read window {want} exceeds {MAX_READ_WINDOW}"),
            });
        }
        let data = std::fs::read(&p).map_err(|e| io_error(&format!("read: {e}")))?;
        let total = data.len() as u64;
        let start = usize::try_from(req.offset.min(total)).unwrap_or(0);
        let end = start.saturating_add(want).min(data.len());
        let window = data.get(start..end).unwrap_or_default();
        // Hand-rolled response — `data` must ride as msgpack BIN (rmp-serde
        // without serde_bytes would emit a per-byte array: ~3x bytes and a
        // slow Swift decode). fixmap{total: uint64, data: bin32}.
        let mut out = Vec::with_capacity(window.len().saturating_add(32));
        out.push(0x82);
        push_str(&mut out, "total");
        out.push(0xcf);
        out.extend_from_slice(&total.to_be_bytes());
        push_str(&mut out, "data");
        out.push(0xc6);
        out.extend_from_slice(&u32::try_from(window.len()).unwrap_or(u32::MAX).to_be_bytes());
        out.extend_from_slice(window);
        Ok(out)
    }

    fn readdir(&self, body: &[u8]) -> Result<Vec<u8>, WireError> {
        #[derive(serde::Deserialize)]
        struct Req {
            path: String,
        }
        #[derive(serde::Serialize)]
        struct Entry {
            name: String,
            is_dir: bool,
            size: u64,
        }
        #[derive(serde::Serialize)]
        struct Resp {
            entries: Vec<Entry>,
            truncated: bool,
        }
        let req: Req = decode_body(body)?;
        let p = self.contained(&req.path)?;
        let rd = std::fs::read_dir(&p).map_err(|e| io_error(&format!("readdir: {e}")))?;
        let mut entries = Vec::new();
        let mut truncated = false;
        for item in rd {
            if entries.len() >= MAX_DIR_ENTRIES {
                truncated = true;
                break;
            }
            let Ok(item) = item else { continue };
            let name = item.file_name().to_string_lossy().into_owned();
            let meta = item.metadata().ok();
            entries.push(Entry {
                name,
                is_dir: meta.as_ref().is_some_and(std::fs::Metadata::is_dir),
                size: meta.as_ref().map_or(0, std::fs::Metadata::len),
            });
        }
        // Deterministic order (read_dir order is platform-arbitrary).
        entries.sort_by(|a, b| a.name.cmp(&b.name));
        encode_body(&Resp { entries, truncated })
    }
}

fn unauthorized(text: &str) -> WireError {
    WireError { code: "unauthorized".into(), text: text.into() }
}

fn io_error(text: &str) -> WireError {
    WireError { code: "internal".into(), text: text.into() }
}

fn modified_ms(meta: &std::fs::Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .and_then(|d| i64::try_from(d.as_millis()).ok())
        .unwrap_or(0)
}

fn push_str(out: &mut Vec<u8>, s: &str) {
    out.push(0xa0 | u8::try_from(s.len().min(31)).unwrap_or(31));
    out.extend_from_slice(s.as_bytes());
}

fn decode_body<T: serde::de::DeserializeOwned>(body: &[u8]) -> Result<T, WireError> {
    let mut framed = Vec::with_capacity(body.len().saturating_add(4));
    framed.extend_from_slice(&u32::try_from(body.len()).unwrap_or(u32::MAX).to_le_bytes());
    framed.extend_from_slice(body);
    wire::decode_frame(&framed).map_err(|_| WireError {
        code: "wire_error".into(),
        text: "malformed fs request body".into(),
    })
}

fn encode_body<T: serde::Serialize>(value: &T) -> Result<Vec<u8>, WireError> {
    let framed = wire::encode_frame(value).map_err(|_| WireError {
        code: "wire_error".into(),
        text: "fs response encode failed".into(),
    })?;
    Ok(framed.get(4..).map(<[u8]>::to_vec).unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs as stdfs;

    struct TempRoot {
        path: PathBuf,
    }

    impl TempRoot {
        fn new() -> Self {
            static SEQ: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
            let path = std::env::temp_dir().join(format!(
                "mdv-fs-test-{}-{}",
                std::process::id(),
                SEQ.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
            ));
            let _ = stdfs::remove_dir_all(&path);
            #[allow(clippy::unwrap_used, reason = "test setup")]
            stdfs::create_dir_all(path.join("sub")).unwrap();
            #[allow(clippy::unwrap_used, reason = "test setup")]
            stdfs::write(path.join("a.txt"), b"hello fs family").unwrap();
            #[allow(clippy::unwrap_used, reason = "test setup")]
            stdfs::write(path.join("sub/b.txt"), b"nested").unwrap();
            Self { path }
        }
        fn ctx(&self) -> FsCtx {
            #[allow(clippy::unwrap_used, reason = "test setup")]
            FsCtx::new(Some(self.path.to_str().unwrap())).unwrap()
        }
    }

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = stdfs::remove_dir_all(&self.path);
        }
    }

    fn body<T: serde::Serialize>(v: &T) -> Vec<u8> {
        #[allow(clippy::unwrap_used, reason = "test fixture")]
        let framed = wire::encode_frame(v).unwrap();
        framed.get(4..).map(<[u8]>::to_vec).unwrap_or_default()
    }

    #[derive(serde::Serialize)]
    struct PathReq<'a> {
        path: &'a str,
    }

    #[test]
    fn read_is_windowed_with_total() {
        let root = TempRoot::new();
        let ctx = root.ctx();
        #[derive(serde::Serialize)]
        struct Req<'a> {
            path: &'a str,
            offset: u64,
            len: u64,
        }
        let resp = ctx
            .dispatch("fs.read", &body(&Req { path: "a.txt", offset: 6, len: 2 }))
            .unwrap_or_default();
        // fixmap{total: uint64=15, data: bin "fs"}
        assert!(resp.windows(2).any(|w| w == b"fs"), "window bytes present");
        assert!(resp.contains(&0xc6), "data must ride as bin32");
        // Beyond-EOF offset → empty window, total still reported.
        let resp = ctx
            .dispatch("fs.read", &body(&Req { path: "a.txt", offset: 999, len: 4 }))
            .unwrap_or_default();
        assert!(resp.contains(&0xc6));
        // Oversized window → too_large.
        let err = ctx
            .dispatch("fs.read", &body(&Req { path: "a.txt", offset: 0, len: u64::MAX }))
            .unwrap_err();
        assert_eq!(err.code, "too_large");
    }

    #[test]
    fn containment_blocks_dotdot_and_absolute_escapes() {
        let root = TempRoot::new();
        let ctx = root.ctx();
        for escape in ["../..", "../../etc/passwd", "/etc/passwd", "sub/../../.."] {
            let err = ctx
                .dispatch("fs.read", &body(&ReadReq { path: escape, offset: 0, len: 4 }))
                .unwrap_err();
            assert_eq!(err.code, "unauthorized", "escape '{escape}' must be refused");
        }
        // A contained absolute path (inside the root) is fine.
        let abs = root.path.join("a.txt");
        #[allow(clippy::unwrap_used, reason = "test fixture")]
        let ok = ctx.dispatch(
            "fs.read",
            &body(&ReadReq { path: abs.to_str().unwrap(), offset: 0, len: 5 }),
        );
        assert!(ok.is_ok());
    }

    #[derive(serde::Serialize)]
    struct ReadReq<'a> {
        path: &'a str,
        offset: u64,
        len: u64,
    }

    #[test]
    fn symlink_escape_is_refused() {
        let root = TempRoot::new();
        let ctx = root.ctx();
        let link = root.path.join("escape-link");
        #[allow(clippy::unwrap_used, reason = "test setup")]
        std::os::unix::fs::symlink("/etc", &link).unwrap();
        let err = ctx
            .dispatch("fs.readdir", &body(&PathReq { path: "escape-link" }))
            .unwrap_err();
        assert_eq!(err.code, "unauthorized", "symlink out of root must die at canonicalize");
    }

    #[test]
    fn readdir_lists_sorted_and_stat_answers() {
        let root = TempRoot::new();
        let ctx = root.ctx();
        let resp = ctx
            .dispatch("fs.readdir", &body(&PathReq { path: "." }))
            .unwrap_or_default();
        #[derive(serde::Deserialize)]
        struct Entry {
            name: String,
            is_dir: bool,
        }
        #[derive(serde::Deserialize)]
        struct Resp {
            entries: Vec<Entry>,
            truncated: bool,
        }
        let mut framed = u32::try_from(resp.len()).unwrap_or(0).to_le_bytes().to_vec();
        framed.extend_from_slice(&resp);
        #[allow(clippy::unwrap_used, reason = "test decode")]
        let decoded: Resp = wire::decode_frame(&framed).unwrap();
        assert_eq!(
            decoded.entries.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(),
            vec!["a.txt", "sub"],
            "sorted, complete listing"
        );
        assert!(decoded.entries.iter().any(|e| e.is_dir));
        assert!(!decoded.truncated);

        // stat: existing file, then a missing-but-contained path.
        let ok = ctx.dispatch("fs.stat", &body(&PathReq { path: "a.txt" }));
        assert!(ok.is_ok());
        let missing = ctx.dispatch("fs.stat", &body(&PathReq { path: "nope.txt" }));
        assert!(missing.is_ok(), "missing-inside-root is an ANSWER (exists=false)");
    }

    #[test]
    fn no_root_means_unauthorized() {
        #[allow(clippy::unwrap_used, reason = "test setup")]
        let ctx = FsCtx::new(None).unwrap();
        assert!(!ctx.enabled());
        let err = ctx
            .dispatch("fs.stat", &body(&PathReq { path: "x" }))
            .unwrap_err();
        assert_eq!(err.code, "unauthorized");
    }
}
