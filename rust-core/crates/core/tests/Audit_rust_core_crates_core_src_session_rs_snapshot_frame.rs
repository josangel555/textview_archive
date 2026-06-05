//! Regression coverage for the S3/perf audit fix in
//! `rust-core/crates/core/src/session.rs`:
//!
//!   - `CachedView` no longer retains a second full copy of the visible rows
//!     (it caches only `indices`); the snapshot projects rows from
//!     `table.rows` on demand.
//!   - `CsvSession::snapshot_frame()` encodes the level-triggered snapshot
//!     directly from borrows, skipping the per-pull row clone. Its output MUST
//!     be byte-for-byte identical to `wire::encode_frame(&session.snapshot())`,
//!     and round-trip back to an equal `Snapshot`.
//!
//! Integration test (separate crate) so it only touches the public API.

use mdvcore_core::filter::{Query, Scope};
use mdvcore_core::session::CsvSession;
use mdvcore_core::wire::{self, Snapshot};

const CSV: &str = "name,city\nAlice,Paris\nBob,Parma\nCarol,Berlin\n";

/// The borrow-based frame must equal the owned-snapshot frame, unfiltered.
#[test]
fn snapshot_frame_matches_owned_unfiltered() {
    let mut s = CsvSession::open(CSV.as_bytes()).unwrap();

    let owned = s.snapshot();
    let owned_frame = wire::encode_frame(&owned).unwrap();
    let borrow_frame = s.snapshot_frame().unwrap();

    assert_eq!(
        owned_frame, borrow_frame,
        "snapshot_frame must be byte-identical to encode_frame(&snapshot())"
    );

    // And it must decode back to the same Snapshot.
    let decoded: Snapshot = wire::decode_frame(&borrow_frame).unwrap();
    assert_eq!(decoded, owned);
    assert_eq!(decoded.rows.len(), 3);
    assert_eq!(decoded.indices, vec![0, 1, 2]);
    assert_eq!(decoded.total_rows, 3);
}

/// Same equivalence under an active filter (the non-fast-path projection).
#[test]
fn snapshot_frame_matches_owned_filtered() {
    let mut s = CsvSession::open(CSV.as_bytes()).unwrap();
    s.set_filter(Query {
        text: "par".into(),
        scope: Scope::All,
    });

    let owned = s.snapshot();
    let owned_frame = wire::encode_frame(&owned).unwrap();
    let borrow_frame = s.snapshot_frame().unwrap();

    assert_eq!(owned_frame, borrow_frame);

    let decoded: Snapshot = wire::decode_frame(&borrow_frame).unwrap();
    assert_eq!(decoded, owned);
    assert_eq!(decoded.rows.len(), 2); // Paris, Parma
    assert_eq!(decoded.indices, vec![0, 1]);
    assert_eq!(decoded.total_rows, 3);
}

/// Empty result set still produces a valid, matching frame.
#[test]
fn snapshot_frame_matches_owned_no_match() {
    let mut s = CsvSession::open(CSV.as_bytes()).unwrap();
    s.set_filter(Query {
        text: "zzz-no-such-needle".into(),
        scope: Scope::All,
    });

    let owned = s.snapshot();
    let owned_frame = wire::encode_frame(&owned).unwrap();
    let borrow_frame = s.snapshot_frame().unwrap();

    assert_eq!(owned_frame, borrow_frame);

    let decoded: Snapshot = wire::decode_frame(&borrow_frame).unwrap();
    assert_eq!(decoded, owned);
    assert!(decoded.rows.is_empty());
    assert!(decoded.indices.is_empty());
    assert_eq!(decoded.total_rows, 3);
}

/// Equivalence holds across a filter change (cache invalidation + reproject)
/// and is stable across repeated pulls (level-triggered contract).
#[test]
fn snapshot_frame_stable_across_refilter_and_repull() {
    let mut s = CsvSession::open(CSV.as_bytes()).unwrap();

    s.set_filter(Query {
        text: "berlin".into(),
        scope: Scope::All,
    });
    let f1a = s.snapshot_frame().unwrap();
    let f1b = s.snapshot_frame().unwrap();
    assert_eq!(f1a, f1b, "repeated pulls without a mutation must be identical");
    assert_eq!(f1a, wire::encode_frame(&s.snapshot()).unwrap());

    // Clear the filter: all rows return, frame must track the new state.
    s.set_filter(Query::empty());
    let f2 = s.snapshot_frame().unwrap();
    assert_ne!(f1a, f2, "frame must reflect the new (unfiltered) state");
    assert_eq!(f2, wire::encode_frame(&s.snapshot()).unwrap());

    let decoded: Snapshot = wire::decode_frame(&f2).unwrap();
    assert_eq!(decoded.rows.len(), 3);
}
