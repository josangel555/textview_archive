//! Row filtering for a parsed [`Table`]. Pure value logic, mirroring the
//! Swift `CSVFilter`'s global-query semantics:
//!
//!   - `query` is a case-insensitive substring match.
//!   - when `scope == Scope::All`, a row matches if ANY cell contains the
//!     needle; `Scope::Column(i)` restricts to column `i`.
//!   - an empty query matches everything.
//!
//! The Swift impl also has per-column operator expressions (`>`, `>=`, `=`,
//! …); for the PoC slice we implement the global-query path (the part Stage 2
//! exercises via `setFilter(q)`), which is the load-bearing case for the
//! level-triggered snapshot test. Per-column expressions are noted as deferred
//! in STATUS.md — adding them is mechanical and doesn't change the FFI shape.

use crate::wire::Table;

/// Scope of the global query.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Scope {
    /// Match against any column.
    All,
    /// Restrict the match to a single column index.
    Column(usize),
}

/// A filter query applied to a table's body rows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Query {
    /// The raw query string (matched case-insensitively as a substring).
    pub text: String,
    /// Which column(s) to search.
    pub scope: Scope,
}

impl Query {
    /// A query that matches every row.
    #[must_use]
    pub fn empty() -> Self {
        Self {
            text: String::new(),
            scope: Scope::All,
        }
    }

    /// Whether this query matches everything (no filtering work needed).
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.text.is_empty()
    }
}

/// Apply `query` to `table.rows`, returning the surviving original body-row
/// indices — WITHOUT cloning any row data. `indices` preserve the original line
/// numbers for projection.
///
/// This is the allocation-light filter path: callers that hold the table (e.g.
/// `CsvSession`) project the visible rows on demand from these indices, so the
/// match loop never duplicates the (possibly multi-MB) body.
#[must_use]
pub fn matching_indices(table: &Table, query: &Query) -> Vec<u32> {
    matching_indices_in(&table.rows, query)
}

/// Like [`matching_indices`] but over a bare row set — for callers (the
/// front-end view-model) that hold `header`/`rows` directly without a wire
/// [`Table`]. [`matching_indices`] delegates here so the match semantics live in
/// exactly one place.
#[must_use]
pub fn matching_indices_in(rows: &[Vec<String>], query: &Query) -> Vec<u32> {
    if query.is_empty() {
        return (0..rows.len())
            .map(|i| u32::try_from(i).unwrap_or(u32::MAX))
            .collect();
    }

    let matcher = CellMatcher::new(&query.text);
    let mut indices = Vec::new();
    for (i, row) in rows.iter().enumerate() {
        let matched = match &query.scope {
            Scope::All => row.iter().any(|cell| matcher.matches(cell)),
            Scope::Column(c) => row.get(*c).is_some_and(|cell| matcher.matches(cell)),
        };
        if matched {
            indices.push(u32::try_from(i).unwrap_or(u32::MAX));
        }
    }

    indices
}

/// The per-cell match predicate, factored out so every row-storage layout
/// (the `Vec<Vec<String>>` paths here, the [`crate::table_arena::TableArena`]
/// scan) shares ONE home for the match semantics — the Unicode-parity suite
/// below pins it once for all of them.
#[derive(Debug)]
pub struct CellMatcher {
    needle: String,
    needle_is_ascii: bool,
}

impl CellMatcher {
    /// Build a matcher for `query_text` (folded once, reused per cell).
    #[must_use]
    pub fn new(query_text: &str) -> Self {
        // ASCII fast path is only valid when the lowercased needle is itself
        // ASCII. (`to_lowercase` maps ASCII to ASCII — but the *query* may
        // already contain non-ASCII, so guard on the result.) When the needle
        // has any non-ASCII byte we always take the `to_lowercase()` Unicode
        // path for byte-identity with the Swift impl.
        let needle = query_text.to_lowercase();
        let needle_is_ascii = needle.is_ascii();
        Self { needle, needle_is_ascii }
    }

