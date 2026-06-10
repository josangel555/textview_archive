//! In-file content find — the pure substring matcher shared by every
//! front-end's "find in this document" feature (the ratatui TUI's `/` overlay,
//! the web tier's find box, and any future tier). Given a document's text and a
//! query it returns every non-overlapping match position (0-based line + the
//! byte range within that line), so the front-ends highlight + navigate the same
//! matches *by construction* instead of each re-deriving "what counts as a hit".
//!
//! **No dependency, no regex.** This is a deliberately literal substring search
//! (the `regex`-backed `FindEngine` is dep-gated and owner-blocked, see the Swift
//! side). Case-insensitive matching folds ASCII only (`A`..`Z` ⇆ `a`..`z`): that
//! keeps every reported byte offset valid, because `to_ascii_lowercase` never
//! changes a byte's length — non-ASCII bytes pass through untouched. Full Unicode
//! case-folding would change byte lengths (and need a table/dep), so it is out of
//! scope; the front-ends document "case-insensitive = ASCII".
//!
//! Sans-IO and allocation-light: the caller supplies the already-read text; this
//! module only walks it. Lines are split on `\n` with a trailing `\r` stripped
//! (so CRLF files report ranges into the visible, CR-free line — matching how the
//! TUI/web render each line).
//!
//! Match positions are **byte offsets**, not char/grapheme indices: every
//! front-end slices the same UTF-8 `&str` the core split, so byte ranges are the
//! lingua franca (and the only offsets that are O(1) to apply). Ranges never
//! split a UTF-8 code point — they always start/end on `query`'s own boundaries.

/// One match of the query within the document.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Match {
    /// 0-based index of the line the match sits on.
    pub line: usize,
    /// Byte offset of the match start within that line (CR-stripped).
    pub start: usize,
    /// Byte offset just past the match end within that line (`start + query.len()`
    /// for a case-sensitive search; identical length for ASCII-folded search).
    pub end: usize,
}

/// Case sensitivity for a find. `Insensitive` folds ASCII letters only.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Case {
    /// Exact byte match — `Hello` does not match `hello`.
    Sensitive,
    /// ASCII-folded match — `A`..`Z` match `a`..`z` (non-ASCII unchanged).
    Insensitive,
}

/// Every non-overlapping occurrence of `query` across `text`, in document order
/// (top-to-bottom, left-to-right within a line). An empty `query` yields no
/// matches (a find box with no needle highlights nothing). Overlapping hits are
/// not double-counted: after a match the scan resumes at its end, so `"aa"` in
/// `"aaaa"` reports two matches (offsets 0 and 2), not three.
#[must_use]
pub fn find_matches(text: &str, query: &str, case: Case) -> Vec<Match> {
    if query.is_empty() {
        return Vec::new();
    }
    let needle = fold(query, case);
    let mut out: Vec<Match> = Vec::new();
    for (idx, raw) in text.split('\n').enumerate() {
        let line = raw.strip_suffix('\r').unwrap_or(raw);
        let hay = fold(line, case);
        // Walk the (folded) line, resuming past each hit so matches don't
        // overlap. `hay` is byte-length-identical to `line` (ASCII fold), so the
        // offsets we collect index straight back into the original `line`.
        let mut from = 0usize;
        while let Some(rel) = hay.get(from..).and_then(|s| s.find(&needle)) {
            let start = from + rel;
            let end = start + needle.len();
            out.push(Match { line: idx, start, end });
            // Advance at least one byte to guarantee termination even for a
            // degenerate (never produced here — empty query is rejected above)
            // zero-length needle.
            from = end.max(start + 1);
        }
    }
    out
}

/// Index into a `matches` slice of the first match at or after the caret
/// `(line, col)` (byte offset), used for "find from the cursor down". Wraps to
/// the first match when the caret is past the last hit, so repeated find always
/// lands somewhere when `matches` is non-empty. Returns `None` only for an empty
/// slice. `matches` is assumed sorted in document order (as [`find_matches`]
/// returns it).
#[must_use]
pub fn first_from(matches: &[Match], line: usize, col: usize) -> Option<usize> {
    if matches.is_empty() {
        return None;
    }
    let at_or_after = matches
        .iter()
        .position(|m| m.line > line || (m.line == line && m.start >= col));
    Some(at_or_after.unwrap_or(0))
}

