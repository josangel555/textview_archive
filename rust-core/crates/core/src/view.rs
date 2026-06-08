//! Render-agnostic **view-model** shared by every front-end (the ratatui TUI,
//! the web server, and any future tier). Given a file's bytes + name + the
//! requested mode, it shapes the content the same way for all of them — so the
//! front-ends stay at feature parity *by construction* instead of each
//! re-implementing capped reads, file-type detection, the mode set, and the
//! per-mode content build.
//!
//! Pure + sans-IO: the front-end still does the IO (reading the file); only the
//! shaping lives here, composing [`crate::csv`], [`crate::hex`], and
//! [`crate::indent`]. A front-end becomes a thin renderer over [`View`].

use crate::{csv, filter, hex, image, indent};

/// Bytes per HEX row (the project-wide default).
const HEX_WIDTH: usize = 16;
/// Cap on text lines kept (a pathological single-line file can't blow memory).
const MAX_TEXT_LINES: usize = 200_000;
/// Lines sampled for indent detection.
const INDENT_SAMPLE: usize = 50;

/// The view a front-end is showing for a file.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ViewMode {
    /// Plain text, line by line.
    Text,
    /// A HEX dump (offset · bytes · ASCII).
    Hex,
    /// A parsed CSV/TSV table.
    Table,
    /// A unified diff, lines classified for +/- coloring.
    Diff,
    /// A raster image (shown inline by the web tier, as a metadata card by the
    /// terminal tier).
    Image,
    /// Pretty-printed structured text (JSON today; XML is a follow-up). The body
    /// is `ViewBody::Text` of the reformatted document — a renderer draws it
    /// exactly like `Text`; only `View.mode` distinguishes them.
    Formatted,
}

/// What a file is, by name — drives the default mode and the mode set offered.
/// A single classification (rather than a pile of `is_*` bools threaded through
/// every function) keeps the front-ends' mode plumbing honest and extensible.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum FileKind {
    /// Anything not recognized as tabular or a diff (the `Text`/`Hex` default).
    Plain,
    /// CSV/TSV — leads with the `Table` mode.
    Tabular,
    /// `.diff`/`.patch` — leads with the `Diff` mode.
    Diff,
    /// A raster image (PNG/JPEG/GIF/BMP/WEBP) — leads with the `Image` mode.
    Image,
    /// Structured text that supports pretty-print (`.json` today; `.xml` joins
    /// when the XML formatter lands). Leads with `Text`, but offers `Formatted`.
    Structured,
}

/// How a single diff display line should be colored. Derived purely from the
/// line's leading characters, so it works for git-format diffs, plain unified
/// diffs (no `diff --git` header), and `git show` output alike — unlike the
/// git-structured [`crate::diff::parse`], which requires a `diff --git` line and
/// is pinned byte-for-byte to the Swift A/B contract (so it must not change).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum DiffLineKind {
    /// `diff --git`, `index `, `--- `, `+++ `, `new/deleted file`, `rename`,
    /// `Binary files …` — file-level metadata.
    FileHeader,
    /// `@@ … @@` hunk header.
    Hunk,
    /// An added line (`+`, but not the `+++` file header).
    Added,
    /// A removed line (`-`, but not the `--- ` file header).
    Removed,
    /// A context line (leading space) or anything unclassified.
    Context,
}

/// One classified diff display line: its `kind` (for coloring) + the verbatim
/// text (prefix char included, so the renderer can show the raw diff faithfully).
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct DiffLine {
    /// Coloring class.
    pub kind: DiffLineKind,
    /// The line's full text, leading `+`/`-`/`@`/space included.
    pub text: String,
}

/// The shaped content for the chosen [`ViewMode`] — a renderer consumes exactly
/// one of these and draws it (as terminal rows, HTML, etc.).
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum ViewBody {
    /// Text lines (tabs expanded, CRs stripped), capped at `MAX_TEXT_LINES`.
    Text(Vec<String>),
    /// Pre-rendered HEX-dump lines (no trailing blank line).
    Hex(Vec<String>),
    /// A parsed table: a header row + body rows (rows normalized to the
    /// header's column count by the core CSV parser).
    Table {
        /// Header (CSV row 0).
        header: Vec<String>,
        /// Body rows.
        rows: Vec<Vec<String>>,
        /// Parse-level truncation (PARSE-04): a CSV size cap fired during parse —
        /// a cell exceeded `max_cell_chars`, a row exceeded `max_cells_per_row`,
        /// or the total-cell cap was hit — so some data was dropped/clamped.
        /// Distinct from the file byte-cap truncation the caller tracks
        /// separately — front-ends should surface this so a clamped table is not
        /// mistaken for the complete data. Mirrors `csv::Table::truncated`.
        truncated: bool,
    },
    /// A unified diff: display lines pre-classified for +/- coloring, capped at
    /// `MAX_TEXT_LINES` (a pathological diff can't blow memory).
    Diff(Vec<DiffLine>),
    /// A raster image: parsed header info (`None` if the dimensions couldn't be
    /// read). The front-end still renders the image itself (web inlines the
    /// bytes; the TUI shows a metadata card) — this carries only what's needed
    /// for the dimensions/format card.
    Image(Option<image::ImageInfo>),
}

