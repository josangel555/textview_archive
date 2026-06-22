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

use crate::table_arena::TableArena;
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
    /// Max ESTIMATED heap bytes for the parsed table (audit TSK-557). The
    /// cell-count caps don't model memory: each cell costs `String` header +
    /// allocator slack and each row a `Vec` of the same, so ~4 MB of bare
    /// newlines amplifies to ~480 MB resident under the count caps alone.
    /// Accounting = content bytes + [`CELL_HEAP_OVERHEAD`]/cell +
    /// [`ROW_HEAP_OVERHEAD`]/row; a trip flips `truncated` and stops the
    /// parse, making worst-case memory O(this cap). Rust-only field (not in
    /// the Swift mirror yet — the Swift parser's own caps are tracked by the
    /// deep-audit Swift tickets).
    pub max_estimated_heap_bytes: usize,
}

/// Estimated per-cell heap overhead: `String` header (24 B on 64-bit) plus
/// allocator slack for the smallest bucket. An estimate, not an exact model —
/// the cap is a blast-radius guard, not an allocator audit.
pub const CELL_HEAP_OVERHEAD: usize = 48;

/// Estimated per-row heap overhead: the row `Vec` header plus slack.
pub const ROW_HEAP_OVERHEAD: usize = 48;

impl Default for Limits {
    fn default() -> Self {
        // Count caps match the Swift parser; the heap cap is Rust-only (see
        // its field doc) and sized to the same scale as `max_input_scalars`.
        Self {
            max_cell_chars: 64 * 1024,
            max_cells_per_row: 4096,
            max_total_cells: 32_000_000,
            max_input_scalars: 256 * 1024 * 1024,
            max_estimated_heap_bytes: 256 * 1024 * 1024,
        }
    }
}