/// Step from match index `cur` to the next match, wrapping past the end. Returns
/// `None` for an empty slice. (`cur` need not be in range — it is taken modulo
/// the length, so a stale index from a shrunk match set is still safe.)
#[must_use]
pub fn next_index(matches: &[Match], cur: usize) -> Option<usize> {
    let n = matches.len();
    if n == 0 {
        return None;
    }
    Some((cur % n + 1) % n)
}

/// Step from match index `cur` to the previous match, wrapping past the start.
/// Returns `None` for an empty slice.
#[must_use]
pub fn prev_index(matches: &[Match], cur: usize) -> Option<usize> {
    let n = matches.len();
    if n == 0 {
        return None;
    }
    Some((cur % n + (n - 1)) % n)
}

/// One line of a file that contains at least one match — the unit of a
/// cross-file "grep" results list. Carries the 0-based `line` index and the
/// line's full CR-stripped text (so a front-end can show the hit in context and
/// link to `?line=line+1`).
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct LineHit {
    /// 0-based line index of the matching line.
    pub line: usize,
    /// The matching line's full text (trailing `\r` stripped).
    pub text: String,
}

/// The distinct lines of `text` containing `query`, in document order, capped at
/// `max` hits (`0` = unlimited) — the shared per-file matcher behind every
/// front-end's cross-file folder grep (the web `/grep` route, the TUI search-
/// anywhere overlay). Built on [`find_matches`], so "what counts as a hit" is
/// identical to the in-file find; a line with several matches appears once. An
/// empty query yields no hits.
#[must_use]
pub fn grep_lines(text: &str, query: &str, case: Case, max: usize) -> Vec<LineHit> {
    let lines: Vec<&str> = text.split('\n').collect();
    let mut out: Vec<LineHit> = Vec::new();
    let mut last: Option<usize> = None;
    for m in find_matches(text, query, case) {
        if last == Some(m.line) {
            continue; // collapse multiple matches on the same line to one hit
        }
        if max != 0 && out.len() >= max {
            break;
        }
        let raw = lines.get(m.line).copied().unwrap_or("");
        out.push(LineHit { line: m.line, text: raw.strip_suffix('\r').unwrap_or(raw).to_string() });
        last = Some(m.line);
    }
    out
}

/// Which of `buckets` equal slices of a `total_lines` document the 0-based
/// `line` falls into (clamped to `0..buckets`). The shared mapping behind every
/// front-end's find minimap / scroll-position indicator, so a match lands in the
/// same bucket in the TUI column and the web bar by construction. `buckets` and
/// `total_lines` of `0` are treated as `1` (no divide-by-zero; everything maps to
/// bucket `0`).
#[must_use]
pub fn bucket_of(line: usize, total_lines: usize, buckets: usize) -> usize {
    let b = buckets.max(1);
    let total = total_lines.max(1);
    (line.saturating_mul(b) / total).min(b - 1)
}

/// Per-bucket match counts for a find minimap: `match_lines` (0-based line
/// indices, any order) distributed across `buckets` equal slices of a
/// `total_lines` document via [`bucket_of`]. The result always has exactly
/// `buckets.max(1)` entries; a non-zero entry means that slice of the document
/// holds at least one match (a front-end marks it on the minimap/scrollbar).
/// Pure, allocation-light.
#[must_use]
pub fn match_minimap(match_lines: &[usize], total_lines: usize, buckets: usize) -> Vec<usize> {
    let b = buckets.max(1);
    let mut out = vec![0usize; b];
    for &line in match_lines {
        if let Some(c) = out.get_mut(bucket_of(line, total_lines, b)) {
            *c += 1;
        }
    }
    out
}

/// ASCII-fold a string for case-insensitive comparison (no allocation when
/// `Sensitive`). `to_ascii_lowercase` preserves every byte's length, so offsets
/// into the folded string map 1:1 back onto the original.
fn fold(s: &str, case: Case) -> String {
    match case {
        Case::Sensitive => s.to_string(),
        Case::Insensitive => s.to_ascii_lowercase(),
    }
}