/// A fully-shaped view: the active mode, its content, the detected indentation
/// badge, whether the file is tabular, and the modes the user can switch to.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct View {
    /// The mode this view was built for.
    pub mode: ViewMode,
    /// The shaped content for `mode`.
    pub body: ViewBody,
    /// Indent badge (e.g. `"Spaces (4)"`, `"Tabs"`, `"—"`).
    pub indent: String,
    /// What the file is (drives the mode set + default). `Tabular` ⇒ `Table` is
    /// offered; `Diff` ⇒ `Diff` is offered.
    pub kind: FileKind,
    /// Modes the user may switch between for this file, in cycle order.
    pub available_modes: Vec<ViewMode>,
}

/// Width (in decimal digits) of the line-number gutter for a body of
/// `line_count` lines — i.e. the number of digits in the largest line number.
/// A front-end right-pads each line number to this width so the gutter column
/// is flush. Always ≥ 1 (an empty body still gets a 1-wide gutter so the
/// separator has a column to sit against): `0|1 → 1`, `10 → 2`, `1000 → 4`.
#[must_use]
pub fn gutter_width(line_count: usize) -> usize {
    let mut digits = 1;
    let mut n = line_count;
    while n >= 10 {
        n /= 10;
        digits += 1;
    }
    digits
}

/// Clamp a 1-based `target` line number into the valid range for a body of
/// `line_count` lines — the shared "go to line" rule both renderers apply, so a
/// hand-typed or URL-supplied line number lands on the same row in the TUI and
/// the web tier by construction. The result is always 1-based and in
/// `1..=max(line_count, 1)`: `0` (or any under-shoot) clamps up to the first
/// line, an over-shoot clamps down to the last, and an empty body still yields
/// `1` (there's a notional first row to sit on). Convert to a 0-based scroll
/// offset at the call site with `clamp_line(..) - 1`.
#[must_use]
pub fn clamp_line(target: usize, line_count: usize) -> usize {
    target.clamp(1, line_count.max(1))
}

/// Body rows sampled by [`table_col_widths`] when sizing columns — measuring
/// every row of a huge CSV is wasteful and one runaway row far down shouldn't
/// dominate the layout, so only the first N are inspected.
const TABLE_WIDTH_SAMPLE: usize = 200;
/// Minimum column width (chars) — an empty/short column still gets a usable cell.
const TABLE_MIN_COL: usize = 4;
/// Maximum column width (chars) — one long value can't blow the layout; over-long
/// cells are truncated/ellipsized by the front-end within this bound.
const TABLE_MAX_COL: usize = 30;

/// Per-column display widths (in characters) for a table view — shared by every
/// front-end so a CSV renders with the SAME column proportions in the TUI (fixed
/// `Constraint::Length`) and the web tier (`<col>` `ch` widths) by construction.
///
/// Each column's width is the widest of its header and a sample of body cells
/// (first [`TABLE_WIDTH_SAMPLE`] rows), clamped to
/// [`TABLE_MIN_COL`]..=[`TABLE_MAX_COL`]. Char-counted (not byte), so multi-byte
/// content measures correctly. Returns exactly one width per header column (an
/// empty header yields an empty `Vec`). Pure, allocation-light, never indexes.
///
/// ```
/// use mdvcore_core::view::table_col_widths;
/// let header = vec!["id".to_string(), "name".to_string()];
/// let rows = vec![vec!["1".to_string(), "Alexandra".to_string()]];
/// let w = table_col_widths(&header, &rows);
/// assert_eq!(w[0], 4);  // "id"/"1" both short → clamped up to the 4-char min
/// assert_eq!(w[1], 9);  // widest is "Alexandra" (9)
/// ```
#[must_use]
pub fn table_col_widths(header: &[String], rows: &[Vec<String>]) -> Vec<usize> {
    let mut w = vec![0usize; header.len()];
    for (i, h) in header.iter().enumerate() {
        if let Some(c) = w.get_mut(i) {
            *c = h.chars().count();
        }
    }
    for row in rows.iter().take(TABLE_WIDTH_SAMPLE) {
        for (i, cell) in row.iter().enumerate() {
            if let Some(c) = w.get_mut(i) {
                *c = (*c).max(cell.chars().count());
            }
        }
    }
    w.into_iter().map(|x| x.clamp(TABLE_MIN_COL, TABLE_MAX_COL)).collect()
}

