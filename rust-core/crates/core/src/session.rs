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

use crate::filter::Query;
use crate::table_arena::TableArena;
use crate::trace::{self, Level};
use crate::wire::{self, Snapshot, Table, WireFault};
use serde::Serialize;

/// A parsed CSV table plus its active filter. Owns all state for one open CSV.
///
/// Storage is the [`TableArena`] (TSK-546): one contiguous text buffer + a
/// flat offset table instead of the wire DTO's `Vec<Vec<String>>` — the
/// per-keystroke filter scan walks linear memory, and a 1M-cell table costs
/// 2 resident heap blocks instead of ~2M+.
#[derive(Debug)]
pub struct CsvSession {
    arena: TableArena,
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
        // Parse STRAIGHT into the arena (TSK-844) — no throwaway
        // `Vec<Vec<String>>`, no per-cell `String`, no second byte copy.
        let arena = crate::csv::parse_arena(text);
        if trace::sink_installed() {
            trace::event(
                Level::Info,
                "session.opened",
                vec![("rows", arena.row_count().to_string())],
            );
        }
        Ok(Self {
            arena,
            query: Query::empty(),
            version: 1,
            cached: None,
        })
    }

    /// The arena store (read-only borrow) — span accessors without
    /// materializing a wire [`Table`].
    #[must_use]
    pub fn arena(&self) -> &TableArena {
        &self.arena
    }

    /// Materialize the parsed table as an owned wire [`Table`] (tests /
    /// callers that need the DTO). The FFI full-table pull should use
    /// [`CsvSession::table_frame`], which encodes straight from spans.
    #[must_use]
    pub fn to_table(&self) -> Table {
        self.arena.to_table()
    }

    /// Encode the full table as a length-prefixed MessagePack frame,
    /// byte-identical to `wire::encode_frame(&self.to_table())` but without
    /// materializing the owned DTO (the `mdvcore_session_table` path).
    ///
    /// # Errors
    /// [`WireFault::Encode`] / [`WireFault::TooLarge`] per `encode_frame`.
    pub fn table_frame(&self) -> Result<Vec<u8>, WireFault> {
        self.arena.table_frame()
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
        if trace::sink_installed() {
            trace::event(
                Level::Info,
                "session.filter_changed",
                vec![("version", self.version.to_string())],
            );
        }
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
            header: self.arena.header_vec().into_iter().map(str::to_string).collect(),
            indices,
            rows,
            total_rows: u32::try_from(self.arena.row_count()).unwrap_or(u32::MAX),
            query: self.query.text.clone(),
            version: self.version,
            truncated: self.arena.truncated(),
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
        // Project rows as arena SPANS — `&str` serializes identically to
        // `String`, so the frame matches the owned `Snapshot` exactly.
        let rows: Vec<Vec<&str>> = indices
            .iter()
            .filter(|&&i| (i as usize) < self.arena.row_count())
            .map(|&i| self.arena.row(i as usize).collect())
            .collect();
        let view = SnapshotView {
            header: self.arena.header_vec(),
            indices,
            rows,
            total_rows: u32::try_from(self.arena.row_count()).unwrap_or(u32::MAX),
            query: &self.query.text,
            version: self.version,
            truncated: self.arena.truncated(),
        };
        wire::encode_frame(&view)
    }

    /// Encode a WINDOW of the current visible rows — `indices[offset ..
    /// offset+limit]` — to a length-prefixed frame, instead of the whole
    /// surviving set (TSK-559). This makes filter-as-you-type O(window) per
    /// pull rather than O(table): the consumer pulls only the visible viewport
    /// (± a buffer), so a 1M-row filtered table costs ~one screen of rows per
    /// keystroke and never approaches the 16 MiB wire cap that `snapshot_frame`
    /// hits on large files.
    ///
    /// The frame reuses the EXACT [`SnapshotView`] wire shape, so the existing
    /// decoder reads it unchanged — `indices` carry the ABSOLUTE row ids of the
    /// window (so the consumer knows which rows it got) and `total_rows` is the
    /// table total. The one datum a window omits — the surviving (post-filter)
    /// count needed to size a scrollbar — is served cheaply by
    /// [`CsvSession::filtered_row_count`], so NO new wire field is required.
    ///
    /// Clamping: `offset` past the surviving end yields an empty window (the
    /// consumer scrolled past the last row — valid, not an error); `limit`
    /// saturates at the surviving end.
    ///
    /// # Errors
    /// [`WireFault::Encode`] / [`WireFault::Framing`] per `encode_frame`.
    pub fn snapshot_window_frame(
        &mut self,
        offset: usize,
        limit: usize,
    ) -> Result<Vec<u8>, WireFault> {
        let _span = trace::Span::enter("session.snapshot_window_frame");
        self.ensure_cached();
        let all: &[u32] = self.cached.as_ref().map_or(&[], |view| view.indices.as_slice());
        // Clamp the window into the surviving set.
        let start = offset.min(all.len());
        let end = start.saturating_add(limit).min(all.len());
        // start <= end <= len by construction, so this is always Some; `.get`
        // keeps it panic-free for the no-panic FFI lint wall (TSK-566).
        let indices: &[u32] = all.get(start..end).unwrap_or(&[]);
        let rows: Vec<Vec<&str>> = indices
            .iter()
            .filter(|&&i| (i as usize) < self.arena.row_count())
            .map(|&i| self.arena.row(i as usize).collect())
            .collect();
        let view = SnapshotView {
            header: self.arena.header_vec(),
            indices,
            rows,
            total_rows: u32::try_from(self.arena.row_count()).unwrap_or(u32::MAX),
            query: &self.query.text,
            version: self.version,
            truncated: self.arena.truncated(),
        };
        wire::encode_frame(&view)
    }

    /// The number of rows surviving the current filter (the size of the
    /// windowable set). Cheap — counts cached indices, projects no rows.
    /// Pairs with [`CsvSession::snapshot_window_frame`]: the consumer sizes
    /// its scrollbar from this and pulls only the visible window.
    pub fn filtered_row_count(&mut self) -> usize {
        self.ensure_cached();
        self.cached.as_ref().map_or(0, |view| view.indices.len())
    }

    /// Project the visible rows for `indices` as owned strings from the
    /// arena. Out-of-range indices (which cannot occur for a cache computed
    /// against the current table) project as empty rows via the arena's
    /// no-panic accessors.
    fn project_rows(&self, indices: &[u32]) -> Vec<Vec<String>> {
        indices
            .iter()
            .filter(|&&i| (i as usize) < self.arena.row_count())
            .map(|&i| self.arena.row(i as usize).map(str::to_string).collect())
            .collect()
    }

    fn ensure_cached(&mut self) {
        let needs_recompute = self
            .cached
            .as_ref()
            .is_none_or(|c| c.for_version != self.version);
        if needs_recompute {
            // Cache the surviving indices only; rows are projected on demand.
            // The arena scan runs the match loop over ONE contiguous buffer
            // (no per-cell pointer chase) — match semantics live in
            // `filter::CellMatcher`, shared with the Vec-based paths.
            let indices = self.arena.matching_indices(&self.query);
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
    header: Vec<&'a str>,
    indices: &'a [u32],
    rows: Vec<Vec<&'a str>>,
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
        assert_eq!(s.to_table().header, vec!["name", "city"]);
        assert_eq!(s.arena().row_count(), 3);
        assert_eq!(s.version(), 1);
    }

    /// TSK-546 — the arena store must encode the SAME full-table frame the
    /// wire DTO would: byte-identical to encoding the materialized Table.
    #[test]
    fn table_frame_matches_owned_table_encode() {
        let s = CsvSession::open(CSV.as_bytes()).unwrap();
        assert_eq!(
            s.table_frame().unwrap(),
            wire::encode_frame(&s.to_table()).unwrap(),
            "span-projected table frame must be byte-identical to the DTO frame"
        );
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

    /// TSK-142/143 — the filter cache must hold INDICES ONLY, never a
    /// second copy of the row data. The audited leak was a resident
    /// `Vec<Vec<String>>` duplicate of `table.rows` living in the cache
    /// for the session lifetime (verbatim on the unfiltered fast path),
    /// plus per-snapshot deep clones of the full filtered rowset. The
    /// size assertion fails if row storage is reintroduced into
    /// `CachedView`; referencing `.indices` fails to COMPILE if the
    /// field is replaced by row storage under another name.
    #[test]
    fn cache_is_indices_only_no_resident_row_copy() {
        assert_eq!(
            core::mem::size_of::<CachedView>(),
            core::mem::size_of::<u64>() + core::mem::size_of::<Vec<u32>>(),
            "CachedView grew beyond {{for_version, indices}} — a resident row copy was reintroduced?"
        );
        let mut s = CsvSession::open(CSV.as_bytes()).unwrap();
        s.set_filter(Query {
            text: "par".into(),
            scope: Scope::All,
        });
        let snap_a = s.snapshot();
        let snap_b = s.snapshot(); // repeated pulls must serve from the cache
        assert_eq!(snap_a.indices, snap_b.indices);
        let cached = s.cached.as_ref().expect("snapshot populates the cache");
        assert_eq!(cached.for_version, s.version());
        assert_eq!(
            cached.indices, snap_a.indices,
            "cache must hold exactly the surviving original-row indices"
        );
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
