//! Canvas M1.S1 — the flat record store (TSK-1356).
//!
//! The engine's load-bearing storage decision (docs/canvas/01-RESEARCH-ANALYSIS
//! §1, docs/canvas/02-CORE-ENGINE §2): records live in a **flat map keyed by
//! id**; hierarchy is a **`Place { parent, index }` field on the child** —
//! ONE atomically-updated field (the Figma rule: parent link and sibling
//! position must move together or concurrent/batched moves orphan nodes).
//! Sibling order is a **fractional index** (lexicographic byte order over a
//! base-62 alphabet): insert-between is O(1) with no sibling renumbering.
//!
//! Single-writer v1: index minting is deterministic midpoints (no jitter —
//! jitter exists to stop two CLIENTS minting identical keys; the multi-writer
//! door stays open, the rng dependency stays out).
//!
//! Ids are branded, prefixed, opaque, caller-suppliable, and NEVER reused
//! (tombstones) — the anti-topological-naming rule (01 §8).

use std::collections::{HashMap, HashSet};

/// Base-62 digit alphabet in ASCII order — lexicographic byte comparison of
/// index strings therefore equals numeric fractional order.
const DIGITS: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const BASE: usize = 62;

/// Position of a digit byte in [`DIGITS`] (None for a foreign byte).
fn digit_value(b: u8) -> Option<usize> {
    DIGITS.iter().position(|d| *d == b)
}

/// A fractional sibling index: a non-empty base-62 string that never ends in
/// the minimum digit (`'0'`), so every key has room below and equality can't
/// hide behind trailing zeros.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct FracIndex(String);

/// Errors from index arithmetic.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IndexError {
    /// `between` requires `a < b`.
    NotOrdered,
    /// A key contained a byte outside the base-62 alphabet.
    BadDigit,
}

impl FracIndex {
    /// The canonical first key for an empty sibling list (mid-alphabet keeps
    /// both directions open).
    #[must_use]
    pub fn initial() -> Self {
        FracIndex("V".to_owned())
    }

    /// The string form (for serialization).
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Parse a serialized key, validating the alphabet + no-trailing-zero
    /// invariant.
    pub fn parse(s: &str) -> Result<Self, IndexError> {
        if s.is_empty() || s.ends_with('0') {
            return Err(IndexError::BadDigit);
        }
        if s.bytes().any(|b| digit_value(b).is_none()) {
            return Err(IndexError::BadDigit);
        }
        Ok(FracIndex(s.to_owned()))
    }

    /// Digit at position `i` of `self` padded with infinite trailing zeros.
    fn digit(&self, i: usize) -> usize {
        self.0
            .as_bytes()
            .get(i)
            .and_then(|b| digit_value(*b))
            .unwrap_or(0)
    }

    /// A key strictly between `a` and `b` (either side open). `(None, None)`
    /// yields [`FracIndex::initial`]-adjacent keys; `a < b` is required when
    /// both are given. Digit-wise midpoint over the virtual infinite-precision
    /// fractions (the Figma/fractional-indexing construction).
    pub fn between(a: Option<&FracIndex>, b: Option<&FracIndex>) -> Result<Self, IndexError> {
        if let (Some(x), Some(y)) = (a, b)
            && x >= y
        {
            return Err(IndexError::NotOrdered);
        }
        let mut out: Vec<u8> = Vec::new();
        let mut i = 0usize;
        loop {
            let da = a.map_or(0, |x| x.digit(i));
            let db = b.map_or(BASE, |y| y.digit(i));
            if db.saturating_sub(da) > 1 {
                let mid = da + (db - da) / 2;
                let Some(d) = DIGITS.get(mid) else {
                    return Err(IndexError::BadDigit);
                };
                out.push(*d);
                break;
            }
            // Digits equal, or adjacent (db == da + 1): emit `da` and descend.
            // Once we've committed to da < db at this digit, only the LOWER
            // bound constrains the remaining digits — the upper side is open
            // because any extension of ...da is < ...db. Model that by keeping
            // `a`'s tail only when we followed a's digit exactly.
            let Some(d) = DIGITS.get(da) else {
                return Err(IndexError::BadDigit);
            };
            out.push(*d);
            if db != da {
                // Committed strictly below b: drop the upper bound, keep
                // walking a's tail until a digit < max appears to split above.
                let mut j = i + 1;
                loop {
                    let daj = a.map_or(0, |x| x.digit(j));
                    if BASE - daj > 1 {
                        let mid = daj + (BASE - daj) / 2;
                        let Some(dd) = DIGITS.get(mid) else {
                            return Err(IndexError::BadDigit);
                        };
                        out.push(*dd);
                        let s = String::from_utf8(out).map_err(|_| IndexError::BadDigit)?;
                        return Ok(FracIndex(s));
                    }
                    let Some(dd) = DIGITS.get(daj) else {
                        return Err(IndexError::BadDigit);
                    };
                    out.push(*dd);
                    j += 1;
                }
            }
            i += 1;
        }
        let s = String::from_utf8(out).map_err(|_| IndexError::BadDigit)?;
        Ok(FracIndex(s))
    }
}

