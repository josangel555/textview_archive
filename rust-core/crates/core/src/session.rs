//! Stateful CSV session — the Stage 2 "the core owns state" type.
//!
//! A [`CsvSession`] owns the parsed [`Table`] AND the active filter [`Query`].
//! The UI sends commands (`set_filter`) and pulls a **level-triggered**
//! [`Snapshot`] of the current visible rows. Level-triggered means: every
//! snapshot is the *complete current state*, never a delta. The projection
//! reconciles against it; a dropped/missed snapshot is self-healing because
//! the next pull carries the full truth (the Kubernetes-reconciliation model
//! from the playbook §4).
//!
//! Idempotency / hot-reload: calling `set_filter` with the same query twice is
//! a no-op (the `version` does not advance) — `snapshot()` is pure with
//! respect to state, so re-pulling without a mutation returns an identical
//! value. This is asserted in tests.
//!
//! Threading: the session is a plain `&mut self` state machine — `Send` but
//! NOT `Sync` (no interior sync). Single-writer is the invariant; the FFI
//! layer enforces it (see `mdvcore-ffi`). We do NOT slap `unsafe impl Sync` on it.

use crate::filter::{self, Query};
use crate::trace::{self, Level};
use crate::wire::{Snapshot, Table};

/// A parsed CSV table plus its active filter. Owns all state for one open CSV.
#[derive(Debug)]
pub struct CsvSession {
    table: Table,
    query: Query,
    version: u64,
    // Cached filtered view, recomputed lazily when the query changes. Stores
    // the version it was computed for so a stale cache is detectable.
    cached: Option<CachedView>,
}

#[derive(Debug)]
struct CachedView {
    for_version: u64,
    indices: Vec<u32>,
    rows: Vec<Vec<String>>,
}

impl CsvSession {
    /// Open a session by parsing `bytes` as UTF-8 CSV.
    ///
    /// # Errors
    /// Returns [`OpenError::BadUtf8`] if the input is not valid UTF-8.
    pub fn open(bytes: &[u8]) -> Result<Self, OpenError> {
        let _span = trace::Span::enter("session.open");
        let text = core::str::from_utf8(bytes).map_err(|e| OpenError::BadUtf8 {
            valid_up_to: e.valid_up_to(),
        })?;
        let table = crate::csv::parse(text);
        trace::event(
            Level::Info,
            "session.opened",
            vec![("rows", table.rows.len().to_string())],
        );
        Ok(Self {
            table,
            query: Query::empty(),
            version: 1,
            cached: None,
        })
    }

    /// Open a session from an already-parsed table (used in tests / when the
    /// caller parsed separately).
    #[must_use]
    pub fn from_table(table: Table) -> Self {
        Self {
            table,
            query: Query::empty(),
            version: 1,
            cached: None,
        }
    }

    /// The parsed table (read-only borrow).
    #[must_use]
    pub fn table(&self) -> &Table {
        &self.table
    }

    /// The active query.
    #[must_use]
    pub fn query(&self) -> &Query {
        &self.query
    }

    /// Current state version (advances on every mutation).
    #[must_use]
    pub fn version(&self) -> u64 {
        self.version
    }

    /// Set the active filter query. Idempotent: setting the same query is a
    /// no-op and does NOT advance the version (hot-reload / replay friendly).
    /// Returns `true` if the state actually changed.
    pub fn set_filter(&mut self, query: Query) -> bool {
        if query == self.query {
            trace::event(Level::Debug, "session.set_filter.noop", vec![]);
            return false;
        }
        let _span = trace::Span::enter("session.set_filter");
        self.query = query;
        self.version += 1;
        self.cached = None; // invalidate
        trace::event(
            Level::Info,
            "session.filter_changed",
            vec![("version", self.version.to_string())],
        );
        true
    }

    /// Produce a level-triggered snapshot of the current visible rows. Pure
    /// w.r.t. state (modulo the internal cache fill), so repeated calls
    /// without a mutation return identical values.
    pub fn snapshot(&mut self) -> Snapshot {
        let _span = trace::Span::enter("session.snapshot");
        self.ensure_cached();
        // ensure_cached guarantees `cached` is Some for the current version.
        let (indices, rows) = match self.cached.as_ref() {
            Some(view) => (view.indices.clone(), view.rows.clone()),
            None => (Vec::new(), Vec::new()),
        };
        Snapshot {
            header: self.table.header.clone(),
            indices,
            rows,
            total_rows: u32::try_from(self.table.rows.len()).unwrap_or(u32::MAX),
            query: self.query.text.clone(),
            version: self.version,
            truncated: self.table.truncated,
        }
    }

