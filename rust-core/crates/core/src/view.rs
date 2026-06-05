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

use crate::{csv, hex, indent};

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
    /// Whether the file is CSV/TSV (drives whether `Table` is offered).
    pub is_tabular: bool,
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

/// Whether `name` looks like a delimited table (drives the `Table` mode).
#[must_use]
pub fn looks_tabular(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    lower.ends_with(".csv") || lower.ends_with(".tsv")
}

/// The modes available for a (tabular?) file, in cycle order. `Table` leads for
/// tabular files since it's the most useful default there.
#[must_use]
pub fn available_modes(is_tabular: bool) -> Vec<ViewMode> {
    if is_tabular {
        vec![ViewMode::Table, ViewMode::Text, ViewMode::Hex]
    } else {
        vec![ViewMode::Text, ViewMode::Hex]
    }
}

/// The default mode a file opens in.
#[must_use]
pub fn default_mode(is_tabular: bool) -> ViewMode {
    if is_tabular { ViewMode::Table } else { ViewMode::Text }
}

/// The next mode after `mode` in the file's cycle (wraps around).
#[must_use]
pub fn cycle(mode: ViewMode, is_tabular: bool) -> ViewMode {
    let modes = available_modes(is_tabular);
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
    let is_tabular = looks_tabular(name);
    let text = String::from_utf8_lossy(bytes);
    let indent = indent::detect(&text, INDENT_SAMPLE);
    let body = match mode {
        ViewMode::Text => ViewBody::Text(text_lines(&text)),
        ViewMode::Hex => ViewBody::Hex(hex_lines(bytes, total_byte_count, truncated)),
        ViewMode::Table => {
            let t = csv::parse(&text);
            ViewBody::Table { header: t.header, rows: t.rows, truncated: t.truncated }
        }
    };
    View { mode, body, indent, is_tabular, available_modes: available_modes(is_tabular) }
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
        assert_eq!(default_mode(false), ViewMode::Text);
        assert_eq!(default_mode(true), ViewMode::Table);
        assert_eq!(available_modes(false), vec![ViewMode::Text, ViewMode::Hex]);
        // non-tabular cycle: Text → Hex → Text
        assert_eq!(cycle(ViewMode::Text, false), ViewMode::Hex);
        assert_eq!(cycle(ViewMode::Hex, false), ViewMode::Text);
        // tabular cycle: Table → Text → Hex → Table
        assert_eq!(cycle(ViewMode::Table, true), ViewMode::Text);
        assert_eq!(cycle(ViewMode::Text, true), ViewMode::Hex);
        assert_eq!(cycle(ViewMode::Hex, true), ViewMode::Table);
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
        assert!(!v.is_tabular);
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
        assert!(v.is_tabular);
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
