//! TSK-1517 (stateful-core S2) — the process-global editor-document registry
//! and its wire family.
//!
//! One [`CoreRuntime`]`<`[`EditorSession`]`>` owns every open editor document,
//! keyed by never-reused [`DocId`]. The document crosses the boundary ONCE at
//! `doc.open`; every subsequent mutation is a delta against the id — the
//! endgame of the TSK-543 traffic redesign (`cm_edit::apply_delta_wire`'s doc
//! comment describes exactly this session-keyed export).
//!
//! ## Eviction (owner policy, 2026-07-04 — supersedes the 2026-06-19 defaults)
//! Budget = **1.5 GB** resident editor text (the 1–2 GB band's middle) AND
//! **200 documents**, whichever binds first; TTL disabled in-process (a
//! remote deployment enables it as the orphan reaper). **Dirty documents are
//! NEVER evicted**: effective pin = `host_pin || is_dirty()`, recomputed after
//! every state-changing call, so an unsaved buffer cannot be a victim even
//! when the set is over budget ([`eviction_plan`] then stays over-budget by
//! design — the host's close-some-tabs signal).
//!
//! ## Wire conventions
//! msgpack frames via [`crate::wire`]; a MISSING/EVICTED id is DATA
//! (`found: false`), never a fault — the host rehydrates by re-opening from
//! the bytes it still holds. A REJECTED edit batch is `found: true,
//! changed: null` (atomic no-op server-side), the host's cue to full-resync.
//! Hosts pass `now_ms` (monotonic) so the core stays sans-IO and the eviction
//! policy is deterministically testable.

use std::collections::HashSet;
use std::sync::{Mutex, OnceLock, PoisonError};

use serde::{Deserialize, Serialize};

use crate::cm_edit::CmEdit;
use crate::editor_session::{EditorSession, EditorSessionMeta};
use crate::runtime::{CoreRuntime, DocId, EvictionBudget};
use crate::wire::{self, WireFault};

/// Resident-bytes ceiling for editor documents (owner 2026-07-04: the 1–2 GB
/// band; 1.5 GB is the shipped middle — `runtime_configure` can retune).
pub const EDITOR_MAX_BYTES: usize = 1_500 * 1024 * 1024;
/// Document-count ceiling (owner 2026-07-04: 200, whichever bound binds first).
pub const EDITOR_MAX_DOCS: usize = 200;
/// Idle TTL: disabled in-process; a remote deployment sets a reaper horizon.
pub const EDITOR_TTL_MS: u64 = 0;

/// The registry: the generic runtime plus the host-pin set that composes with
/// content-dirtiness into the effective eviction pin.
pub struct DocRegistry {
    runtime: CoreRuntime<EditorSession>,
    /// Ids the HOST pinned (visible tab / explicit hold). Composed as
    /// `effective_pin = host_pin || dirty` on every recompute.
    host_pins: Mutex<HashSet<u64>>,
}

impl Default for DocRegistry {
    fn default() -> Self {
        Self::new(EvictionBudget::new(EDITOR_MAX_BYTES, EDITOR_MAX_DOCS, EDITOR_TTL_MS))
    }
}

impl DocRegistry {
    /// A registry with an explicit budget — tests force tiny budgets to
    /// exercise eviction deterministically.
    #[must_use]
    pub fn new(budget: EvictionBudget) -> Self {
        Self { runtime: CoreRuntime::new(budget), host_pins: Mutex::new(HashSet::new()) }
    }

