//! Hand-rolled, dependency-free CSV parser. NO `csv` crate — the whole point
//! is an A/B against the existing Swift `CSVParser`, so the behavior here
//! mirrors it deliberately:
//!
//!   - delimiter auto-detection over `\t , ; |` (tab wins if present;
//!     otherwise the candidate with the most fields in the first record),
//!     and the detection is **quote-aware** (delimiters inside `"..."` don't
//!     count).
//!   - RFC-4180-ish quoting: double-quoted fields may contain delimiters and
//!     newlines; `""` is an escaped literal quote.
//!   - line endings: `\n`, `\r\n`, and bare `\r` (Mac classic) all terminate a
//!     record; `\r\n` does not produce an empty row.
//!   - first row is the header; body rows are normalized to `header.len()`
//!     columns (long rows truncated, short rows padded with empty cells).
//!   - resource caps ([`Limits`]) truncate-with-a-marker and flip
//!     [`Table::truncated`] rather than throwing (matches Swift's PARSE-04).
//!
//! Implementation note on iteration unit: the Swift parser iterates Unicode
//! scalars (so a CRLF decomposes). Rust `&str` chars ARE Unicode scalar values
//! (`char`), so iterating `chars()` is the direct equivalent — no grapheme
//! collapse to worry about. Input must be valid UTF-8 (the FFI layer validates
//! the incoming bytes and returns `BadUtf8` otherwise).

use crate::trace::{self, Level};
use crate::wire::Table;

/// Resource caps guarding degenerate input. Mirrors Swift `CSVParser.Limits`.
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    /// Max chars in a single cell; a runaway quoted field is cut here and gets
    /// a trailing `…` marker.
    pub max_cell_chars: usize,
    /// Max cells in a single row; excess cells past this are dropped.
    pub max_cells_per_row: usize,
    /// Max total cells across the whole table.
    pub max_total_cells: usize,
    /// Max scalars consumed from the input (coarse overall-size backstop).
    pub max_input_scalars: usize,
}

impl Default for Limits {
    fn default() -> Self {
        // Same defaults as the Swift parser.
        Self {
            max_cell_chars: 64 * 1024,
            max_cells_per_row: 4096,
            max_total_cells: 32_000_000,
            max_input_scalars: 256 * 1024 * 1024,
        }
    }
}

/// Auto-detect the delimiter by counting candidates in the first record,
/// quote-aware. Tabs win when present; otherwise the candidate producing the
/// most fields. Falls back to `,`.
#[must_use]
pub fn detect_delimiter(text: &str) -> char {
    let (mut tabs, mut commas, mut semis, mut pipes) = (0usize, 0usize, 0usize, 0usize);
    let mut in_quotes = false;
    let mut chars = text.chars().peekable();

    while let Some(c) = chars.next() {
        if in_quotes {
            if c == '"' {
                match chars.peek() {
                    Some('"') => {
                        chars.next(); // consume escaped ""
                    }
                    Some('\n' | '\r') => {
                        // Closing quote then record terminator → done.
                        break;
                    }
                    Some(&n) => {
                        in_quotes = false;
                        chars.next();
                        bump(n, &mut tabs, &mut commas, &mut semis, &mut pipes);
                    }
                    None => in_quotes = false,
                }
            }
            continue;
        }
        match c {
            '"' => in_quotes = true,
            '\n' | '\r' => break, // end of first record
            _ => bump(c, &mut tabs, &mut commas, &mut semis, &mut pipes),
        }
    }

    if tabs > 0 {
        return '\t';
    }
    // Pick the max of comma / semi / pipe (comma wins ties, matching the
    // Swift `.max(by:)` which keeps the first on equal counts).
    let mut best = (',', commas);
    if semis > best.1 {
        best = (';', semis);
    }
    if pipes > best.1 {
        best = ('|', pipes);
    }
    best.0
}

#[inline]
fn bump(c: char, tabs: &mut usize, commas: &mut usize, semis: &mut usize, pipes: &mut usize) {
    match c {
        '\t' => *tabs += 1,
        ',' => *commas += 1,
        ';' => *semis += 1,
        '|' => *pipes += 1,
        _ => {}
    }
}

/// Parse with auto-detected delimiter and default limits.
#[must_use]
pub fn parse(text: &str) -> Table {
    parse_with(text, detect_delimiter(text), Limits::default())
}