/// Auto-detect the delimiter by counting candidates in the first record,
/// quote-aware. Tabs win when present; otherwise the candidate producing the
/// most fields. Falls back to `,`.
#[must_use]
pub(crate) fn detect_delimiter(text: &str) -> char {
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

/// Parse with auto-detected delimiter and default limits, into the wire DTO.
#[must_use]
pub fn parse(text: &str) -> Table {
    parse_with(text, detect_delimiter(text), Limits::default())
}

/// Parse with auto-detected delimiter and default limits, STRAIGHT into the
/// arena store (TSK-844). Skips the throwaway `Vec<Vec<String>>` — the
/// session-open hot path — so a 1M-cell CSV no longer allocates ~2M `String`s
/// only to copy their bytes into the arena and free them. Shares the single
/// [`tokenize`] grammar with [`parse`], so cap behaviour is byte-identical.
#[must_use]
pub fn parse_arena(text: &str) -> TableArena {
    parse_arena_with(text, detect_delimiter(text), Limits::default())
}

/// Parse with an explicit delimiter and explicit limits, STRAIGHT into the
/// arena (the [`parse_arena`] twin of [`parse_with`]). Shares the single
/// [`tokenize`] grammar, so the resource caps fire byte-identically to the Vec
/// path.
#[must_use]
pub fn parse_arena_with(text: &str, delimiter: char, limits: Limits) -> TableArena {
    let _span = trace::Span::enter("csv.parse_arena");
    let mut sink = ArenaSink::new();
    let truncated = tokenize(text, delimiter, limits, &mut sink);
    sink.finish(delimiter, truncated)
}

/// Parse with an explicit delimiter and explicit limits, into the wire DTO.
#[must_use]
pub(crate) fn parse_with(text: &str, delimiter: char, limits: Limits) -> Table {
    let _span = trace::Span::enter("csv.parse");
    let mut sink = VecSink::default();
    let truncated = tokenize(text, delimiter, limits, &mut sink);
    sink.finish(delimiter, truncated)
}

/// Receives committed cells + row boundaries from the shared CSV [`tokenize`]
/// grammar. The two implementations differ ONLY in where a committed cell
/// lands: [`VecSink`] moves each field into the wire `Vec<Vec<String>>` (the
/// DTO the TUI/web table View needs), while [`ArenaSink`] copies it straight
/// into a contiguous arena buffer using a REUSED field scratch — no per-cell
/// `String`. Every resource-cap decision stays in [`tokenize`], so both sinks
/// observe byte-identical cap behaviour by construction.
trait CsvSink {
    /// Cells already committed in the in-progress row (drives the per-row cap).
    fn cur_row_cells(&self) -> usize;
    /// Commit `field` as the next cell of the current row, resetting `field`
    /// (the tokenizer reuses the buffer for the next cell).
    fn commit_field(&mut self, field: &mut String);
    /// Close the current row.
    fn end_row(&mut self);
}

/// Drive `sink` over `text`. Returns whether any resource cap fired
/// (`truncated`). This is the single home of the CSV grammar + cap accounting;
/// [`parse_with`] and [`parse_arena`] differ only in the sink they hand it.
#[allow(
    clippy::too_many_lines,
    reason = "single tokenizer loop; splitting hurts clarity"
)]
fn tokenize<S: CsvSink>(text: &str, delimiter: char, limits: Limits, sink: &mut S) -> bool {
    let mut field = String::new();
    let mut field_chars = 0usize; // tracked separately to avoid O(n) char counts
    let mut in_quotes = false;

    let mut truncated = false;
    let mut total_cells = 0usize;
    let mut scalars_consumed = 0usize;
    let mut field_capped = false;
    // Running estimate of the parsed table's heap footprint (audit TSK-557):
    // content bytes + per-cell/per-row overhead. See the Limits field doc.
    let mut estimated_heap = 0usize;

    // TSK-560: byte-SPAN tokenizer. The old loop walked char-at-a-time with
    // per-char cap checks and per-char String::push — several× slower than
    // scanning runs. Structure: a manual byte index; the four special bytes
    // ('"', '\n', '\r', the delimiter) are all matched at byte level (UTF-8
    // continuation bytes can never equal an ASCII special, so the scan is
    // char-safe); everything between specials appends as ONE push_str with
    // char-counted cap splitting that reproduces the old per-char boundaries
    // exactly (the golden + cap suites referee). A non-ASCII delimiter is
    // decoded at its first byte before being treated as a hit.
    let bytes = text.as_bytes();
    let delim_first = {
        let mut buf = [0u8; 4];
        let s = delimiter.encode_utf8(&mut buf);
        s.as_bytes().first().copied().unwrap_or(b',')
    };
    let delim_len = delimiter.len_utf8();
    let mut i = 0usize;

    // Append `span` to the field honoring max_cell_chars + the one-time '…'
    // marker, and the global scalar cap. Returns false when the SCALAR cap
    // tripped (caller breaks). Mirrors the old per-char semantics: the char
    // that would EXCEED max_input_scalars is not processed.
    macro_rules! append_span {
        ($span:expr) => {{
            let mut span: &str = $span;
            let mut span_chars = span.chars().count();
            let mut scalar_capped = false;
            if scalars_consumed + span_chars > limits.max_input_scalars {
                let take = limits.max_input_scalars - scalars_consumed;
                let cut = span
                    .char_indices()
                    .nth(take)
                    .map_or(span.len(), |(b, _)| b);
                span = span.get(..cut).unwrap_or(span);
                span_chars = take;
                scalar_capped = true;
                truncated = true;
            }
            scalars_consumed += span_chars;
            if field_chars + span_chars > limits.max_cell_chars {
                let room = limits.max_cell_chars.saturating_sub(field_chars);
                let cut = span
                    .char_indices()
                    .nth(room)
                    .map_or(span.len(), |(b, _)| b);
                field.push_str(span.get(..cut).unwrap_or(span));
                field_chars += room;
                if !field_capped {
                    field.push('…');
                    field_capped = true;
                    truncated = true;
                }
            } else {
                field.push_str(span);
                field_chars += span_chars;
            }
            !scalar_capped
        }};
    }

    // Consume ONE special/control char's scalar budget (the old loop counted
    // every char incl. delimiters/quotes/newlines). False = cap tripped.
    macro_rules! consume_scalar {
        () => {{
            scalars_consumed += 1;
            if scalars_consumed > limits.max_input_scalars {
                truncated = true;
                false
            } else {
                true
            }
        }};
    }

    // Commit current field into the row honoring the per-row cell cap.
    macro_rules! commit_field {
        () => {{
            if sink.cur_row_cells() < limits.max_cells_per_row {
                estimated_heap += field.len() + CELL_HEAP_OVERHEAD;
                sink.commit_field(&mut field);
            } else {
                truncated = true;
                field.clear();
            }
            field_chars = 0;
            field_capped = false;
        }};
    }

    'outer: while i < bytes.len() {
        if total_cells >= limits.max_total_cells {
            truncated = true;
            break;
        }
        if estimated_heap >= limits.max_estimated_heap_bytes {
            truncated = true;
            break;
        }

        if in_quotes {
            // Span until the closing quote, appended in bulk.
            match bytes.get(i..).unwrap_or(&[]).iter().position(|&b| b == b'"') {
                None => {
                    let _ = append_span!(text.get(i..).unwrap_or(""));
                    i = bytes.len();
                }
                Some(rel) => {
                    if rel > 0 && !append_span!(text.get(i..i + rel).unwrap_or("")) {
                        break 'outer;
                    }
                    i += rel + 1; // past the quote
                    if !consume_scalar!() {
                        break 'outer;
                    }
                    if bytes.get(i) == Some(&b'"') {
                        // Escaped "" → one literal quote.
                        i += 1;
                        if !consume_scalar!() {
                            break 'outer;
                        }
                        let _ = append_span!("\"");
                    } else {
                        in_quotes = false;
                    }
                }
            }
            continue;
        }

        // Outside quotes: scan the plain run up to the next special byte.
        let mut j = i;
        while let Some(&b) = bytes.get(j) {
            if b == b'"' || b == b'\n' || b == b'\r' || b == delim_first {
                break;
            }
            j += 1;
        }
        if j > i {
            if !append_span!(text.get(i..j).unwrap_or("")) {
                break 'outer;
            }
            i = j;
            continue;
        }

        // i sits on a special byte.
        let Some(&b) = bytes.get(i) else { break };
        if b == delim_first {
            // For a multi-byte delimiter, verify the full char; a first-byte
            // false hit is appended as a plain char and the scan resumes.
            if delim_len > 1
                && !text.get(i..).unwrap_or("").starts_with(delimiter) {
                let ch_len = text
                    .get(i..)
                    .and_then(|s| s.chars().next())
                    .map_or(1, char::len_utf8);
                if !append_span!(text.get(i..i + ch_len).unwrap_or("")) {
                    break 'outer;
                }
                i += ch_len;
                continue;
            }
            if !consume_scalar!() {
                break 'outer;
            }
            commit_field!();
            total_cells += 1;
            i += delim_len;
            continue;
        }
        if b == b'"' {
            if !consume_scalar!() {
                break 'outer;
            }
            if field.is_empty() && !field_capped {
                in_quotes = true;
            } else {
                let _ = append_span!("\"");
            }
            i += 1;
            continue;
        }
        if b == b'\n' {
            if !consume_scalar!() {
                break 'outer;
            }
            commit_field!();
            total_cells += 1;
            estimated_heap += ROW_HEAP_OVERHEAD;
            sink.end_row();
            i += 1;
            continue;
        }
        // b == b'\r'
        if !consume_scalar!() {
            break 'outer;
        }
        commit_field!();
        total_cells += 1;
        estimated_heap += ROW_HEAP_OVERHEAD;
        sink.end_row();
        i += 1;
        // Swallow a following LF so CRLF doesn't make an empty row.
        if bytes.get(i) == Some(&b'\n') {
            i += 1;
            if !consume_scalar!() {
                break 'outer;
            }
        }
    }

    // Flush trailing field / row. We inline the row-cap check here rather than
    // reuse `commit_field!` so the macro's per-field reset (field_chars /
    // field_capped) — dead at end-of-input — doesn't trip `unused_assignments`.
    if !field.is_empty() || sink.cur_row_cells() > 0 {
        if sink.cur_row_cells() < limits.max_cells_per_row {
            sink.commit_field(&mut field);
        } else {
            truncated = true;
        }
        sink.end_row();
    }

    truncated
}

