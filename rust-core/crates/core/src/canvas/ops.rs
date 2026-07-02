//! Canvas M1.S3 — ops, inverses, revisions (TSK-1358; design 02-CORE-ENGINE §4).
//!
//! The ONLY write path: a batch of typed ops applies ATOMICALLY against a
//! revisioned document — every op is fence-validated (S2) as it applies, and
//! any failure ROLLS BACK the batch via the inverses collected so far, so a
//! bad op can never leave a half-applied batch. Every applied batch yields
//! its inverse (the undo unit) and bumps `rev` exactly once.
//!
//! Idempotent replays: `Insert` with a caller-supplied id that already exists
//! with the SAME kind+parent+props is an Ok NO-OP (agent retry semantics,
//! 07-DSL-SPIKE §0/§1); any other id collision is a typed error.

use super::props::{PropBag, PropKey, Value};
use super::registry::{self, FenceError, MAX_PROPS_PER_RECORD, MAX_RECORDS_PER_DOC};
use super::store::{Id, Place, Position, Record, RecordKind, Store, StoreError};

/// One canvas operation (the op layer's public vocabulary).
#[derive(Debug, Clone, PartialEq)]
pub enum CanvasOp {
    /// Create a component DEFINITION root (M4.S3): a `cmp:*` Frame subtree
    /// root the DSL's `component #name { … }` block targets. Idempotent
    /// replay: an existing empty-or-identical-kind root is an Ok no-op.
    DefineComponent { id: Id },
    Insert {
        /// Caller-supplied id (idempotent retries) or None to mint.
        id: Option<Id>,
        kind: RecordKind,
        parent: Id,
        pos: Position,
        props: Vec<(PropKey, Value)>,
    },
    Update {
        id: Id,
        set: Vec<(PropKey, Value)>,
        unset: Vec<PropKey>,
    },
    Move {
        id: Id,
        parent: Id,
        pos: Position,
    },
    Remove {
        id: Id,
    },
}

/// The exact-state inverse of one applied op (internal undo vocabulary —
/// restores EXACT places/props, never re-mints indexes).
#[derive(Debug, Clone)]
pub enum UndoOp {
    RemoveInserted(Id),
    RestoreProps {
        id: Id,
        set: Vec<(PropKey, Value)>,
        unset: Vec<PropKey>,
    },
    RestorePlace {
        id: Id,
        place: Option<Place>,
    },
    Resurrect(Vec<Record>),
}

/// Apply faults.
#[derive(Debug, Clone, PartialEq)]
pub enum ApplyError {
    /// Stale `base_rev` — the caller must re-query and retry (02 §4).
    Conflict { current: u64 },
    Fence(FenceError),
    Store(StoreError),
    /// Insert id collision with DIFFERENT content (not an idempotent replay).
    IdInUse(String),
}

impl From<FenceError> for ApplyError {
    fn from(e: FenceError) -> Self {
        ApplyError::Fence(e)
    }
}
impl From<StoreError> for ApplyError {
    fn from(e: StoreError) -> Self {
        ApplyError::Store(e)
    }
}

/// What one op actually did (parallel to the batch — the patch planner's
/// input; an idempotent replay is `Noop` and must yield zero patches).
#[derive(Debug, Clone, PartialEq)]
pub enum AppliedEffect {
    Noop,
    /// A definition root was created — never rendered, never patched.
    Defined(Id),
    /// The RESOLVED id (supplied or minted) + the DOM anchor (next sibling)
    /// captured AT APPLY TIME — a later op in the same batch may invalidate
    /// final-state anchors, so the planner must not recompute them.
    Inserted { id: Id, before: Option<Id> },
    Updated(Id),
    Moved { id: Id, before: Option<Id> },
    Removed(Id),
}

/// A successfully applied batch.
#[derive(Debug)]
pub struct Applied {
    pub rev: u64,
    /// Inverses in REVERSE apply order — running them front-to-back undoes
    /// the batch exactly.
    pub inverses: Vec<UndoOp>,
    /// Ids minted for `Insert { id: None }` ops, in op order.
    pub minted: Vec<Id>,
    /// Per-op outcomes, parallel to the input batch.
    pub effects: Vec<AppliedEffect>,
    /// True when every op was an idempotent replay (rev did NOT bump).
    pub noop: bool,
}

/// A revisioned canvas document: the store + its monotonic revision.
#[derive(Debug, Default)]
pub struct DocState {
    pub store: Store,
    rev: u64,
    /// Inverses of the most recent mutating batch (the doc facade moves
    /// these onto its bounded undo history after each wire apply).
    last_inverses: Option<Vec<UndoOp>>,
}