/// A branded record id: `<prefix>:<suffix>`, prefix ∈ the closed kind set,
/// suffix non-empty. Opaque, stable, never reused.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Id(Box<str>);

/// Legal id prefixes (one per record kind family).
const ID_PREFIXES: &[&str] = &["nd", "pg", "cmp", "tok", "dat", "tl"];

/// Errors from id validation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IdError {
    /// Not `<prefix>:<suffix>`, empty suffix, or a namespaced expansion id.
    BadShape,
    /// The prefix is not one of the legal id families.
    UnknownPrefix,
}

impl Id {
    /// Validate + construct from `<prefix>:<suffix>`.
    pub fn parse(s: &str) -> Result<Self, IdError> {
        let Some((prefix, suffix)) = s.split_once(':') else {
            return Err(IdError::BadShape);
        };
        if suffix.is_empty() {
            return Err(IdError::BadShape);
        }
        // Namespaced EXPANSION ids (nd:inst/nd:inner) are DOM-only (M4-PLAN
        // leakage fence): they must never become op targets — instances are
        // edited via their definition or overrides.
        if suffix.contains('/') {
            return Err(IdError::BadShape);
        }
        if !ID_PREFIXES.contains(&prefix) {
            return Err(IdError::UnknownPrefix);
        }
        Ok(Id(s.into()))
    }

    /// The string form.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Infallible constructor for the fixed root-page ids (`pg:<n>`), used by
    /// engine internals that need a statically-valid id without a fallible
    /// parse (no-panic policy).
    #[must_use]
    pub fn page(n: u32) -> Id {
        Id(format!("pg:{n}").into())
    }
}

#[cfg(test)]
mod id_fence_tests {
    use super::*;

    #[test]
    fn namespaced_expansion_ids_are_dom_only() {
        // The M4 leakage fence: expanded ids can never be op targets.
        assert_eq!(Id::parse("nd:inst-a/nd:inner"), Err(IdError::BadShape));
        assert!(Id::parse("nd:inst-a").is_ok());
    }
}

/// Hierarchy — parent link + sibling order as ONE field (atomic by
/// construction: there is no way to update one without the other).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Place {
    /// The containing parent.
    pub parent: Id,
    /// Fractional sibling index within the parent.
    pub index: FracIndex,
}

/// Record kind stub (S2's type registry richens this; S1 needs only the
/// distinction "can parent" for structural rules).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecordKind {
    /// A root page.
    Page,
    /// A container frame (can parent).
    Frame,
    /// A text element.
    Text,
    /// An image element (`src` prop).
    Image,
    /// A vector shape.
    Shape,
    /// A component instance (`use #name`).
    Component,
    /// An embedded external resource.
    Embed,
    /// A component slot placeholder.
    Hole,
    /// Tabular data (M4.S7a): rows/cells from a JSON `data` prop, lowered
    /// to a real `<table>`.
    Table,
    /// Pre-formatted code (M4.S7a): the `text` prop + a `language` tag.
    Code,
    /// Chart (M4.S7b): a hand-rolled Vega-Lite-SUBSET `spec` prop rendered
    /// to deterministic SVG rust-side (bar/line/pie; zero deps).
    Chart,
    /// Diagram (M4.S7b): mermaid SOURCE in the `text` prop; the canvas
    /// lowers a labeled block (live mermaid render = shell integration).
    Diagram,
}

impl RecordKind {
    /// May this kind contain children?
    #[must_use]
    pub fn can_parent(self) -> bool {
        matches!(self, RecordKind::Page | RecordKind::Frame)
    }
}

/// One stored record: identity, kind, placement, and the S2 prop bag.
#[derive(Debug, Clone)]
pub struct Record {
    /// Stable identity.
    pub id: Id,
    /// Element kind.
    pub kind: RecordKind,
    /// `None` = a root record (a page). Everything else is placed.
    pub place: Option<Place>,
    /// Typed properties (S2: interned keys, fence-validated by the op layer).
    pub props: super::props::PropBag,
}

