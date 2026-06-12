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
            Some(b' ') => hunk.append(LineKind::Context, raw.get(1..).unwrap_or("")),
            Some(b'+') => hunk.append(LineKind::Added, raw.get(1..).unwrap_or("")),
            Some(b'-') => hunk.append(LineKind::Removed, raw.get(1..).unwrap_or("")),
            Some(b'\\') => hunk.append(LineKind::NoNewline, raw.get(1..).unwrap_or("")),
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
    if rest.starts_with('"')
        && let Some(mid) = rest.find("\" \"") {
            let a = rest.get(..mid).unwrap_or("");
            let b = rest.get(mid + 3..).unwrap_or("");
            let bs = b.strip_suffix('"').unwrap_or(b);
            return (strip_path_prefix(&format!("{a}\"")), strip_path_prefix(bs));
        }
    // (2) Equal-prefix same-file case: a ` b/` where the prefix is `a/PATH` and
    // the suffix equals `PATH`.
    for (idx, _) in rest.match_indices(" b/") {
        let a_part = rest.get(..idx).unwrap_or("");
        let b_part = rest.get(idx + 3..).unwrap_or("");
        if let Some(a_path) = a_part.strip_prefix("a/")
            && a_path == b_part {
                return (a_path.to_string(), b_part.to_string());
            }
    }
    // (3) Rename / asymmetric — fall back to the LAST ` b/`.
    if let Some(idx) = rest.rfind(" b/") {
        let a = rest.get(..idx).unwrap_or("");
        let b = rest.get(idx + 3..).unwrap_or("");
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
        t = t.get(1..t.len() - 1).unwrap_or(&t).to_string();
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
    let second_rel = raw.get(after_first..)?.find("@@")?;
    let second = after_first + second_rel;
    let coords = raw.get(after_first..second).unwrap_or("").trim();
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
    let tail = raw.get(second + 2..).unwrap_or("").trim().to_string();
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
/// named-map frame the Swift side builds (matching `to_vec_named`). Borrowed
/// (TSK-561): the text points into the request frame — diffs cross on every
/// gutter refresh of the viewed file, so the owned copy was pure overhead.
#[derive(Serialize, Deserialize)]
struct ParseRequest<'a> {
    #[serde(borrow)]
    text: std::borrow::Cow<'a, str>,
}

// Positional per-element wire records (TSK-563). Named-map encoding repeated
// the field-name keys on EVERY line (~41 bytes/line of key text); tuple
// structs serialize as MessagePack ARRAYS, so the per-element keys vanish.
// The ENVELOPE stays a named map ({files: …}) — the top level is where remote
// debuggability matters and its keys amortize over the whole frame. Field
// ORDER is the wire contract (mirrored by the Swift decoders + the owned
// twins below); append-only, never reorder. Wire version bumped 1 → 2.

/// One line, positional: `[kind, old_line_no, new_line_no, content]`.
#[derive(Serialize)]
struct LineView<'a>(LineKind, Option<i64>, Option<i64>, &'a str);

/// One hunk, positional: `[old_start, old_count, new_start, new_count, header, lines]`.
#[derive(Serialize)]
struct HunkView<'a>(i64, i64, i64, i64, &'a str, Vec<LineView<'a>>);

/// One file, positional:
/// `[old_path, new_path, is_new, is_deleted, is_binary, is_rename, hunks]`.
#[derive(Serialize)]
struct FileView<'a>(&'a str, &'a str, bool, bool, bool, bool, Vec<HunkView<'a>>);

/// Response envelope: named map, positional elements.
#[derive(Serialize)]
struct ParseResponseView<'a> {
    files: Vec<FileView<'a>>,
}

fn file_views(files: &[File]) -> Vec<FileView<'_>> {
    files
        .iter()
        .map(|f| {
            FileView(
                &f.old_path,
                &f.new_path,
                f.is_new,
                f.is_deleted,
                f.is_binary,
                f.is_rename,
                f.hunks
                    .iter()
                    .map(|h| {
                        HunkView(
                            h.old_start,
                            h.old_count,
                            h.new_start,
                            h.new_count,
                            &h.header,
                            h.lines
                                .iter()
                                .map(|l| LineView(l.kind, l.old_line_no, l.new_line_no, &l.content))
                                .collect(),
                        )
                    })
                    .collect(),
            )
        })
        .collect()
}