    /// The process-global instance every wire call routes through.
    pub fn global() -> &'static DocRegistry {
        static GLOBAL: OnceLock<DocRegistry> = OnceLock::new();
        GLOBAL.get_or_init(DocRegistry::default)
    }

    fn host_pinned(&self, id: u64) -> bool {
        self.host_pins
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains(&id)
    }

    /// Recompute the effective eviction pin for `id` from the CURRENT session
    /// state: `host_pin || dirty`. The dirty half is the TSK-589 absolute —
    /// unsaved work is never a victim.
    fn refresh_pin(&self, id: DocId, session: &EditorSession) {
        let pinned = self.host_pinned(id.0) || session.is_dirty();
        self.runtime.set_pinned(id, pinned);
    }

    /// Open a document (the one full-text transfer). Returns the new id plus
    /// any ids evicted on admission.
    pub fn open(&self, text: &str, meta: EditorSessionMeta, now_ms: u64) -> (DocId, Vec<DocId>) {
        let session = EditorSession::new(text, meta);
        let bytes = session.estimated_bytes();
        let (id, evicted) = self.runtime.open(session, bytes, now_ms);
        // Fresh docs are clean + unpinned until the host pins or edits arrive.
        evicted.iter().for_each(|e| self.drop_host_pin(e.0));
        (id, evicted)
    }

    /// Apply an edit batch to `id`. `None` = unknown/evicted id. On a live id,
    /// the inner `Option` mirrors [`EditorSession::apply_delta`] (None =
    /// rejected batch, atomic no-op). Pin + byte estimate refresh afterwards;
    /// the budget is enforced on the way out (an edit can grow a doc past it).
    pub fn apply_delta(
        &self,
        id: DocId,
        edits: &[CmEdit],
        now_ms: u64,
    ) -> Option<(Option<crate::editor_session::AppliedDelta>, u64, usize, bool)> {
        let handle = self.runtime.get(id, now_ms)?;
        let mut session = handle.lock().unwrap_or_else(PoisonError::into_inner);
        let applied = session.apply_delta(edits);
        let (rev, len, dirty) = (session.rev(), session.len_utf16(), session.is_dirty());
        self.runtime.update_estimate(id, session.estimated_bytes());
        self.refresh_pin(id, &session);
        drop(session);
        self.runtime.enforce(now_ms);
        Some((applied, rev, len, dirty))
    }

    /// Full text of `id` (the save path — always the real text, never a
    /// fingerprint shortcut). `None` outer = unknown id.
    pub fn text(&self, id: DocId, now_ms: u64) -> Option<Option<String>> {
        let handle = self.runtime.get(id, now_ms)?;
        let session = handle.lock().unwrap_or_else(PoisonError::into_inner);
        Some(session.text())
    }

    /// Windowed lossy read (viewer path — large docs never ship whole).
    pub fn window(&self, id: DocId, from: usize, len: usize, now_ms: u64) -> Option<String> {
        let handle = self.runtime.get(id, now_ms)?;
        let session = handle.lock().unwrap_or_else(PoisonError::into_inner);
        Some(session.window(from, len))
    }

    /// Record a save on `id`: baseline reset (clean) + pin recompute. Returns
    /// the saved rev, or `None` for an unknown id.
    pub fn mark_saved(&self, id: DocId, now_ms: u64) -> Option<u64> {
        let handle = self.runtime.get(id, now_ms)?;
        let mut session = handle.lock().unwrap_or_else(PoisonError::into_inner);
        let rev = session.mark_saved();
        self.refresh_pin(id, &session);
        Some(rev)
    }

    /// Host pin/unpin (visible tab, explicit hold). The dirty half of the
    /// effective pin is independent — unpinning a dirty doc leaves it pinned.
    pub fn set_host_pinned(&self, id: DocId, pinned: bool, now_ms: u64) -> bool {
        let Some(handle) = self.runtime.get(id, now_ms) else { return false };
        {
            let mut pins = self.host_pins.lock().unwrap_or_else(PoisonError::into_inner);
            if pinned {
                pins.insert(id.0);
            } else {
                pins.remove(&id.0);
            }
        }
        let session = handle.lock().unwrap_or_else(PoisonError::into_inner);
        self.refresh_pin(id, &session);
        true
    }

    /// Close (idempotent).
    pub fn close(&self, id: DocId) {
        self.drop_host_pin(id.0);
        self.runtime.close(id);
    }

    fn drop_host_pin(&self, raw: u64) {
        self.host_pins
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&raw);
    }

    /// Resident doc count (diagnostics + tests).
    #[must_use]
    pub fn doc_count(&self) -> usize {
        self.runtime.doc_count()
    }
}

// ── Wire family (msgpack frames; served by dispatch Method ids 18–23) ──────

#[derive(Deserialize)]
struct OpenRequest {
    text: String,
    url: Option<String>,
    language: Option<String>,
    now_ms: u64,
}

#[derive(Serialize)]
struct OpenResponse {
    doc_id: u64,
    evicted: Vec<u64>,
}