    /// Case-insensitive substring test for one cell.
    #[must_use]
    pub fn matches(&self, cell: &str) -> bool {
        // ASCII-vs-ASCII: a no-alloc `eq_ignore_ascii_case` byte-window scan.
        // For ASCII data this is exactly equivalent to
        // `cell.to_lowercase().contains(&needle)` — both fold `A-Z` → `a-z`
        // and leave every other byte untouched. Non-ASCII cells (or a
        // non-ASCII needle) fall back to the Unicode `to_lowercase()` path so
        // Unicode case-folding semantics stay identical to Swift.
        if self.needle_is_ascii && cell.is_ascii() {
            ascii_contains_ignore_case(cell.as_bytes(), self.needle.as_bytes())
        } else {
            cell.to_lowercase().contains(&self.needle)
        }
    }
}

/// No-alloc, no-panic case-insensitive substring test for ASCII byte strings.
///
/// Returns whether `haystack` contains `needle` ignoring ASCII case. Mirrors
/// `haystack.to_lowercase().contains(&needle.to_lowercase())` for ASCII-only
/// inputs without allocating. Callers must ensure both slices are ASCII; this is
/// only invoked on that fast path.
///
/// No-panic: uses `slice::windows` (yields nothing when `needle` is longer than
/// `haystack`, never indexes out of bounds). An empty `needle` matches anything,
/// matching `str::contains("")`.
fn ascii_contains_ignore_case(haystack: &[u8], needle: &[u8]) -> bool {
    if needle.is_empty() {
        return true;
    }
    haystack
        .windows(needle.len())
        .any(|window| window.eq_ignore_ascii_case(needle))
}

/// Apply `query` to `table.rows`, returning surviving `(indices, rows)`.
/// `indices` are the original body-row indices (parallel to the returned
/// rows), preserving original line numbers for the projection.
///
/// Expressed as [`matching_indices`] + a projection so the match semantics live
/// in exactly one place. Callers that only need the indices should call
/// [`matching_indices`] directly to skip the row clones.
#[must_use]
pub fn apply(table: &Table, query: &Query) -> (Vec<u32>, Vec<Vec<String>>) {
    apply_rows(&table.rows, query)
}

