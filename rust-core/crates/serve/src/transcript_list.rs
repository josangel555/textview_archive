//! `transcript.list` (TSK-658) — server-side discovery of Claude Code
//! transcripts. The base directory is FIXED (`$HOME/.claude/projects`,
//! `--claude-dir` overrides for tests/deployments): the client supplies NO
//! path input at all, so there is no traversal surface — discovery is "what
//! does THIS server have", nothing else.

use std::path::PathBuf;

use mdvcore_core::wire;

use crate::envelope::WireError;

/// Listing caps: projects × files both bounded (a runaway ~/.claude must
/// not balloon the response).
const MAX_PROJECTS: usize = 512;
const MAX_FILES_PER_PROJECT: usize = 256;

/// The fixed discovery base.
#[derive(Debug, Clone)]
pub struct TranscriptCtx {
    base: PathBuf,
}

impl TranscriptCtx {
    /// `--claude-dir` override, else `$HOME/.claude`.
    #[must_use]
    pub fn new(claude_dir: Option<&str>) -> Self {
        let base = claude_dir.map_or_else(
            || {
                std::env::var_os("HOME")
                    .map(PathBuf::from)
                    .unwrap_or_default()
                    .join(".claude")
            },
            PathBuf::from,
        );
        Self { base: base.join("projects") }
    }

    /// The fixed discovery base (`transcript.follow` resolves its
    /// {dir, name} identifiers against it — TSK-663).
    pub(crate) fn base(&self) -> &std::path::Path {
        &self.base
    }

    /// `transcript.list` — no request body fields in v1.
    pub fn list(&self) -> Result<Vec<u8>, WireError> {
        #[derive(serde::Serialize)]
        struct File {
            name: String,
            size: u64,
            modified_ms: i64,
        }
        #[derive(serde::Serialize)]
        struct Project {
            dir: String,
            files: Vec<File>,
        }
        #[derive(serde::Serialize)]
        struct Resp {
            projects: Vec<Project>,
            truncated: bool,
        }

        let mut projects = Vec::new();
        let mut truncated = false;
        let entries = std::fs::read_dir(&self.base).ok();
        if let Some(entries) = entries {
            for entry in entries.flatten() {
                if projects.len() >= MAX_PROJECTS {
                    truncated = true;
                    break;
                }
                let path = entry.path();
                if !path.is_dir() {
                    continue;
                }
                let mut files = Vec::new();
                if let Ok(children) = std::fs::read_dir(&path) {
                    for child in children.flatten() {
                        if files.len() >= MAX_FILES_PER_PROJECT {
                            truncated = true;
                            break;
                        }
                        let cpath = child.path();
                        if cpath.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                            continue;
                        }
                        let meta = child.metadata().ok();
                        files.push(File {
                            name: child.file_name().to_string_lossy().into_owned(),
                            size: meta.as_ref().map_or(0, std::fs::Metadata::len),
                            modified_ms: meta
                                .as_ref()
                                .and_then(|m| m.modified().ok())
                                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                                .and_then(|d| i64::try_from(d.as_millis()).ok())
                                .unwrap_or(0),
                        });
                    }
                }
                if files.is_empty() {
                    continue; // transcript-less dirs are noise
                }
                files.sort_by(|a, b| b.modified_ms.cmp(&a.modified_ms));
                projects.push(Project {
                    dir: entry.file_name().to_string_lossy().into_owned(),
                    files,
                });
            }
        }
        projects.sort_by(|a, b| a.dir.cmp(&b.dir));

        let framed = wire::encode_frame(&Resp { projects, truncated }).map_err(|_| WireError {
            code: "wire_error".into(),
            text: "transcript.list encode failed".into(),
        })?;
        Ok(framed.get(4..).map(<[u8]>::to_vec).unwrap_or_default())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_only_jsonl_bearing_projects_sorted() {
        static SEQ: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let base = std::env::temp_dir().join(format!(
            "mdv-tlist-{}-{}",
            std::process::id(),
            SEQ.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
        ));
        let projects = base.join("projects");
        #[allow(clippy::unwrap_used, reason = "test setup")]
        {
            std::fs::create_dir_all(projects.join("-Users-a-proj")).unwrap();
            std::fs::create_dir_all(projects.join("-Users-b-empty")).unwrap();
            std::fs::write(projects.join("-Users-a-proj/s1.jsonl"), "{}\n").unwrap();
            std::fs::write(projects.join("-Users-a-proj/notes.txt"), "x").unwrap();
        }
        let ctx = TranscriptCtx::new(base.to_str());
        let resp = ctx.list().unwrap_or_default();

        #[derive(serde::Deserialize)]
        struct File {
            name: String,
        }
        #[derive(serde::Deserialize)]
        struct Project {
            dir: String,
            files: Vec<File>,
        }
        #[derive(serde::Deserialize)]
        struct Resp {
            projects: Vec<Project>,
            truncated: bool,
        }
        let mut framed = u32::try_from(resp.len()).unwrap_or(0).to_le_bytes().to_vec();
        framed.extend_from_slice(&resp);
        #[allow(clippy::unwrap_used, reason = "test decode")]
        let decoded: Resp = wire::decode_frame(&framed).unwrap();
        assert_eq!(decoded.projects.len(), 1, "empty project dirs are dropped");
        assert_eq!(decoded.projects.first().map(|p| p.dir.as_str()), Some("-Users-a-proj"));
        assert_eq!(
            decoded.projects.first().map(|p| p.files.iter().map(|f| f.name.as_str()).collect::<Vec<_>>()),
            Some(vec!["s1.jsonl"]),
            "only .jsonl files listed"
        );
        assert!(!decoded.truncated);
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn missing_base_answers_empty_not_error() {
        let ctx = TranscriptCtx::new(Some("/nonexistent/claude/dir"));
        let resp = ctx.list();
        assert!(resp.is_ok(), "no ~/.claude is an empty answer, not a fault");
    }
}