/// Sentinel [`TableHit::row`] for a header-cell match (negative so it can never
/// collide with a real `rows` index).
pub const TABLE_HEADER_ROW: i64 = -1;

/// A matching cell in a parsed table — the cell-coordinate find behind a CSV
/// grid's Cmd-F (parity with the Swift `CSVFind`). `row == TABLE_HEADER_ROW`
/// (-1) marks a header cell; data cells carry their 0-based `rows` index.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct TableHit {
    /// Row index: `TABLE_HEADER_ROW` (-1) for a header cell, else the 0-based
    /// `rows` index of the matching data cell.
    pub row: i64,
    /// 0-based column index of the matching cell within its row.
    pub col: usize,
}

/// Every cell containing `query` (case per `case`), in reading order: header
/// first (when `include_header`), then data rows top-to-bottom, each
/// left-to-right — which is the order next/prev cycles. An empty `query` yields
/// no hits. `scope` restricts to a single column when `Some` (an out-of-range
/// column yields no hits, matching the Swift side). Substring match, mirroring
/// `find_matches`/`CSVFilter` so the user has one mental model across views.
///
/// Navigation reuses the existing wraparound: callers step with
/// `(cur + 1) % hits.len()` (forward) / the [`prev_index`] pattern — the hit
/// list is a flat `Vec`, so the same modulo math applies.
/// Generic over the row type (`R: AsRef<[String]>`) so callers pass either owned
/// rows (`&[Vec<String>]` — the web/core path) or borrowed rows
/// (`&[&Vec<String>]` — the TUI's already-filtered `shown` slice) without a
/// clone. `TableHit.row` indexes into the `rows` slice passed here.
#[must_use]
pub fn find_in_table<R: AsRef<[String]>>(
    header: &[String],
    rows: &[R],
    query: &str,
    case: Case,
    include_header: bool,
    scope: Option<usize>,
) -> Vec<TableHit> {
    if query.is_empty() {
        return Vec::new();
    }
    let needle = fold(query, case);
    let mut out: Vec<TableHit> = Vec::new();
    if include_header {
        push_row_hits(&mut out, TABLE_HEADER_ROW, header, &needle, case, scope);
    }
    for (i, row) in rows.iter().enumerate() {
        // A row index past i64::MAX is unreachable for any real table; saturate
        // rather than panic to stay lint-clean under the no-panic policy.
        let r = i64::try_from(i).unwrap_or(i64::MAX);
        push_row_hits(&mut out, r, row.as_ref(), &needle, case, scope);
    }
    out
}

