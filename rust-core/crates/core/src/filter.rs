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

/// Apply `query` to `table.rows`, returning surviving `(indices, rows)`.
/// `indices` are the original body-row indices (parallel to the returned
/// rows), preserving original line numbers for the projection.
#[must_use]
pub fn apply(table: &Table, query: &Query) -> (Vec<u32>, Vec<Vec<String>>) {
    if query.is_empty() {
        let indices = (0..table.rows.len())
            .map(|i| u32::try_from(i).unwrap_or(u32::MAX))
            .collect();
        return (indices, table.rows.clone());
    }

    let needle = query.text.to_lowercase();
    let mut indices = Vec::new();
    let mut rows = Vec::new();

    for (i, row) in table.rows.iter().enumerate() {
        let matched = match &query.scope {
            Scope::All => row.iter().any(|cell| cell.to_lowercase().contains(&needle)),
            Scope::Column(c) => row
                .get(*c)
                .is_some_and(|cell| cell.to_lowercase().contains(&needle)),
        };
        if matched {
            indices.push(u32::try_from(i).unwrap_or(u32::MAX));
            rows.push(row.clone());
        }
    }

    (indices, rows)
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
