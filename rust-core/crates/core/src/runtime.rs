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

use std::collections::HashSet;

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
}