    fn ensure_cached(&mut self) {
        let needs_recompute = self
            .cached
            .as_ref()
            .is_none_or(|c| c.for_version != self.version);
        if needs_recompute {
            let (indices, rows) = filter::apply(&self.table, &self.query);
            self.cached = Some(CachedView {
                for_version: self.version,
                indices,
                rows,
            });
        }
    }
}

/// Errors from [`CsvSession::open`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpenError {
    /// Input was not valid UTF-8.
    BadUtf8 {
        /// Byte offset where validity ended.
        valid_up_to: usize,
    },
}

impl core::fmt::Display for OpenError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            OpenError::BadUtf8 { valid_up_to } => {
                write!(
                    f,
                    "input is not valid UTF-8 (valid up to byte {valid_up_to})"
                )
            }
        }
    }
}

impl std::error::Error for OpenError {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::filter::Scope;

    const CSV: &str = "name,city\nAlice,Paris\nBob,Parma\nCarol,Berlin\n";

    #[test]
    fn open_parses() {
        let s = CsvSession::open(CSV.as_bytes()).unwrap();
        assert_eq!(s.table().header, vec!["name", "city"]);
        assert_eq!(s.table().rows.len(), 3);
        assert_eq!(s.version(), 1);
    }

    #[test]
    fn open_rejects_bad_utf8() {
        let err = CsvSession::open(&[0x61, 0xFF, 0x62]).unwrap_err();
        assert!(matches!(err, OpenError::BadUtf8 { .. }));
    }

    #[test]
    fn snapshot_unfiltered_shows_all() {
        let mut s = CsvSession::open(CSV.as_bytes()).unwrap();
        let snap = s.snapshot();
        assert_eq!(snap.total_rows, 3);
        assert_eq!(snap.rows.len(), 3);
        assert_eq!(snap.indices, vec![0, 1, 2]);
        assert_eq!(snap.version, 1);
    }

    #[test]
    fn set_filter_changes_visible_rows() {
        let mut s = CsvSession::open(CSV.as_bytes()).unwrap();
        let changed = s.set_filter(Query {
            text: "par".into(),
            scope: Scope::All,
        });
        assert!(changed);
        let snap = s.snapshot();
        assert_eq!(snap.rows.len(), 2); // Paris, Parma
        assert_eq!(snap.indices, vec![0, 1]);
        assert_eq!(snap.total_rows, 3);
        assert_eq!(snap.version, 2);
    }

    #[test]
    fn set_filter_is_idempotent() {
        let mut s = CsvSession::open(CSV.as_bytes()).unwrap();
        let q = Query {
            text: "par".into(),
            scope: Scope::All,
        };
        assert!(s.set_filter(q.clone()));
        let v_after = s.version();
        // Same query again → no change, version frozen.
        assert!(!s.set_filter(q));
        assert_eq!(s.version(), v_after);
    }

    #[test]
    fn snapshot_is_level_triggered_and_stable() {
        // Pulling the snapshot repeatedly without a mutation yields identical
        // full-state values (the reconciliation contract).
        let mut s = CsvSession::open(CSV.as_bytes()).unwrap();
        s.set_filter(Query {
            text: "a".into(),
            scope: Scope::All,
        });
        let a = s.snapshot();
        let b = s.snapshot();
        assert_eq!(a, b);
    }

    #[test]
    fn clearing_filter_restores_all_rows() {
        let mut s = CsvSession::open(CSV.as_bytes()).unwrap();
        s.set_filter(Query {
            text: "berlin".into(),
            scope: Scope::All,
        });
        assert_eq!(s.snapshot().rows.len(), 1);
        s.set_filter(Query::empty());
        let snap = s.snapshot();
        assert_eq!(snap.rows.len(), 3);
        assert_eq!(snap.version, 3); // open=1, set berlin=2, clear=3
    }
}
