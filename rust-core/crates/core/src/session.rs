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
use crate::wire::{self, Snapshot, Table, WireFault};
use serde::Serialize;

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
    // Only the surviving original row indices are cached. The visible rows are
    // projected on demand from `self.table.rows` via these indices, so the
    // session never holds a second full copy of the (possibly multi-MB) body —
    // the unfiltered fast path in particular previously duplicated `table.rows`
    // verbatim for the whole session lifetime.
    indices: Vec<u32>,
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
    ///
    /// This builds an OWNED [`Snapshot`] (cloning the visible rows). When the
    /// caller only needs the serialized wire frame (the FFI path), prefer
    /// [`CsvSession::snapshot_frame`], which encodes from borrows and skips the
    /// per-pull row clone entirely.
    pub fn snapshot(&mut self) -> Snapshot {
        let _span = trace::Span::enter("session.snapshot");
        self.ensure_cached();
        // ensure_cached guarantees `cached` is Some for the current version.
        let indices = self
            .cached
            .as_ref()
            .map(|view| view.indices.clone())
            .unwrap_or_default();
        let rows = self.project_rows(&indices);
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

    /// Encode a level-triggered snapshot directly to a length-prefixed
    /// MessagePack frame, WITHOUT materializing an owned [`Snapshot`] (so the
    /// visible rows are never cloned — they are serialized straight from
    /// borrows of `self.table.rows`). Byte-for-byte identical to
    /// `wire::encode_frame(&self.snapshot())`.
    ///
    /// This is the allocation-light path for the FFI pull, which only ever
    /// needs the frame bytes.
    ///
    /// # Errors
    /// Returns [`WireFault::Encode`] on serialization failure or
    /// [`WireFault::Framing`] if the encoded frame exceeds the wire cap.
    pub fn snapshot_frame(&mut self) -> Result<Vec<u8>, WireFault> {
        let _span = trace::Span::enter("session.snapshot_frame");
        self.ensure_cached();
        // ensure_cached guarantees `cached` is Some for the current version; an
        // empty index slice (no surviving rows) is the safe fallback.
        let indices: &[u32] = self.cached.as_ref().map_or(&[], |view| view.indices.as_slice());
        // Project rows as BORROWS — `&Vec<String>` serializes identically to
        // `Vec<String>`, so the frame matches the owned `Snapshot` exactly.
        let rows: Vec<&Vec<String>> = indices
            .iter()
            .filter_map(|&i| self.table.rows.get(i as usize))
            .collect();
        let view = SnapshotView {
            header: &self.table.header,
            indices,
            rows: &rows,
            total_rows: u32::try_from(self.table.rows.len()).unwrap_or(u32::MAX),
            query: &self.query.text,
            version: self.version,
            truncated: self.table.truncated,
        };
        wire::encode_frame(&view)
    }

    /// Project the visible rows for `indices` by borrowing from
    /// `self.table.rows`. Out-of-range indices (which cannot occur for a cache
    /// computed against the current table) are skipped rather than panicking.
    fn project_rows(&self, indices: &[u32]) -> Vec<Vec<String>> {
        indices
            .iter()
            .filter_map(|&i| self.table.rows.get(i as usize).cloned())
            .collect()
    }

    fn ensure_cached(&mut self) {
        let needs_recompute = self
            .cached
            .as_ref()
            .is_none_or(|c| c.for_version != self.version);
        if needs_recompute {
            // Cache the surviving indices only; rows are projected on demand.
            // `filter::matching_indices` runs the match loop WITHOUT cloning any
            // row — both the (default) empty-query identity path and the
            // non-empty filter path go through it, so the match semantics live
            // in one place and the session never materializes a row clone it
            // would immediately discard.
            let indices = filter::matching_indices(&self.table, &self.query);
            self.cached = Some(CachedView {
                for_version: self.version,
                indices,
            });
        }
    }
}

/// Borrow-based serialization mirror of [`Snapshot`]. Field names and types
/// match `Snapshot` exactly so `to_vec_named` produces a byte-identical frame,
/// but every field is a borrow — encoding does not clone the visible rows.
///
/// Kept private: this is purely an internal serialize-only helper for
/// [`CsvSession::snapshot_frame`]; callers that need an owned value use
/// [`Snapshot`].
#[derive(Serialize)]
struct SnapshotView<'a> {
    header: &'a [String],
    indices: &'a [u32],
    rows: &'a [&'a Vec<String>],
    total_rows: u32,
    query: &'a str,
    version: u64,
    truncated: bool,
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