/// Parse with an explicit delimiter and explicit limits.
#[must_use]
#[allow(
    clippy::too_many_lines,
    reason = "single tokenizer loop; splitting hurts clarity"
)]
pub fn parse_with(text: &str, delimiter: char, limits: Limits) -> Table {
    let _span = trace::Span::enter("csv.parse");

    let mut rows: Vec<Vec<String>> = Vec::new();
    let mut field = String::new();
    let mut field_chars = 0usize; // tracked separately to avoid O(n) char counts
    let mut row: Vec<String> = Vec::new();
    let mut in_quotes = false;

    let mut truncated = false;
    let mut total_cells = 0usize;
    let mut scalars_consumed = 0usize;
    let mut field_capped = false;

    let mut chars = text.chars().peekable();

    // Append honoring the per-cell char cap (one `…` marker on first overflow).
    macro_rules! append_to_field {
        ($c:expr) => {{
            if field_chars >= limits.max_cell_chars {
                if !field_capped {
                    field.push('…');
                    field_capped = true;
                    truncated = true;
                }
            } else {
                field.push($c);
                field_chars += 1;
            }
        }};
    }

    // Commit current field into the row honoring the per-row cell cap.
    macro_rules! commit_field {
        () => {{
            if row.len() < limits.max_cells_per_row {
                row.push(core::mem::take(&mut field));
            } else {
                truncated = true;
                field.clear();
            }
            field_chars = 0;
            field_capped = false;
        }};
    }

    while let Some(c) = chars.next() {
        scalars_consumed += 1;
        if scalars_consumed > limits.max_input_scalars {
            truncated = true;
            break;
        }
        if total_cells >= limits.max_total_cells {
            truncated = true;
            break;
        }

        if in_quotes {
            if c == '"' {
                match chars.peek() {
                    Some('"') => {
                        chars.next();
                        append_to_field!('"');
                    }
                    _ => in_quotes = false,
                }
            } else {
                append_to_field!(c);
            }
            continue;
        }

        // Outside quotes.
        if c == '"' && field.is_empty() {
            in_quotes = true;
            continue;
        }
        if c == delimiter {
            commit_field!();
            total_cells += 1;
            continue;
        }
        if c == '\n' {
            commit_field!();
            total_cells += 1;
            rows.push(core::mem::take(&mut row));
            continue;
        }
        if c == '\r' {
            commit_field!();
            total_cells += 1;
            rows.push(core::mem::take(&mut row));
            // Swallow a following LF so CRLF doesn't make an empty row.
            if chars.peek() == Some(&'\n') {
                chars.next();
            }
            continue;
        }
        append_to_field!(c);
    }

    // Flush trailing field / row. We inline the row-cap check here rather than
    // reuse `commit_field!` so the macro's per-field reset (field_chars /
    // field_capped) — dead at end-of-input — doesn't trip `unused_assignments`.
    if !field.is_empty() || !row.is_empty() {
        if row.len() < limits.max_cells_per_row {
            row.push(core::mem::take(&mut field));
        } else {
            truncated = true;
        }
        rows.push(core::mem::take(&mut row));
    }

    // Drop a terminal all-empty row caused by a trailing newline.
    if rows
        .last()
        .is_some_and(|last| last.len() == 1 && last.first().is_some_and(String::is_empty))
    {
        rows.pop();
    }

    let delim_str = delimiter.to_string();
    if rows.is_empty() {
        trace::event(Level::Info, "csv.parse.empty", vec![]);
        return Table {
            delimiter: delim_str,
            header: Vec::new(),
            rows: Vec::new(),
            truncated,
        };
    }

    // First row is the header; normalize body column counts both ways.
    let header = rows.remove(0);
    let cols = header.len();
    let body: Vec<Vec<String>> = rows
        .into_iter()
        .map(|mut r| {
            if r.len() > cols {
                r.truncate(cols);
            } else if r.len() < cols {
                r.resize(cols, String::new());
            }
            r
        })
        .collect();

    trace::event(
        Level::Info,
        "csv.parse.done",
        vec![
            ("cols", cols.to_string()),
            ("rows", body.len().to_string()),
            ("truncated", truncated.to_string()),
        ],
    );

    Table {
        delimiter: delim_str,
        header,
        rows: body,
        truncated,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn basic_comma() {
        let t = parse("a,b,c\n1,2,3\n4,5,6\n");
        assert_eq!(t.delimiter, ",");
        assert_eq!(t.header, vec!["a", "b", "c"]);
        assert_eq!(t.rows, vec![vec!["1", "2", "3"], vec!["4", "5", "6"]]);
        assert!(!t.truncated);
    }

    #[test]
    fn tab_wins_over_comma() {
        let t = parse("a\tb,c\td\n1\t2,3\t4\n");
        assert_eq!(t.delimiter, "\t");
        assert_eq!(t.header, vec!["a", "b,c", "d"]);
    }

    #[test]
    fn semicolon_detected() {
        let t = parse("a;b;c\n1;2;3\n");
        assert_eq!(t.delimiter, ";");
        assert_eq!(t.header.len(), 3);
    }

    #[test]
    fn pipe_detected() {
        let t = parse("a|b|c\n1|2|3\n");
        assert_eq!(t.delimiter, "|");
    }

    #[test]
    fn quoted_field_with_delimiter() {
        let t = parse("a,b\n\"x,y\",z\n");
        assert_eq!(t.rows, vec![vec!["x,y", "z"]]);
    }

    #[test]
    fn quoted_field_with_newline() {
        let t = parse("a,b\n\"line1\nline2\",z\n");
        assert_eq!(t.rows, vec![vec!["line1\nline2", "z"]]);
    }

    #[test]
    fn escaped_quotes() {
        let t = parse("a,b\n\"she said \"\"hi\"\"\",z\n");
        assert_eq!(t.rows, vec![vec!["she said \"hi\"", "z"]]);
    }

    #[test]
    fn quote_aware_delimiter_detection() {
        // Header `"a,b,c";x;y` has 3 commas inside quotes, 2 real semicolons.
        // Quote-aware detection must pick `;`, not `,`.
        let t = parse("\"a,b,c\";x;y\n1;2;3\n");
        assert_eq!(t.delimiter, ";");
        assert_eq!(t.header, vec!["a,b,c", "x", "y"]);
    }

    #[test]
    fn crlf_no_empty_rows() {
        let t = parse("a,b\r\n1,2\r\n3,4\r\n");
        assert_eq!(t.rows, vec![vec!["1", "2"], vec!["3", "4"]]);
    }

    #[test]
    fn bare_cr_terminates() {
        let t = parse("a,b\r1,2\r3,4\r");
        assert_eq!(t.rows, vec![vec!["1", "2"], vec!["3", "4"]]);
    }

    #[test]
    fn ragged_rows_normalized() {
        // Long row truncated, short row padded.
        let t = parse("a,b,c\n1,2,3,4\n5,6\n");
        assert_eq!(t.rows, vec![vec!["1", "2", "3"], vec!["5", "6", ""]]);
    }

    #[test]
    fn trailing_field_no_newline() {
        let t = parse("a,b\n1,2");
        assert_eq!(t.rows, vec![vec!["1", "2"]]);
    }

    #[test]
    fn empty_input() {
        let t = parse("");
        assert!(t.header.is_empty());
        assert!(t.rows.is_empty());
    }

    #[test]
    fn header_only() {
        let t = parse("a,b,c\n");
        assert_eq!(t.header, vec!["a", "b", "c"]);
        assert!(t.rows.is_empty());
    }

    #[test]
    fn cell_char_cap_truncates_with_marker() {
        let limits = Limits {
            max_cell_chars: 5,
            ..Limits::default()
        };
        let t = parse_with("h\nabcdefghij\n", ',', limits);
        assert!(t.truncated);
        // 5 chars then the marker.
        assert_eq!(t.rows[0][0], "abcde…");
    }

    #[test]
    fn input_scalar_cap_truncates() {
        let limits = Limits {
            max_input_scalars: 4,
            ..Limits::default()
        };
        let t = parse_with("abcdefghij\n", ',', limits);
        assert!(t.truncated);
    }

    #[test]
    fn total_cells_cap() {
        let limits = Limits {
            max_total_cells: 2,
            ..Limits::default()
        };
        let t = parse_with("a,b,c\n1,2,3\n4,5,6\n", ',', limits);
        assert!(t.truncated);
    }

    #[test]
    fn unicode_cells() {
        let t = parse("name,emoji\nJosé,🎉\n");
        assert_eq!(t.rows, vec![vec!["José", "🎉"]]);
    }
}
