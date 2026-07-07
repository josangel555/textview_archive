//! TSK-1516 (stateful-core S1) — the rust-owned editor document session.
//!
//! `EditorSession` is the concrete document type the whole-core migration
//! hangs off (design: `docs/research/stateful-core-spike-2026-07-04/DESIGN.md`):
//! a [`CmDoc`] UTF-16 mirror plus the three pieces of DOCUMENT state that
//! Swift's `EditorBuffer` owns today —
//!
//!   * a **saved baseline** for content-based dirty detection (`is_dirty` is
//!     `fingerprint(now) != fingerprint(saved)`, so an edit that is later
//!     reverted byte-for-byte reads CLEAN again — better than Swift's sticky
//!     dirty flag),
//!   * an append-only **op-log** of applied edit batches (durability /
//!     local-history feed; interactive undo deliberately STAYS in CM6), with
//!     a compaction mechanism so a long typing session cannot grow the log
//!     without bound, and
//!   * document **meta** (url, language, the on-disk `(mtime,size)` baseline
//!     the external-change watcher compares against).
//!
//! Contracts pinned by the tests below:
//!   1. REPLAY LAW — replaying the op-log over the initial snapshot always
//!      reproduces the current text (also across `compact_log`).
//!   2. DIRTY LAW — content-based: new/`mark_saved` ⇒ clean; a content change
//!      ⇒ dirty; reverting to baseline content ⇒ clean again.
//!   3. ATOMICITY — a rejected batch changes NOTHING (text, rev, log, dirty),
//!      mirroring `CmDoc::apply_delta`'s apply-or-reject contract.
//!   4. NOOP — an empty batch bumps nothing.
//!
//! Dirty detection uses a 64-bit content fingerprint (`hash + len`): a false
//! CLEAN needs a same-length 64-bit collision against the baseline. That is
//! an acceptable bar for dirty UX/eviction-pinning; the save path must (and
//! does, by design) write the CURRENT text, never trust the fingerprint.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};

use crate::cm_edit::{ChangedRegion, CmDoc, CmEdit};

/// Content fingerprint: 64-bit hash + length in UTF-16 units. Length rides
/// along so the common "same hash, different size" corruption class can never
/// alias, and comparisons stay O(1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Fingerprint {
    hash: u64,
    len: usize,
}

impl Fingerprint {
    fn of(units_hashable: &CmDoc) -> Self {
        let mut h = DefaultHasher::new();
        // Hash the decoded-form-independent unit sequence via the doc's
        // canonical text when well-formed, else the length-only degenerate
        // (an ill-formed mirror only arises from a hostile resync and is
        // always dirty-vs-any-baseline in practice).
        if let Some(t) = units_hashable.text() {
            t.hash(&mut h);
        }
        Fingerprint { hash: h.finish(), len: units_hashable.len_utf16() }
    }
}

/// Document metadata the session carries for its host: where the document
/// lives, how it is highlighted, and the on-disk baseline the external-change
/// watcher compares against. All optional — an untitled buffer has none.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct EditorSessionMeta {
    /// Absolute file path/URL the document is backed by (None = untitled).
    pub url: Option<String>,
    /// Language id used for highlighting/folds (e.g. "swift", "markdown").
    pub language: Option<String>,
    /// On-disk mtime (ms since epoch) at load/save — the watcher baseline.
    pub disk_mtime_ms: Option<u64>,
    /// On-disk byte size at load/save — the watcher baseline's cheap half.
    pub disk_size: Option<u64>,
}

/// One applied edit batch in the op-log: the revision it produced plus the
/// owned edits, replayable in order over the initial snapshot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoggedBatch {
    /// The session revision this batch produced (monotonic, 1-based).
    pub rev: u64,
    /// The batch's edits exactly as applied.
    pub edits: Vec<CmEdit>,
}

/// The result of a successful [`EditorSession::apply_delta`]: the new
/// revision and the changed span (post-edit coordinates) for consumers that
/// re-decorate only the affected region.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AppliedDelta {
    /// The revision the document is now at.
    pub rev: u64,
    /// The changed span in the post-edit document.
    pub region: ChangedRegion,
}

/// A rust-owned, stateful editor document: mirror + dirty baseline + op-log +
/// meta. See the module docs for the contracts; see `CoreRuntime` for how many
/// of these are registered/evicted (S2 wires `is_dirty` ⇒ pinned).
#[derive(Debug, Clone)]
pub struct EditorSession {
    doc: CmDoc,
    rev: u64,
    /// Snapshot of the doc at the START of the current op-log window; the
    /// replay law reproduces `doc` from `log_initial + log`.
    log_initial: CmDoc,
    log: Vec<LoggedBatch>,
    /// Fingerprint of the last-saved content — the dirty baseline.
    baseline: Fingerprint,
    /// Revision at the last `mark_saved` (0 = the load revision).
    saved_rev: u64,
    meta: EditorSessionMeta,
}