/// Stateless wire seam for the FFI shim `mdvcore_diff_parse`: decode a
/// length-prefixed MessagePack request frame `{text}`, parse the unified diff,
/// and encode a `{files:[…]}` response frame (positional per-element records,
/// TSK-563). Pure + sans-IO, so it is fully cargo-testable without the C edge;
/// the FFI layer adds only the pointer/`MdvBuf`/panic-guard plumbing.
///
/// # Errors
/// [`crate::wire::WireFault`] on a malformed/oversized request frame or an
/// encode failure. (A diff that parses to zero files is NOT an error — it
/// returns Ok with `files: []`.)
pub fn parse_wire(req_frame: &[u8]) -> Result<Vec<u8>, crate::wire::WireFault> {
    let req: ParseRequest<'_> = crate::wire::decode_frame_borrowed(req_frame)?;
    let files = parse(&req.text);
    crate::wire::encode_frame(&ParseResponseView { files: file_views(&files) })
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
                let rest = line.get(plus + 1..).unwrap_or("");
                if let Some(end) = rest.find([' ', ','])
                    && let Ok(n) = rest.get(..end).unwrap_or("").parse::<i64>() {
                        // Clamp like parse_coord (TSK-576): the header is
                        // attacker-controlled, and an unclamped i64::MIN
                        // overflows the `- 1` (panic in dev, wrap in release).
                        // PARITY-LOCKED with Swift DiffHunkParser.
                        line_in_new = n.clamp(0, MAX_COORD) - 1; // bumped before each consumed line
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
                // `.max(1)` (TSK-565): a deletion at the very top of the file
                // (new-side start 0) would otherwise mark line 0 — keys are
                // 1-based, so the tick was invisible in the gutter. PARITY-
                // LOCKED with Swift DiffHunkParser.
                marks.entry((line_in_new + 1).max(1)).or_insert(DiffMark::Deleted);
            }
            // "\ No newline…" and any unknown marker: skip silently.
            _ => {}
        }
    }
    marks
}

/// One `line → mark` pair, positional (TSK-563): `[line, mark]`. A list, not a
/// map keyed by line: the Swift `MsgPackReader` decodes only string-keyed maps.
#[derive(Serialize, Deserialize)]
struct MarkWire(i64, DiffMark);

