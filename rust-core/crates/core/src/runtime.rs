//! Eviction-policy core for the multi-document runtime (TSK-589).
//!
//! **Slice 1: the PURE eviction decision.** No registry, no FFI, no clock —
//! given a snapshot of resident documents (`DocMeta`) and an [`EvictionBudget`],
//! [`eviction_plan`] returns the `DocId`s to evict to bring memory under the
//! byte budget + count cap, never evicting a pinned (active / visible / unsaved)
//! document, with an optional TTL idle-reaper as the orphan backstop. The owning
//! `CoreRuntime` registry (the `RwLock<HashMap<DocId, …>>` store), the FFI/serve
//! shims, and `DocNotFound` rehydration are later slices.
//!
//! Keeping the policy a pure function makes it fully unit-testable on the host
//! (no VM, no FFI) — the validation tier `CLAUDE.md` calls "pure-logic ⇒ write
//! the behaviour test, self-validate".
//!
//! Design: `docs/SESSION_EVICTION_POLICY_2026-06-19.md` (Option 4 — hybrid
//! byte-budget + count-cap LRU with host pinning + TTL reaper). Owner-ratified
//! defaults (2026-06-19): 512 MiB / 64 docs / TTL-off, all configurable.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError, RwLock, RwLockReadGuard, RwLockWriteGuard};

/// Monotonic, never-reused document id (the audit's Phase-2 `DocId`; the
/// `usize` token in `crates/ffi/src/handle.rs` is its de-facto precursor).
/// Never reused ⇒ a stale id is always a recoverable `DocNotFound`, never ABA.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, PartialOrd, Ord)]
pub struct DocId(pub u64);

/// Eviction thresholds. All runtime-configurable (a later `runtime_configure`
/// slice) so the host can tune per device — a 96 GB Mac Studio vs an 8 GB Air —
/// and a test can force a tiny budget to exercise eviction deterministically.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct EvictionBudget {
    /// Hard resident-document RAM ceiling — the primary bound.
    pub max_bytes: usize,
    /// Secondary guard against many-tiny-docs map bloat. `0` = disabled.
    pub max_count: usize,
    /// Idle-reaper horizon in milliseconds. `0` = disabled (byte + count only).
    pub ttl_ms: u64,
}

impl EvictionBudget {
    /// Owner-ratified in-process defaults (TSK-589, 2026-06-19).
    pub const DEFAULT_MAX_BYTES: usize = 512 * 1024 * 1024;
    pub const DEFAULT_MAX_COUNT: usize = 64;

    pub fn new(max_bytes: usize, max_count: usize, ttl_ms: u64) -> Self {
        Self { max_bytes, max_count, ttl_ms }
    }
}

impl Default for EvictionBudget {
    fn default() -> Self {
        Self {
            max_bytes: Self::DEFAULT_MAX_BYTES,
            max_count: Self::DEFAULT_MAX_COUNT,
            ttl_ms: 0,
        }
    }
}

/// A resident document's eviction-relevant metadata (a snapshot; the registry
/// owns the live documents). `last_touched_ms` is a host-supplied monotonic
/// clock reading, passed in so the policy stays pure and deterministically
/// testable rather than reading a wall clock.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DocMeta {
    pub id: DocId,
    /// Estimated resident bytes (text buffer + offset table + filter cache).
    pub estimated_bytes: usize,
    /// Monotonic ms timestamp of the last access (LRU + TTL basis).
    pub last_touched_ms: u64,
    /// Host-pinned (active / visible / unsaved-edit) ⇒ never an eviction victim.
    pub pinned: bool,
}

/// Total resident bytes of a document set — the size hook behind `runtime_stats`.
pub fn resident_bytes(docs: &[DocMeta]) -> usize {
    docs.iter().map(|d| d.estimated_bytes).sum()
}