impl DocState {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Persistence restore: adopt a rebuilt store at a saved revision.
    #[must_use]
    pub fn restore(store: Store, rev: u64) -> Self {
        DocState {
            store,
            rev,
            last_inverses: None,
        }
    }

    /// Move the most recent mutating batch's inverses out (None when the
    /// last apply was a no-op or they were already taken).
    pub fn take_last_inverses(&mut self) -> Option<Vec<UndoOp>> {
        self.last_inverses.take()
    }

    #[must_use]
    pub fn rev(&self) -> u64 {
        self.rev
    }

    /// Apply `ops` atomically against `base_rev`.
    pub fn apply(&mut self, base_rev: u64, ops: &[CanvasOp]) -> Result<Applied, ApplyError> {
        if base_rev != self.rev {
            return Err(ApplyError::Conflict { current: self.rev });
        }
        let mut inverses: Vec<UndoOp> = Vec::new();
        let mut minted: Vec<Id> = Vec::new();
        let mut effects: Vec<AppliedEffect> = Vec::new();
        let mut mutated = false;
        for op in ops {
            match self.apply_one(op, &mut minted) {
                Ok(Some((undo, effect))) => {
                    mutated = true;
                    inverses.push(undo);
                    effects.push(effect);
                }
                Ok(None) => effects.push(AppliedEffect::Noop), // idempotent replay
                Err(e) => {
                    // Roll back everything this batch already applied.
                    while let Some(undo) = inverses.pop() {
                        self.run_undo(undo);
                    }
                    return Err(e);
                }
            }
        }
        // Expansion cycle FENCE (M4.S1b): a batch that leaves a definition
        // transitively instantiating itself is REJECTED atomically — roll
        // back through the collected inverses (the render-side depth cap is
        // only the backstop; the fence keeps the document valid).
        if mutated && super::lower::find_expansion_cycle(&self.store).is_some() {
            while let Some(undo) = inverses.pop() {
                self.run_undo(undo);
            }
            return Err(ApplyError::Fence(super::registry::FenceError::KindMismatch {
                kind: "component",
                why: "this batch would make a definition transitively instantiate \
                      itself (expansion cycle) — break the ref chain",
            }));
        }
        // Override fence (M4.S2): every instance's overrides table must be
        // well-formed and anchor into ITS definition — rejected atomically
        // with the store's teaching description in the detail channel.
        if mutated && let Some(why) = super::lower::find_invalid_override(&self.store) {
            while let Some(undo) = inverses.pop() {
                self.run_undo(undo);
            }
            return Err(ApplyError::Fence(super::registry::FenceError::Detail(why)));
        }
        if mutated {
            self.rev = self.rev.saturating_add(1);
        }
        inverses.reverse();
        self.last_inverses = if mutated { Some(inverses.clone()) } else { None };
        Ok(Applied {
            rev: self.rev,
            inverses,
            minted,
            effects,
            noop: !mutated,
        })
    }

    /// Undo a previously returned inverse list (front-to-back), bumping rev.
    pub fn undo(&mut self, inverses: Vec<UndoOp>) {
        let mutated = !inverses.is_empty();
        for undo in inverses {
            self.run_undo(undo);
        }
        if mutated {
            self.rev = self.rev.saturating_add(1);
        }
    }

    // MARK: internals