/// Response payload: the gutter marks as a deterministic (line-sorted) list
/// (named-map envelope, positional elements).
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
    let req: ParseRequest<'_> = crate::wire::decode_frame_borrowed(req_frame)?;
    let marks: Vec<MarkWire> = hunk_marks(&req.text)
        .into_iter()
        .map(|(line, mark)| MarkWire(line, mark))
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
    fn git_paths_strategy4_leading_space_splits_like_swift() {
        // Strategy (4) fallback: no quoted form, no ` b/` marker at all, so the
        // path pair is recovered by splitting at the first space. TSK-182: Swift's
        // `split(maxSplits: 1, omittingEmptySubsequences: true)` collapses a
        // LEADING space-run WITHOUT spending its single split, so the rust port
        // trims leading spaces before `splitn` to match. A leading-space input
        // must therefore NOT degenerate to (rest, rest).
        let (a, b) = parse_diff_git_paths("  alpha beta");
        assert_eq!(a, "alpha", "leading spaces collapsed; first token is alpha");
        assert_eq!(b, "beta");

        // A whitespace RUN between the two tokens: only the first space is the
        // split point; the trailing remainder is trimmed by strip_path_prefix.
        let (c, d) = parse_diff_git_paths("foo   qux");
        assert_eq!((c.as_str(), d.as_str()), ("foo", "qux"));

        // Fewer than two non-empty tokens → fall back to the ORIGINAL
        // (untrimmed) `rest` on BOTH sides, matching Swift's untrimmed return.
        let (e, f) = parse_diff_git_paths("solo");
        assert_eq!((e.as_str(), f.as_str()), ("solo", "solo"));
        let (g, h) = parse_diff_git_paths("   ");
        assert_eq!((g.as_str(), h.as_str()), ("   ", "   "),
            "all-spaces yields the untrimmed original, not the trimmed empty");
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
    fn coord_comma_led_and_empty_start_omit_empty() {
        // Comma-led / empty-start / empty-middle coordinates. The parser mirrors
        // Swift `split(separator: ",")` (omittingEmptySubsequences: true): empty
        // pieces are dropped, so the first NON-empty piece is the start and the
        // next is the count. The Swift diff parser was removed in the rust-core
        // migration (slice #3), so this impl is now the single source of truth —
        // these assertions lock the degenerate shapes the audit flagged (TSK-154)
        // so the behavior can't silently drift.
        assert_eq!(parse_coord(",3"), (3, 1)); // leading empty dropped → "3" is the start
        assert_eq!(parse_coord(",5"), (5, 1)); // same: empty start, "5" becomes start
        assert_eq!(parse_coord("5,"), (5, 1)); // trailing empty dropped → count defaults to 1
        assert_eq!(parse_coord(","), (0, 1)); // all empty → start 0, count 1
        assert_eq!(parse_coord(""), (0, 1)); // empty input → both default
        assert_eq!(parse_coord("3,,5"), (3, 5)); // empty middle dropped → start 3, count 5
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
        assert_eq!(lines[1], Line { kind: LineKind::Context, old_line_no: Some(2), new_line_no: Some(2), content: String::new() });
    }

    /// Owned positional twins (TSK-563): tuple structs DESERIALIZE only from
    /// MessagePack arrays — decoding the response through these both
    /// round-trips the data AND pins that the per-element encoding really is
    /// positional (a regression to named maps fails the tuple decode).
    #[derive(serde::Deserialize)]
    struct LineWireOwned(LineKind, Option<i64>, Option<i64>, String);
    #[derive(serde::Deserialize)]
    struct HunkWireOwned(i64, i64, i64, i64, String, Vec<LineWireOwned>);
    #[derive(serde::Deserialize)]
    struct FileWireOwned(String, String, bool, bool, bool, bool, Vec<HunkWireOwned>);
    #[derive(serde::Deserialize)]
    struct ParseResponseOwned {
        files: Vec<FileWireOwned>,
    }

    fn rebuild(files: Vec<FileWireOwned>) -> Vec<File> {
        files
            .into_iter()
            .map(|f| File {
                old_path: f.0,
                new_path: f.1,
                is_new: f.2,
                is_deleted: f.3,
                is_binary: f.4,
                is_rename: f.5,
                hunks: f
                    .6
                    .into_iter()
                    .map(|h| Hunk {
                        old_start: h.0,
                        old_count: h.1,
                        new_start: h.2,
                        new_count: h.3,
                        header: h.4,
                        lines: h
                            .5
                            .into_iter()
                            .map(|l| Line {
                                kind: l.0,
                                old_line_no: l.1,
                                new_line_no: l.2,
                                content: l.3,
                            })
                            .collect(),
                    })
                    .collect(),
            })
            .collect()
    }

    #[test]
    fn wire_round_trip_matches_direct_parse() {
        // parse_wire(encode {text}) must decode to the same files as parse().
        // Decoding through the tuple twins also pins the POSITIONAL element
        // encoding (tuples reject named maps).
        let d = "diff --git a/foo.txt b/foo.txt\n@@ -1,2 +1,3 @@ ctx\n a\n-b\n+c\n+d\n";
        let req = crate::wire::encode_frame(&ParseRequest { text: d.into() }).unwrap();
        let resp_frame = parse_wire(&req).unwrap();
        let resp: ParseResponseOwned = crate::wire::decode_frame(&resp_frame).unwrap();
        assert_eq!(rebuild(resp.files), parse(d));
    }

    #[test]
    fn positional_elements_shrink_the_frame_vs_named_maps() {
        // The point of TSK-563: the same diff encoded with named-map elements
        // (the old shape, reconstructed locally) must be strictly larger —
        // per-line key text is the dominant payload for small records.
        #[derive(Serialize)]
        struct NamedResponse<'a> {
            files: &'a [File],
        }
        let d = "diff --git a/foo.txt b/foo.txt\n@@ -1,4 +1,5 @@ ctx\n a\n-b\n+c\n+d\n e\n f\n";
        let req = crate::wire::encode_frame(&ParseRequest { text: d.into() }).unwrap();
        let positional = parse_wire(&req).unwrap();
        let files = parse(d);
        let named = crate::wire::encode_frame(&NamedResponse { files: &files }).unwrap();
        assert!(
            positional.len() < named.len(),
            "positional frame ({}) must be smaller than named-map frame ({})",
            positional.len(),
            named.len()
        );
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
    fn hunk_marks_hostile_header_clamps_not_panics() {
        // TSK-576: an i64::MIN new-side start used to overflow `n - 1`
        // (panic in dev/test, silent wrap in release).
        let d = "@@ -1 +-9223372036854775808,0 @@\n-gone\n";
        let m = hunk_marks(d);
        assert_eq!(m.get(&1), Some(&DiffMark::Deleted));
        // i64::MAX side: clamped to MAX_COORD, key stays in range.
        let d2 = "@@ -1 +9223372036854775807,0 @@\n-gone\n";
        let m2 = hunk_marks(d2);
        assert!(m2.keys().all(|k| (1..=MAX_COORD).contains(k)));
    }

    #[test]
    fn hunk_marks_top_of_file_deletion_lands_on_line_1() {
        // TSK-565: "@@ -1,2 +0,0 @@" (delete the first two lines, add nothing)
        // used to put the tick on line 0 — invisible in the 1-based gutter.
        // PARITY-LOCKED with Swift DiffHunkParserTests.
        let d = "@@ -1,2 +0,0 @@\n-a\n-b\n";
        let m = hunk_marks(d);
        assert_eq!(m.get(&1), Some(&DiffMark::Deleted));
        assert!(!m.contains_key(&0));
    }

    #[test]
    fn hunk_marks_wire_round_trips() {
        let d = "diff --git a/f b/f\n@@ -1 +1,2 @@\n ctx\n+added\n";
        let req = crate::wire::encode_frame(&ParseRequest { text: d.into() }).unwrap();
        let frame = hunk_marks_wire(&req).unwrap();
        let resp: HunkMarksResponse = crate::wire::decode_frame(&frame).unwrap();
        assert_eq!(resp.marks.len(), 1);
        assert_eq!(resp.marks[0].0, 2);
        assert_eq!(resp.marks[0].1, DiffMark::Added);
    }
}
