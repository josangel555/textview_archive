//! Unified-diff parser — the Rust port of the Swift `DiffParser` /
//! `UnifiedDiff` (migration plan slice #3). Pure, sans-IO. Only the PARSING
//! moves here; the `git diff` subprocess that produces the text stays Swift.
//!
//! Faithful to the Swift contract (the A/B test pins it byte-for-byte): tolerant
//! of a `git show` prefix, multi-file, rename/copy/binary metadata, the
//! 4-strategy `diff --git` path split (quoted form → equal-prefix same-file →
//! last ` b/` → first-space), and hunk-coordinate clamping to a sane ceiling.

use serde::{Deserialize, Serialize};

/// A diff line's kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LineKind {
    /// Unchanged context line (` ` prefix).
    Context,
    /// Added line (`+`).
    Added,
    /// Removed line (`-`).
    Removed,
    /// `\ No newline at end of file` marker.
    NoNewline,
}

/// One diff line, with resolved old/new line numbers (`None` where N/A).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Line {
    /// The line's kind (context / added / removed / no-newline marker).
    pub kind: LineKind,
    /// 1-based line number in the OLD file (`None` for added lines).
    pub old_line_no: Option<i64>,
    /// 1-based line number in the NEW file (`None` for removed lines).
    pub new_line_no: Option<i64>,
    /// Content without the `+`/`-`/space prefix.
    pub content: String,
}

/// One hunk: `@@ -old_start,old_count +new_start,new_count @@ header`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Hunk {
    /// Old-file start line (clamped to `0..=MAX_COORD`).
    pub old_start: i64,
    /// Old-file line count (defaults to 1 when omitted in the header).
    pub old_count: i64,
    /// New-file start line.
    pub new_start: i64,
    /// New-file line count.
    pub new_count: i64,
    /// Context tail after the second `@@`.
    pub header: String,
    /// The hunk's lines in order.
    pub lines: Vec<Line>,
}

/// One file's diff.
#[allow(
    clippy::struct_excessive_bools,
    reason = "the four flags are independent facts (a file may be both binary and renamed) and mirror the Swift UnifiedDiff.File wire type 1:1"
)]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct File {
    /// Old path, without the `a/` prefix.
    pub old_path: String,
    /// New path, without the `b/` prefix.
    pub new_path: String,
    /// `new file mode …` was seen.
    pub is_new: bool,
    /// `deleted file mode …` was seen.
    pub is_deleted: bool,
    /// `Binary files … differ` was seen.
    pub is_binary: bool,
    /// A rename/copy was seen (paths differ, not a pure add/delete).
    pub is_rename: bool,
    /// The file's hunks in order.
    pub hunks: Vec<Hunk>,
}

/// Upper bound on a parsed hunk start/count (mirrors `DiffParser.maxCoord`).
const MAX_COORD: i64 = 1_000_000_000;

/// Parse a full unified diff (possibly multi-file). Tolerant of a `git show`
/// prefix before the first `diff --git`.
#[must_use]
pub fn parse(text: &str) -> Vec<File> {
    let mut files: Vec<File> = Vec::new();
    let mut current: Option<PartialFile> = None;
    let mut current_hunk: Option<PartialHunk> = None;

    // split('\n') keeps empty subsequences (matches Swift
    // omittingEmptySubsequences:false), incl. the trailing "" after a final \n.
    for raw in text.split('\n') {
        // -- file boundary --
        if let Some(rest) = raw.strip_prefix("diff --git ") {
            flush_hunk(&mut current, &mut current_hunk);
            flush(&mut files, &mut current);
            let (a, b) = parse_diff_git_paths(rest);
            current = Some(PartialFile::new(a, b));
            continue;
        }
        let Some(file) = current.as_mut() else {
            // No "diff --git" yet — `git show` header; skip.
            continue;
        };
        // -- file metadata --
        if raw.starts_with("new file mode ") {
            file.is_new = true;
            continue;
        }
        if raw.starts_with("deleted file mode ") {
            file.is_deleted = true;
            continue;
        }
        if let Some(p) = raw.strip_prefix("rename from ") {
            file.is_rename = true;
            file.old_path = p.to_string();
            continue;
        }
        if let Some(p) = raw.strip_prefix("rename to ") {
            file.is_rename = true;
            file.new_path = p.to_string();
            continue;
        }
        if raw.starts_with("copy from ")
            || raw.starts_with("copy to ")
            || raw.starts_with("similarity index ")
            || raw.starts_with("dissimilarity index ")
            || raw.starts_with("index ")
            || raw.starts_with("old mode ")
            || raw.starts_with("new mode ")
        {
            continue;
        }
        if raw.starts_with("Binary files ") {
            file.is_binary = true;
            continue;
        }
        if let Some(p) = raw.strip_prefix("--- ") {
            let p = strip_path_prefix(p);
            if p != "/dev/null" && !file.is_rename {
                file.old_path = p;
            }
            continue;
        }
        if let Some(p) = raw.strip_prefix("+++ ") {
            let p = strip_path_prefix(p);
            if p != "/dev/null" && !file.is_rename {
                file.new_path = p;
            }
            continue;
        }
        // -- hunk header --
        if raw.starts_with("@@") {
            flush_hunk(&mut current, &mut current_hunk);
            if let Some(h) = parse_hunk_header(raw) {
                current_hunk = Some(h);
            }
            continue;
        }
        // -- hunk body --
        let Some(hunk) = current_hunk.as_mut() else { continue };
        if raw.is_empty() {
            hunk.append(LineKind::Context, "");
            continue;
        }
        match raw.as_bytes().first() {
            Some(b' ') => hunk.append(LineKind::Context, &raw[1..]),
            Some(b'+') => hunk.append(LineKind::Added, &raw[1..]),
            Some(b'-') => hunk.append(LineKind::Removed, &raw[1..]),
            Some(b'\\') => hunk.append(LineKind::NoNewline, &raw[1..]),
            // Tolerate unknown prefixes (e.g. combined diff): whole line as context.
            _ => hunk.append(LineKind::Context, raw),
        }
    }

    flush_hunk(&mut current, &mut current_hunk);
    flush(&mut files, &mut current);
    files
}

