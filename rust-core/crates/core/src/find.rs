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

/// ASCII-fold a string for case-insensitive comparison (no allocation when
/// `Sensitive`). `to_ascii_lowercase` preserves every byte's length, so offsets
/// into the folded string map 1:1 back onto the original.
fn fold(s: &str, case: Case) -> String {
    match case {
        Case::Sensitive => s.to_string(),
        Case::Insensitive => s.to_ascii_lowercase(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(line: usize, start: usize, end: usize) -> Match {
        Match { line, start, end }
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
}