    fn apply_one(
        &mut self,
        op: &CanvasOp,
        minted: &mut Vec<Id>,
    ) -> Result<Option<(UndoOp, AppliedEffect)>, ApplyError> {
        match op {
            CanvasOp::DefineComponent { id } => {
                if !id.as_str().starts_with("cmp:") {
                    return Err(FenceError::Detail(format!(
                        "definitions live under cmp:* ids, got '{}'",
                        id.as_str()
                    ))
                    .into());
                }
                if let Some(existing) = self.store.get(id) {
                    if existing.kind == RecordKind::Frame && existing.place.is_none() {
                        return Ok(None); // idempotent replay
                    }
                    return Err(ApplyError::IdInUse(id.as_str().to_owned()));
                }
                self.store
                    .insert_root(id.clone(), RecordKind::Frame)
                    .map_err(ApplyError::Store)?;
                Ok(Some((
                    UndoOp::RemoveInserted(id.clone()),
                    AppliedEffect::Defined(id.clone()),
                )))
            }
            CanvasOp::Insert {
                id,
                kind,
                parent,
                pos,
                props,
            } => {
                if self.store.len() >= MAX_RECORDS_PER_DOC {
                    return Err(FenceError::CapExceeded("records per doc").into());
                }
                if props.len() > MAX_PROPS_PER_RECORD {
                    return Err(FenceError::CapExceeded("props per record").into());
                }
                // Fence EVERY prop before any mutation.
                for (k, v) in props {
                    registry::check_prop(*kind, *k, v)?;
                }
                // Idempotent replay probe (caller-supplied ids only).
                if let Some(existing_id) = id
                    && let Some(existing) = self.store.get(existing_id)
                {
                    let same_kind = existing.kind == *kind;
                    let same_parent =
                        existing.place.as_ref().map(|p| &p.parent) == Some(parent);
                    let mut replay_bag = PropBag::new();
                    for (k, v) in props {
                        replay_bag.set(*k, v.clone());
                    }
                    if same_kind && same_parent && existing.props == replay_bag {
                        return Ok(None); // replay — already applied
                    }
                    return Err(ApplyError::IdInUse(existing_id.as_str().to_owned()));
                }
                let new_id = match id {
                    Some(supplied) => supplied.clone(),
                    None => {
                        let m = self.store.mint_id("nd")?;
                        minted.push(m.clone());
                        m
                    }
                };
                self.store.insert(new_id.clone(), *kind, parent, pos)?;
                let bag = self.store.props_mut(&new_id)?;
                for (k, v) in props {
                    bag.set(*k, v.clone());
                }
                let before = self.next_sibling(parent, &new_id);
                Ok(Some((
                    UndoOp::RemoveInserted(new_id.clone()),
                    AppliedEffect::Inserted { id: new_id, before },
                )))
            }
            CanvasOp::Update { id, set, unset } => {
                let Some(rec) = self.store.get(id) else {
                    return Err(StoreError::UnknownId(id.as_str().to_owned()).into());
                };
                let kind = rec.kind;
                if rec.props.len() + set.len() > MAX_PROPS_PER_RECORD {
                    return Err(FenceError::CapExceeded("props per record").into());
                }
                for (k, v) in set {
                    registry::check_prop(kind, *k, v)?;
                }
                for k in unset {
                    registry::check_allowed(kind, *k)?;
                }
                // Capture the inverse BEFORE mutating.
                let mut inv_set: Vec<(PropKey, Value)> = Vec::new();
                let mut inv_unset: Vec<PropKey> = Vec::new();
                for (k, _) in set {
                    match rec.props.get(*k) {
                        Some(old) => inv_set.push((*k, old.clone())),
                        None => inv_unset.push(*k),
                    }
                }
                for k in unset {
                    if let Some(old) = rec.props.get(*k) {
                        inv_set.push((*k, old.clone()));
                    }
                }
                let bag = self.store.props_mut(id)?;
                for (k, v) in set {
                    bag.set(*k, v.clone());
                }
                for k in unset {
                    bag.unset(*k);
                }
                Ok(Some((
                    UndoOp::RestoreProps {
                        id: id.clone(),
                        set: inv_set,
                        unset: inv_unset,
                    },
                    AppliedEffect::Updated(id.clone()),
                )))
            }
            CanvasOp::Move { id, parent, pos } => {
                let Some(rec) = self.store.get(id) else {
                    return Err(StoreError::UnknownId(id.as_str().to_owned()).into());
                };
                let old_place = rec.place.clone();
                self.store.move_to(id, parent, pos)?;
                Ok(Some((
                    UndoOp::RestorePlace {
                        id: id.clone(),
                        place: old_place,
                    },
                    AppliedEffect::Moved {
                        id: id.clone(),
                        before: self.next_sibling(parent, id),
                    },
                )))
            }
            CanvasOp::Remove { id } => {
                let removed = self.store.remove(id)?;
                Ok(Some((UndoOp::Resurrect(removed), AppliedEffect::Removed(id.clone()))))
            }
        }
    }

    /// The sibling immediately after `id` under `parent` RIGHT NOW (the
    /// `insertBefore` anchor at this point in the batch; None = append).
    fn next_sibling(&self, parent: &Id, id: &Id) -> Option<Id> {
        let kids = self.store.children(parent);
        let idx = kids.iter().position(|k| k == id)?;
        kids.get(idx + 1).cloned()
    }