/// Classify a file by name (extension). Diff/patch wins over tabular wins over
/// plain; the extension sets are disjoint so the order is only a tie-break
/// formality. This is the single source of truth the front-ends use to pick the
/// default mode and the mode switcher.
#[must_use]
pub fn classify(name: &str) -> FileKind {
    let lower = name.to_ascii_lowercase();
    if image::looks_image(&lower) {
        FileKind::Image
    } else if lower.ends_with(".diff") || lower.ends_with(".patch") {
        FileKind::Diff
    } else if lower.ends_with(".csv") || lower.ends_with(".tsv") {
        FileKind::Tabular
    } else if lower.ends_with(".json") {
        // JSON gets the `Formatted` (pretty-print) mode. `.xml` joins here once
        // the XML formatter lands (the deferred slice) — until then it stays
        // `Plain` so we never offer a Formatted mode that no-ops.
        FileKind::Structured
    } else {
        FileKind::Plain
    }
}

/// Whether `name` looks like a delimited table (drives the `Table` mode).
#[must_use]
pub fn looks_tabular(name: &str) -> bool {
    classify(name) == FileKind::Tabular
}

/// The readability state of a file's *content* (its bytes), independent of the
/// name-based [`FileKind`]. Front-ends use this to show an explicit banner —
/// today an empty file renders as a blank pane and a binary file renders as
/// garbled "text" with no hint why; this names those states so both front-ends
/// surface them identically (the SwiftUI app shows the same idea natively).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ContentState {
    /// Zero bytes on disk.
    Empty,
    /// Looks binary: a NUL byte, or a high ratio of control bytes in the sniffed
    /// prefix — text/source rendering would be garbled, so the front-end should
    /// say so (and prefer HEX).
    Binary,
    /// Ordinary readable content (the common case).
    Readable,
}

/// Leading bytes inspected by [`content_state`] — a binary file reveals itself
/// early, so a large readable file need not be rescanned in full.
const CONTENT_SNIFF_BYTES: usize = 8192;
/// Control-byte percentage (of the sniffed prefix) above which content is judged
/// binary even without a NUL — catches latin-1 / other non-UTF-8 blobs.
const BINARY_CONTROL_PCT: usize = 30;

/// Classify the readability [`ContentState`] of `bytes`: empty → `Empty`; a NUL
/// byte, or more than [`BINARY_CONTROL_PCT`]% control bytes (excluding
/// tab/newline/CR) within the first [`CONTENT_SNIFF_BYTES`] → `Binary`;
/// otherwise `Readable`. Pure, allocation-free, a single bounded pass that never
/// indexes (lint-clean under the workspace `indexing_slicing` deny).
#[must_use]
pub fn content_state(bytes: &[u8]) -> ContentState {
    if bytes.is_empty() {
        return ContentState::Empty;
    }
    let prefix = bytes.get(..CONTENT_SNIFF_BYTES).unwrap_or(bytes);
    let mut control = 0usize;
    for &b in prefix {
        if b == 0 {
            return ContentState::Binary;
        }
        // Control chars except the common text whitespace (tab/LF/CR).
        if b < 0x20 && b != b'\t' && b != b'\n' && b != b'\r' {
            control += 1;
        }
    }
    if control.saturating_mul(100) > prefix.len().saturating_mul(BINARY_CONTROL_PCT) {
        ContentState::Binary
    } else {
        ContentState::Readable
    }
}

/// The canonical one-line banner for a [`ContentState`], or `None` when the
/// content is readable (no banner needed). Shared so the TUI status line and the
/// web banner read identically; truncation (the byte-cap) is a separate signal
/// each front-end already surfaces alongside this.
#[must_use]
pub fn content_state_banner(state: ContentState) -> Option<&'static str> {
    match state {
        ContentState::Empty => Some("empty file"),
        ContentState::Binary => Some("binary file"),
        ContentState::Readable => None,
    }
}

