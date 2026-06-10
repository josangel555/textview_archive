//! Pure parsing of `git status --porcelain=v1 --branch` output into a compact,
//! renderable [`RepoStatus`] summary shared by all three front-ends.
//!
//! **No process spawning here.** The core is sans-IO: a front-end invokes `git`
//! (the I/O), then hands the raw stdout to [`parse_status`]. Keeping the parse in
//! the core makes it host-testable with real merge-gate teeth, and guarantees the
//! TUI and web tiers compute IDENTICAL summaries from the same bytes — the
//! "one core, three front-ends" rule.
//!
//! Porcelain v1 line shapes consumed:
//! ```text
//! ## main...origin/main [ahead 1, behind 2]   <- branch header (with --branch)
//! ## No commits yet on main                    <- fresh repo, no commits
//! ## HEAD (no branch)                          <- detached HEAD
//!  M src/lib.rs        XY entry: X=index(staged) Y=work-tree(unstaged)
//! M  Cargo.toml        staged modification
//! ?? scratch.txt       untracked
//! UU merge.rs          unmerged / conflicted
//! ```

/// A one-glance summary of a working tree's git state, derived from
/// `git status --porcelain=v1 --branch`. All counts are file counts.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RepoStatus {
    /// Current branch name (e.g. `"main"`), or `None` when detached / unknown.
    pub branch: Option<String>,
    /// Commits ahead of the upstream (`[ahead N]` in the branch header).
    pub ahead: usize,
    /// Commits behind the upstream (`[behind N]`).
    pub behind: usize,
    /// Files with staged (index-side) changes.
    pub staged: usize,
    /// Tracked files with unstaged (work-tree-side) changes.
    pub modified: usize,
    /// Untracked files (`??`).
    pub untracked: usize,
    /// Unmerged / conflicted paths.
    pub conflicted: usize,
}

impl RepoStatus {
    /// `true` when nothing is staged, modified, untracked, or conflicted — i.e.
    /// the working tree is clean (ahead/behind do not count as "dirty").
    #[must_use]
    pub fn is_clean(&self) -> bool {
        self.staged == 0 && self.modified == 0 && self.untracked == 0 && self.conflicted == 0
    }

    /// A compact, color-free label, e.g. `"main ↑1↓2 +3 ~1 ?4 !1"` or `"main ✓"`.
    /// Only non-zero segments are emitted; the glyphs (not color) carry meaning so
    /// a colorless TUI snapshot can assert on them. A detached HEAD with no branch
    /// drops the leading name.
    #[must_use]
    pub fn summary(&self) -> String {
        let mut out = String::new();
        if let Some(b) = &self.branch {
            out.push_str(b);
        } else {
            out.push_str("detached");
        }
        if self.ahead > 0 {
            out.push_str(&format!(" ↑{}", self.ahead));
        }
        if self.behind > 0 {
            out.push_str(&format!(" ↓{}", self.behind));
        }
        if self.is_clean() {
            out.push_str(" ✓");
            return out;
        }
        if self.staged > 0 {
            out.push_str(&format!(" +{}", self.staged));
        }
        if self.modified > 0 {
            out.push_str(&format!(" ~{}", self.modified));
        }
        if self.untracked > 0 {
            out.push_str(&format!(" ?{}", self.untracked));
        }
        if self.conflicted > 0 {
            out.push_str(&format!(" !{}", self.conflicted));
        }
        out
    }
}

/// Two-letter unmerged status codes (porcelain v1). Any entry whose XY equals one
/// of these — or whose X or Y is `U` — is a conflict, NOT a staged/unstaged edit.
const UNMERGED: [&str; 7] = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"];

/// Parse `git status --porcelain=v1 --branch` stdout into a [`RepoStatus`].
///
/// Tolerant by design: a missing branch header, blank lines, and unknown trailing
/// content are ignored rather than erroring. Counting mirrors `git status`:
/// a single path can be both staged AND modified (e.g. `MM`) and is counted in
/// both; `??` is untracked; unmerged codes are conflicts.
#[must_use]
pub fn parse_status(porcelain: &str) -> RepoStatus {
    let mut st = RepoStatus::default();
    for line in porcelain.lines() {
        if let Some(rest) = line.strip_prefix("## ") {
            parse_branch_header(rest, &mut st);
            continue;
        }
        // An XY entry needs the 2-char code, a separator, and a path.
        let Some(code) = line.get(..2) else { continue };
        if line.len() < 3 {
            continue;
        }
        if code == "??" {
            st.untracked = st.untracked.saturating_add(1);
            continue;
        }
        if UNMERGED.contains(&code) || code.starts_with('U') || code.ends_with('U') {
            st.conflicted = st.conflicted.saturating_add(1);
            continue;
        }
        let mut chars = code.chars();
        let x = chars.next().unwrap_or(' ');
        let y = chars.next().unwrap_or(' ');
        if x != ' ' && x != '?' {
            st.staged = st.staged.saturating_add(1);
        }
        if y != ' ' && y != '?' {
            st.modified = st.modified.saturating_add(1);
        }
    }
    st
}