    fn run_undo(&mut self, undo: UndoOp) {
        // Undo ops restore states this engine itself captured; a failure here
        // means internal inconsistency — surface loudly in debug, tolerate in
        // release (the store stays valid either way).
        match undo {
            UndoOp::RemoveInserted(id) => {
                let r = self.store.remove(&id);
                debug_assert!(r.is_ok(), "undo remove failed: {r:?}");
            }
            UndoOp::RestoreProps { id, set, unset } => {
                if let Ok(bag) = self.store.props_mut(&id) {
                    for (k, v) in set {
                        bag.set(k, v);
                    }
                    for k in unset {
                        bag.unset(k);
                    }
                }
            }
            UndoOp::RestorePlace { id, place } => {
                let r = self.store.set_place(&id, place);
                debug_assert!(r.is_ok(), "undo place failed: {r:?}");
            }
            UndoOp::Resurrect(records) => {
                let r = self.store.resurrect(records);
                debug_assert!(r.is_ok(), "undo resurrect failed: {r:?}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn id(s: &str) -> Id {
        Id::parse(s).expect("id")
    }
    fn key(name: &str) -> PropKey {
        PropKey::by_name(name).expect("key")
    }

    fn doc_with_page() -> (DocState, Id) {
        let mut d = DocState::new();
        let pg = id("pg:1");
        d.store.insert_root(pg.clone(), RecordKind::Page).expect("root");
        (d, pg)
    }

    fn insert_text(ids: &str, parent: &Id, text: &str) -> CanvasOp {
        CanvasOp::Insert {
            id: Some(id(ids)),
            kind: RecordKind::Text,
            parent: parent.clone(),
            pos: Position::Last,
            props: vec![(key("text"), Value::Str(text.to_owned()))],
        }
    }

    #[test]
    fn apply_bumps_rev_and_undo_restores_fingerprint() {
        let (mut d, pg) = doc_with_page();
        let before = d.store.fingerprint();
        let applied = d
            .apply(0, &[insert_text("nd:a", &pg, "hello")])
            .expect("apply");
        assert_eq!(applied.rev, 1);
        assert_ne!(d.store.fingerprint(), before);
        d.undo(applied.inverses);
        assert_eq!(d.store.fingerprint(), before, "undo must restore exactly");
        assert_eq!(d.rev(), 2, "undo is itself a revision");
    }

    #[test]
    fn stale_base_rev_conflicts_with_current() {
        let (mut d, pg) = doc_with_page();
        d.apply(0, &[insert_text("nd:a", &pg, "x")]).expect("first");
        let err = d.apply(0, &[insert_text("nd:b", &pg, "y")]).expect_err("stale");
        assert_eq!(err, ApplyError::Conflict { current: 1 });
    }

    #[test]
    fn failing_op_rolls_back_the_whole_batch() {
        let (mut d, pg) = doc_with_page();
        let before = d.store.fingerprint();
        // Second op violates the fence (text prop on a frame).
        let batch = [
            insert_text("nd:ok", &pg, "fine"),
            CanvasOp::Insert {
                id: Some(id("nd:bad")),
                kind: RecordKind::Frame,
                parent: pg.clone(),
                pos: Position::Last,
                props: vec![(key("text"), Value::Str("nope".to_owned()))],
            },
        ];
        let err = d.apply(0, &batch).expect_err("fence");
        assert!(matches!(err, ApplyError::Fence(FenceError::PropNotAllowed { .. })));
        assert_eq!(d.store.fingerprint(), before, "no partial application");
        assert_eq!(d.rev(), 0, "failed batch must not bump rev");
        assert!(d.store.get(&id("nd:ok")).is_none());
    }

    #[test]
    fn insert_replay_with_same_content_is_idempotent_noop() {
        let (mut d, pg) = doc_with_page();
        let op = insert_text("nd:a", &pg, "hello");
        let first = d.apply(0, std::slice::from_ref(&op)).expect("first");
        assert_eq!(first.rev, 1);
        // Replay (e.g. an agent retry after a lost reply): Ok, no rev bump.
        let replay = d.apply(1, std::slice::from_ref(&op)).expect("replay");
        assert!(replay.noop);
        assert_eq!(replay.rev, 1);
        // Same id, DIFFERENT content: typed error.
        let clash = insert_text("nd:a", &pg, "different");
        assert!(matches!(
            d.apply(1, &[clash]).expect_err("clash"),
            ApplyError::IdInUse(_)
        ));
    }

    #[test]
    fn update_inverse_restores_prior_values_and_absences() {
        let (mut d, pg) = doc_with_page();
        d.apply(0, &[insert_text("nd:a", &pg, "v1")]).expect("seed");
        let before = d.store.fingerprint();
        let applied = d
            .apply(
                1,
                &[CanvasOp::Update {
                    id: id("nd:a"),
                    set: vec![
                        (key("text"), Value::Str("v2".to_owned())),
                        (key("color"), Value::Token("color.accent".to_owned())),
                    ],
                    unset: vec![],
                }],
            )
            .expect("update");
        d.undo(applied.inverses);
        assert_eq!(d.store.fingerprint(), before);
    }

    #[test]
    fn move_inverse_restores_exact_place_and_remove_resurrects_subtree() {
        let (mut d, pg) = doc_with_page();
        d.apply(
            0,
            &[
                CanvasOp::Insert {
                    id: Some(id("nd:f")),
                    kind: RecordKind::Frame,
                    parent: pg.clone(),
                    pos: Position::Last,
                    props: vec![],
                },
                insert_text("nd:a", &pg, "a"),
            ],
        )
        .expect("seed");
        let before = d.store.fingerprint();
        // Move then undo.
        let moved = d
            .apply(
                1,
                &[CanvasOp::Move {
                    id: id("nd:a"),
                    parent: id("nd:f"),
                    pos: Position::First,
                }],
            )
            .expect("move");
        d.undo(moved.inverses);
        assert_eq!(d.store.fingerprint(), before);
        // Remove the frame subtree then undo.
        let rev = d.rev();
        let removed = d
            .apply(rev, &[CanvasOp::Remove { id: id("nd:f") }])
            .expect("remove");
        d.undo(removed.inverses);
        assert_eq!(d.store.fingerprint(), before);
    }

    proptest! {
        /// apply ∘ undo = identity over arbitrary batches spanning the FULL
        /// op vocabulary (Insert / Update / Move / Remove / DefineComponent —
        /// the last two were undo-covered only by example tests). AND: a
        /// batch the fence REJECTS leaves state byte-identical (atomicity).
        /// Byte range 0..6 exercises every arm; invalid combos (e.g. remove
        /// then touch the same id) exercise the rejection path.
        #[test]
        fn apply_then_undo_is_identity(seed in proptest::collection::vec(0u8..6, 1..30)) {
            let (mut d, pg) = doc_with_page();
            // Seed some structure.
            d.apply(0, &[
                CanvasOp::Insert { id: Some(id("nd:f")), kind: RecordKind::Frame,
                    parent: pg.clone(), pos: Position::Last, props: vec![] },
                insert_text("nd:t1", &pg, "one"),
                insert_text("nd:t2", &pg, "two"),
            ]).expect("seed");
            let before = d.store.fingerprint();
            let base = d.rev();
            // Build a batch from the seed bytes.
            let mut batch: Vec<CanvasOp> = Vec::new();
            for (i, b) in seed.iter().enumerate() {
                match b {
                    0 => batch.push(CanvasOp::Insert {
                        id: None, kind: RecordKind::Text, parent: pg.clone(),
                        pos: Position::Last,
                        props: vec![(key("text"), Value::Str(format!("gen{i}")))],
                    }),
                    1 => batch.push(CanvasOp::Update {
                        id: id("nd:t1"),
                        set: vec![(key("text"), Value::Str(format!("upd{i}")))],
                        unset: vec![],
                    }),
                    2 => batch.push(CanvasOp::Move {
                        id: id("nd:t2"), parent: id("nd:f"), pos: Position::First,
                    }),
                    3 => batch.push(CanvasOp::Update {
                        id: id("nd:t2"),
                        set: vec![(key("color"), Value::Token("color.fg".to_owned()))],
                        unset: vec![(key("font"))],
                    }),
                    // M4.S3 op — a definition root (undo = subtree resurrection).
                    4 => batch.push(CanvasOp::DefineComponent {
                        id: id(&format!("cmp:gen{i}")),
                    }),
                    // Remove — order vs Move/Update of the same id may make the
                    // batch invalid, exercising the rejection-atomicity path.
                    _ => batch.push(CanvasOp::Remove { id: id("nd:t2") }),
                }
            }
            match d.apply(base, &batch) {
                Ok(applied) => {
                    d.undo(applied.inverses);
                    prop_assert_eq!(d.store.fingerprint(), before, "apply∘undo = identity");
                }
                Err(_) => {
                    // The fence rejected the batch atomically: NO state change.
                    prop_assert_eq!(
                        d.store.fingerprint(), before,
                        "a rejected batch leaves state byte-identical");
                }
            }
        }
    }
}