/// Decide which documents to evict to satisfy `budget` as of `now_ms`.
///
/// Order:
/// 1. **TTL reaper** (when `ttl_ms > 0`) drops every unpinned doc idle beyond
///    `ttl_ms` — the orphan backstop for a remote client that died without close.
/// 2. **Byte + count loop** evicts the least-recently-used UNPINNED doc until
///    both `max_bytes` and `max_count` are satisfied, or only pinned docs remain.
///
/// Pinned docs are never evicted: if pinned docs alone exceed the budget the set
/// stays over-budget (the host's signal to close tabs) rather than surprise-
/// closing a visible document. Returns victims in eviction order.
pub fn eviction_plan(docs: &[DocMeta], budget: &EvictionBudget, now_ms: u64) -> Vec<DocId> {
    let mut victims: Vec<DocId> = Vec::new();
    let mut evicted: HashSet<DocId> = HashSet::new();

    // 1. TTL idle-reaper (orphan backstop) — only when enabled. DocIds are
    //    unique per the registry contract, so no dedup is needed here.
    if budget.ttl_ms > 0 {
        for d in docs {
            let idle = now_ms.saturating_sub(d.last_touched_ms);
            if !d.pinned && idle > budget.ttl_ms {
                evicted.insert(d.id);
                victims.push(d.id);
            }
        }
    }

    // 2. Byte budget + count cap — evict the LRU-unpinned doc until within both
    //    bounds (or no unpinned doc remains). Recomputes the resident totals each
    //    pass; the doc set is small (bounded by the count cap + pins).
    loop {
        let mut total_bytes = 0usize;
        let mut count = 0usize;
        let mut lru: Option<&DocMeta> = None;
        for d in docs {
            if evicted.contains(&d.id) {
                continue;
            }
            total_bytes += d.estimated_bytes;
            count += 1;
            if !d.pinned {
                // Track the oldest (smallest last_touched) unpinned doc.
                let older = match lru {
                    Some(cur) => d.last_touched_ms < cur.last_touched_ms,
                    None => true,
                };
                if older {
                    lru = Some(d);
                }
            }
        }
        let over_bytes = total_bytes > budget.max_bytes;
        let over_count = budget.max_count > 0 && count > budget.max_count;
        if !over_bytes && !over_count {
            break;
        }
        match lru {
            Some(v) => {
                evicted.insert(v.id);
                victims.push(v.id);
            }
            None => break, // only pinned docs remain → stay over-budget
        }
    }

    victims
}

/// A snapshot of the runtime for diagnostics / `runtime_stats` (size + count
/// hook). `over_budget` is true when resident bytes exceed `budget.max_bytes` —
/// which can only happen when pinned docs alone exceed it (the host's signal to
/// close tabs), since unpinned docs are evicted to stay under.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RuntimeStats {
    pub doc_count: usize,
    pub total_bytes: usize,
    pub over_budget: bool,
    pub budget: EvictionBudget,
}

/// The multi-document runtime registry (TSK-589 slice 2). Owns the resident
/// documents keyed by monotonic [`DocId`], tracks per-doc eviction metadata, and
/// applies [`eviction_plan`] on admission (open) and on demand (`enforce`).
///
/// Generic over the stored payload `D` so it is fully host-testable without the
/// `CsvSession` / FFI layers — slice 4 wires the concrete `DocumentSession` and
/// its `estimated_bytes()`; slice 5 adds the Swift `DocNotFound` rehydration.
/// This replaces `crates/ffi/src/handle.rs`'s unbounded `Arc<HashMap>` whose only
/// GC is Swift ARC `deinit` (which breaks once the core goes remote/out-of-process).
pub struct CoreRuntime<D> {
    docs: RwLock<HashMap<DocId, Arc<Mutex<D>>>>,
    meta: RwLock<HashMap<DocId, DocMeta>>,
    budget: RwLock<EvictionBudget>,
    next_id: AtomicU64,
}

/// Acquire a read guard, recovering from lock poisoning: a holder thread that
/// panicked left the protected data structurally valid, so the runtime recovers
/// the guard rather than crashing. (Also keeps the lock sites clippy-clean — no
/// `unwrap`/`expect`.)
#[inline]
fn read_guard<T>(lock: &RwLock<T>) -> RwLockReadGuard<'_, T> {
    lock.read().unwrap_or_else(PoisonError::into_inner)
}

/// Acquire a write guard, recovering from lock poisoning (see [`read_guard`]).
#[inline]
fn write_guard<T>(lock: &RwLock<T>) -> RwLockWriteGuard<'_, T> {
    lock.write().unwrap_or_else(PoisonError::into_inner)
}