/// `doc.open` — the one full-text transfer that starts a session.
///
/// # Errors
/// [`WireFault`] on a malformed/oversized frame.
pub fn open_wire(req_frame: &[u8]) -> Result<Vec<u8>, WireFault> {
    let req: OpenRequest = wire::decode_frame(req_frame)?;
    let meta = EditorSessionMeta {
        url: req.url,
        language: req.language,
        ..EditorSessionMeta::default()
    };
    let (id, evicted) = DocRegistry::global().open(&req.text, meta, req.now_ms);
    wire::encode_frame(&OpenResponse {
        doc_id: id.0,
        evicted: evicted.into_iter().map(|d| d.0).collect(),
    })
}

#[derive(Deserialize)]
struct EditWire {
    from: i64,
    to: i64,
    insert: String,
}

#[derive(Deserialize)]
struct DeltaRequest {
    doc_id: u64,
    now_ms: u64,
    edits: Vec<EditWire>,
}

#[derive(Serialize)]
struct RegionWire {
    from: u64,
    len_after: u64,
    removed: u64,
}

#[derive(Serialize)]
struct DeltaResponse {
    found: bool,
    /// `null` with `found: true` = the batch was REJECTED (host full-resyncs).
    changed: Option<RegionWire>,
    rev: u64,
    len_utf16: u64,
    dirty: bool,
}

/// `doc.apply_delta` — the keystroke path: deltas + id in, changed region out;
/// the buffer never crosses.
///
/// # Errors
/// [`WireFault`] on a malformed frame (a rejected batch or unknown id is DATA).
#[allow(clippy::cast_possible_truncation,
        reason = "usize→u64 widens losslessly on 64-bit targets; region fields are \
                  bounded by doc length, itself bounded by the wire cap")]
pub fn apply_delta_wire(req_frame: &[u8]) -> Result<Vec<u8>, WireFault> {
    let req: DeltaRequest = wire::decode_frame(req_frame)?;
    let edits: Vec<CmEdit> = req
        .edits
        .into_iter()
        .map(|e| CmEdit { from: e.from, to: e.to, insert: e.insert })
        .collect();
    let resp = match DocRegistry::global().apply_delta(DocId(req.doc_id), &edits, req.now_ms) {
        None => DeltaResponse { found: false, changed: None, rev: 0, len_utf16: 0, dirty: false },
        Some((applied, rev, len, dirty)) => DeltaResponse {
            found: true,
            changed: applied.map(|a| RegionWire {
                from: a.region.from as u64,
                len_after: a.region.len_after as u64,
                removed: a.region.removed as u64,
            }),
            rev,
            len_utf16: len as u64,
            dirty,
        },
    };
    wire::encode_frame(&resp)
}

#[derive(Deserialize)]
struct IdRequest {
    doc_id: u64,
    now_ms: u64,
}

#[derive(Serialize)]
struct TextResponse {
    found: bool,
    text: Option<String>,
}

/// `doc.text` — the full-text read (save path).
///
/// # Errors
/// [`WireFault`] on a malformed frame.
pub fn text_wire(req_frame: &[u8]) -> Result<Vec<u8>, WireFault> {
    let req: IdRequest = wire::decode_frame(req_frame)?;
    let resp = match DocRegistry::global().text(DocId(req.doc_id), req.now_ms) {
        None => TextResponse { found: false, text: None },
        Some(t) => TextResponse { found: true, text: t },
    };
    wire::encode_frame(&resp)
}

#[derive(Deserialize)]
struct WindowRequest {
    doc_id: u64,
    now_ms: u64,
    from: u64,
    len: u64,
}

/// `doc.window` — windowed lossy read for viewers.
///
/// # Errors
/// [`WireFault`] on a malformed frame.
#[allow(clippy::cast_possible_truncation,
        reason = "u64→usize narrows only on 32-bit targets, where a >4 GiB window \
                  offset cannot address a resident doc anyway; min() clamps first")]
pub fn window_wire(req_frame: &[u8]) -> Result<Vec<u8>, WireFault> {
    let req: WindowRequest = wire::decode_frame(req_frame)?;
    let from = usize::try_from(req.from).unwrap_or(usize::MAX);
    let len = usize::try_from(req.len).unwrap_or(usize::MAX);
    let resp = match DocRegistry::global().window(DocId(req.doc_id), from, len, req.now_ms) {
        None => TextResponse { found: false, text: None },
        Some(t) => TextResponse { found: true, text: Some(t) },
    };
    wire::encode_frame(&resp)
}

