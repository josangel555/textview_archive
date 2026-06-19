//! `search.files` (TSK-656) — cross-file search over the served root, the
//! remote twin of the Swift `CrossFileSearch`. Reuses the ported
//! [`mdvcore_core::find_engine`] per file (worst-case-linear PikeVM — a
//! hostile remote regex cannot ReDoS the server).
//!
//! Containment BY CONSTRUCTION: the walk starts at the canonical served
//! root and NEVER follows symlinks (kills escapes and cycles in one rule).
//! Bounded single response for v1: per-file size cap, binary sniff, total
//! match + files-walked caps with a `truncated` flag (streaming joins the
//! push loop later).

use std::path::Path;

use mdvcore_core::{find_engine, wire};

use crate::envelope::WireError;
use crate::fs::FsCtx;

/// Files larger than this are skipped (counted in `skipped_large`).
const MAX_FILE_BYTES: u64 = 4 * 1024 * 1024;
/// Total match ceiling across the walk.
const MAX_MATCHES: usize = 1000;
/// Files-walked ceiling (a runaway tree must terminate the walk).
const MAX_FILES: usize = 10_000;
/// Binary sniff window: a NUL in the first 8 KiB ⇒ skip.
const SNIFF_BYTES: usize = 8 * 1024;

/// Directory names never descended into: VCS metadata + dependency / build
/// output trees. These hold thousands of files that are NEVER what a
/// cross-file search wants, and walking them dominates the cost on a real
/// repo (TSK-973). Matched on the directory's own name, case-sensitively
/// (these are the canonical lowercase spellings the ecosystems use).
const SKIP_DIRS: &[&str] = &[
    ".git",
    ".hg",
    ".svn",
    "node_modules",
    "target",       // Rust / sbt build output
    "build",
    "dist",
    ".build",       // SwiftPM build output
    ".next",        // Next.js
    ".venv",
    "venv",
    "__pycache__",
    ".gradle",
    ".idea",
    ".cache",
    ".terraform",
    "vendor",       // Go / PHP vendored deps
];

/// True if a directory name should be skipped wholesale (not descended into).
fn is_skipped_dir(name: &std::ffi::OsStr) -> bool {
    name.to_str().is_some_and(|n| SKIP_DIRS.contains(&n))
}

#[derive(serde::Deserialize)]
struct Req {
    query: String,
    /// "literal" | "regex".
    kind: String,
    case_sensitive: bool,
    whole_word: bool,
}

#[derive(serde::Serialize)]
struct Hit {
    /// Root-relative path.
    path: String,
    line: u32,
    column: u32,
}

#[derive(serde::Serialize)]
struct Resp {
    hits: Vec<Hit>,
    files_with_hits: u32,
    truncated: bool,
    /// Non-empty when the pattern failed to compile (the typed channel —
    /// mirrors the engine's `{error, matches}` shape).
    error: String,
}

/// Dispatch `search.files`.
pub fn dispatch(fs_ctx: &FsCtx, method: &str, body: &[u8]) -> Result<Vec<u8>, WireError> {
    if method != "search.files" {
        return Err(WireError {
            code: "unknown_method".into(),
            text: format!("no search method '{method}'"),
        });
    }
    let req: Req = decode_body(body)?;
    let root = fs_ctx.contained(".")?; // root presence + canonical base
    let kind = match req.kind.as_str() {
        "literal" => find_engine::QueryKind::Literal,
        "regex" => find_engine::QueryKind::Regex,
        other => {
            return encode_body(&Resp {
                hits: Vec::new(),
                files_with_hits: 0,
                truncated: false,
                error: format!("unknown search kind '{other}'"),
            })
        }
    };

    // Compile the user pattern ONCE for the whole walk (TSK-973): the old
    // path called find_engine::search() per file, which re-compiled the
    // regex/literal matcher on every single file. A bad pattern is reported
    // here, once, before walking anything.
    let matcher = match find_engine::CompiledMatcher::compile(
        &req.query,
        kind,
        req.case_sensitive,
        req.whole_word,
    ) {
        Ok(m) => m,
        Err(reason) => {
            return encode_body(&Resp {
                hits: Vec::new(),
                files_with_hits: 0,
                truncated: false,
                error: reason, // the pattern is bad for EVERY file — answer once.
            })
        }
    };

    let mut hits = Vec::new();
    let mut files_with_hits: u32 = 0;
    let mut files_walked = 0usize;
    let mut truncated = false;

    let mut stack = vec![root.clone()];
    'walk: while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            // NEVER follow symlinks — escape + cycle safety in one rule.
            let Ok(meta) = entry.metadata() else { continue };
            let Ok(sym) = std::fs::symlink_metadata(&path) else { continue };
            if sym.file_type().is_symlink() {
                continue;
            }
            if meta.is_dir() {
                // Prune VCS/dependency/build trees wholesale (TSK-973) — they
                // are thousands of files a cross-file search never wants.
                if is_skipped_dir(entry.file_name().as_os_str()) {
                    continue;
                }
                stack.push(path);
                continue;
            }
            files_walked = files_walked.saturating_add(1);
            if files_walked > MAX_FILES {
                truncated = true;
                break 'walk;
            }
            if meta.len() > MAX_FILE_BYTES {
                continue;
            }
            let Ok(bytes) = std::fs::read(&path) else { continue };
            if bytes
                .get(..bytes.len().min(SNIFF_BYTES))
                .is_some_and(|w| w.contains(&0))
            {
                continue; // binary
            }
            let Ok(text) = String::from_utf8(bytes) else { continue };
            let matches = matcher.search_text(&text);
            if !matches.is_empty() {
                files_with_hits = files_with_hits.saturating_add(1);
                let rel = relative_display(&root, &path);
                for m in matches {
                    if hits.len() >= MAX_MATCHES {
                        truncated = true;
                        break 'walk;
                    }
                    hits.push(Hit { path: rel.clone(), line: m.line, column: m.column });
                }
            }
        }
    }

    // Deterministic order (the stack walk is directory-order-arbitrary).
    hits.sort_by(|a, b| a.path.cmp(&b.path).then(a.line.cmp(&b.line)).then(a.column.cmp(&b.column)));
    encode_body(&Resp { hits, files_with_hits, truncated, error: String::new() })
}