/// Like [`apply`] but over a bare row set — for the front-end view-model, which
/// holds `header`/`rows` directly without a wire [`Table`]. Returns the surviving
/// `(indices, rows)`; `indices` are the original body-row indices (parallel to
/// the returned rows).
#[must_use]
pub fn apply_rows(rows: &[Vec<String>], query: &Query) -> (Vec<u32>, Vec<Vec<String>>) {
    let indices = matching_indices_in(rows, query);
    let out = indices.iter().filter_map(|&i| rows.get(i as usize).cloned()).collect();
    (indices, out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    /// TSK-585 (proptest lane): differential property — `matching_indices_in` must
    /// equal a naive case-insensitive substring filter for arbitrary rows × query.
    /// ASCII inputs exercise the no-alloc fast path (`ascii_contains_ignore_case`),
    /// which must agree with `to_lowercase().contains()`. Built-in strategies (no
    /// custom Arbitrary); a Unicode-input suite can follow.
    fn naive_matching(rows: &[Vec<String>], query: &str) -> Vec<u32> {
        if query.is_empty() {
            return (0..rows.len())
                .map(|i| u32::try_from(i).unwrap_or(u32::MAX))
                .collect();
        }
        let q = query.to_lowercase();
        rows.iter()
            .enumerate()
            .filter(|(_, row)| row.iter().any(|c| c.to_lowercase().contains(&q)))
            .map(|(i, _)| u32::try_from(i).unwrap_or(u32::MAX))
            .collect()
    }

    proptest! {
        #[test]
        fn matching_indices_equals_naive(
            rows in prop::collection::vec(
                prop::collection::vec("[a-zA-Z0-9 ]{0,6}", 0..4), 0..16),
            query in "[a-zA-Z0-9 ]{0,4}",
        ) {
            let q = Query { text: query.clone(), scope: Scope::All };
            prop_assert_eq!(matching_indices_in(&rows, &q), naive_matching(&rows, &query));
        }
    }

    fn table() -> Table {
        Table {
            delimiter: ",".into(),
            header: vec!["name".into(), "city".into()],
            rows: vec![
                vec!["Alice".into(), "Paris".into()],
                vec!["Bob".into(), "Parma".into()],
                vec!["Carol".into(), "Berlin".into()],
            ],
            truncated: false,
        }
    }

    #[test]
    fn empty_query_matches_all() {
        let (idx, rows) = apply(&table(), &Query::empty());
        assert_eq!(idx, vec![0, 1, 2]);
        assert_eq!(rows.len(), 3);
    }

    #[test]
    fn matching_indices_empty_query_is_identity() {
        assert_eq!(matching_indices(&table(), &Query::empty()), vec![0, 1, 2]);
    }

    #[test]
    fn matching_indices_matches_apply_indices() {
        // The index half of `apply` must be byte-identical to `matching_indices`
        // across the same set of queries (apply is expressed in terms of it).
        let t = table();
        let queries = [
            Query::empty(),
            Query {
                text: "par".into(),
                scope: Scope::All,
            },
            Query {
                text: "a".into(),
                scope: Scope::Column(0),
            },
            Query {
                text: "zzz".into(),
                scope: Scope::All,
            },
            Query {
                text: "a".into(),
                scope: Scope::Column(99),
            },
        ];
        for q in &queries {
            let (apply_idx, apply_rows) = apply(&t, q);
            let idx = matching_indices(&t, q);
            assert_eq!(apply_idx, idx, "index parity for {q:?}");
            // And the projected rows are exactly the rows at those indices.
            let projected: Vec<Vec<String>> =
                idx.iter().map(|&i| t.rows[i as usize].clone()).collect();
            assert_eq!(apply_rows, projected, "row projection parity for {q:?}");
        }
    }

    #[test]
    fn case_insensitive_substring_any_column() {
        let q = Query {
            text: "par".into(),
            scope: Scope::All,
        };
        let (idx, _rows) = apply(&table(), &q);
        // "Paris" and "Parma" both contain "par".
        assert_eq!(idx, vec![0, 1]);
    }

    #[test]
    fn column_scoped() {
        let q = Query {
            text: "a".into(),
            scope: Scope::Column(0),
        };
        let (idx, _) = apply(&table(), &q);
        // Names containing 'a' (case-insensitive): Alice, Carol.
        assert_eq!(idx, vec![0, 2]);
    }

    #[test]
    fn no_match() {
        let q = Query {
            text: "zzz".into(),
            scope: Scope::All,
        };
        let (idx, rows) = apply(&table(), &q);
        assert!(idx.is_empty());
        assert!(rows.is_empty());
    }

    #[test]
    fn out_of_range_column_matches_nothing() {
        let q = Query {
            text: "a".into(),
            scope: Scope::Column(99),
        };
        let (idx, _) = apply(&table(), &q);
        assert!(idx.is_empty());
    }

    // --- ASCII fast-path / Unicode fallback parity ---------------------------

    /// Reference implementation: the exact pre-optimization match semantics
    /// (`to_lowercase().contains` everywhere). The optimized `matching_indices`
    /// MUST be byte-identical to filtering with this for every query/table.
    fn reference_indices(table: &Table, query: &Query) -> Vec<u32> {
        if query.is_empty() {
            return (0..table.rows.len())
                .map(|i| u32::try_from(i).unwrap_or(u32::MAX))
                .collect();
        }
        let needle = query.text.to_lowercase();
        let mut out = Vec::new();
        for (i, row) in table.rows.iter().enumerate() {
            let matched = match &query.scope {
                Scope::All => row.iter().any(|c| c.to_lowercase().contains(&needle)),
                Scope::Column(c) => row
                    .get(*c)
                    .is_some_and(|cell| cell.to_lowercase().contains(&needle)),
            };
            if matched {
                out.push(u32::try_from(i).unwrap_or(u32::MAX));
            }
        }
        out
    }

    fn unicode_table() -> Table {
        Table {
            delimiter: ",".into(),
            header: vec!["place".into(), "note".into()],
            rows: vec![
                // Dotted capital I (Turkish). `to_lowercase()` folds 'İ' (U+0130)
                // to "i\u{0307}", so "istanbul" does NOT substring-match — the
                // Unicode path must be preserved exactly (no ASCII shortcut).
                vec!["İstanbul".into(), "city".into()],
                // German sharp s. `to_lowercase()` leaves 'ß' as 'ß' (it does not
                // expand to "ss"), so "strasse" must NOT match "Straße".
                vec!["Straße".into(), "road".into()],
                // Plain ASCII control row.
                vec!["Berlin".into(), "Straße-bahn".into()],
                // Uppercase ASCII to exercise the eq_ignore_ascii_case fold.
                vec!["PARIS".into(), "Capital".into()],
            ],
            truncated: false,
        }
    }

    #[test]
    fn unicode_rows_match_reference_across_queries() {
        let t = unicode_table();
        let queries = [
            // ASCII needle vs Unicode cells (mixed): exercises both paths.
            Query { text: "istanbul".into(), scope: Scope::All },
            Query { text: "İstanbul".into(), scope: Scope::All },
            Query { text: "straße".into(), scope: Scope::All },
            Query { text: "strasse".into(), scope: Scope::All },
            Query { text: "ß".into(), scope: Scope::All },
            // ASCII fast path: uppercase needle must match uppercase ASCII cell.
            Query { text: "paris".into(), scope: Scope::All },
            Query { text: "PARIS".into(), scope: Scope::Column(0) },
            // Non-ASCII needle, column-scoped.
            Query { text: "İ".into(), scope: Scope::Column(0) },
            // Empty-needle / no-match edges.
            Query { text: "zzz".into(), scope: Scope::All },
        ];
        for q in &queries {
            assert_eq!(
                matching_indices(&t, q),
                reference_indices(&t, q),
                "Unicode parity mismatch for {q:?}",
            );
        }
    }

    #[test]
    fn dotted_capital_i_does_not_match_ascii_i() {
        // 'İ'.to_lowercase() == "i\u{0307}", so the ASCII substring "istanbul"
        // is NOT present in the folded form — must yield no match, identical to
        // the reference. This is the canonical case the ASCII shortcut would
        // break if it were wrongly applied to non-ASCII cells.
        let t = unicode_table();
        let q = Query { text: "istanbul".into(), scope: Scope::All };
        assert!(matching_indices(&t, &q).is_empty());
        assert_eq!(matching_indices(&t, &q), reference_indices(&t, &q));
    }

    #[test]
    fn sharp_s_does_not_expand_to_ss() {
        // 'ß'.to_lowercase() stays 'ß' (no "ss" expansion), so "strasse" must
        // not match "Straße" — parity with the reference.
        let t = unicode_table();
        let q = Query { text: "strasse".into(), scope: Scope::All };
        assert!(matching_indices(&t, &q).is_empty());
        assert_eq!(matching_indices(&t, &q), reference_indices(&t, &q));
    }

    #[test]
    fn ascii_contains_ignore_case_helper() {
        assert!(ascii_contains_ignore_case(b"Paris", b"par"));
        assert!(ascii_contains_ignore_case(b"PARMA", b"arm"));
        assert!(ascii_contains_ignore_case(b"abc", b"abc"));
        assert!(ascii_contains_ignore_case(b"abc", b"")); // empty matches all
        assert!(!ascii_contains_ignore_case(b"abc", b"abcd")); // needle longer
        assert!(!ascii_contains_ignore_case(b"abc", b"xyz"));
        assert!(!ascii_contains_ignore_case(b"", b"a"));
        assert!(ascii_contains_ignore_case(b"", b"")); // both empty
    }

    #[test]
    fn ascii_fast_path_matches_reference() {
        // The existing ASCII table: the optimized path must equal the reference
        // for the standard query set too (regression guard on the fast path).
        let t = table();
        let queries = [
            Query::empty(),
            Query { text: "par".into(), scope: Scope::All },
            Query { text: "PAR".into(), scope: Scope::All },
            Query { text: "a".into(), scope: Scope::Column(0) },
            Query { text: "zzz".into(), scope: Scope::All },
        ];
        for q in &queries {
            assert_eq!(
                matching_indices(&t, q),
                reference_indices(&t, q),
                "ASCII parity mismatch for {q:?}",
            );
        }
    }
}