/// Parse the text after `"## "` in the branch header into `st.branch`/ahead/behind.
fn parse_branch_header(rest: &str, st: &mut RepoStatus) {
    // Detached: "HEAD (no branch)" → leave branch None.
    if rest.starts_with("HEAD (no branch)") {
        return;
    }
    // Fresh repo: "No commits yet on <branch>".
    if let Some(b) = rest.strip_prefix("No commits yet on ") {
        st.branch = Some(b.trim().to_string());
        return;
    }
    // "<branch>...<upstream> [ahead N, behind M]" or just "<branch>".
    // Branch name ends at the first "..." (upstream marker) or whitespace.
    let head = rest.split("...").next().unwrap_or(rest);
    let name = head.split_whitespace().next().unwrap_or("").trim();
    if !name.is_empty() {
        st.branch = Some(name.to_string());
    }
    // Ahead/behind live inside the trailing "[...]" bracket; absent on a tracking
    // branch with no divergence (or a branch with no upstream).
    if let Some(open) = rest.find('[')
        && let Some(seg) = rest.get(open..) {
            st.ahead = bracket_count(seg, "ahead ");
            st.behind = bracket_count(seg, "behind ");
        }
}

/// Extract the integer following `key` (e.g. `"ahead "`) within the bracket
/// segment, reading consecutive ASCII digits. Returns 0 when the key is absent
/// or not followed by a number.
fn bracket_count(seg: &str, key: &str) -> usize {
    let Some(after) = seg.split(key).nth(1) else { return 0 };
    let digits: String = after.chars().take_while(char::is_ascii_digit).collect();
    digits.parse().unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_tracking_branch_reports_branch_ahead_behind_and_clean() {
        let st = parse_status("## main...origin/main [ahead 1, behind 2]\n");
        assert_eq!(st.branch.as_deref(), Some("main"));
        assert_eq!(st.ahead, 1);
        assert_eq!(st.behind, 2);
        assert!(st.is_clean(), "no entry lines ⇒ clean");
        assert_eq!(st.summary(), "main ↑1 ↓2 ✓");
    }

    #[test]
    fn counts_staged_modified_untracked_and_conflicted_distinctly() {
        // M_=staged, _M=modified, MM=both, ??=untracked, UU=conflict, A_=staged add.
        let porcelain = "\
## feature
M  staged.rs
 M modified.rs
MM both.rs
A  added.rs
?? new.txt
UU conflict.rs
";
        let st = parse_status(porcelain);
        assert_eq!(st.branch.as_deref(), Some("feature"));
        assert_eq!(st.staged, 3, "M , MM, A  are staged");
        assert_eq!(st.modified, 2, " M and MM are unstaged-modified");
        assert_eq!(st.untracked, 1);
        assert_eq!(st.conflicted, 1);
        assert!(!st.is_clean());
        assert_eq!(st.summary(), "feature +3 ~2 ?1 !1");
    }

    #[test]
    fn fresh_repo_no_commits_yet_extracts_branch() {
        let st = parse_status("## No commits yet on main\n?? README.md\n");
        assert_eq!(st.branch.as_deref(), Some("main"));
        assert_eq!(st.untracked, 1);
    }

    #[test]
    fn detached_head_has_no_branch() {
        let st = parse_status("## HEAD (no branch)\n M x.rs\n");
        assert_eq!(st.branch, None);
        assert_eq!(st.modified, 1);
        assert_eq!(st.summary(), "detached ~1");
    }

    #[test]
    fn branch_without_upstream_has_no_ahead_behind() {
        let st = parse_status("## solo\n");
        assert_eq!(st.branch.as_deref(), Some("solo"));
        assert_eq!(st.ahead, 0);
        assert_eq!(st.behind, 0);
        assert_eq!(st.summary(), "solo ✓");
    }

    #[test]
    fn ahead_only_and_behind_only_parse_independently() {
        let ahead = parse_status("## a...o/a [ahead 5]\n");
        assert_eq!((ahead.ahead, ahead.behind), (5, 0));
        let behind = parse_status("## b...o/b [behind 3]\n");
        assert_eq!((behind.ahead, behind.behind), (0, 3));
    }

    #[test]
    fn empty_and_garbage_input_is_clean_and_unbranched() {
        let st = parse_status("");
        assert_eq!(st, RepoStatus::default());
        // A stray short line (< 3 chars) must not panic or miscount.
        let st2 = parse_status("?\nx\n");
        assert!(st2.is_clean());
    }

    #[test]
    fn unmerged_variants_all_count_as_conflicts_not_edits() {
        let st = parse_status("## m\nDD a\nAU b\nUD c\nUA d\nDU e\nAA f\nUU g\n");
        assert_eq!(st.conflicted, 7);
        assert_eq!(st.staged, 0);
        assert_eq!(st.modified, 0);
    }
}