impl EditorSession {
    /// Open a session seeded from `text` (the ONE full-document transfer that
    /// bootstraps it; every subsequent mutation is a delta). The fresh
    /// session is clean: baseline == content, rev 0, empty log.
    #[must_use]
    pub fn new(text: &str, meta: EditorSessionMeta) -> Self {
        let doc = CmDoc::new(text);
        let baseline = Fingerprint::of(&doc);
        Self {
            log_initial: doc.clone(),
            doc,
            rev: 0,
            log: Vec::new(),
            baseline,
            saved_rev: 0,
            meta,
        }
    }

    /// The current revision (bumps once per successful content-changing
    /// batch; loads at 0).
    #[must_use]
    pub fn rev(&self) -> u64 {
        self.rev
    }

    /// The revision at the last save (0 until the first `mark_saved`).
    #[must_use]
    pub fn saved_rev(&self) -> u64 {
        self.saved_rev
    }

    /// Apply an edit batch. On success the mirror mutates in place, the rev
    /// bumps, and the batch is appended to the op-log; the returned
    /// [`AppliedDelta`] carries the changed region. A REJECTED batch (out of
    /// bounds / overlapping / malformed — see `CmDoc::apply_delta`) returns
    /// `None` and changes NOTHING. An EMPTY batch is a successful no-op:
    /// no rev bump, no log entry, empty region.
    pub fn apply_delta(&mut self, edits: &[CmEdit]) -> Option<AppliedDelta> {
        if edits.is_empty() {
            return Some(AppliedDelta {
                rev: self.rev,
                region: ChangedRegion { from: 0, len_after: 0, removed: 0 },
            });
        }
        let region = self.doc.apply_delta(edits)?;
        self.rev += 1;
        self.log.push(LoggedBatch { rev: self.rev, edits: edits.to_vec() });
        Some(AppliedDelta { rev: self.rev, region })
    }

    /// The current document text, or `None` for an ill-formed UTF-16 mirror
    /// (unreachable through the delta path — `CmDoc` rejects splices that
    /// would break surrogate pairs at the kernel level).
    #[must_use]
    pub fn text(&self) -> Option<String> {
        self.doc.text()
    }

    /// Document length in UTF-16 code units.
    #[must_use]
    pub fn len_utf16(&self) -> usize {
        self.doc.len_utf16()
    }

    /// A windowed read: up to `len` UTF-16 units starting at `from`, decoded
    /// LOSSILY (a window may split a surrogate pair at either edge; viewers
    /// tolerate a replacement char at the seam). Out-of-range is clamped —
    /// total by construction, never a panic.
    #[must_use]
    pub fn window(&self, from: usize, len: usize) -> String {
        let total = self.doc.len_utf16();
        let start = from.min(total);
        let end = start.saturating_add(len).min(total);
        self.doc.units_lossy(start, end)
    }

    /// Content-based dirty: does the current content differ from the saved
    /// baseline? Reverting an edit byte-for-byte reads CLEAN again.
    #[must_use]
    pub fn is_dirty(&self) -> bool {
        Fingerprint::of(&self.doc) != self.baseline
    }

    /// Record a save: the current content becomes the dirty baseline and the
    /// current rev becomes `saved_rev`. Returns that rev. (The HOST performs
    /// the actual IO — sans-IO core — and must write `text()`, never trust
    /// the fingerprint.)
    pub fn mark_saved(&mut self) -> u64 {
        self.baseline = Fingerprint::of(&self.doc);
        self.saved_rev = self.rev;
        self.rev
    }

    /// Shared read access to the metadata.
    #[must_use]
    pub fn meta(&self) -> &EditorSessionMeta {
        &self.meta
    }

    /// Mutable access to the metadata (host updates the disk baseline after
    /// save/reload).
    pub fn meta_mut(&mut self) -> &mut EditorSessionMeta {
        &mut self.meta
    }

    /// The op-log window (batches since `log_initial`), oldest first.
    #[must_use]
    pub fn op_log(&self) -> &[LoggedBatch] {
        &self.log
    }

    /// Replay the op-log over the initial snapshot and return the resulting
    /// text — the REPLAY-LAW audit surface (`None` only if a stored batch
    /// fails to re-apply, which the law says cannot happen).
    #[must_use]
    pub fn replay_from_log(&self) -> Option<String> {
        let mut doc = self.log_initial.clone();
        for batch in &self.log {
            doc.apply_delta(&batch.edits)?;
        }
        doc.text()
    }