/// Append the matching-cell hits for one row (header or data). Split out so the
/// header and data passes share identical column-scope + folding logic.
fn push_row_hits(
    out: &mut Vec<TableHit>,
    row: i64,
    cells: &[String],
    needle: &str,
    case: Case,
    scope: Option<usize>,
) {
    for (col, cell) in cells.iter().enumerate() {
        if let Some(only) = scope
            && only != col {
                continue;
            }
        if fold(cell, case).contains(needle) {
            out.push(TableHit { row, col });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(line: usize, start: usize, end: usize) -> Match {
        Match { line, start, end }
    }

    #[test]
    fn bucket_of_maps_lines_into_clamped_buckets() {
        // First line → bucket 0; last line → last bucket; midpoint → middle.
        assert_eq!(bucket_of(0, 100, 10), 0);
        assert_eq!(bucket_of(99, 100, 10), 9);
        assert_eq!(bucket_of(50, 100, 10), 5);
        // Out-of-range line clamps to the last bucket; zero total/buckets are safe.
        assert_eq!(bucket_of(999, 100, 10), 9);
        assert_eq!(bucket_of(5, 0, 0), 0);
        assert_eq!(bucket_of(0, 10, 1), 0);
    }

    #[test]
    fn match_minimap_buckets_match_counts() {
        // 3 matches across a 90-line doc into 9 buckets: lines 0, 45, 89.
        let mm = match_minimap(&[0, 45, 89], 90, 9);
        assert_eq!(mm.len(), 9, "one entry per bucket");
        assert_eq!(mm[0], 1, "line 0 → bucket 0");
        assert_eq!(mm[4], 1, "line 45 → bucket 4");
        assert_eq!(mm[8], 1, "line 89 → bucket 8");
        assert_eq!(mm.iter().sum::<usize>(), 3, "every match counted once");
        // Two matches in the same bucket accumulate; no matches → all zero.
        assert_eq!(match_minimap(&[1, 2], 10, 2)[0], 2);
        assert!(match_minimap(&[], 10, 5).iter().all(|&c| c == 0));
    }

    #[test]
    fn grep_lines_returns_distinct_matching_lines_capped() {
        let text = "alpha\nbeta beta\ngamma\nbeta end\n";
        // Two lines contain "beta" (line 1 has two matches → one hit; line 3 → one).
        let hits = grep_lines(text, "beta", Case::Insensitive, 0);
        assert_eq!(hits.len(), 2, "distinct lines, multi-match line collapsed: {hits:?}");
        assert_eq!(hits[0], LineHit { line: 1, text: "beta beta".to_string() });
        assert_eq!(hits[1], LineHit { line: 3, text: "beta end".to_string() });
        // Cap limits the hit count.
        let capped = grep_lines(text, "beta", Case::Insensitive, 1);
        assert_eq!(capped.len(), 1, "max caps the results");
        assert_eq!(capped[0].line, 1);
        // Case-insensitive folds; CRLF line keeps CR stripped.
        let crlf = "Foo BAR\r\nbaz\r\n";
        let h = grep_lines(crlf, "bar", Case::Insensitive, 0);
        assert_eq!(h, vec![LineHit { line: 0, text: "Foo BAR".to_string() }]);
        // Empty query → no hits.
        assert!(grep_lines(text, "", Case::Insensitive, 0).is_empty());
    }

    #[test]
    fn empty_query_yields_no_matches() {
        assert!(find_matches("anything at all", "", Case::Sensitive).is_empty());
        assert!(find_matches("anything", "", Case::Insensitive).is_empty());
    }

    #[test]
    fn single_match_on_one_line() {
        let hits = find_matches("hello world", "world", Case::Sensitive);
        assert_eq!(hits, vec![m(0, 6, 11)]);
    }

    #[test]
    fn multiple_matches_same_line_left_to_right() {
        let hits = find_matches("ababab", "ab", Case::Sensitive);
        assert_eq!(hits, vec![m(0, 0, 2), m(0, 2, 4), m(0, 4, 6)]);
    }

    #[test]
    fn overlapping_needle_is_not_double_counted() {
        // "aa" in "aaaa" → offsets 0 and 2 (non-overlapping), not 0/1/2.
        let hits = find_matches("aaaa", "aa", Case::Sensitive);
        assert_eq!(hits, vec![m(0, 0, 2), m(0, 2, 4)]);
    }

    #[test]
    fn matches_span_multiple_lines_in_document_order() {
        let text = "foo\nbar foo\nbaz";
        let hits = find_matches(text, "foo", Case::Sensitive);
        assert_eq!(hits, vec![m(0, 0, 3), m(1, 4, 7)]);
    }

    #[test]
    fn case_sensitive_does_not_match_other_case() {
        assert!(find_matches("Hello", "hello", Case::Sensitive).is_empty());
    }

    #[test]
    fn case_insensitive_matches_mixed_case() {
        let hits = find_matches("Hello HELLO hello", "hello", Case::Insensitive);
        assert_eq!(hits, vec![m(0, 0, 5), m(0, 6, 11), m(0, 12, 17)]);
    }

    #[test]
    fn crlf_lines_report_ranges_into_the_cr_free_line() {
        // The match on line 1 sits before the stripped \r; offsets index the
        // visible (CR-free) line, matching how front-ends render it.
        let text = "one\r\ntwo two\r\n";
        let hits = find_matches(text, "two", Case::Sensitive);
        assert_eq!(hits, vec![m(1, 0, 3), m(1, 4, 7)]);
    }

    #[test]
    fn utf8_offsets_are_byte_accurate_and_dont_split_codepoints() {
        // "café" is 5 bytes (é = 2 bytes); "x" after it starts at byte 5.
        let text = "café x café";
        let hits = find_matches(text, "café", Case::Sensitive);
        // First "café" at bytes 0..5; then " x " is 3 bytes (5,6,7), so the
        // second "café" is byte 8..13.
        assert_eq!(hits, vec![m(0, 0, 5), m(0, 8, 13)]);
        // The reported ranges slice cleanly (no panic, valid UTF-8).
        for h in &hits {
            let line = "café x café";
            assert!(line.get(h.start..h.end).is_some(), "{h:?} must be a char boundary");
        }
    }

    #[test]
    fn ascii_fold_keeps_offsets_valid_with_nonascii_present() {
        // Non-ASCII bytes are untouched by the fold, so offsets stay aligned.
        let text = "Über ÜBER über";
        let hits = find_matches(text, "ber", Case::Insensitive);
        // "ber" appears in each of the three words (after the Ü/ü, 2 bytes each).
        assert_eq!(hits.len(), 3, "{hits:?}");
    }

    #[test]
    fn no_match_returns_empty() {
        assert!(find_matches("the quick brown fox", "zebra", Case::Sensitive).is_empty());
    }

    #[test]
    fn first_from_picks_match_at_or_after_caret() {
        let hits = vec![m(0, 0, 2), m(2, 4, 6), m(5, 1, 3)];
        // Caret before everything → first match.
        assert_eq!(first_from(&hits, 0, 0), Some(0));
        // Caret between match 0 and 1 → match 1.
        assert_eq!(first_from(&hits, 1, 0), Some(1));
        // Caret exactly on match 1's start → match 1 (inclusive).
        assert_eq!(first_from(&hits, 2, 4), Some(1));
        // Caret just past match 1's start → match 2.
        assert_eq!(first_from(&hits, 2, 5), Some(2));
        // Caret past the last match → wrap to the first.
        assert_eq!(first_from(&hits, 9, 0), Some(0));
    }

    #[test]
    fn first_from_empty_is_none() {
        assert_eq!(first_from(&[], 0, 0), None);
    }

    #[test]
    fn next_and_prev_index_wrap() {
        let hits = vec![m(0, 0, 1), m(1, 0, 1), m(2, 0, 1)];
        assert_eq!(next_index(&hits, 0), Some(1));
        assert_eq!(next_index(&hits, 2), Some(0)); // wrap forward
        assert_eq!(prev_index(&hits, 0), Some(2)); // wrap backward
        assert_eq!(prev_index(&hits, 2), Some(1));
    }

    #[test]
    fn next_prev_tolerate_out_of_range_cur() {
        // A stale `cur` (e.g. the match set shrank) is taken modulo len.
        let hits = vec![m(0, 0, 1), m(1, 0, 1)];
        assert_eq!(next_index(&hits, 99), Some((99 % 2 + 1) % 2));
        assert_eq!(prev_index(&hits, 99), Some((99 % 2 + 1) % 2));
    }

    #[test]
    fn next_prev_empty_is_none() {
        assert_eq!(next_index(&[], 0), None);
        assert_eq!(prev_index(&[], 0), None);
    }

    #[test]
    fn blank_lines_between_matches_keep_line_indices_accurate() {
        let text = "hit\n\n\nhit";
        let hits = find_matches(text, "hit", Case::Sensitive);
        assert_eq!(hits, vec![m(0, 0, 3), m(3, 0, 3)]);
    }

    // MARK: - find_in_table (CSV cell-find, parity with Swift CSVFind)

    fn cells(rows: &[&[&str]]) -> Vec<Vec<String>> {
        rows.iter().map(|r| r.iter().map(std::string::ToString::to_string).collect()).collect()
    }
    fn hdr(names: &[&str]) -> Vec<String> {
        names.iter().map(std::string::ToString::to_string).collect()
    }
    fn th(row: i64, col: usize) -> TableHit {
        TableHit { row, col }
    }

    #[test]
    fn table_find_empty_query_is_none() {
        let h = hdr(&["Name", "City"]);
        let r = cells(&[&["Alice", "NYC"]]);
        assert!(find_in_table(&h, &r, "", Case::Insensitive, true, None).is_empty());
    }

    #[test]
    fn table_find_reading_order_header_then_rows_left_to_right() {
        let h = hdr(&["Name", "City"]);
        let r = cells(&[&["Alice", "NYC"], &["Bob", "LA"], &["Carol", "Austin"]]);
        // "a" (insensitive): header "Name"(-1,0); Alice(0,0); LA(1,1); Carol(2,0); Austin(2,1).
        let hits = find_in_table(&h, &r, "a", Case::Insensitive, true, None);
        assert_eq!(hits, vec![
            th(TABLE_HEADER_ROW, 0),
            th(0, 0),
            th(1, 1),
            th(2, 0),
            th(2, 1),
        ]);
    }

    #[test]
    fn table_find_case_sensitive_vs_insensitive() {
        let h = hdr(&["Name"]);
        let r = cells(&[&["alice"], &["Alice"]]);
        // Sensitive "Alice" hits only the capitalized data cell.
        assert_eq!(
            find_in_table(&h, &r, "Alice", Case::Sensitive, false, None),
            vec![th(1, 0)]
        );
        // Insensitive "alice" hits both.
        assert_eq!(
            find_in_table(&h, &r, "alice", Case::Insensitive, false, None),
            vec![th(0, 0), th(1, 0)]
        );
    }

    #[test]
    fn table_find_include_header_toggle() {
        let h = hdr(&["Name", "City"]);
        let r = cells(&[&["Alice", "NYC"]]);
        // "name" with header excluded → no hit.
        assert!(find_in_table(&h, &r, "name", Case::Insensitive, false, None).is_empty());
        // included → the header cell.
        assert_eq!(
            find_in_table(&h, &r, "name", Case::Insensitive, true, None),
            vec![th(TABLE_HEADER_ROW, 0)]
        );
    }

    #[test]
    fn table_find_column_scope_and_out_of_range() {
        let h = hdr(&["Name", "City"]);
        let r = cells(&[&["Alice", "NYC"], &["Bob", "LA"], &["Carol", "Austin"]]);
        // "a" restricted to column 1 (City): LA(1,1), Austin(2,1).
        assert_eq!(
            find_in_table(&h, &r, "a", Case::Insensitive, false, Some(1)),
            vec![th(1, 1), th(2, 1)]
        );
        // Out-of-range column → nothing.
        assert!(find_in_table(&h, &r, "a", Case::Insensitive, true, Some(99)).is_empty());
    }

    #[test]
    fn table_find_no_match_and_empty_table() {
        let h = hdr(&["Name"]);
        let r = cells(&[&["Alice"]]);
        assert!(find_in_table(&h, &r, "zzz", Case::Insensitive, true, None).is_empty());
        // Empty table (no header, no rows) → no hits, no panic. The empty `rows`
        // slice needs a type now that `find_in_table` is generic over the row type.
        let empty: &[Vec<String>] = &[];
        assert!(find_in_table(&[], empty, "x", Case::Insensitive, true, None).is_empty());
    }

    #[test]
    fn table_find_substring_not_just_equality() {
        let h = hdr(&["x"]);
        let r = cells(&[&["foobar"]]);
        assert_eq!(
            find_in_table(&h, &r, "oba", Case::Insensitive, false, None),
            vec![th(0, 0)]
        );
    }

    #[test]
    fn table_find_navigation_wraps_via_existing_modulo() {
        // The hit list is a flat Vec, so next/prev wraparound reuses the same
        // modulo math as next_index/prev_index over its length.
        let h = hdr(&["a"]);
        let r = cells(&[&["a"], &["a"], &["a"]]);
        let hits = find_in_table(&h, &r, "a", Case::Insensitive, false, None);
        assert_eq!(hits.len(), 3);
        let n = hits.len();
        assert_eq!((2 + 1) % n, 0, "forward from last wraps to first");
        assert_eq!((n - 1) % n, 2, "backward from first wraps to last");
    }
}