/// The modes available for a file, in cycle order. The kind-specific mode leads
/// (it's the most useful default there); `Text`/`Hex` always follow as the
/// universal fallbacks.
#[must_use]
pub fn available_modes(kind: FileKind) -> Vec<ViewMode> {
    match kind {
        FileKind::Diff => vec![ViewMode::Diff, ViewMode::Text, ViewMode::Hex],
        FileKind::Tabular => vec![ViewMode::Table, ViewMode::Text, ViewMode::Hex],
        // An image's bytes are binary — `Text` would be garbage, so only the
        // `Image` card/preview and the `Hex` byte dump are offered.
        FileKind::Image => vec![ViewMode::Image, ViewMode::Hex],
        // Structured (JSON): the raw `Text` leads (it's the source of truth);
        // `Formatted` re-indents it; `Hex` as ever.
        FileKind::Structured => vec![ViewMode::Text, ViewMode::Formatted, ViewMode::Hex],
        FileKind::Plain => vec![ViewMode::Text, ViewMode::Hex],
    }
}

/// The default mode a file opens in (the head of its [`available_modes`]).
#[must_use]
pub fn default_mode(kind: FileKind) -> ViewMode {
    match kind {
        FileKind::Diff => ViewMode::Diff,
        FileKind::Tabular => ViewMode::Table,
        FileKind::Image => ViewMode::Image,
        FileKind::Structured | FileKind::Plain => ViewMode::Text,
    }
}

/// The next mode after `mode` in the file's cycle (wraps around).
#[must_use]
pub fn cycle(mode: ViewMode, kind: FileKind) -> ViewMode {
    let modes = available_modes(kind);
    let idx = modes.iter().position(|&m| m == mode).unwrap_or(0);
    let next = (idx + 1) % modes.len().max(1);
    modes.get(next).copied().unwrap_or(mode)
}

/// Shape `bytes` (a file named `name`, of original size `total_byte_count`,
/// possibly `truncated` on read) into a [`View`] for `mode`.
#[must_use]
pub fn build(
    bytes: &[u8],
    name: &str,
    total_byte_count: usize,
    truncated: bool,
    mode: ViewMode,
) -> View {
    let kind = classify(name);
    let text = String::from_utf8_lossy(bytes);
    let indent = indent::detect(&text, INDENT_SAMPLE);
    let body = match mode {
        ViewMode::Text => ViewBody::Text(text_lines(&text)),
        ViewMode::Hex => ViewBody::Hex(hex_lines(bytes, total_byte_count, truncated)),
        ViewMode::Table => {
            let t = csv::parse(&text);
            ViewBody::Table { header: t.header, rows: t.rows, truncated: t.truncated }
        }
        ViewMode::Diff => ViewBody::Diff(diff_lines(&text)),
        ViewMode::Image => ViewBody::Image(image::identify(bytes)),
        ViewMode::Formatted => ViewBody::Text(formatted_lines(&text)),
    };
    View { mode, body, indent, kind, available_modes: available_modes(kind) }
}

/// Build a [`filter::Query`] from a user filter string against `header`. A
/// `col:term` form (where `col` matches a header name, case-insensitively)
/// scopes the match to that column; otherwise the whole (trimmed) string is a
/// global any-cell substring. Empty/blank → matches everything. Shared by both
/// front-ends so the TUI prompt and the web `?tfilter=` box behave identically.
#[must_use]
pub fn table_query(header: &[String], raw: &str) -> filter::Query {
    let q = raw.trim();
    if q.is_empty() {
        return filter::Query::empty();
    }
    if let Some((col, term)) = q.split_once(':') {
        let col_lc = col.trim().to_ascii_lowercase();
        if let Some(idx) = header.iter().position(|h| h.trim().to_ascii_lowercase() == col_lc) {
            return filter::Query { text: term.trim().to_string(), scope: filter::Scope::Column(idx) };
        }
    }
    filter::Query { text: q.to_string(), scope: filter::Scope::All }
}

