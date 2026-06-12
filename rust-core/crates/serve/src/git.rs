//! The git capability family (TSK-657) — host-layer, the repo lives on the
//! server. Spawn discipline mirrors the Swift `GitClient`: the server's
//! `git` binary, NEVER a shell, hard timeout (poll + kill), output cap.
//! `git.head` reads `.git/HEAD` directly (the statusbar-chip feed — cheap
//! enough to poll, no subprocess). Repo paths resolve through the SAME
//! root containment as the fs family; no served root = family disabled.
//!
//! V1 is READ-ONLY by design: no checkout/switch/mutations (client-decided,
//! later, gated), no diff text (composes with the ported diff engine later).

use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use mdvcore_core::wire;

use crate::envelope::WireError;
use crate::fs::FsCtx;

/// Hard subprocess deadline (the Swift GitClient uses 5 s for status).
const GIT_TIMEOUT: Duration = Duration::from_secs(5);
/// Output ceiling — beyond this the child is killed and `truncated` set.
const MAX_GIT_OUTPUT: usize = 1024 * 1024;
/// `git.log` entry ceiling regardless of the requested limit.
const MAX_LOG_ENTRIES: u32 = 500;

/// Dispatch a `git.*` method (the UNFRAMED response body on success).
pub fn dispatch(fs_ctx: &FsCtx, method: &str, body: &[u8]) -> Result<Vec<u8>, WireError> {
    match method {
        "git.head" => head(fs_ctx, body),
        "git.status" => status(fs_ctx, body),
        "git.branches" => branches(fs_ctx, body),
        "git.log" => log(fs_ctx, body),
        _ => Err(WireError {
            code: "unknown_method".into(),
            text: format!("no git method '{method}'"),
        }),
    }
}

#[derive(serde::Deserialize)]
struct RepoReq {
    repo: String,
}

fn head(fs_ctx: &FsCtx, body: &[u8]) -> Result<Vec<u8>, WireError> {
    #[derive(serde::Serialize)]
    struct Resp {
        /// Branch name for an attached HEAD; empty when detached/not a repo.
        branch: String,
        detached: bool,
        /// Detached-HEAD sha (empty for attached — the chip needs the name).
        sha: String,
        is_repo: bool,
    }
    let req: RepoReq = decode_body(body)?;
    let repo = fs_ctx.contained(&req.repo)?;
    let head_path = match git_dir(&repo) {
        Some(dir) => dir.join("HEAD"),
        None => {
            return encode_body(&Resp {
                branch: String::new(),
                detached: false,
                sha: String::new(),
                is_repo: false,
            })
        }
    };
    let content = std::fs::read_to_string(&head_path).unwrap_or_default();
    let line = content.trim();
    let resp = if let Some(r) = line.strip_prefix("ref: refs/heads/") {
        Resp { branch: r.to_owned(), detached: false, sha: String::new(), is_repo: true }
    } else if line.len() >= 40 && line.bytes().all(|b| b.is_ascii_hexdigit()) {
        Resp { branch: String::new(), detached: true, sha: line.to_owned(), is_repo: true }
    } else {
        Resp { branch: String::new(), detached: false, sha: String::new(), is_repo: !line.is_empty() }
    };
    encode_body(&resp)
}

/// Resolve the `.git` directory, following ONE level of worktree
/// indirection (`.git` as a `gitdir: <path>` file).
fn git_dir(repo: &Path) -> Option<std::path::PathBuf> {
    let dot = repo.join(".git");
    if dot.is_dir() {
        return Some(dot);
    }
    if dot.is_file() {
        let content = std::fs::read_to_string(&dot).ok()?;
        let target = content.trim().strip_prefix("gitdir: ")?;
        return Some(std::path::PathBuf::from(target));
    }
    None
}

fn status(fs_ctx: &FsCtx, body: &[u8]) -> Result<Vec<u8>, WireError> {
    #[derive(serde::Serialize)]
    struct Resp {
        lines: Vec<String>,
        truncated: bool,
    }
    let req: RepoReq = decode_body(body)?;
    let repo = fs_ctx.contained(&req.repo)?;
    let (out, truncated) = run_git(&repo, &["status", "--porcelain=v2"])?;
    encode_body(&Resp {
        lines: out.lines().map(str::to_owned).collect(),
        truncated,
    })
}

fn branches(fs_ctx: &FsCtx, body: &[u8]) -> Result<Vec<u8>, WireError> {
    #[derive(serde::Serialize)]
    struct Resp {
        branches: Vec<String>,
        truncated: bool,
    }
    let req: RepoReq = decode_body(body)?;
    let repo = fs_ctx.contained(&req.repo)?;
    let (out, truncated) = run_git(
        &repo,
        &["for-each-ref", "--format=%(refname:short)", "refs/heads/"],
    )?;
    encode_body(&Resp {
        branches: out.lines().map(str::to_owned).collect(),
        truncated,
    })
}