/// Builds the wire `Vec<Vec<String>>` DTO — the path [`parse`]/[`parse_with`]
/// feed (TUI/web table View). Each committed cell is MOVED out of the
/// tokenizer's field scratch, identical to the pre-TSK-844 behaviour.
#[derive(Default)]
struct VecSink {
    rows: Vec<Vec<String>>,
    row: Vec<String>,
}

impl CsvSink for VecSink {
    fn cur_row_cells(&self) -> usize {
        self.row.len()
    }
    fn commit_field(&mut self, field: &mut String) {
        self.row.push(core::mem::take(field));
    }
    fn end_row(&mut self) {
        self.rows.push(core::mem::take(&mut self.row));
    }
}

impl VecSink {
    /// Header-extract + body column normalization + terminal-empty-row drop —
    /// the exact post-parse step the pre-TSK-844 `parse_with` did inline.
    fn finish(self, delimiter: char, truncated: bool) -> Table {
        let mut rows = self.rows;
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

        if trace::sink_installed() {
            trace::event(
                Level::Info,
                "csv.parse.done",
                vec![
                    ("cols", cols.to_string()),
                    ("rows", body.len().to_string()),
                    ("truncated", truncated.to_string()),
                ],
            );
        }

        Table {
            delimiter: delim_str,
            header,
            rows: body,
            truncated,
        }
    }
}