/// Where to insert/move within a parent's sibling list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Position {
    /// First among the parent's children.
    First,
    /// Last among the parent's children.
    Last,
    /// Immediately before the anchor sibling.
    Before(Id),
    /// Immediately after the anchor sibling.
    After(Id),
}

/// Store faults — typed, never panics.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StoreError {
    /// No live record with this id.
    UnknownId(String),
    /// An insert reused a live id.
    DuplicateId(String),
    /// The id was used before and removed — ids are never reused.
    TombstonedId(String),
    /// The named parent cannot hold children.
    NotAParent(String),
    /// The move would place a record under its own descendant.
    CycleMove(String),
    /// A Before/After anchor is not a child of the target parent.
    BadAnchor(String),
    /// A fractional-index fault.
    Index(IndexError),
}

impl From<IndexError> for StoreError {
    fn from(e: IndexError) -> Self {
        StoreError::Index(e)
    }
}

/// The flat record store.
#[derive(Debug, Default)]
pub struct Store {
    records: HashMap<Id, Record>,
    tombstones: HashSet<Id>,
    /// Mint counter for engine-generated ids (per-store, monotonic).
    next_serial: u64,
}

impl Store {
    /// An empty store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Number of live records.
    #[must_use]
    pub fn len(&self) -> usize {
        self.records.len()
    }

    /// True when no live records exist.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    /// The live record for `id`, if any.
    #[must_use]
    pub fn get(&self, id: &Id) -> Option<&Record> {
        self.records.get(id)
    }

    /// All live record ids (unordered; callers sort for determinism).
    pub fn ids(&self) -> impl Iterator<Item = &Id> {
        self.records.keys()
    }

    /// Tombstoned ids (unordered; persistence sorts).
    pub fn tombstone_ids(&self) -> impl Iterator<Item = &Id> {
        self.tombstones.iter()
    }

    /// The id-mint serial (persisted so loads keep minting fresh ids).
    #[must_use]
    pub fn serial(&self) -> u64 {
        self.next_serial
    }

    /// Persistence restore: bulk-place verbatim records. Rejects duplicate
    /// ids; performs NO structural validation beyond that (the saved form is
    /// this engine's own output — `load` shape-checks fields).
    pub fn restore_records(&mut self, records: Vec<Record>) -> Result<(), StoreError> {
        for rec in records {
            if self.records.contains_key(&rec.id) {
                return Err(StoreError::DuplicateId(rec.id.as_str().to_owned()));
            }
            self.records.insert(rec.id.clone(), rec);
        }
        Ok(())
    }

    /// Persistence restore: the tombstone set.
    pub fn restore_tombstones(&mut self, ids: Vec<Id>) {
        self.tombstones.extend(ids);
    }

    /// Persistence restore: the mint serial.
    pub fn restore_serial(&mut self, serial: u64) {
        self.next_serial = serial;
    }

    /// Mint a fresh, never-used id with the given prefix.
    pub fn mint_id(&mut self, prefix: &str) -> Result<Id, StoreError> {
        loop {
            self.next_serial += 1;
            let candidate = format!("{prefix}:{serial:x}", serial = self.next_serial);
            match Id::parse(&candidate) {
                Ok(id) => {
                    if !self.records.contains_key(&id) && !self.tombstones.contains(&id) {
                        return Ok(id);
                    }
                }
                Err(_) => return Err(StoreError::UnknownId(candidate)),
            }
        }
    }

    /// Ordered children ids of `parent` (ascending fractional index).
    #[must_use]
    pub fn children(&self, parent: &Id) -> Vec<Id> {
        let mut kids: Vec<(&FracIndex, &Id)> = self
            .records
            .values()
            .filter_map(|r| match &r.place {
                Some(p) if p.parent == *parent => Some((&p.index, &r.id)),
                _ => None,
            })
            .collect();
        kids.sort();
        kids.into_iter().map(|(_, id)| id.clone()).collect()
    }

    /// Insert a ROOT record (a page) — no place.
    pub fn insert_root(&mut self, id: Id, kind: RecordKind) -> Result<(), StoreError> {
        self.check_fresh(&id)?;
        self.records.insert(
            id.clone(),
            Record {
                id,
                kind,
                place: None,
                props: super::props::PropBag::new(),
            },
        );
        Ok(())
    }