/// Classify a unified-diff line by its leading characters (see [`DiffLineKind`]).
/// File-header checks precede the bare `+`/`-` checks so `+++`/`--- ` headers
/// aren't mistaken for added/removed lines.
#[must_use]
pub fn classify_diff_line(line: &str) -> DiffLineKind {
    if line.starts_with("@@") {
        DiffLineKind::Hunk
    } else if line.starts_with("+++")
        || line.starts_with("--- ")
        || line.starts_with("diff ")
        || line.starts_with("index ")
        || line.starts_with("new file")
        || line.starts_with("deleted file")
        || line.starts_with("rename ")
        || line.starts_with("copy ")
        || line.starts_with("similarity ")
        || line.starts_with("dissimilarity ")
        || line.starts_with("old mode ")
        || line.starts_with("new mode ")
        || line.starts_with("Binary files ")
    {
        DiffLineKind::FileHeader
    } else if line.starts_with('+') {
        DiffLineKind::Added
    } else if line.starts_with('-') {
        DiffLineKind::Removed
    } else {
        DiffLineKind::Context
    }
}

fn diff_lines(text: &str) -> Vec<DiffLine> {
    text.split('\n')
        .take(MAX_TEXT_LINES)
        .map(|l| {
            let text = l.replace('\r', "");
            DiffLine { kind: classify_diff_line(&text), text }
        })
        .collect()
}

/// Pretty-print structured text for the `Formatted` mode. JSON is reformatted
/// via [`crate::format::pretty_json`]; anything that isn't valid JSON (XML,
/// malformed input) falls back to the raw `Text` shaping so the mode never shows
/// an empty or garbled body. Capped at `MAX_TEXT_LINES` like `Text`.
fn formatted_lines(text: &str) -> Vec<String> {
    match crate::format::pretty_json(text) {
        Some(pretty) => pretty.split('\n').take(MAX_TEXT_LINES).map(str::to_string).collect(),
        None => text_lines(text),
    }
}

fn text_lines(text: &str) -> Vec<String> {
    text.split('\n')
        .take(MAX_TEXT_LINES)
        .map(|l| l.replace('\t', "    ").replace('\r', ""))
        .collect()
}