/// Writes committed cells STRAIGHT into a contiguous arena buffer (TSK-844).
/// The field scratch is reused (`field.clear()`), so no per-cell `String` is
/// allocated; `offsets` is a fencepost array (`offsets[k]..offsets[k+1]` is
/// global cell `k`) in commit order, and `row_lens` records each row's cell
/// count so [`ArenaSink::finish`] can normalize to header arity.
struct ArenaSink {
    bytes: String,
    /// Fencepost offsets into `bytes`, one per committed cell + a leading `0`.
    offsets: Vec<usize>,
    /// Cell count of every committed row, in order (header first).
    row_lens: Vec<usize>,
    cur_row_len: usize,
}

impl ArenaSink {
    fn new() -> Self {
        Self {
            bytes: String::new(),
            offsets: vec![0],
            row_lens: Vec::new(),
            cur_row_len: 0,
        }
    }

    /// Terminal-empty-row drop + header-arity normalization, then build the
    /// arena. Mirrors `VecSink::finish` + `TableArena::from_table`'s
    /// normalization exactly (refereed by the `parse_arena` parity tests).
    fn finish(mut self, delimiter: char, truncated: bool) -> TableArena {
        // Drop a terminal all-empty row (exactly one empty cell), same rule as
        // the Vec path. Its single cell is the last fencepost pair.
        if self.row_lens.last().copied() == Some(1) {
            let last_empty = matches!(
                (self.offsets.iter().nth_back(1), self.offsets.last()),
                (Some(&s), Some(&e)) if s == e
            );
            if last_empty {
                self.row_lens.pop();
                self.offsets.pop();
            }
        }

        let delim_str = delimiter.to_string();
        let Some(&cols) = self.row_lens.first() else {
            // No rows at all → empty arena (matches from_table of an empty Table).
            return TableArena::from_csv_parts(delim_str, truncated, 0, 0, String::new(), vec![0]);
        };
        let row_count = self.row_lens.len() - 1;

        // Fast path: every body row already has exactly `cols` cells, so the
        // as-built (contiguous, header-first, row-major) buffer IS the arena
        // layout — zero extra byte copies.
        if self.row_lens.iter().skip(1).all(|&l| l == cols) {
            return TableArena::from_csv_parts(
                delim_str,
                truncated,
                cols,
                row_count,
                self.bytes,
                self.offsets,
            );
        }

        // Ragged path (rare): re-lay-out body rows to header arity — short rows
        // pad with empty cells, long rows truncate — copying spans once.
        let mut new_bytes = String::with_capacity(self.bytes.len());
        let mut new_offsets = Vec::with_capacity(cols.saturating_mul(row_count + 1) + 1);
        new_offsets.push(0);
        // Cumulative cell-start index per row: row r occupies as-built global
        // cells cum[r]..cum[r+1].
        let mut cum = Vec::with_capacity(self.row_lens.len() + 1);
        cum.push(0usize);
        for &l in &self.row_lens {
            cum.push(cum.last().copied().unwrap_or(0) + l);
        }
        for (r, &row_len) in self.row_lens.iter().enumerate() {
            let row_start = cum.get(r).copied().unwrap_or(0);
            // Header (r==0) keeps its own length (== cols by definition); body
            // rows are normalized to cols.
            let want = if r == 0 { row_len } else { cols };
            for c in 0..want {
                if c < row_len {
                    let k = row_start + c;
                    let span = match (self.offsets.get(k), self.offsets.get(k + 1)) {
                        (Some(&s), Some(&e)) => self.bytes.get(s..e).unwrap_or(""),
                        _ => "",
                    };
                    new_bytes.push_str(span);
                }
                new_offsets.push(new_bytes.len());
            }
        }
        TableArena::from_csv_parts(delim_str, truncated, cols, row_count, new_bytes, new_offsets)
    }
}

