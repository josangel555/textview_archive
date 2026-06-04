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
            ViewBody::Table { header: t.header, rows: t.rows }
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
            ViewBody::Table { header, rows } => {
                assert_eq!(header, vec!["name", "age"]);
                assert_eq!(rows, vec![vec!["Alice", "30"]]);
            }
            _ => unreachable!("expected Table body"),
        }
    }
}