fn relative_display(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .to_string_lossy()
        .into_owned()
}

fn decode_body<T: serde::de::DeserializeOwned>(body: &[u8]) -> Result<T, WireError> {
    let mut framed = Vec::with_capacity(body.len().saturating_add(4));
    framed.extend_from_slice(&u32::try_from(body.len()).unwrap_or(u32::MAX).to_le_bytes());
    framed.extend_from_slice(body);
    wire::decode_frame(&framed).map_err(|_| WireError {
        code: "wire_error".into(),
        text: "malformed search request body".into(),
    })
}

fn encode_body<T: serde::Serialize>(value: &T) -> Result<Vec<u8>, WireError> {
    let framed = wire::encode_frame(value).map_err(|_| WireError {
        code: "wire_error".into(),
        text: "search response encode failed".into(),
    })?;
    Ok(framed.get(4..).map(<[u8]>::to_vec).unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    struct TempTree {
        path: PathBuf,
    }

    impl TempTree {
        fn new() -> Self {
            static SEQ: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
            let path = std::env::temp_dir().join(format!(
                "mdv-search-test-{}-{}",
                std::process::id(),
                SEQ.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
            ));
            let _ = std::fs::remove_dir_all(&path);
            #[allow(clippy::unwrap_used, reason = "test setup")]
            {
                std::fs::create_dir_all(path.join("sub")).unwrap();
                std::fs::write(path.join("a.txt"), "needle here\nand a needle again\n").unwrap();
                std::fs::write(path.join("sub/b.txt"), "no match\nneedle deep\n").unwrap();
                std::fs::write(path.join("bin.dat"), b"bin\0needle\0ary").unwrap();
                std::fs::write(path.join("c.txt"), "nothing\n").unwrap();
            }
            Self { path }
        }
        fn ctx(&self) -> FsCtx {
            #[allow(clippy::unwrap_used, reason = "test setup")]
            FsCtx::new(Some(self.path.to_str().unwrap())).unwrap()
        }
    }

    impl Drop for TempTree {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    fn body(query: &str, kind: &str) -> Vec<u8> {
        #[derive(serde::Serialize)]
        struct R<'a> {
            query: &'a str,
            kind: &'a str,
            case_sensitive: bool,
            whole_word: bool,
        }
        #[allow(clippy::unwrap_used, reason = "test fixture")]
        let framed = wire::encode_frame(&R {
            query,
            kind,
            case_sensitive: false,
            whole_word: false,
        })
        .unwrap();
        framed.get(4..).map(<[u8]>::to_vec).unwrap_or_default()
    }

    #[derive(serde::Deserialize)]
    struct Hit {
        path: String,
        line: u32,
    }
    #[derive(serde::Deserialize)]
    struct Resp {
        hits: Vec<Hit>,
        files_with_hits: u32,
        truncated: bool,
        error: String,
    }

    fn run(ctx: &FsCtx, b: &[u8]) -> Resp {
        #[allow(clippy::unwrap_used, reason = "test decode")]
        let out = dispatch(ctx, "search.files", b).unwrap();
        let mut framed = u32::try_from(out.len()).unwrap_or(0).to_le_bytes().to_vec();
        framed.extend_from_slice(&out);
        #[allow(clippy::unwrap_used, reason = "test decode")]
        wire::decode_frame(&framed).unwrap()
    }

    #[test]
    fn finds_across_files_sorted_binary_skipped() {
        let tree = TempTree::new();
        let resp = run(&tree.ctx(), &body("needle", "literal"));
        assert!(resp.error.is_empty());
        assert_eq!(resp.files_with_hits, 2, "binary file must be skipped");
        assert_eq!(
            resp.hits.iter().map(|h| (h.path.as_str(), h.line)).collect::<Vec<_>>(),
            vec![("a.txt", 1), ("a.txt", 2), ("sub/b.txt", 2)],
            "sorted root-relative hits with 1-based lines"
        );
        assert!(!resp.truncated);
    }

    #[test]
    fn regex_and_invalid_pattern_channel() {
        let tree = TempTree::new();
        let resp = run(&tree.ctx(), &body(r"need\w+", "regex"));
        assert!(resp.error.is_empty());
        assert_eq!(resp.hits.len(), 3);
        let resp = run(&tree.ctx(), &body("(unclosed", "regex"));
        assert!(!resp.error.is_empty(), "compile failure rides the error field once");
        assert!(resp.hits.is_empty());
    }

    #[test]
    fn symlinked_dir_is_never_followed() {
        let tree = TempTree::new();
        // A symlink pointing OUTSIDE the root (and one inside, for cycles).
        #[allow(clippy::unwrap_used, reason = "test setup")]
        {
            std::os::unix::fs::symlink("/etc", tree.path.join("outside")).unwrap();
            std::os::unix::fs::symlink(&tree.path, tree.path.join("cycle")).unwrap();
        }
        let resp = run(&tree.ctx(), &body("needle", "literal"));
        // Terminates (no cycle) and finds exactly the in-root hits.
        assert_eq!(resp.files_with_hits, 2);
        assert!(resp.hits.iter().all(|h| !h.path.starts_with("outside")));
    }

    #[test]
    fn skips_vcs_and_dependency_dirs() {
        // TSK-973: a hit inside .git / node_modules / build / target must NOT
        // be returned, while a real source hit at the same depth still is.
        let tree = TempTree::new();
        #[allow(clippy::unwrap_used, reason = "test setup")]
        {
            for d in [".git", "node_modules", "build", "target"] {
                std::fs::create_dir_all(tree.path.join(d)).unwrap();
                std::fs::write(tree.path.join(d).join("hidden.txt"), "needle in junk\n").unwrap();
            }
            // A skipped dir NESTED under a real dir is still skipped.
            std::fs::create_dir_all(tree.path.join("sub/node_modules")).unwrap();
            std::fs::write(
                tree.path.join("sub/node_modules/dep.txt"),
                "needle deep in deps\n",
            )
            .unwrap();
        }
        let resp = run(&tree.ctx(), &body("needle", "literal"));
        assert!(resp.error.is_empty());
        // Baseline tree has 2 real text hits (a.txt + sub/b.txt); the junk dirs
        // add NONE. The teeth: drop is_skipped_dir and this jumps to 6.
        assert_eq!(
            resp.files_with_hits, 2,
            "VCS/dependency/build dirs must be pruned, not searched"
        );
        assert!(
            resp.hits.iter().all(|h| {
                !h.path.contains(".git")
                    && !h.path.contains("node_modules")
                    && !h.path.contains("build")
                    && !h.path.contains("target")
            }),
            "no hit may come from a pruned directory: {:?}",
            resp.hits.iter().map(|h| &h.path).collect::<Vec<_>>()
        );
    }

    #[test]
    fn skip_dirs_only_match_whole_name_not_prefix() {
        // "buildkite" is NOT "build" — a real dir whose name merely starts with
        // a skip token must still be searched.
        let tree = TempTree::new();
        #[allow(clippy::unwrap_used, reason = "test setup")]
        {
            std::fs::create_dir_all(tree.path.join("buildkite")).unwrap();
            std::fs::write(tree.path.join("buildkite/ci.txt"), "needle in ci\n").unwrap();
        }
        let resp = run(&tree.ctx(), &body("needle", "literal"));
        assert_eq!(
            resp.files_with_hits, 3,
            "a dir merely prefixed with a skip token (buildkite) must NOT be pruned"
        );
        assert!(resp.hits.iter().any(|h| h.path.starts_with("buildkite")));
    }

    #[test]
    fn no_root_refuses() {
        #[allow(clippy::unwrap_used, reason = "test setup")]
        let ctx = FsCtx::new(None).unwrap();
        let err = dispatch(&ctx, "search.files", &body("x", "literal")).unwrap_err();
        assert_eq!(err.code, "unauthorized");
    }
}