fn flush_hunk(file: &mut Option<PartialFile>, hunk: &mut Option<PartialHunk>) {
    if let (Some(h), Some(f)) = (hunk.take(), file.as_mut()) {
        f.hunks.push(h.materialize());
    }
}

fn flush(files: &mut Vec<File>, partial: &mut Option<PartialFile>) {
    if let Some(p) = partial.take() {
        files.push(p.materialize());
    }
}

/// `a/old b/new` (the text after `diff --git `) → (`old`, `new`). Mirrors the
/// Swift 4-strategy splitter.
fn parse_diff_git_paths(rest: &str) -> (String, String) {
    // (1) Quoted form: `"a/…" "b/…"`.
    if rest.starts_with('"') {
        if let Some(mid) = rest.find("\" \"") {
            let a = &rest[..mid];
            let b = &rest[mid + 3..];
            let bs = b.strip_suffix('"').unwrap_or(b);
            return (strip_path_prefix(&format!("{a}\"")), strip_path_prefix(bs));
        }
    }
    // (2) Equal-prefix same-file case: a ` b/` where the prefix is `a/PATH` and
    // the suffix equals `PATH`.
    for (idx, _) in rest.match_indices(" b/") {
        let a_part = &rest[..idx];
        let b_part = &rest[idx + 3..];
        if let Some(a_path) = a_part.strip_prefix("a/") {
            if a_path == b_part {
                return (a_path.to_string(), b_part.to_string());
            }
        }
    }
    // (3) Rename / asymmetric — fall back to the LAST ` b/`.
    if let Some(idx) = rest.rfind(" b/") {
        let a = &rest[..idx];
        let b = &rest[idx + 3..];
        return (strip_path_prefix(a), b.to_string());
    }
    // (4) Last resort: split at first space.
    if let Some(sp) = rest.find(' ') {
        return (strip_path_prefix(&rest[..sp]), strip_path_prefix(&rest[sp + 1..]));
    }
    (rest.to_string(), rest.to_string())
}

/// Strip leading `a/`/`b/`, surrounding quotes, surrounding whitespace.
fn strip_path_prefix(s: &str) -> String {
    let mut t = s.trim().to_string();
    if t.starts_with('"') && t.ends_with('"') && t.len() >= 2 {
        t = t[1..t.len() - 1].to_string();
    }
    if let Some(rest) = t.strip_prefix("a/").or_else(|| t.strip_prefix("b/")) {
        t = rest.to_string();
    }
    t
}

/// Parse `@@ -10,5 +12,7 @@ tail`.
fn parse_hunk_header(raw: &str) -> Option<PartialHunk> {
    let first = raw.find("@@")?;
    let after_first = first + 2;
    let second_rel = raw[after_first..].find("@@")?;
    let second = after_first + second_rel;
    let coords = raw[after_first..second].trim();
    // "-10,5 +12,7" or "-10 +12".
    let parts: Vec<&str> = coords.split(' ').filter(|s| !s.is_empty()).collect();
    let [old_part, new_part] = parts.as_slice() else {
        return None;
    };
    if !old_part.starts_with('-') || !new_part.starts_with('+') {
        return None;
    }
    let (old_start, old_count) = parse_coord(old_part.get(1..).unwrap_or(""));
    let (new_start, new_count) = parse_coord(new_part.get(1..).unwrap_or(""));
    let tail = raw[second + 2..].trim().to_string();
    Some(PartialHunk::new(old_start, old_count, new_start, new_count, tail))
}