fn log(fs_ctx: &FsCtx, body: &[u8]) -> Result<Vec<u8>, WireError> {
    #[derive(serde::Deserialize)]
    struct Req {
        repo: String,
        limit: u32,
    }
    #[derive(serde::Serialize)]
    struct Resp {
        entries: Vec<String>,
        truncated: bool,
    }
    let req: Req = decode_body(body)?;
    let repo = fs_ctx.contained(&req.repo)?;
    let limit = req.limit.clamp(1, MAX_LOG_ENTRIES);
    let n = format!("-n{limit}");
    let (out, truncated) = run_git(&repo, &["log", "--oneline", "--no-decorate", &n])?;
    encode_body(&Resp {
        entries: out.lines().map(str::to_owned).collect(),
        truncated,
    })
}

/// Spawn the server's git with a hard deadline and output cap. Returns
/// `(stdout_text, truncated)`. The reader thread drains stdout so a
/// chatty child never deadlocks on a full pipe; over-cap output kills
/// the child rather than buffering without bound.
#[allow(
    clippy::disallowed_methods,
    reason = "the determinism lint protects the sans-IO CORE; this is the host \
              layer and the ambient clock IS the subprocess deadline (the same \
              posture as mdv-web's request deadline)"
)]
fn run_git(repo: &Path, args: &[&str]) -> Result<(String, bool), WireError> {
    let mut child = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| WireError { code: "internal".into(), text: format!("spawn git: {e}") })?;

    let Some(mut stdout) = child.stdout.take() else {
        let _ = child.kill();
        let _ = child.wait();
        return Err(WireError { code: "internal".into(), text: "no stdout pipe".into() });
    };
    let reader = std::thread::spawn(move || {
        let mut buf: Vec<u8> = Vec::new();
        let mut chunk = [0u8; 8192];
        let mut truncated = false;
        loop {
            match stdout.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    let room = MAX_GIT_OUTPUT.saturating_sub(buf.len());
                    let take = n.min(room);
                    buf.extend_from_slice(chunk.get(..take).unwrap_or_default());
                    if take < n {
                        truncated = true;
                        break; // stop reading; the killer below reaps the child
                    }
                }
            }
        }
        (buf, truncated)
    });

    let deadline = Instant::now() + GIT_TIMEOUT;
    let mut timed_out = false;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) => {
                if Instant::now() >= deadline {
                    timed_out = true;
                    let _ = child.kill();
                    let _ = child.wait();
                    break;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(_) => break,
        }
    }
    let (buf, mut truncated) = reader.join().unwrap_or_default();
    if timed_out {
        return Err(WireError {
            code: "internal".into(),
            text: format!("git {} timed out after {GIT_TIMEOUT:?}", args.first().unwrap_or(&"?")),
        });
    }
    if buf.len() >= MAX_GIT_OUTPUT {
        truncated = true;
    }
    Ok((String::from_utf8_lossy(&buf).into_owned(), truncated))
}

fn decode_body<T: serde::de::DeserializeOwned>(body: &[u8]) -> Result<T, WireError> {
    let mut framed = Vec::with_capacity(body.len().saturating_add(4));
    framed.extend_from_slice(&u32::try_from(body.len()).unwrap_or(u32::MAX).to_le_bytes());
    framed.extend_from_slice(body);
    wire::decode_frame(&framed).map_err(|_| WireError {
        code: "wire_error".into(),
        text: "malformed git request body".into(),
    })
}

