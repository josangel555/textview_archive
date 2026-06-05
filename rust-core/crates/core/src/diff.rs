//! Unified-diff parser — the Rust port of the Swift `DiffParser` /
//! `UnifiedDiff` (migration plan slice #3). Pure, sans-IO. Only the PARSING
//! moves here; the `git diff` subprocess that produces the text stays Swift.
//!
//! Faithful to the Swift contract (the A/B test pins it byte-for-byte): tolerant
//! of a `git show` prefix, multi-file, rename/copy/binary metadata, the
//! 4-strategy `diff --git` path split (quoted form → equal-prefix same-file →
//! last ` b/` → first-space), and hunk-coordinate clamping to a sane ceiling.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

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
    // (4) Last resort: split at first space. Mirror Swift's
    // `rest.split(separator: " ", maxSplits: 1)`, whose default
    // `omittingEmptySubsequences: true` drops leading/empty space tokens — so
    // trim leading spaces before the first-space split (Swift collapses the
    // leading empties without spending the single split), then drop any
    // residual empty token. Only when fewer than two tokens remain do we fall
    // back to `(rest, rest)`, using the ORIGINAL `rest` (Swift returns the
    // untrimmed input on that path).
    let tokens: Vec<&str> = rest
        .trim_start_matches(' ')
        .splitn(2, ' ')
        .filter(|t| !t.is_empty())
        .collect();
    if let [a, b] = tokens.as_slice() {
        return (strip_path_prefix(a), strip_path_prefix(b));
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
    // Mirror Swift `s.split(separator: ",")`, whose default
    // `omittingEmptySubsequences: true` drops leading/empty pieces — so an
    // absent or empty start and an absent count both fall back identically.
    let mut parts = s.split(',').filter(|p| !p.is_empty());
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

// MARK: - Wire seam (stateless FFI request/response)

/// Request payload: the raw unified-diff text. Deserialized from the MessagePack
/// named-map frame the Swift side builds (matching `to_vec_named`).
#[derive(Serialize, Deserialize)]
struct ParseRequest {
    text: String,
}

/// Response payload: the parsed files (the full structured diff). `File`/`Hunk`/
/// `Line` already derive `Serialize`, so they ride the wire as named maps.
#[derive(Serialize, Deserialize)]
struct ParseResponse {
    files: Vec<File>,
}

/// Stateless wire seam for the FFI shim `mdvcore_diff_parse`: decode a
/// length-prefixed MessagePack request frame `{text}`, parse the unified diff,
/// and encode a `{files:[…]}` response frame. Pure + sans-IO, so it is fully
/// cargo-testable without the C edge; the FFI layer adds only the pointer/
/// `MdvBuf`/panic-guard plumbing.
///
/// # Errors
/// [`crate::wire::WireFault`] on a malformed/oversized request frame or an
/// encode failure. (A diff that parses to zero files is NOT an error — it
/// returns Ok with `files: []`.)
pub fn parse_wire(req_frame: &[u8]) -> Result<Vec<u8>, crate::wire::WireFault> {
    let req: ParseRequest = crate::wire::decode_frame(req_frame)?;
    let files = parse(&req.text);
    crate::wire::encode_frame(&ParseResponse { files })
}

// MARK: - Per-line gutter marks (port of Swift DiffHunkParser)

/// Per-working-tree-line diff status (mirrors Swift `DiffMark`). Unlike the
/// structured [`parse`], this flattens a diff to a `line → mark` map the
/// source-view gutter renders against; keys are 1-based line numbers in the file
/// *as it stands on disk* (the new side).
#[derive(Serialize, Deserialize, PartialEq, Eq, Clone, Copy, Debug)]
#[serde(rename_all = "lowercase")]
pub enum DiffMark {
    /// New line in the working tree (didn't exist at HEAD).
    Added,
    /// Line existed at HEAD but its content changed (a `-` immediately followed
    /// by a `+` at the same new-side position).
    Modified,
    /// The working-tree line just after a deletion — the gutter tick that signals
    /// lines were removed above (the deleted line itself isn't on disk).
    Deleted,
}

/// Flatten a unified diff to a `new-side-line → mark` map (mirrors
/// `DiffHunkParser.parse`). Multi-file diffs accumulate across every hunk.
#[must_use]
pub fn hunk_marks(diff: &str) -> BTreeMap<i64, DiffMark> {
    let mut marks: BTreeMap<i64, DiffMark> = BTreeMap::new();
    let mut line_in_new: i64 = 0;
    let mut pending_deletion = false;

    for line in diff.split('\n') {
        if line.starts_with("@@") {
            // "@@ -old,len +new,len @@" — read the new-side start after the '+',
            // up to the first space or comma (matches Swift exactly: a header
            // without that terminator leaves line_in_new unchanged).
            if let Some(plus) = line.find('+') {
                let rest = &line[plus + 1..];
                if let Some(end) = rest.find([' ', ',']) {
                    if let Ok(n) = rest[..end].parse::<i64>() {
                        line_in_new = n - 1; // bumped before each consumed line
                    }
                }
            }
            pending_deletion = false;
            continue;
        }
        // Non-hunk metadata (note "+++ " is caught here, before the '+' arm).
        if line.starts_with("diff ")
            || line.starts_with("index ")
            || line.starts_with("--- ")
            || line.starts_with("+++ ")
            || line.starts_with("Binary ")
            || line.starts_with("new file")
            || line.starts_with("deleted file")
            || line.starts_with("similarity ")
            || line.starts_with("rename ")
            || line.starts_with("copy ")
        {
            continue;
        }
        let Some(first) = line.chars().next() else {
            // Blank in-hunk line is a context line in the new file.
            line_in_new += 1;
            continue;
        };
        match first {
            ' ' => {
                line_in_new += 1;
                pending_deletion = false;
            }
            '+' => {
                line_in_new += 1;
                marks.insert(
                    line_in_new,
                    if pending_deletion { DiffMark::Modified } else { DiffMark::Added },
                );
                pending_deletion = false;
            }
            '-' => {
                pending_deletion = true;
                // Land the tick on the successor line; don't clobber an existing
                // mark (a later '+' upgrades to Modified via the insert above).
                marks.entry(line_in_new + 1).or_insert(DiffMark::Deleted);
            }
            // "\ No newline…" and any unknown marker: skip silently.
            _ => {}
        }
    }
    marks
}

/// One `line → mark` pair as it crosses the wire (a list, not a map: the Swift
/// `MsgPackReader` decodes only string-keyed maps, and these keys are ints).
#[derive(Serialize, Deserialize)]
struct MarkWire {
    line: i64,
    mark: DiffMark,
}

/// Response payload: the gutter marks as a deterministic (line-sorted) list.
#[derive(Serialize, Deserialize)]
struct HunkMarksResponse {
    marks: Vec<MarkWire>,
}

/// Stateless wire seam for the FFI shim `mdvcore_diff_hunk_marks`: decode a
/// `{text}` request frame, flatten to gutter marks, encode a `{marks:[{line,
/// mark}]}` response frame. Pure + sans-IO (cargo-testable).
///
/// # Errors
/// [`crate::wire::WireFault`] on a malformed/oversized request frame or an
/// encode failure.
pub fn hunk_marks_wire(req_frame: &[u8]) -> Result<Vec<u8>, crate::wire::WireFault> {
    let req: ParseRequest = crate::wire::decode_frame(req_frame)?;
    let marks: Vec<MarkWire> = hunk_marks(&req.text)
        .into_iter()
        .map(|(line, mark)| MarkWire { line, mark })
        .collect();
    crate::wire::encode_frame(&HunkMarksResponse { marks })
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

    #[test]
    fn wire_round_trip_matches_direct_parse() {
        // parse_wire(encode {text}) must decode to the same files as parse().
        let d = "diff --git a/foo.txt b/foo.txt\n@@ -1,2 +1,3 @@ ctx\n a\n-b\n+c\n+d\n";
        let req = crate::wire::encode_frame(&ParseRequest { text: d.to_string() }).unwrap();
        let resp_frame = parse_wire(&req).unwrap();
        let resp: ParseResponse = crate::wire::decode_frame(&resp_frame).unwrap();
        assert_eq!(resp.files, parse(d));
    }

    #[test]
    fn hunk_marks_added_modified_deleted() {
        // @@ -1,3 +1,4 @@ : context, modify (remove+add), pure add, delete-at-end.
        let d = "diff --git a/f b/f\n@@ -1,3 +1,4 @@\n ctx\n-old\n+new\n+fresh\n-gone\n";
        let m = hunk_marks(d);
        // line 1 = context (no mark); line 2 = modified (-old then +new);
        // line 3 = added (+fresh); then -gone marks line 4 as deleted.
        assert_eq!(m.get(&2), Some(&DiffMark::Modified));
        assert_eq!(m.get(&3), Some(&DiffMark::Added));
        assert_eq!(m.get(&4), Some(&DiffMark::Deleted));
        assert_eq!(m.get(&1), None);
    }

    #[test]
    fn hunk_marks_skips_metadata_and_pluspluplus() {
        // "+++ b/f" must NOT be read as an added content line.
        let d = "diff --git a/f b/f\nindex 1..2 100644\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n";
        let m = hunk_marks(d);
        assert_eq!(m.get(&1), Some(&DiffMark::Modified));
        assert_eq!(m.len(), 1);
    }

    #[test]
    fn hunk_marks_wire_round_trips() {
        let d = "diff --git a/f b/f\n@@ -1 +1,2 @@\n ctx\n+added\n";
        let req = crate::wire::encode_frame(&ParseRequest { text: d.to_string() }).unwrap();
        let frame = hunk_marks_wire(&req).unwrap();
        let resp: HunkMarksResponse = crate::wire::decode_frame(&frame).unwrap();
        assert_eq!(resp.marks.len(), 1);
        assert_eq!(resp.marks[0].line, 2);
        assert_eq!(resp.marks[0].mark, DiffMark::Added);
    }
}