    /// Mutable prop access for the op layer (which owns fence validation).
    pub fn props_mut(&mut self, id: &Id) -> Result<&mut super::props::PropBag, StoreError> {
        self.records
            .get_mut(id)
            .map(|r| &mut r.props)
            .ok_or_else(|| StoreError::UnknownId(id.as_str().to_owned()))
    }

    /// Restore a record's EXACT place (undo path — no index re-mint).
    pub fn set_place(&mut self, id: &Id, place: Option<Place>) -> Result<(), StoreError> {
        let Some(rec) = self.records.get_mut(id) else {
            return Err(StoreError::UnknownId(id.as_str().to_owned()));
        };
        rec.place = place;
        Ok(())
    }

    /// Re-insert previously-removed records VERBATIM (the undo of a subtree
    /// remove). The ONLY path that clears a tombstone — an undo legitimately
    /// resurrects ids; ordinary inserts still never reuse them.
    pub fn resurrect(&mut self, records: Vec<Record>) -> Result<(), StoreError> {
        for rec in &records {
            if self.records.contains_key(&rec.id) {
                return Err(StoreError::DuplicateId(rec.id.as_str().to_owned()));
            }
        }
        for rec in records {
            self.tombstones.remove(&rec.id);
            self.records.insert(rec.id.clone(), rec);
        }
        Ok(())
    }

    /// A deterministic content fingerprint (sorted id → kind/place/props dump)
    /// for equality-style assertions that must ignore mint counters.
    #[must_use]
    pub fn fingerprint(&self) -> String {
        let mut ids: Vec<&Id> = self.records.keys().collect();
        ids.sort();
        let mut out = String::new();
        for id in ids {
            let Some(r) = self.records.get(id) else { continue };
            out.push_str(id.as_str());
            out.push('=');
            out.push_str(&format!("{:?}|{:?}|{:?};", r.kind, r.place, r.props));
        }
        out
    }

    /// Insert a placed record under `parent` at `pos`. The id must be fresh
    /// (caller-supplied ids make agent retries idempotent at the op layer —
    /// the DUPLICATE error is how the op layer detects the replay).
    pub fn insert(
        &mut self,
        id: Id,
        kind: RecordKind,
        parent: &Id,
        pos: &Position,
    ) -> Result<(), StoreError> {
        self.check_fresh(&id)?;
        let index = self.index_for(parent, pos, None)?;
        self.records.insert(
            id.clone(),
            Record {
                id,
                kind,
                place: Some(Place {
                    parent: parent.clone(),
                    index,
                }),
                props: super::props::PropBag::new(),
            },
        );
        Ok(())
    }

    /// Move a record to `parent` at `pos` — updates the ONE place field.
    pub fn move_to(&mut self, id: &Id, parent: &Id, pos: &Position) -> Result<(), StoreError> {
        if !self.records.contains_key(id) {
            return Err(StoreError::UnknownId(id.as_str().to_owned()));
        }
        // Cycle check: parent (and its ancestors) must not include `id`.
        let mut cursor = Some(parent.clone());
        while let Some(c) = cursor {
            if c == *id {
                return Err(StoreError::CycleMove(id.as_str().to_owned()));
            }
            cursor = self
                .records
                .get(&c)
                .and_then(|r| r.place.as_ref())
                .map(|p| p.parent.clone());
        }
        let index = self.index_for(parent, pos, Some(id))?;
        let Some(rec) = self.records.get_mut(id) else {
            return Err(StoreError::UnknownId(id.as_str().to_owned()));
        };
        rec.place = Some(Place {
            parent: parent.clone(),
            index,
        });
        Ok(())
    }

    /// Remove a record AND its subtree; all removed ids tombstone. Returns the
    /// removed RECORDS verbatim — the op layer's inverse resurrects them.
    pub fn remove(&mut self, id: &Id) -> Result<Vec<Record>, StoreError> {
        if !self.records.contains_key(id) {
            return Err(StoreError::UnknownId(id.as_str().to_owned()));
        }
        let mut removed = Vec::new();
        let mut stack = vec![id.clone()];
        while let Some(current) = stack.pop() {
            for kid in self.children(&current) {
                stack.push(kid);
            }
            if let Some(rec) = self.records.remove(&current) {
                self.tombstones.insert(current.clone());
                removed.push(rec);
            }
        }
        Ok(removed)
    }

    // MARK: internals

    fn check_fresh(&self, id: &Id) -> Result<(), StoreError> {
        if self.records.contains_key(id) {
            return Err(StoreError::DuplicateId(id.as_str().to_owned()));
        }
        if self.tombstones.contains(id) {
            return Err(StoreError::TombstonedId(id.as_str().to_owned()));
        }
        Ok(())
    }