fn encode_body<T: serde::Serialize>(value: &T) -> Result<Vec<u8>, WireError> {
    let framed = wire::encode_frame(value).map_err(|_| WireError {
        code: "wire_error".into(),
        text: "git response encode failed".into(),
    })?;
    Ok(framed.get(4..).map(<[u8]>::to_vec).unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    struct TempRepo {
        path: std::path::PathBuf,
    }

    impl TempRepo {
        fn new() -> Self {
            static SEQ: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
            let path = std::env::temp_dir().join(format!(
                "mdv-git-test-{}-{}",
                std::process::id(),
                SEQ.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
            ));
            let _ = std::fs::remove_dir_all(&path);
            #[allow(clippy::unwrap_used, reason = "test setup")]
            std::fs::create_dir_all(&path).unwrap();
            let git = |args: &[&str]| {
                #[allow(clippy::unwrap_used, reason = "test setup")]
                let st = Command::new("git")
                    .arg("-C")
                    .arg(&path)
                    .args(args)
                    .env("GIT_AUTHOR_NAME", "t")
                    .env("GIT_AUTHOR_EMAIL", "t@t")
                    .env("GIT_COMMITTER_NAME", "t")
                    .env("GIT_COMMITTER_EMAIL", "t@t")
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status()
                    .unwrap();
                assert!(st.success(), "git {args:?} failed");
            };
            git(&["init", "-q", "-b", "main"]);
            #[allow(clippy::unwrap_used, reason = "test setup")]
            std::fs::write(path.join("f.txt"), "one").unwrap();
            git(&["add", "."]);
            git(&["commit", "-q", "-m", "first"]);
            Self { path }
        }
        fn ctx(&self) -> FsCtx {
            #[allow(clippy::unwrap_used, reason = "test setup")]
            FsCtx::new(Some(self.path.to_str().unwrap())).unwrap()
        }
    }

    impl Drop for TempRepo {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    fn body<T: serde::Serialize>(v: &T) -> Vec<u8> {
        #[allow(clippy::unwrap_used, reason = "test fixture")]
        let framed = wire::encode_frame(v).unwrap();
        framed.get(4..).map(<[u8]>::to_vec).unwrap_or_default()
    }

    fn decode<T: serde::de::DeserializeOwned>(unframed: &[u8]) -> T {
        let mut framed = u32::try_from(unframed.len()).unwrap_or(0).to_le_bytes().to_vec();
        framed.extend_from_slice(unframed);
        #[allow(clippy::unwrap_used, reason = "test decode")]
        wire::decode_frame(&framed).unwrap()
    }

    #[derive(serde::Serialize)]
    struct Repo<'a> {
        repo: &'a str,
    }

    #[test]
    fn head_reads_branch_without_subprocess() {
        let repo = TempRepo::new();
        let ctx = repo.ctx();
        #[derive(serde::Deserialize)]
        struct Head {
            branch: String,
            detached: bool,
            is_repo: bool,
        }
        let resp = dispatch(&ctx, "git.head", &body(&Repo { repo: "." })).unwrap_or_default();
        let h: Head = decode(&resp);
        assert_eq!(h.branch, "main");
        assert!(!h.detached);
        assert!(h.is_repo);
    }

    #[test]
    fn status_branches_log_round_trip() {
        let repo = TempRepo::new();
        let ctx = repo.ctx();
        // Dirty the tree so status has a line.
        #[allow(clippy::unwrap_used, reason = "test setup")]
        std::fs::write(repo.path.join("f.txt"), "two").unwrap();

        #[derive(serde::Deserialize)]
        struct Lines {
            lines: Vec<String>,
            truncated: bool,
        }
        let resp = dispatch(&ctx, "git.status", &body(&Repo { repo: "." })).unwrap_or_default();
        let s: Lines = decode(&resp);
        assert!(s.lines.iter().any(|l| l.contains("f.txt")), "dirty file listed: {:?}", s.lines);
        assert!(!s.truncated);

        #[derive(serde::Deserialize)]
        struct Branches {
            branches: Vec<String>,
        }
        let resp = dispatch(&ctx, "git.branches", &body(&Repo { repo: "." })).unwrap_or_default();
        let b: Branches = decode(&resp);
        assert_eq!(b.branches, vec!["main"]);

        #[derive(serde::Serialize)]
        struct LogReq<'a> {
            repo: &'a str,
            limit: u32,
        }
        #[derive(serde::Deserialize)]
        struct Log {
            entries: Vec<String>,
        }
        let resp = dispatch(&ctx, "git.log", &body(&LogReq { repo: ".", limit: 10 }))
            .unwrap_or_default();
        let l: Log = decode(&resp);
        assert_eq!(l.entries.len(), 1);
        assert!(l.entries.first().is_some_and(|e| e.contains("first")));
    }

    #[test]
    fn non_repo_head_answers_is_repo_false() {
        let repo = TempRepo::new();
        // A plain subdir is contained but not a repo.
        #[allow(clippy::unwrap_used, reason = "test setup")]
        std::fs::create_dir_all(repo.path.join("plain")).unwrap();
        let ctx = repo.ctx();
        #[derive(serde::Deserialize)]
        struct Head {
            is_repo: bool,
        }
        let resp = dispatch(&ctx, "git.head", &body(&Repo { repo: "plain" })).unwrap_or_default();
        let h: Head = decode(&resp);
        assert!(!h.is_repo);
    }

    #[test]
    fn containment_and_no_root_refuse() {
        let repo = TempRepo::new();
        let ctx = repo.ctx();
        let err = dispatch(&ctx, "git.head", &body(&Repo { repo: "../.." })).unwrap_err();
        assert_eq!(err.code, "unauthorized");
        #[allow(clippy::unwrap_used, reason = "test setup")]
        let disabled = FsCtx::new(None).unwrap();
        let err = dispatch(&disabled, "git.status", &body(&Repo { repo: "." })).unwrap_err();
        assert_eq!(err.code, "unauthorized");
    }
}