fn hex_lines(bytes: &[u8], total: usize, truncated: bool) -> Vec<String> {
    let dump = hex::render_all(bytes, HEX_WIDTH, total, truncated);
    let mut lines: Vec<String> = dump.split('\n').map(str::to_string).collect();
    if lines.last().is_some_and(String::is_empty) {
        lines.pop(); // render_all ends with a trailing '\n'
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modes_and_cycle() {
        assert_eq!(default_mode(FileKind::Plain), ViewMode::Text);
        assert_eq!(default_mode(FileKind::Tabular), ViewMode::Table);
        assert_eq!(default_mode(FileKind::Diff), ViewMode::Diff);
        assert_eq!(available_modes(FileKind::Plain), vec![ViewMode::Text, ViewMode::Hex]);
        // structured (JSON): Text default, Formatted offered, Hex.
        assert_eq!(default_mode(FileKind::Structured), ViewMode::Text);
        assert_eq!(
            available_modes(FileKind::Structured),
            vec![ViewMode::Text, ViewMode::Formatted, ViewMode::Hex]
        );
        // structured cycle: Text → Formatted → Hex → Text
        assert_eq!(cycle(ViewMode::Text, FileKind::Structured), ViewMode::Formatted);
        assert_eq!(cycle(ViewMode::Formatted, FileKind::Structured), ViewMode::Hex);
        assert_eq!(cycle(ViewMode::Hex, FileKind::Structured), ViewMode::Text);
        // plain cycle: Text → Hex → Text
        assert_eq!(cycle(ViewMode::Text, FileKind::Plain), ViewMode::Hex);
        assert_eq!(cycle(ViewMode::Hex, FileKind::Plain), ViewMode::Text);
        // tabular cycle: Table → Text → Hex → Table
        assert_eq!(cycle(ViewMode::Table, FileKind::Tabular), ViewMode::Text);
        assert_eq!(cycle(ViewMode::Text, FileKind::Tabular), ViewMode::Hex);
        assert_eq!(cycle(ViewMode::Hex, FileKind::Tabular), ViewMode::Table);
        // diff cycle: Diff → Text → Hex → Diff
        assert_eq!(cycle(ViewMode::Diff, FileKind::Diff), ViewMode::Text);
        assert_eq!(cycle(ViewMode::Text, FileKind::Diff), ViewMode::Hex);
        assert_eq!(cycle(ViewMode::Hex, FileKind::Diff), ViewMode::Diff);
        // image: only Image + Hex (no Text — binary), default Image, cycle wraps.
        assert_eq!(default_mode(FileKind::Image), ViewMode::Image);
        assert_eq!(available_modes(FileKind::Image), vec![ViewMode::Image, ViewMode::Hex]);
        assert_eq!(cycle(ViewMode::Image, FileKind::Image), ViewMode::Hex);
        assert_eq!(cycle(ViewMode::Hex, FileKind::Image), ViewMode::Image);
    }

    #[test]
    fn classify_by_extension() {
        assert_eq!(classify("a.diff"), FileKind::Diff);
        assert_eq!(classify("a.PATCH"), FileKind::Diff);
        assert_eq!(classify("a.csv"), FileKind::Tabular);
        assert_eq!(classify("a.tsv"), FileKind::Tabular);
        assert_eq!(classify("a.PNG"), FileKind::Image);
        assert_eq!(classify("a.jpeg"), FileKind::Image);
        assert_eq!(classify("a.txt"), FileKind::Plain);
        assert_eq!(classify("patch"), FileKind::Plain);
    }

    #[test]
    fn table_col_widths_measures_header_and_sampled_cells_clamped() {
        let header = vec!["id".to_string(), "name".to_string(), "note".to_string()];
        let rows = vec![
            vec!["1".to_string(), "Alexandra".to_string(), "x".to_string()],
            vec!["22".to_string(), "Bo".to_string(), "y".to_string()],
        ];
        let w = table_col_widths(&header, &rows);
        assert_eq!(w.len(), 3, "one width per header column");
        assert_eq!(w[0], 4, "id/1/22 all under the 4-char min → clamped up");
        assert_eq!(w[1], 9, "widest body cell Alexandra (9) wins over header name (4)");
        assert_eq!(w[2], 4, "note(4)/x/y → exactly the min");
    }

    #[test]
    fn table_col_widths_caps_runaway_cell_and_handles_empty() {
        // A 100-char cell is clamped to the 30-char max so it can't blow layout.
        let header = vec!["c".to_string()];
        let rows = vec![vec!["z".repeat(100)]];
        assert_eq!(table_col_widths(&header, &rows), vec![30]);
        // Empty header → empty widths (no columns).
        assert!(table_col_widths(&[], &[]).is_empty());
        // Multi-byte header measured by chars, not bytes (clamped to min here).
        let h = vec!["café".to_string()];
        assert_eq!(table_col_widths(&h, &[]), vec![4]);
    }

    #[test]
    fn content_state_classifies_empty_binary_readable() {
        // Empty bytes → Empty (banner says so).
        assert_eq!(content_state(b""), ContentState::Empty);
        assert_eq!(content_state_banner(ContentState::Empty), Some("empty file"));
        // A NUL byte anywhere in the prefix → Binary.
        assert_eq!(content_state(&[0x00, 0x41, 0xff]), ContentState::Binary);
        assert_eq!(content_state_banner(ContentState::Binary), Some("binary file"));
        // Ordinary UTF-8 text (with tab/newline/CR whitespace) → Readable, no banner.
        assert_eq!(content_state(b"hello world\n\ttab\r\nok"), ContentState::Readable);
        assert_eq!(content_state_banner(ContentState::Readable), None);
        // Multi-byte UTF-8 (no control bytes) stays Readable.
        assert_eq!(content_state("café — déjà".as_bytes()), ContentState::Readable);
    }

    #[test]
    fn content_state_flags_control_heavy_blob_without_nul() {
        // A blob that's >30% control bytes (no NUL) is still judged binary.
        let mut blob = vec![0x01u8; 40];
        blob.extend_from_slice(&[b'a'; 60]); // 40/100 = 40% control → Binary
        assert_eq!(content_state(&blob), ContentState::Binary);
        // Just under the threshold stays Readable (29 control / 100 bytes).
        let mut ok = vec![0x01u8; 29];
        ok.extend_from_slice(&[b'a'; 71]);
        assert_eq!(content_state(&ok), ContentState::Readable);
    }

    #[test]
    fn content_state_only_sniffs_a_bounded_prefix() {
        // A binary byte AFTER the sniff window doesn't flip a large readable file.
        let mut big = vec![b'a'; CONTENT_SNIFF_BYTES + 10];
        if let Some(last) = big.last_mut() {
            *last = 0x00;
        }
        assert_eq!(content_state(&big), ContentState::Readable, "byte past the sniff prefix is ignored");
    }

    #[test]
    fn table_query_parses_global_and_per_column() {
        let header = vec!["name".to_string(), "city".to_string()];
        // Empty → match-all.
        assert!(table_query(&header, "  ").is_empty());
        // Plain string → global (any-cell) substring.
        let g = table_query(&header, "par");
        assert_eq!(g.text, "par");
        assert_eq!(g.scope, filter::Scope::All);
        // `col:term` with a known header (case-insensitive) → column-scoped.
        let c = table_query(&header, "City: paris");
        assert_eq!(c.text, "paris");
        assert_eq!(c.scope, filter::Scope::Column(1));
        // `col:term` where `col` is NOT a header → treated as a global substring
        // (the literal "foo:bar"), not a broken column filter.
        let u = table_query(&header, "foo:bar");
        assert_eq!(u.text, "foo:bar");
        assert_eq!(u.scope, filter::Scope::All);
    }

    #[test]
    fn build_image_reads_dimensions() {
        // A minimal PNG header (signature + IHDR width/height) → Image body with
        // parsed dimensions; `.png` opens in Image mode by default.
        let mut png = vec![0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a];
        png.extend_from_slice(&[0, 0, 0, 13]);
        png.extend_from_slice(b"IHDR");
        png.extend_from_slice(&64u32.to_be_bytes());
        png.extend_from_slice(&48u32.to_be_bytes());
        let v = build(&png, "logo.png", png.len(), false, default_mode(classify("logo.png")));
        assert_eq!(v.kind, FileKind::Image);
        assert_eq!(v.mode, ViewMode::Image);
        assert_eq!(v.available_modes, vec![ViewMode::Image, ViewMode::Hex]);
        match v.body {
            ViewBody::Image(Some(info)) => {
                assert_eq!(info.width, 64);
                assert_eq!(info.height, 48);
            }
            other => unreachable!("expected Image body with dimensions, got {other:?}"),
        }
    }

    #[test]
    fn classify_diff_line_by_leading_chars() {
        use DiffLineKind::{Added, Context, FileHeader, Hunk, Removed};
        // Header forms must win over the bare +/- checks.
        assert_eq!(classify_diff_line("+++ b/file.rs"), FileHeader);
        assert_eq!(classify_diff_line("--- a/file.rs"), FileHeader);
        assert_eq!(classify_diff_line("diff --git a/x b/x"), FileHeader);
        assert_eq!(classify_diff_line("index e69de29..0000000"), FileHeader);
        assert_eq!(classify_diff_line("new file mode 100644"), FileHeader);
        assert_eq!(classify_diff_line("Binary files a and b differ"), FileHeader);
        assert_eq!(classify_diff_line("@@ -1,3 +1,4 @@ fn main()"), Hunk);
        assert_eq!(classify_diff_line("+added line"), Added);
        assert_eq!(classify_diff_line("-removed line"), Removed);
        assert_eq!(classify_diff_line(" context line"), Context);
        assert_eq!(classify_diff_line(""), Context);
    }

    #[test]
    fn build_diff_classifies_plain_unified_diff() {
        // A PLAIN unified diff (no `diff --git` header) — the git-structured
        // `diff::parse` would yield zero files here, so the view classifies by
        // leading char instead. `.diff` opens in Diff mode by default.
        let raw = "--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n-old\n+new\n unchanged\n";
        let v = build(raw.as_bytes(), "p.diff", raw.len(), false, default_mode(classify("p.diff")));
        assert_eq!(v.kind, FileKind::Diff);
        assert_eq!(v.mode, ViewMode::Diff);
        assert_eq!(v.available_modes.first(), Some(&ViewMode::Diff));
        match v.body {
            ViewBody::Diff(lines) => {
                use DiffLineKind::{Added, Context, FileHeader, Hunk, Removed};
                let kinds: Vec<_> = lines.iter().map(|l| l.kind).collect();
                assert_eq!(
                    &kinds[..6],
                    &[FileHeader, FileHeader, Hunk, Removed, Added, Context]
                );
                assert_eq!(lines[3].text, "-old");
                assert_eq!(lines[4].text, "+new");
            }
            _ => unreachable!("expected Diff body"),
        }
    }

    #[test]
    fn gutter_width_counts_decimal_digits() {
        // Boundary cases from the port plan: 1→1, 10→2, 1000→4.
        assert_eq!(gutter_width(1), 1);
        assert_eq!(gutter_width(10), 2);
        assert_eq!(gutter_width(1000), 4);
        // An empty body still gets a 1-wide gutter (never 0).
        assert_eq!(gutter_width(0), 1);
        // Just-below / just-at each power-of-ten boundary.
        assert_eq!(gutter_width(9), 1);
        assert_eq!(gutter_width(99), 2);
        assert_eq!(gutter_width(100), 3);
        assert_eq!(gutter_width(999), 3);
        assert_eq!(gutter_width(10_000), 5);
        // Matches the decimal-string length for a spread of values.
        for n in [1usize, 2, 7, 42, 128, 4096, 200_000] {
            assert_eq!(gutter_width(n), n.to_string().len(), "n={n}");
        }
    }

    #[test]
    fn clamp_line_is_1_based_and_bounded() {
        // Boundary cases from the port plan: under-shoot clamps to the first
        // line, over-shoot to the last.
        assert_eq!(clamp_line(0, 10), 1);
        assert_eq!(clamp_line(99, 10), 10);
        // In-range values pass through unchanged.
        assert_eq!(clamp_line(1, 10), 1);
        assert_eq!(clamp_line(5, 10), 5);
        assert_eq!(clamp_line(10, 10), 10);
        // An empty body still has a notional first row (never 0).
        assert_eq!(clamp_line(0, 0), 1);
        assert_eq!(clamp_line(1, 0), 1);
        assert_eq!(clamp_line(42, 0), 1);
        // A single-line body pins everything to line 1.
        assert_eq!(clamp_line(0, 1), 1);
        assert_eq!(clamp_line(7, 1), 1);
        // The result is always a valid 1-based index into a `line_count` body
        // (i.e. `clamp_line(..) - 1` is a safe 0-based scroll offset).
        for line_count in [0usize, 1, 2, 10, 1000] {
            for target in [0usize, 1, 2, 9, 10, 11, 1001, usize::MAX] {
                let r = clamp_line(target, line_count);
                assert!(r >= 1, "always 1-based: target={target} len={line_count}");
                assert!(r <= line_count.max(1), "never past last: target={target} len={line_count}");
            }
        }
    }

    #[test]
    fn looks_tabular_by_extension() {
        assert!(looks_tabular("a.csv"));
        assert!(looks_tabular("A.TSV"));
        assert!(!looks_tabular("a.txt"));
        assert!(!looks_tabular("csv"));
    }

    #[test]
    fn build_text_expands_tabs_strips_cr() {
        let v = build(b"a\tb\r\nc\n", "f.txt", 6, false, ViewMode::Text);
        assert_eq!(v.mode, ViewMode::Text);
        assert_eq!(v.kind, FileKind::Plain);
        match v.body {
            ViewBody::Text(lines) => {
                assert_eq!(lines.first().map(String::as_str), Some("a    b"));
                assert_eq!(lines.get(1).map(String::as_str), Some("c"));
            }
            _ => unreachable!("expected Text body"),
        }
    }

    #[test]
    fn build_hex_uses_core_render() {
        let v = build(&[0x00, 0x41, 0xff], "f.bin", 3, false, ViewMode::Hex);
        match v.body {
            ViewBody::Hex(lines) => {
                assert_eq!(lines.len(), 1);
                assert!(lines[0].starts_with("00000000  00 41 ff"), "{:?}", lines[0]);
            }
            _ => unreachable!("expected Hex body"),
        }
    }

    #[test]
    fn build_table_parses_csv() {
        let v = build(b"name,age\nAlice,30\n", "p.csv", 18, false, ViewMode::Table);
        assert_eq!(v.kind, FileKind::Tabular);
        assert_eq!(v.available_modes.first(), Some(&ViewMode::Table));
        match v.body {
            ViewBody::Table { header, rows, truncated } => {
                assert_eq!(header, vec!["name", "age"]);
                assert_eq!(rows, vec![vec!["Alice", "30"]]);
                assert!(!truncated, "well-formed CSV must not report parse truncation");
            }
            _ => unreachable!("expected Table body"),
        }
    }

    #[test]
    fn build_table_propagates_parse_truncation() {
        // A row exceeding the per-row cell cap (default 4096) makes the CSV parser
        // flag `truncated` (PARSE-04 data loss). The view body must carry that
        // through so front-ends can banner it (was dropped before — TSK-155).
        let mut csv = String::from("h\n");
        csv.push_str(&"x,".repeat(5000)); // 5000 cells > max_cells_per_row
        csv.push('\n');
        let v = build(csv.as_bytes(), "p.csv", csv.len(), false, ViewMode::Table);
        match v.body {
            ViewBody::Table { truncated, .. } => {
                assert!(truncated, "row past the per-row cell cap must surface as parse truncation");
            }
            _ => unreachable!("expected Table body"),
        }
    }
}