impl<D> CoreRuntime<D> {
    pub fn new(budget: EvictionBudget) -> Self {
        Self {
            docs: RwLock::new(HashMap::new()),
            meta: RwLock::new(HashMap::new()),
            budget: RwLock::new(budget),
            next_id: AtomicU64::new(1),
        }
    }

    /// Replace the budget at runtime (`runtime_configure`).
    pub fn configure(&self, budget: EvictionBudget) {
        *write_guard(&self.budget) = budget;
    }

    pub fn doc_count(&self) -> usize {
        read_guard(&self.docs).len()
    }

    /// Open a document: assign a fresh never-reused [`DocId`], insert it, then run
    /// admission eviction as of `now_ms`. The just-opened doc is protected from
    /// its OWN admission (spike §5: "admitted anyway, never refuse what the user
    /// asked for"), so it survives even if it alone exceeds the budget. Returns
    /// the new id and the ids evicted to admit it.
    pub fn open(&self, doc: D, estimated_bytes: usize, now_ms: u64) -> (DocId, Vec<DocId>) {
        let id = DocId(self.next_id.fetch_add(1, Ordering::Relaxed));
        {
            write_guard(&self.docs).insert(id, Arc::new(Mutex::new(doc)));
            write_guard(&self.meta).insert(
                id,
                DocMeta { id, estimated_bytes, last_touched_ms: now_ms, pinned: true },
            );
        }
        // Admission runs with the new doc pinned so it can never be its own
        // victim; restore the default-unpinned state afterwards (the host pins
        // visible/unsaved docs explicitly via set_pinned).
        let evicted = self.enforce(now_ms);
        self.set_pinned(id, false);
        (id, evicted)
    }

    /// Fetch a document handle, bumping its `last_touched`. `None` means the id
    /// was evicted or never existed — a recoverable `DocNotFound` the host
    /// rehydrates from the bytes it still holds (slice 5).
    pub fn get(&self, id: DocId, now_ms: u64) -> Option<Arc<Mutex<D>>> {
        let handle = read_guard(&self.docs).get(&id).cloned();
        // Bump recency on a hit; meta mirrors docs so a miss is a harmless no-op.
        if let Some(m) = write_guard(&self.meta).get_mut(&id) {
            m.last_touched_ms = now_ms;
        }
        handle
    }

    /// Mark a doc pinned (active / visible / unsaved-edit) or not. Pinned docs
    /// are never eviction victims. (Owner riders: all open tabs pinned; unsaved
    /// docs always pinned — enforced by the host at its call sites.)
    pub fn set_pinned(&self, id: DocId, pinned: bool) {
        if let Some(m) = write_guard(&self.meta).get_mut(&id) {
            m.pinned = pinned;
        }
    }

    /// Explicit close (replaces `session_free`; idempotent).
    pub fn close(&self, id: DocId) {
        write_guard(&self.docs).remove(&id);
        write_guard(&self.meta).remove(&id);
    }

    /// Apply the eviction policy now (admission ceiling + idle reaper), removing
    /// victims from the registry. Returns the evicted ids.
    pub fn enforce(&self, now_ms: u64) -> Vec<DocId> {
        let budget = *read_guard(&self.budget);
        let metas: Vec<DocMeta> = read_guard(&self.meta).values().copied().collect();
        let victims = eviction_plan(&metas, &budget, now_ms);
        if !victims.is_empty() {
            let mut docs = write_guard(&self.docs);
            let mut meta = write_guard(&self.meta);
            for v in &victims {
                docs.remove(v);
                meta.remove(v);
            }
        }
        victims
    }

    /// Refresh a doc's estimated resident bytes (TSK-1517: editor documents
    /// grow/shrink with every edit batch — the admission-time estimate goes
    /// stale, which would let a giant edited doc hide from the byte budget).
    /// Missing id is a harmless no-op (evicted/closed).
    pub fn update_estimate(&self, id: DocId, estimated_bytes: usize) {
        if let Some(m) = write_guard(&self.meta).get_mut(&id) {
            m.estimated_bytes = estimated_bytes;
        }
    }

