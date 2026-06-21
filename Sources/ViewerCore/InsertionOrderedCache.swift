import Foundation

/// A bounded key→value cache with insertion-ordered **batch eviction**. When it
/// grows past `cap`, it drops the OLDEST entries down to ~2/3 `cap` in a single
/// batch — never a full wipe.
///
/// This replaces the wipe-on-overflow policy (`removeAll` at the cap) that
/// thrashed caches whose working key set exceeds the cap: every overflow cleared
/// ALL entries, so the very next lookups degraded to cold misses (TSK-591
/// candidate 3 — the sidebar norm / repo-icon caches on trees with > cap
/// distinct row URLs, where each mouse-move re-eval re-stat'd from scratch).
/// Bounded + survivor-preserving keeps the hot recent set resident.
///
/// Eviction is FIFO by first-insert (no per-access reordering) — cheap, and
/// enough for the churn-bounded sidebar caches; updating an existing key keeps
/// its original position. `remove` / `removeAll` support targeted and full
/// invalidation (e.g. an FSEvents `.git` flip invalidating one dir vs all).
public struct InsertionOrderedCache<Key: Hashable, Value> {

    private var map: [Key: Value]
    /// Live keys in first-insert order, oldest first; exactly one entry per key.
    private var order: [Key] = []

    public let cap: Int
    /// Size the cache shrinks to on an overflow eviction batch.
    public let target: Int

    public init(cap: Int) {
        precondition(cap > 0, "cache cap must be positive")
        self.cap = cap
        self.target = Swift.max(1, cap * 2 / 3)
        self.map = Dictionary(minimumCapacity: cap)
        self.order.reserveCapacity(cap)
    }

    public var count: Int { map.count }

    public subscript(_ key: Key) -> Value? { map[key] }

    /// Insert or update `key`. On overflow, evicts the oldest entries down to
    /// `target` in one batch. Returns `true` iff an eviction batch ran.
    @discardableResult
    public mutating func insert(_ value: Value, forKey key: Key) -> Bool {
        if map[key] == nil { order.append(key) }
        map[key] = value
        guard map.count > cap else { return false }
        var evicted = 0
        while map.count > target && evicted < order.count {
            map.removeValue(forKey: order[evicted])
            evicted += 1
        }
        order.removeFirst(evicted)
        return true
    }

    /// Remove a single key (targeted invalidation). No-op if absent.
    public mutating func remove(_ key: Key) {
        guard map.removeValue(forKey: key) != nil else { return }
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
    }

    /// Drop every entry (full invalidation), keeping the allocated capacity.
    public mutating func removeAll() {
        map.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }
}