#[derive(Serialize)]
struct SavedResponse {
    found: bool,
    rev: u64,
}

/// `doc.mark_saved` — baseline reset after the HOST performed the IO.
///
/// # Errors
/// [`WireFault`] on a malformed frame.
pub fn mark_saved_wire(req_frame: &[u8]) -> Result<Vec<u8>, WireFault> {
    let req: IdRequest = wire::decode_frame(req_frame)?;
    let resp = match DocRegistry::global().mark_saved(DocId(req.doc_id), req.now_ms) {
        None => SavedResponse { found: false, rev: 0 },
        Some(rev) => SavedResponse { found: true, rev },
    };
    wire::encode_frame(&resp)
}

#[derive(Deserialize)]
struct PinOrCloseRequest {
    doc_id: u64,
    now_ms: u64,
    /// `Some(pinned)` = host pin/unpin; `None` = close.
    pinned: Option<bool>,
}

#[derive(Serialize)]
struct AckResponse {
    found: bool,
}

/// `doc.pin_close` — host pin/unpin (`pinned: bool`) or close (`pinned: null`).
/// One method keeps the dispatch surface small; both are idempotent acks.
///
/// # Errors
/// [`WireFault`] on a malformed frame.
pub fn pin_close_wire(req_frame: &[u8]) -> Result<Vec<u8>, WireFault> {
    let req: PinOrCloseRequest = wire::decode_frame(req_frame)?;
    let found = match req.pinned {
        Some(p) => DocRegistry::global().set_host_pinned(DocId(req.doc_id), p, req.now_ms),
        None => {
            DocRegistry::global().close(DocId(req.doc_id));
            true
        }
    };
    wire::encode_frame(&AckResponse { found })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ins(at: i64, s: &str) -> CmEdit {
        CmEdit::new(at, at, s)
    }

    fn tiny_registry() -> DocRegistry {
        // 64 bytes / 2 docs — everything evicts unless pinned.
        DocRegistry::new(EvictionBudget::new(64, 2, 0))
    }

    #[test]
    fn shipped_constants_match_the_owner_policy() {
        assert_eq!(EDITOR_MAX_BYTES, 1_500 * 1024 * 1024, "1.5 GB — the 1–2 GB band middle");
        assert_eq!(EDITOR_MAX_DOCS, 200);
        assert_eq!(EDITOR_TTL_MS, 0, "TTL is a remote-deployment knob");
    }

    #[test]
    fn open_apply_text_roundtrip() {
        let r = DocRegistry::default();
        let (id, evicted) = r.open("hello", EditorSessionMeta::default(), 1);
        assert!(evicted.is_empty());
        let (applied, rev, len, dirty) =
            r.apply_delta(id, &[ins(5, " world")], 2).expect("live id");
        assert!(applied.is_some());
        assert_eq!((rev, len, dirty), (1, 11, true));
        assert_eq!(r.text(id, 3), Some(Some("hello world".into())));
        assert_eq!(r.window(id, 6, 5, 4), Some("world".into()));
    }

    #[test]
    fn unknown_id_is_data_not_panic() {
        let r = DocRegistry::default();
        assert!(r.apply_delta(DocId(999), &[ins(0, "x")], 1).is_none());
        assert!(r.text(DocId(999), 1).is_none());
        assert!(r.mark_saved(DocId(999), 1).is_none());
        assert!(!r.set_host_pinned(DocId(999), true, 1));
        r.close(DocId(999)); // idempotent no-op
    }

    /// THE TSK-589 LAW: dirty docs are never evicted, even with the whole set
    /// over budget — the plan simply stays over-budget.
    #[test]
    fn dirty_docs_survive_eviction_even_over_budget() {
        let r = tiny_registry();
        let mut ids = Vec::new();
        for i in 0..4u64 {
            let (id, _) = r.open("0123456789", EditorSessionMeta::default(), i);
            // Dirty every doc: pin = dirty must hold it resident.
            r.apply_delta(id, &[ins(0, "dirty-dirty-dirty")], i + 10).unwrap();
            ids.push(id);
        }
        // 4 docs × >64 bytes each, budget 64B/2docs — massively over, all dirty.
        assert_eq!(r.doc_count(), 4, "over-budget but ALL dirty ⇒ zero evictions");
        for id in &ids {
            assert!(r.text(*id, 100).is_some(), "{id:?} must still be resident");
        }
    }

    /// The other half: CLEAN docs do evict under pressure (LRU), and a saved
    /// (clean-again) doc becomes evictable.
    #[test]
    fn clean_docs_evict_lru_and_saved_docs_become_evictable() {
        let r = tiny_registry();
        let (a, _) = r.open("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", EditorSessionMeta::default(), 1);
        // Dirty `a`, then SAVE it — clean again ⇒ unpinned ⇒ evictable.
        r.apply_delta(a, &[ins(0, "x")], 2).unwrap();
        r.mark_saved(a, 3).unwrap();
        // Admitting two more clean docs blows the 2-doc cap; LRU (a) evicts.
        let (_b, _) = r.open("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", EditorSessionMeta::default(), 10);
        let (_c, ev) = r.open("cccccccccccccccccccccccccccccccccccccccc", EditorSessionMeta::default(), 20);
        assert!(!ev.is_empty(), "count cap must force an eviction");
        assert!(r.text(a, 30).is_none(), "the saved-clean LRU doc was the victim");
    }

    #[test]
    fn host_pin_composes_with_dirty() {
        let r = tiny_registry();
        let (a, _) = r.open("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", EditorSessionMeta::default(), 1);
        assert!(r.set_host_pinned(a, true, 2));
        let (_b, _) = r.open("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", EditorSessionMeta::default(), 10);
        let (_c, _) = r.open("cccccccccccccccccccccccccccccccccccccccc", EditorSessionMeta::default(), 20);
        assert!(r.text(a, 30).is_some(), "host-pinned clean doc survives pressure");
        // Unpin: now it's the LRU clean doc — next admission evicts it.
        assert!(r.set_host_pinned(a, false, 31));
        let (_d, _) = r.open("dddddddddddddddddddddddddddddddddddddddd", EditorSessionMeta::default(), 40);
        assert!(r.text(a, 50).is_none(), "unpinned clean LRU evicts");
    }

    #[test]
    fn wire_roundtrip_open_apply_text() {
        // Typed request mirrors — the core is serde_json-free by design; the
        // wire layer is msgpack via crate::wire.
        #[derive(Serialize)]
        struct OpenReq<'a> {
            text: &'a str,
            url: Option<&'a str>,
            language: Option<&'a str>,
            now_ms: u64,
        }
        #[derive(Serialize)]
        struct EditReq<'a> { from: i64, to: i64, insert: &'a str }
        #[derive(Serialize)]
        struct DeltaReq<'a> { doc_id: u64, now_ms: u64, edits: Vec<EditReq<'a>> }
        #[derive(Serialize)]
        struct IdReq { doc_id: u64, now_ms: u64 }

        // Through the GLOBAL registry — ids are process-unique, so no cleanup
        // races with other tests (they use instance registries).
        let open = wire::encode_frame(&OpenReq { text: "wire", url: None, language: None, now_ms: 1 })
            .and_then(|f| open_wire(&f))
            .expect("open");
        #[derive(Deserialize)]
        struct O { doc_id: u64 }
        let o: O = wire::decode_frame(&open).expect("decode open");

        let delta = wire::encode_frame(&DeltaReq {
            doc_id: o.doc_id,
            now_ms: 2,
            edits: vec![EditReq { from: 4, to: 4, insert: "-ok" }],
        })
        .and_then(|f| apply_delta_wire(&f))
        .expect("delta");
        #[derive(Deserialize)]
        struct D { found: bool, dirty: bool, len_utf16: u64 }
        let d: D = wire::decode_frame(&delta).expect("decode delta");
        assert!(d.found && d.dirty);
        assert_eq!(d.len_utf16, 7);

        let text = wire::encode_frame(&IdReq { doc_id: o.doc_id, now_ms: 3 })
            .and_then(|f| text_wire(&f))
            .expect("text");
        #[derive(Deserialize)]
        struct T { found: bool, text: Option<String> }
        let t: T = wire::decode_frame(&text).expect("decode text");
        assert_eq!((t.found, t.text.as_deref()), (true, Some("wire-ok")));

        // Unknown id over the wire = found:false, not a fault.
        let missing = wire::encode_frame(&IdReq { doc_id: 4_000_000_000, now_ms: 4 })
            .and_then(|f| text_wire(&f))
            .expect("missing");
        let m: T = wire::decode_frame(&missing).expect("decode missing");
        assert!(!m.found);
    }
}