    /// Diagnostics snapshot (the enumeration + size hook).
    pub fn stats(&self, _now_ms: u64) -> RuntimeStats {
        let budget = *read_guard(&self.budget);
        let metas: Vec<DocMeta> = read_guard(&self.meta).values().copied().collect();
        let total_bytes = resident_bytes(&metas);
        RuntimeStats {
            doc_count: metas.len(),
            total_bytes,
            over_budget: total_bytes > budget.max_bytes,
            budget,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc(id: u64, bytes: usize, touched: u64, pinned: bool) -> DocMeta {
        DocMeta { id: DocId(id), estimated_bytes: bytes, last_touched_ms: touched, pinned }
    }

    #[test]
    fn within_budget_evicts_nothing() {
        let docs = [doc(1, 100, 1, false), doc(2, 100, 2, false)];
        assert!(eviction_plan(&docs, &EvictionBudget::new(1000, 10, 0), 100).is_empty());
    }

    #[test]
    fn byte_budget_evicts_lru_unpinned() {
        // 3×100 = 300 over a 250 budget → evict exactly the oldest (id1, touched 10).
        let docs = [doc(1, 100, 10, false), doc(2, 100, 30, false), doc(3, 100, 20, false)];
        assert_eq!(eviction_plan(&docs, &EvictionBudget::new(250, 0, 0), 100), vec![DocId(1)]);
    }

    #[test]
    fn pinned_never_evicted_even_over_budget() {
        // all pinned, 300 > 100 budget → nothing evicted (over-budget signal).
        let docs = [doc(1, 100, 10, true), doc(2, 100, 20, true), doc(3, 100, 30, true)];
        assert!(eviction_plan(&docs, &EvictionBudget::new(100, 0, 0), 100).is_empty());
    }

    #[test]
    fn lru_skips_pinned_picks_oldest_unpinned() {
        // oldest (id1) is pinned → the next-oldest UNPINNED (id2) is the victim.
        let docs = [doc(1, 200, 10, true), doc(2, 200, 20, false), doc(3, 200, 30, false)];
        assert_eq!(eviction_plan(&docs, &EvictionBudget::new(450, 0, 0), 100), vec![DocId(2)]);
    }

    #[test]
    fn count_cap_evicts_lru() {
        let docs = [doc(1, 10, 10, false), doc(2, 10, 20, false), doc(3, 10, 30, false)];
        assert_eq!(eviction_plan(&docs, &EvictionBudget::new(usize::MAX, 2, 0), 100), vec![DocId(1)]);
    }

    #[test]
    fn count_cap_zero_is_disabled() {
        let docs = [doc(1, 10, 10, false), doc(2, 10, 20, false)];
        assert!(eviction_plan(&docs, &EvictionBudget::new(usize::MAX, 0, 0), 100).is_empty());
    }

    #[test]
    fn ttl_reaper_drops_idle_unpinned() {
        // ttl 50: id1 idle 90 (>50) reaped; id2 idle 10 kept.
        let docs = [doc(1, 10, 10, false), doc(2, 10, 90, false)];
        assert_eq!(eviction_plan(&docs, &EvictionBudget::new(usize::MAX, 0, 50), 100), vec![DocId(1)]);
    }

    #[test]
    fn ttl_zero_keeps_idle_docs() {
        let docs = [doc(1, 10, 0, false)];
        assert!(eviction_plan(&docs, &EvictionBudget::new(usize::MAX, 0, 0), 100).is_empty());
    }

    #[test]
    fn ttl_never_reaps_pinned() {
        let docs = [doc(1, 10, 0, true)]; // idle 100 but pinned
        assert!(eviction_plan(&docs, &EvictionBudget::new(usize::MAX, 0, 50), 100).is_empty());
    }

    /// §5e teeth: a tiny budget over three docs evicts exactly the LRU-unpinned
    /// ones (in order) to get under budget — fails the moment eviction no-ops.
    #[test]
    fn teeth_tiny_budget_evicts_lru_in_order() {
        // 3×100 = 300 over a 150 budget → evict the two oldest (10, 20), keep 30.
        let docs = [doc(1, 100, 10, false), doc(2, 100, 20, false), doc(3, 100, 30, false)];
        assert_eq!(
            eviction_plan(&docs, &EvictionBudget::new(150, 0, 0), 100),
            vec![DocId(1), DocId(2)]
        );
    }

    #[test]
    fn defaults_match_owner_ratified() {
        let b = EvictionBudget::default();
        assert_eq!(b.max_bytes, 512 * 1024 * 1024);
        assert_eq!(b.max_count, 64);
        assert_eq!(b.ttl_ms, 0);
    }

    #[test]
    fn resident_bytes_sums() {
        let docs = [doc(1, 100, 1, false), doc(2, 250, 2, true)];
        assert_eq!(resident_bytes(&docs), 350);
    }

    // ---- CoreRuntime registry (slice 2) ----

    #[test]
    fn open_assigns_monotonic_ids() {
        let rt: CoreRuntime<u32> = CoreRuntime::new(EvictionBudget::new(usize::MAX, 0, 0));
        let (a, _) = rt.open(1, 10, 1);
        let (b, _) = rt.open(2, 10, 2);
        assert_eq!(a, DocId(1));
        assert_eq!(b, DocId(2));
    }

    #[test]
    fn get_returns_handle_then_none_after_close() {
        let rt: CoreRuntime<u32> = CoreRuntime::new(EvictionBudget::default());
        let (id, _) = rt.open(42, 10, 1);
        assert_eq!(*rt.get(id, 2).unwrap().lock().unwrap(), 42);
        rt.close(id);
        assert!(rt.get(id, 3).is_none(), "closed id → DocNotFound");
    }

    #[test]
    fn admission_evicts_lru_when_over_budget() {
        // three 100-byte docs over a 250 budget → the 3rd open evicts the LRU.
        let rt: CoreRuntime<u32> = CoreRuntime::new(EvictionBudget::new(250, 0, 0));
        let (a, e1) = rt.open(1, 100, 10);
        assert!(e1.is_empty());
        let (b, e2) = rt.open(2, 100, 20);
        assert!(e2.is_empty(), "total 200 ≤ 250");
        let (c, e3) = rt.open(3, 100, 30);
        assert_eq!(e3, vec![a], "oldest (a) evicted to admit c");
        assert!(rt.get(a, 40).is_none());
        assert!(rt.get(b, 40).is_some());
        assert!(rt.get(c, 40).is_some());
    }

    #[test]
    fn new_doc_admitted_even_when_only_pinned_remain() {
        // a pinned (alone exceeds 50-byte budget); opening b must still admit b.
        let rt: CoreRuntime<u32> = CoreRuntime::new(EvictionBudget::new(50, 0, 0));
        let (a, _) = rt.open(1, 100, 1);
        rt.set_pinned(a, true);
        let (b, e) = rt.open(2, 100, 2);
        assert!(e.is_empty(), "new doc admitted anyway (never refused)");
        assert!(rt.get(b, 3).is_some());
        assert!(rt.get(a, 3).is_some());
    }

    #[test]
    fn pinned_doc_survives_admission_unpinned_evicted() {
        let rt: CoreRuntime<u32> = CoreRuntime::new(EvictionBudget::new(250, 0, 0));
        let (a, _) = rt.open(1, 100, 10);
        rt.set_pinned(a, true); // pin the oldest
        let (b, _) = rt.open(2, 100, 20);
        let (_c, e3) = rt.open(3, 100, 30);
        assert_eq!(e3, vec![b], "LRU-unpinned (b) evicted, pinned (a) spared");
        assert!(rt.get(a, 40).is_some());
    }

    #[test]
    fn touch_updates_recency_so_lru_shifts() {
        let rt: CoreRuntime<u32> = CoreRuntime::new(EvictionBudget::new(250, 0, 0));
        let (a, _) = rt.open(1, 100, 10);
        let (b, _) = rt.open(2, 100, 20);
        rt.get(a, 30); // touch a → now newer than b
        let (_c, e3) = rt.open(3, 100, 40);
        assert_eq!(e3, vec![b], "b is now the LRU and is evicted, not a");
        assert!(rt.get(a, 50).is_some());
    }

    #[test]
    fn close_is_idempotent() {
        let rt: CoreRuntime<u32> = CoreRuntime::new(EvictionBudget::default());
        let (id, _) = rt.open(1, 10, 1);
        rt.close(id);
        rt.close(id); // no panic
        assert_eq!(rt.doc_count(), 0);
    }

    #[test]
    fn enforce_reaps_idle_via_ttl() {
        let rt: CoreRuntime<u32> = CoreRuntime::new(EvictionBudget::new(usize::MAX, 0, 50));
        let (a, _) = rt.open(1, 10, 0);
        let (_b, _) = rt.open(2, 10, 5); // admission at t=5: a idle 5 (<50), kept
        let b = DocId(2);
        rt.get(b, 95); // touch b → last_touched 95
        let evicted = rt.enforce(100); // a idle 100 (>50) reaped; b idle 5 kept
        assert_eq!(evicted, vec![a]);
        assert!(rt.get(a, 110).is_none());
        assert!(rt.get(b, 110).is_some());
    }

    #[test]
    fn stats_flags_over_budget_when_pinned_exceed() {
        let rt: CoreRuntime<u32> = CoreRuntime::new(EvictionBudget::new(150, 0, 0));
        let (a, _) = rt.open(1, 100, 1);
        rt.set_pinned(a, true);
        let (_b, e) = rt.open(2, 100, 2); // admission temp-pins b → both survive
        assert!(e.is_empty());
        let s = rt.stats(3);
        assert_eq!(s.doc_count, 2);
        assert_eq!(s.total_bytes, 200);
        assert!(s.over_budget, "pinned docs exceed budget → over_budget flag");
    }

    // --- Property test (TSK-585 lane): eviction_plan invariants --------------
    use proptest::prelude::*;

    fn docs_strategy() -> impl Strategy<Value = Vec<DocMeta>> {
        proptest::collection::vec((0usize..2000, 0u64..100, any::<bool>()), 0..10)
            .prop_map(|specs| {
                specs
                    .into_iter()
                    .enumerate()
                    .map(|(i, (estimated_bytes, last_touched_ms, pinned))| DocMeta {
                        id: DocId(u64::try_from(i).unwrap_or(0)),
                        estimated_bytes,
                        last_touched_ms,
                        pinned,
                    })
                    .collect()
            })
    }

    proptest! {
        /// eviction_plan: pinned docs are NEVER evicted; victims are distinct
        /// resident DocIds; after eviction the set is within byte+count budget
        /// UNLESS only pinned docs remain; and (ttl>0) no expired unpinned doc
        /// survives the reaper. The core memory-eviction correctness contract.
        #[test]
        fn eviction_plan_respects_budget_and_pins(
            docs in docs_strategy(),
            max_bytes in 0usize..5000,
            max_count in 0usize..12,
            ttl_ms in 0u64..50,
            now_ms in 50u64..150,
        ) {
            let budget = EvictionBudget::new(max_bytes, max_count, ttl_ms);
            let plan = eviction_plan(&docs, &budget, now_ms);
            let victims: HashSet<DocId> = plan.iter().copied().collect();

            prop_assert_eq!(victims.len(), plan.len(), "victims must be distinct");
            let all_ids: HashSet<DocId> = docs.iter().map(|d| d.id).collect();
            for v in &plan {
                prop_assert!(all_ids.contains(v), "victim is not a resident doc");
            }
            for d in &docs {
                if d.pinned {
                    prop_assert!(!victims.contains(&d.id), "a pinned doc was evicted");
                }
            }

            let remaining: Vec<&DocMeta> =
                docs.iter().filter(|d| !victims.contains(&d.id)).collect();
            let rem_bytes: usize = remaining.iter().map(|d| d.estimated_bytes).sum();
            if rem_bytes > max_bytes {
                prop_assert!(remaining.iter().all(|d| d.pinned),
                    "over byte budget but unpinned docs remain to evict");
            }
            if max_count > 0 && remaining.len() > max_count {
                prop_assert!(remaining.iter().all(|d| d.pinned),
                    "over count budget but unpinned docs remain to evict");
            }
            if ttl_ms > 0 {
                for d in &remaining {
                    if !d.pinned {
                        let idle = now_ms.saturating_sub(d.last_touched_ms);
                        prop_assert!(idle <= ttl_ms, "an expired unpinned doc escaped the reaper");
                    }
                }
            }
        }
    }
}