impl CsvSink for ArenaSink {
    fn cur_row_cells(&self) -> usize {
        self.cur_row_len
    }
    fn commit_field(&mut self, field: &mut String) {
        self.bytes.push_str(field);
        self.offsets.push(self.bytes.len());
        field.clear();
        self.cur_row_len += 1;
    }
    fn end_row(&mut self) {
        self.row_lens.push(self.cur_row_len);
        self.cur_row_len = 0;
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

    /// Robustness audit (un-fuzzed shipped engine): arbitrary CSV-shaped input
    /// across the danger surface — quotes, escaped quotes, all three line endings
    /// (\n \r\n \r), control chars incl. NUL, multi-byte scalars, unbalanced
    /// quotes — must NEVER panic in `parse` OR the shipped arena `parse_arena`,
    /// and the wire `Table`'s body rows stay normalized to header width.
    /// Deterministic LCG (no `rand` dep). Teeth: a row-width mis-normalization
    /// fails the assert; an edge-case panic (e.g. a fencepost-offset bug in the
    /// arena path) fails outright.
    #[test]
    #[allow(clippy::cast_possible_truncation)] // LCG values are modulo-bounded before use
    fn parse_fuzz_never_panics_and_normalizes_row_width() {
        const ALPHABET: &[char] = &[
            '"', '"', ',', '\n', '\r', '\t', ';', '|', 'a', 'b', ' ', '\0', 'é', '中',
        ];
        const SEEDS: &[&str] = &[
            "", "\"", "\"\"", "\"\"\"", "a,\"b", "a,b\"c\"d", "\r", "\r\n", "\n\r",
            "a\r\nb\rc\nd", ",,,", "\"a\"\"b\"", "h1,h2,h3\n\"x\ny\",2",
        ];
        fn lcg(state: &mut u64) -> u64 {
            *state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            *state
        }
        let mut state: u64 = 0x0123_4567_89ab_cdef;
        for iter in 0..3000u32 {
            let mut s = String::new();
            let len = (lcg(&mut state) % 80) as usize;
            for _ in 0..len {
                s.push(ALPHABET[(lcg(&mut state) as usize) % ALPHABET.len()]);
            }
            match iter % 4 {
                0 => s.push_str(SEEDS[(lcg(&mut state) as usize) % SEEDS.len()]),
                1 => s.insert_str(0, SEEDS[(lcg(&mut state) as usize) % SEEDS.len()]),
                _ => {}
            }
            let t = parse(&s);
            let cols = t.header.len();
            for row in &t.rows {
                assert_eq!(
                    row.len(),
                    cols,
                    "row width {} != header width {cols} for input {s:?}",
                    row.len()
                );
            }
            // The shipped arena path (parse_arena → TableArena) must also survive.
            let _ = parse_arena(&s);
        }
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
    fn estimated_heap_cap_bounds_newline_flood() {
        // TSK-557: a newline flood costs ~1 input byte per cell+row but
        // ~96 estimated heap bytes — the count caps never see the
        // amplification; the heap cap must. 10k newlines under a 16 KiB cap
        // stops after ~170 rows instead of materializing all 10k.
        let flood = "\n".repeat(10_000);
        let limits = Limits {
            max_estimated_heap_bytes: 16 * 1024,
            ..Limits::default()
        };
        let t = parse_with(&flood, ',', limits);
        assert!(t.truncated, "heap cap must flip truncated");
        let cap_rows = limits.max_estimated_heap_bytes / (CELL_HEAP_OVERHEAD + ROW_HEAP_OVERHEAD);
        assert!(
            t.rows.len() <= cap_rows + 1,
            "rows must be bounded by the heap cap (got {})",
            t.rows.len()
        );
        // The default cap leaves normal input untouched.
        let normal = parse_with("a,b\n1,2\n", ',', Limits::default());
        assert!(!normal.truncated);
    }

    #[test]
    fn unicode_cells() {
        let t = parse("name,emoji\nJosé,🎉\n");
        assert_eq!(t.rows, vec![vec!["José", "🎉"]]);
    }

    // --- PARSE-04 degenerate / quote-state-machine edge cases ---
    // The four shapes below pin the detect-vs-parse contract the hardening was
    // built for; they are deliberately the cases the now-deleted exploratory
    // probe only *looked* at without asserting.

    #[test]
    fn unterminated_quote_caps_with_marker() {
        // A quote that never closes turns the rest of input into one field —
        // exactly the "whole file becomes one giant cell" shape the per-cell
        // cap exists to bound. The cap must fire (truncated flips) and the cell
        // must end in the `…` marker after `max_cell_chars` real chars.
        let limits = Limits {
            max_cell_chars: 5,
            ..Limits::default()
        };
        let t = parse_with("h\n\"abcdefghij\n", ',', limits);
        assert!(t.truncated);
        // 5 chars then the marker; the embedded newline is swallowed by the
        // still-open quote, so it does NOT terminate the record.
        assert_eq!(t.rows[0][0], "abcde…");
    }

    #[test]
    fn mid_field_quote_does_not_open_quoting() {
        // A `"` in the MIDDLE of a non-empty field (`field.is_empty()` gate is
        // false) is a literal char, NOT a quote-open — so the following comma
        // STILL splits the row. This is the branch that makes `detect_delimiter`
        // and `parse` agree on field boundaries here.
        let t = parse("h1,h2\na\"b,c\n");
        assert_eq!(t.rows, vec![vec!["a\"b", "c"]]);
    }

    #[test]
    fn closing_quote_then_text_appends_literally() {
        // `"ab"cd` — the closing quote drops out of quoting, then `cd` appends
        // outside quotes; the trailing comma splits normally.
        let t = parse("h1,h2\n\"ab\"cd,e\n");
        assert_eq!(t.rows, vec![vec!["abcd", "e"]]);
    }

    #[test]
    fn escaped_only_field_then_split() {
        // `"""",x` — `""` is one escaped literal quote, the next `"` closes the
        // field, and the comma splits. The cell is a single `"`.
        let t = parse("h1,h2\n\"\"\"\",x\n");
        assert_eq!(t.rows, vec![vec!["\"", "x"]]);
    }

    // --- TSK-844: parse_arena parity with the Vec path -----------------------
    // The arena parser shares the SINGLE tokenizer with `parse`, differing only
    // in where committed cells land. These pin that the two paths can never
    // diverge — on the logical table OR on resource-cap behaviour.

    /// The whole corpus the unit tests above exercise, plus a couple of shapes
    /// that stress the arena's terminal-drop / ragged / fast-path branches.
    fn parity_corpus() -> Vec<&'static str> {
        vec![
            "",
            "\n",
            "\n\n",
            "a,b,c\n1,2,3\n4,5,6\n",
            "a,b,c\n1,2,3\n4,5,6", // no trailing newline
            "a\tb,c\td\n1\t2,3\t4\n",
            "a;b;c\n1;2;3\n",
            "a|b|c\n1|2|3\n",
            "a,b\n\"x,y\",z\n",
            "a,b\n\"line1\nline2\",z\n",
            "a,b\n\"she said \"\"hi\"\"\",z\n",
            "\"a,b,c\";x;y\n1;2;3\n",
            "a,b\r\n1,2\r\n3,4\r\n",
            "a,b\r1,2\r3,4\r",
            "a,b,c\n1,2,3,4\n5,6\n",   // ragged: long then short
            "a,b\n1,2",
            "a,b,c\n",                 // header only
            "a,b\n\n",                 // trailing blank line → terminal drop
            "name,emoji\nJosé,🎉\n",
            "h1,h2\na\"b,c\n",
            "h1,h2\n\"ab\"cd,e\n",
            "h1,h2\n\"\"\"\",x\n",
            "x,y,z\n1,2\n3\n4,5,6,7,8\n", // every row a different arity
            ",,,\n,,,\n",                 // all-empty cells
        ]
    }

    #[test]
    fn parse_arena_logical_table_matches_parse() {
        for text in parity_corpus() {
            let via_vec = parse(text);
            let arena = parse_arena(text);
            assert_eq!(
                arena.to_table(),
                via_vec,
                "parse_arena diverged from parse on {text:?}"
            );
            assert_eq!(
                arena.truncated(),
                via_vec.truncated,
                "truncated flag diverged on {text:?}"
            );
        }
    }

    #[test]
    fn parse_arena_equals_from_table_for_wellformed() {
        // For non-ragged input the arena is built with ZERO extra byte copies,
        // so it must be STRUCTURALLY identical (bytes + offsets) to the arena
        // that `from_table` would build from the Vec path — not merely equal
        // after projection. (Ragged input legitimately differs in dead bytes;
        // the logical-table test above covers those.)
        let wellformed = [
            "a,b,c\n1,2,3\n4,5,6\n",
            "a,b\r\n1,2\r\n3,4\r\n",
            "name,emoji\nJosé,🎉\n",
            "a,b,c\n",
            "",
            ",,,\n,,,\n",
        ];
        for text in wellformed {
            let direct = parse_arena(text);
            let via_from_table = crate::table_arena::TableArena::from_table(parse(text));
            assert_eq!(
                direct, via_from_table,
                "direct arena must be byte-identical to from_table on {text:?}"
            );
        }
    }

    #[test]
    fn parse_arena_cap_parity() {
        // Every resource cap must fire identically across the two paths. Each
        // case is (text, delimiter, limits) — assert logical table + truncated
        // agree with `parse_with`.
        let cases: Vec<(&str, char, Limits)> = vec![
            ("h\nabcdefghij\n", ',', Limits { max_cell_chars: 5, ..Limits::default() }),
            ("abcdefghij\n", ',', Limits { max_input_scalars: 4, ..Limits::default() }),
            ("a,b,c\n1,2,3\n4,5,6\n", ',', Limits { max_total_cells: 2, ..Limits::default() }),
            ("h\n\"abcdefghij\n", ',', Limits { max_cell_chars: 5, ..Limits::default() }),
            ("a,b,c,d\n1,2,3,4\n", ',', Limits { max_cells_per_row: 2, ..Limits::default() }),
            (
                "a,b\n1,2\n3,4\n5,6\n",
                ',',
                Limits { max_estimated_heap_bytes: 64, ..Limits::default() },
            ),
        ];
        for (text, delim, limits) in cases {
            let via_vec = parse_with(text, delim, limits);
            let arena = parse_arena_with(text, delim, limits);
            assert_eq!(
                arena.to_table(),
                via_vec,
                "cap parity (table) failed on {text:?} with {limits:?}"
            );
            assert_eq!(
                arena.truncated(),
                via_vec.truncated,
                "cap parity (truncated) failed on {text:?} with {limits:?}"
            );
        }
    }

    #[test]
    fn parse_arena_newline_flood_heap_cap_parity() {
        // The TSK-557 heap-flood shape: both paths must stop at the same row
        // count under the same cap.
        let flood = "\n".repeat(10_000);
        let limits = Limits { max_estimated_heap_bytes: 16 * 1024, ..Limits::default() };
        let via_vec = parse_with(&flood, ',', limits);
        let arena = parse_arena_with(&flood, ',', limits);
        assert!(arena.truncated());
        assert_eq!(arena.to_table(), via_vec, "heap-cap flood diverged");
        assert_eq!(arena.row_count(), via_vec.rows.len());
    }

    #[test]
    fn parse_arena_large_table_parity() {
        // A synthetic ~5k-row, 6-col table — the shape the perf win targets.
        // Parity here proves the hot path is correct at scale, not just on the
        // tiny golden cases.
        use core::fmt::Write as _;
        let mut text = String::from("c0,c1,c2,c3,c4,c5\n");
        for r in 0..5_000 {
            let _ = writeln!(text, "{r},val{r},x,y,z,{}", r * 2);
        }
        let via_vec = parse(&text);
        let arena = parse_arena(&text);
        assert_eq!(arena.row_count(), 5_000);
        assert_eq!(arena.to_table(), via_vec, "large-table parity failed");
        // And the fast path produced a byte-identical arena.
        assert_eq!(arena, crate::table_arena::TableArena::from_table(via_vec));
    }
}