    /// Compute the fractional index for `pos` within `parent`'s children,
    /// excluding `moving` (a record being repositioned among its siblings).
    fn index_for(
        &self,
        parent: &Id,
        pos: &Position,
        moving: Option<&Id>,
    ) -> Result<FracIndex, StoreError> {
        let Some(parent_rec) = self.records.get(parent) else {
            return Err(StoreError::UnknownId(parent.as_str().to_owned()));
        };
        if !parent_rec.kind.can_parent() {
            return Err(StoreError::NotAParent(parent.as_str().to_owned()));
        }
        let siblings: Vec<Id> = self
            .children(parent)
            .into_iter()
            .filter(|k| Some(k) != moving)
            .collect();
        let index_of = |sib: &Id| -> Option<&FracIndex> {
            self.records
                .get(sib)
                .and_then(|r| r.place.as_ref())
                .map(|p| &p.index)
        };
        let (lo, hi): (Option<&FracIndex>, Option<&FracIndex>) = match pos {
            Position::First => (None, siblings.first().and_then(index_of)),
            Position::Last => (siblings.last().and_then(index_of), None),
            Position::Before(anchor) => {
                let Some(i) = siblings.iter().position(|s| s == anchor) else {
                    return Err(StoreError::BadAnchor(anchor.as_str().to_owned()));
                };
                let lo = i.checked_sub(1).and_then(|j| siblings.get(j)).and_then(index_of);
                (lo, index_of(anchor))
            }
            Position::After(anchor) => {
                let Some(i) = siblings.iter().position(|s| s == anchor) else {
                    return Err(StoreError::BadAnchor(anchor.as_str().to_owned()));
                };
                (index_of(anchor), siblings.get(i + 1).and_then(index_of))
            }
        };
        if siblings.is_empty() {
            return Ok(FracIndex::initial());
        }
        Ok(FracIndex::between(lo, hi)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn id(s: &str) -> Id {
        Id::parse(s).expect("test id")
    }

    fn store_with_page() -> (Store, Id) {
        let mut s = Store::new();
        let pg = id("pg:1");
        s.insert_root(pg.clone(), RecordKind::Page).expect("root");
        (s, pg)
    }

    #[test]
    fn frac_between_is_strictly_between() {
        let a = FracIndex::parse("V").expect("a");
        let b = FracIndex::parse("W").expect("b");
        let m = FracIndex::between(Some(&a), Some(&b)).expect("mid");
        assert!(a < m && m < b, "{a:?} < {m:?} < {b:?}");
        assert!(!m.as_str().ends_with('0'));
    }

    #[test]
    fn frac_between_rejects_unordered() {
        let a = FracIndex::parse("W").expect("a");
        let b = FracIndex::parse("V").expect("b");
        assert_eq!(
            FracIndex::between(Some(&a), Some(&b)),
            Err(IndexError::NotOrdered)
        );
        assert_eq!(
            FracIndex::between(Some(&a), Some(&a)),
            Err(IndexError::NotOrdered)
        );
    }

    #[test]
    fn thousand_prepends_and_appends_stay_ordered() {
        // Prepends: always insert before the current first.
        let mut first = FracIndex::initial();
        for _ in 0..1000 {
            let newer = FracIndex::between(None, Some(&first)).expect("prepend");
            assert!(newer < first);
            first = newer;
        }
        // Appends: always after the current last.
        let mut last = FracIndex::initial();
        for _ in 0..1000 {
            let newer = FracIndex::between(Some(&last), None).expect("append");
            assert!(newer > last);
            last = newer;
        }
    }

    #[test]
    fn id_validation() {
        assert!(Id::parse("nd:7f3a").is_ok());
        assert!(Id::parse("pg:1").is_ok());
        assert_eq!(Id::parse("nd:"), Err(IdError::BadShape));
        assert_eq!(Id::parse("nd7f3a"), Err(IdError::BadShape));
        assert_eq!(Id::parse("xx:1"), Err(IdError::UnknownPrefix));
    }

    #[test]
    fn insert_positions_order_children() {
        let (mut s, pg) = store_with_page();
        s.insert(id("nd:a"), RecordKind::Frame, &pg, &Position::Last).expect("a");
        s.insert(id("nd:b"), RecordKind::Text, &pg, &Position::Last).expect("b");
        s.insert(id("nd:c"), RecordKind::Text, &pg, &Position::First).expect("c");
        s.insert(id("nd:d"), RecordKind::Text, &pg, &Position::After(id("nd:a"))).expect("d");
        s.insert(id("nd:e"), RecordKind::Text, &pg, &Position::Before(id("nd:b"))).expect("e");
        let order: Vec<String> =
            s.children(&pg).iter().map(|k| k.as_str().to_owned()).collect();
        assert_eq!(order, vec!["nd:c", "nd:a", "nd:d", "nd:e", "nd:b"]);
    }

    #[test]
    fn move_reorders_and_reparents_atomically() {
        let (mut s, pg) = store_with_page();
        s.insert(id("nd:f"), RecordKind::Frame, &pg, &Position::Last).expect("f");
        s.insert(id("nd:x"), RecordKind::Text, &pg, &Position::Last).expect("x");
        s.move_to(&id("nd:x"), &id("nd:f"), &Position::First).expect("move");
        assert_eq!(s.children(&pg).len(), 1);
        assert_eq!(s.children(&id("nd:f")), vec![id("nd:x")]);
        let place = s.get(&id("nd:x")).and_then(|r| r.place.clone()).expect("place");
        assert_eq!(place.parent, id("nd:f"));
    }

    #[test]
    fn cycle_moves_are_rejected() {
        let (mut s, pg) = store_with_page();
        s.insert(id("nd:f"), RecordKind::Frame, &pg, &Position::Last).expect("f");
        s.insert(id("nd:g"), RecordKind::Frame, &id("nd:f"), &Position::Last).expect("g");
        // f under its own child g = cycle.
        assert!(matches!(
            s.move_to(&id("nd:f"), &id("nd:g"), &Position::Last),
            Err(StoreError::CycleMove(_))
        ));
        // Self-parent is also a cycle.
        assert!(matches!(
            s.move_to(&id("nd:f"), &id("nd:f"), &Position::Last),
            Err(StoreError::CycleMove(_))
        ));
    }

    #[test]
    fn remove_takes_subtree_and_tombstones_forever() {
        let (mut s, pg) = store_with_page();
        s.insert(id("nd:f"), RecordKind::Frame, &pg, &Position::Last).expect("f");
        s.insert(id("nd:x"), RecordKind::Text, &id("nd:f"), &Position::Last).expect("x");
        let removed = s.remove(&id("nd:f")).expect("remove");
        assert_eq!(removed.len(), 2);
        assert!(s.get(&id("nd:f")).is_none());
        assert!(s.get(&id("nd:x")).is_none());
        // Never reused:
        assert!(matches!(
            s.insert(id("nd:f"), RecordKind::Frame, &pg, &Position::Last),
            Err(StoreError::TombstonedId(_))
        ));
    }

    #[test]
    fn non_parents_reject_children() {
        let (mut s, pg) = store_with_page();
        s.insert(id("nd:t"), RecordKind::Text, &pg, &Position::Last).expect("t");
        assert!(matches!(
            s.insert(id("nd:y"), RecordKind::Text, &id("nd:t"), &Position::Last),
            Err(StoreError::NotAParent(_))
        ));
    }

    proptest! {
        /// The order-stability storm (M1-PLAN §S1): arbitrary interleavings of
        /// insert-at-position keep children strictly ordered with unique ids.
        #[test]
        fn storm_keeps_children_strictly_ordered(ops in proptest::collection::vec(0u8..4, 1..120)) {
            let (mut s, pg) = store_with_page();
            for (i, op) in ops.into_iter().enumerate() {
                let new_id = s.mint_id("nd").expect("mint");
                let kids = s.children(&pg);
                let pos = match (op, kids.len()) {
                    (0, _) | (_, 0) => Position::First,
                    (1, _) => Position::Last,
                    (2, n) => Position::Before(kids[i % n].clone()),
                    (_, n) => Position::After(kids[i % n].clone()),
                };
                s.insert(new_id, RecordKind::Text, &pg, &pos).expect("insert");
                // Invariant: strictly ascending indexes, no duplicates.
                let kids = s.children(&pg);
                let mut prev: Option<FracIndex> = None;
                for k in &kids {
                    let idx = s.get(k).and_then(|r| r.place.clone()).expect("place").index;
                    if let Some(p) = &prev {
                        prop_assert!(*p < idx, "order violated: {:?} !< {:?}", p, idx);
                    }
                    prev = Some(idx);
                }
                prop_assert_eq!(kids.len(), i + 1);
            }
        }
    }
}