fn parse_coord(s: &str) -> (i64, i64) {
    let mut parts = s.split(',');
    let raw_start: i64 = parts.next().and_then(|p| p.parse().ok()).unwrap_or(0);
    // A present-but-unparsable count defaults to 1 (matches the Swift parser);
    // an absent count (no comma) also defaults to 1.
    let raw_count: i64 = parts.next().map_or(1, |p| p.parse().unwrap_or(1));
    (raw_start.clamp(0, MAX_COORD), raw_count.clamp(0, MAX_COORD))
}

// MARK: - Builders

#[allow(
    clippy::struct_excessive_bools,
    reason = "mutable mirror of File during the parse; same four independent flags"
)]
struct PartialFile {
    old_path: String,
    new_path: String,
    is_new: bool,
    is_deleted: bool,
    is_binary: bool,
    is_rename: bool,
    hunks: Vec<Hunk>,
}

impl PartialFile {
    fn new(old_path: String, new_path: String) -> Self {
        Self {
            old_path,
            new_path,
            is_new: false,
            is_deleted: false,
            is_binary: false,
            is_rename: false,
            hunks: Vec::new(),
        }
    }
    fn materialize(self) -> File {
        File {
            old_path: self.old_path,
            new_path: self.new_path,
            is_new: self.is_new,
            is_deleted: self.is_deleted,
            is_binary: self.is_binary,
            is_rename: self.is_rename,
            hunks: self.hunks,
        }
    }
}

struct PartialHunk {
    old_start: i64,
    old_count: i64,
    new_start: i64,
    new_count: i64,
    header: String,
    lines: Vec<Line>,
    old_cursor: i64,
    new_cursor: i64,
}

impl PartialHunk {
    fn new(old_start: i64, old_count: i64, new_start: i64, new_count: i64, header: String) -> Self {
        Self {
            old_start,
            old_count,
            new_start,
            new_count,
            header,
            lines: Vec::new(),
            old_cursor: old_start,
            new_cursor: new_start,
        }
    }

    fn append(&mut self, kind: LineKind, content: &str) {
        match kind {
            LineKind::Context => {
                self.lines.push(Line {
                    kind: LineKind::Context,
                    old_line_no: Some(self.old_cursor),
                    new_line_no: Some(self.new_cursor),
                    content: content.to_string(),
                });
                self.old_cursor += 1;
                self.new_cursor += 1;
            }
            LineKind::Added => {
                self.lines.push(Line {
                    kind: LineKind::Added,
                    old_line_no: None,
                    new_line_no: Some(self.new_cursor),
                    content: content.to_string(),
                });
                self.new_cursor += 1;
            }
            LineKind::Removed => {
                self.lines.push(Line {
                    kind: LineKind::Removed,
                    old_line_no: Some(self.old_cursor),
                    new_line_no: None,
                    content: content.to_string(),
                });
                self.old_cursor += 1;
            }
            LineKind::NoNewline => {
                self.lines.push(Line {
                    kind: LineKind::NoNewline,
                    old_line_no: None,
                    new_line_no: None,
                    content: content.to_string(),
                });
            }
        }
    }