    /// Compact the op-log: keep only the newest `keep_last` batches and fold
    /// everything older into a fresh initial snapshot, preserving the replay
    /// law over the shorter window. Returns how many batches were dropped.
    /// (Policy — when/how aggressively to compact — belongs to the S2/S3
    /// host wiring; this is the mechanism.)
    pub fn compact_log(&mut self, keep_last: usize) -> usize {
        if self.log.len() <= keep_last {
            return 0;
        }
        let drop_n = self.log.len() - keep_last;
        // Fold the dropped prefix into the snapshot by replaying it. The
        // `.get` is total by construction (drop_n <= len) — the no-panic
        // wall (`-D clippy::indexing-slicing`) wants it spelled that way.
        let Some(prefix) = self.log.get(..drop_n) else { return 0 };
        let mut folded = self.log_initial.clone();
        for batch in prefix {
            // A stored batch always re-applies (replay law); if it ever did
            // not, refusing to compact is the safe posture.
            if folded.apply_delta(&batch.edits).is_none() {
                return 0;
            }
        }
        self.log_initial = folded;
        self.log.drain(..drop_n);
        drop_n
    }

    /// Rough resident size for the eviction budget (S2): both snapshots'
    /// units plus the logged insert text. Deliberately an estimate — the
    /// eviction planner needs proportionality, not bytes-exact accounting.
    #[must_use]
    pub fn estimated_bytes(&self) -> usize {
        let log_bytes: usize = self
            .log
            .iter()
            .map(|b| b.edits.iter().map(|e| e.insert.len()).sum::<usize>() + 48)
            .sum();
        self.doc.len_utf16() * 2 + self.log_initial.len_utf16() * 2 + log_bytes
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn ins(at: i64, s: &str) -> CmEdit {
        CmEdit::new(at, at, s)
    }
    fn del(from: i64, to: i64) -> CmEdit {
        CmEdit::new(from, to, "")
    }

    #[test]
    fn fresh_session_is_clean_at_rev_zero() {
        let s = EditorSession::new("hello", EditorSessionMeta::default());
        assert_eq!(s.rev(), 0);
        assert!(!s.is_dirty());
        assert_eq!(s.text().as_deref(), Some("hello"));
        assert!(s.op_log().is_empty());
    }

    #[test]
    fn apply_bumps_rev_logs_batch_and_dirties() {
        let mut s = EditorSession::new("hello", EditorSessionMeta::default());
        let a = s.apply_delta(&[ins(5, " world")]).expect("valid batch");
        assert_eq!(a.rev, 1);
        assert_eq!(s.text().as_deref(), Some("hello world"));
        assert!(s.is_dirty());
        assert_eq!(s.op_log().len(), 1);
    }

    #[test]
    fn dirty_is_content_based_revert_reads_clean() {
        let mut s = EditorSession::new("hello", EditorSessionMeta::default());
        s.apply_delta(&[ins(5, "!")]).unwrap();
        assert!(s.is_dirty());
        // Revert byte-for-byte: content == baseline ⇒ CLEAN again (the law
        // Swift's sticky flag gets wrong).
        s.apply_delta(&[del(5, 6)]).unwrap();
        assert!(!s.is_dirty());
        // The log still remembers both batches (history ≠ dirtiness).
        assert_eq!(s.op_log().len(), 2);
    }

    #[test]
    fn mark_saved_resets_baseline_and_saved_rev() {
        let mut s = EditorSession::new("a", EditorSessionMeta::default());
        s.apply_delta(&[ins(1, "b")]).unwrap();
        assert!(s.is_dirty());
        let rev = s.mark_saved();
        assert_eq!(rev, 1);
        assert_eq!(s.saved_rev(), 1);
        assert!(!s.is_dirty());
    }

    #[test]
    fn rejected_batch_changes_nothing() {
        let mut s = EditorSession::new("hello", EditorSessionMeta::default());
        s.apply_delta(&[ins(5, "!")]).unwrap();
        let (rev, dirty, text, log_len) =
            (s.rev(), s.is_dirty(), s.text(), s.op_log().len());
        // Out of bounds ⇒ reject.
        assert!(s.apply_delta(&[ins(999, "x")]).is_none());
        assert_eq!(s.rev(), rev);
        assert_eq!(s.is_dirty(), dirty);
        assert_eq!(s.text(), text);
        assert_eq!(s.op_log().len(), log_len);
    }

    #[test]
    fn empty_batch_is_a_true_noop() {
        let mut s = EditorSession::new("x", EditorSessionMeta::default());
        let a = s.apply_delta(&[]).unwrap();
        assert_eq!(a.rev, 0);
        assert_eq!(s.rev(), 0);
        assert!(s.op_log().is_empty());
    }

    #[test]
    fn replay_law_holds_and_survives_compaction() {
        let mut s = EditorSession::new("the quick fox", EditorSessionMeta::default());
        s.apply_delta(&[ins(9, " brown")]).unwrap();
        s.apply_delta(&[del(0, 4)]).unwrap();
        s.apply_delta(&[ins(0, "A")]).unwrap();
        assert_eq!(s.replay_from_log(), s.text());
        let dropped = s.compact_log(1);
        assert_eq!(dropped, 2);
        assert_eq!(s.op_log().len(), 1);
        assert_eq!(s.replay_from_log(), s.text(), "replay law survives compaction");
        // Compacting a shorter-than-keep log is a no-op.
        assert_eq!(s.compact_log(5), 0);
    }

    #[test]
    fn estimated_bytes_tracks_growth() {
        let mut s = EditorSession::new("seed", EditorSessionMeta::default());
        let before = s.estimated_bytes();
        s.apply_delta(&[ins(4, &"x".repeat(1000))]).unwrap();
        assert!(s.estimated_bytes() > before + 1000);
    }

    // ── Property tests ────────────────────────────────────────────────────

    /// Derive a VALID, sorted, non-overlapping batch for a doc of `len`
    /// UTF-16 units from two seed bytes (ASCII inserts keep the generator's
    /// offset math exact; multi-unit handling is pinned by cm_edit's suites).
    fn batch_from_seed(len: usize, a: u8, b: u8) -> Vec<CmEdit> {
        let from = (a as usize) % (len + 1);
        let to = from + ((b as usize) % (len + 1 - from));
        let insert = "qz".repeat((b % 3) as usize);
        vec![CmEdit::new(from as i64, to as i64, insert)]
    }

    proptest! {
        /// REPLAY LAW over arbitrary valid batch sequences, with a mid-stream
        /// compaction thrown in: the log always reproduces the document.
        #[test]
        fn prop_replay_law(
            seed in "[a-z ]{0,32}",
            rounds in proptest::collection::vec((any::<u8>(), any::<u8>()), 1..6),
            keep in 0usize..3,
        ) {
            let mut s = EditorSession::new(&seed, EditorSessionMeta::default());
            let mid = rounds.len() / 2;
            for (i, (a, b)) in rounds.iter().enumerate() {
                let batch = batch_from_seed(s.len_utf16(), *a, *b);
                prop_assert!(s.apply_delta(&batch).is_some(), "generator emits only valid batches");
                if i == mid {
                    s.compact_log(keep);
                }
                prop_assert_eq!(s.replay_from_log(), s.text());
            }
        }

        /// DIRTY LAW: dirty ⇔ content differs from the baseline snapshot.
        #[test]
        fn prop_dirty_iff_content_differs(seed in "[a-z]{0,16}", batch_seed in 0u8..255) {
            let mut s = EditorSession::new(&seed, EditorSessionMeta::default());
            let baseline_text = s.text();
            let at = (batch_seed as usize) % (s.len_utf16() + 1);
            let _ = s.apply_delta(&[CmEdit::new(at as i64, at as i64, "Q")]);
            prop_assert_eq!(s.is_dirty(), s.text() != baseline_text);
        }

        /// TOTALITY (the fuzz lane's cheap twin, TSK-1223-class): ADVERSARIAL
        /// batches — unclamped i64 offsets (negative, reversed, past-end,
        /// overlapping), arbitrary unicode inserts, hostile window/compact
        /// args — must never panic. A rejected batch (`None`) must also be a
        /// true no-op: text, rev, and dirtiness unchanged (atomicity).
        #[test]
        fn prop_adversarial_inputs_are_total_and_rejections_atomic(
            seed in ".{0,24}",
            edits in proptest::collection::vec(
                (any::<i64>(), any::<i64>(), ".{0,8}"), 0..5),
            win in (any::<usize>(), any::<usize>()),
            keep in any::<usize>(),
        ) {
            let mut s = EditorSession::new(&seed, EditorSessionMeta::default());
            let before = (s.text(), s.rev(), s.is_dirty());
            let batch: Vec<CmEdit> = edits
                .into_iter()
                .map(|(f, t, i)| CmEdit { from: f, to: t, insert: i })
                .collect();
            let applied = s.apply_delta(&batch); // must not panic
            if applied.is_none() {
                prop_assert_eq!(
                    (s.text(), s.rev(), s.is_dirty()),
                    before,
                    "a rejected batch must be a perfect no-op"
                );
            }
            let _ = s.window(win.0, win.1);      // total on any range
            let _ = s.compact_log(keep);          // total on any keep
            prop_assert_eq!(s.replay_from_log(), s.text(), "replay law holds after anything");
        }
    }
}