    fn materialize(self) -> Hunk {
        Hunk {
            old_start: self.old_start,
            old_count: self.old_count,
            new_start: self.new_start,
            new_count: self.new_count,
            header: self.header,
            lines: self.lines,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_input_no_files() {
        assert!(parse("").is_empty());
        assert!(parse("commit abc\nAuthor: x\n\n    msg\n").is_empty());
    }

    #[test]
    fn single_file_one_hunk() {
        let d = "diff --git a/foo.txt b/foo.txt\n\
                 index e69de29..4b825dc 100644\n\
                 --- a/foo.txt\n\
                 +++ b/foo.txt\n\
                 @@ -1,2 +1,3 @@ fn main\n\
                 \x20context\n\
                 -removed\n\
                 +added1\n\
                 +added2\n";
        let files = parse(d);
        assert_eq!(files.len(), 1);
        let f = &files[0];
        assert_eq!(f.old_path, "foo.txt");
        assert_eq!(f.new_path, "foo.txt");
        assert!(!f.is_new && !f.is_deleted && !f.is_binary && !f.is_rename);
        assert_eq!(f.hunks.len(), 1);
        let h = &f.hunks[0];
        assert_eq!((h.old_start, h.old_count, h.new_start, h.new_count), (1, 2, 1, 3));
        assert_eq!(h.header, "fn main");
        // line numbers track cursors.
        assert_eq!(h.lines[0], Line { kind: LineKind::Context, old_line_no: Some(1), new_line_no: Some(1), content: "context".into() });
        assert_eq!(h.lines[1], Line { kind: LineKind::Removed, old_line_no: Some(2), new_line_no: None, content: "removed".into() });
        assert_eq!(h.lines[2], Line { kind: LineKind::Added, old_line_no: None, new_line_no: Some(2), content: "added1".into() });
        assert_eq!(h.lines[3], Line { kind: LineKind::Added, old_line_no: None, new_line_no: Some(3), content: "added2".into() });
    }

    #[test]
    fn new_and_deleted_flags() {
        let d = "diff --git a/n.txt b/n.txt\nnew file mode 100644\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1 @@\n+hi\n";
        let f = &parse(d)[0];
        assert!(f.is_new);
        assert_eq!(f.new_path, "n.txt");
        // --- /dev/null must NOT overwrite old_path.
        assert_eq!(f.old_path, "n.txt"); // from the diff --git line
    }

    #[test]
    fn rename_keeps_both_paths() {
        let d = "diff --git a/old.txt b/new.txt\nsimilarity index 95%\nrename from old.txt\nrename to new.txt\n";
        let f = &parse(d)[0];
        assert!(f.is_rename);
        assert_eq!(f.old_path, "old.txt");
        assert_eq!(f.new_path, "new.txt");
    }

    #[test]
    fn binary_file() {
        let d = "diff --git a/img.png b/img.png\nindex 1..2 100644\nBinary files a/img.png and b/img.png differ\n";
        let f = &parse(d)[0];
        assert!(f.is_binary);
    }

    #[test]
    fn multi_file() {
        let d = "diff --git a/a.txt b/a.txt\n@@ -1 +1 @@\n-x\n+y\n\
                 diff --git a/b.txt b/b.txt\n@@ -1 +1 @@\n-p\n+q\n";
        let files = parse(d);
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].new_path, "a.txt");
        assert_eq!(files[1].new_path, "b.txt");
    }

    #[test]
    fn path_with_spaces_same_file() {
        // Strategy (2): equal prefix wins even with spaces in the path.
        let (a, b) = parse_diff_git_paths("a/foo bar.txt b/foo bar.txt");
        assert_eq!(a, "foo bar.txt");
        assert_eq!(b, "foo bar.txt");
    }

    #[test]
    fn path_quoted_form() {
        let (a, b) = parse_diff_git_paths("\"a/wei\\303\\237.txt\" \"b/wei\\303\\237.txt\"");
        assert_eq!(a, "wei\\303\\237.txt");
        assert_eq!(b, "wei\\303\\237.txt");
    }

    #[test]
    fn hunk_header_count_omitted_defaults_to_one() {
        let h = parse_hunk_header("@@ -5 +7 @@").unwrap();
        assert_eq!((h.old_start, h.old_count, h.new_start, h.new_count), (5, 1, 7, 1));
    }

    #[test]
    fn coord_clamps_garbage() {
        // Negative / overflow seeds clamp to the sane range.
        assert_eq!(parse_coord("-5,3"), (0, 3));
        assert_eq!(parse_coord("99999999999999999999,1"), (0, 1)); // unparseable -> 0
        let (s, c) = parse_coord("2000000000,1");
        assert_eq!((s, c), (1_000_000_000, 1)); // clamped to MAX_COORD
    }

    #[test]
    fn no_newline_marker() {
        // No trailing '\n' so the marker is the last line (a trailing newline
        // would split into an extra empty context line — faithful to Swift's
        // omittingEmptySubsequences:false; verified separately below).
        let d = "diff --git a/f b/f\n@@ -1 +1 @@\n-a\n+b\n\\ No newline at end of file";
        let lines = &parse(d)[0].hunks[0].lines;
        assert_eq!(lines.last().unwrap().kind, LineKind::NoNewline);
        assert_eq!(lines.last().unwrap().old_line_no, None);
    }

    #[test]
    fn trailing_newline_adds_empty_context_line() {
        // A final '\n' yields a trailing empty context line (matches Swift).
        let d = "diff --git a/f b/f\n@@ -1 +1 @@\n-a\n+b\n";
        let lines = &parse(d)[0].hunks[0].lines;
        assert_eq!(lines.last().unwrap().kind, LineKind::Context);
        assert_eq!(lines.last().unwrap().content, "");
    }

    #[test]
    fn empty_line_is_context() {
        // A blank body line counts as a context line (content "").
        let d = "diff --git a/f b/f\n@@ -1,2 +1,2 @@\n a\n\n";
        let lines = &parse(d)[0].hunks[0].lines;
        assert_eq!(lines[1], Line { kind: LineKind::Context, old_line_no: Some(2), new_line_no: Some(2), content: "".into() });
    }
}
