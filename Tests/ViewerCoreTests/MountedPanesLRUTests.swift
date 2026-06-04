import XCTest
@testable import ViewerCore

/// Headless coverage for `MountedPanesLRU` — the perf Fix#1 retention set. The
/// eviction ordering is the correctness-critical part the live view turn relies
/// on, so it's pinned here before any UI wiring.
final class MountedPanesLRUTests: XCTestCase {

    private func ids(_ n: Int) -> [UUID] { (0..<n).map { _ in UUID() } }

    func test_capacity_clampedToAtLeastOne() {
        XCTAssertEqual(MountedPanesLRU(capacity: 0).capacity, 1)
        XCTAssertEqual(MountedPanesLRU(capacity: -5).capacity, 1)
        XCTAssertEqual(MountedPanesLRU(capacity: 4).capacity, 4)
    }

    func test_activate_single() {
        var lru = MountedPanesLRU(capacity: 4)
        let a = UUID()
        XCTAssertEqual(lru.activate(a), [], "first activate evicts nothing")
        XCTAssertEqual(lru.ids, [a])
        XCTAssertTrue(lru.contains(a))
    }

    func test_fillToCapacity_noEvict_mruOrder() {
        var lru = MountedPanesLRU(capacity: 4)
        let x = ids(4)
        for id in x { XCTAssertEqual(lru.activate(id), []) }
        // Activated 0,1,2,3 → MRU-first is 3,2,1,0.
        XCTAssertEqual(lru.ids, [x[3], x[2], x[1], x[0]])
    }

    func test_overflow_evictsLeastRecentlyActive() {
        var lru = MountedPanesLRU(capacity: 4)
        let x = ids(5)
        for id in x.prefix(4) { lru.activate(id) }       // [3,2,1,0]
        let evicted = lru.activate(x[4])                 // overflow
        XCTAssertEqual(evicted, [x[0]], "oldest (x0) is evicted")
        XCTAssertEqual(lru.ids, [x[4], x[3], x[2], x[1]])
    }

    func test_reactivate_present_movesToFront_noEvict_noDup() {
        var lru = MountedPanesLRU(capacity: 4)
        let x = ids(4)
        for id in x { lru.activate(id) }                 // [3,2,1,0]
        let evicted = lru.activate(x[0])                 // re-touch the oldest
        XCTAssertEqual(evicted, [], "re-activating a mounted id never evicts")
        XCTAssertEqual(lru.ids, [x[0], x[3], x[2], x[1]])
        XCTAssertEqual(lru.count, 4, "no duplicate")
    }

    func test_lru_notFifo_touchingOldestSpared() {
        // Prove it's LRU, not FIFO: touch the oldest right before overflow → a
        // DIFFERENT id is evicted than FIFO would drop.
        var lru = MountedPanesLRU(capacity: 4)
        let x = ids(5)
        for id in x.prefix(4) { lru.activate(id) }       // [3,2,1,0]
        lru.activate(x[0])                               // [0,3,2,1] — x0 now MRU
        let evicted = lru.activate(x[4])                 // overflow
        XCTAssertEqual(evicted, [x[1]], "x1 is now LRU (not x0, which FIFO would drop)")
        XCTAssertEqual(lru.ids, [x[4], x[0], x[3], x[2]])
    }

    func test_activeAlwaysRetained_evenAtCapacityOne() {
        var lru = MountedPanesLRU(capacity: 1)
        let a = UUID(), b = UUID()
        lru.activate(a)
        let evicted = lru.activate(b)
        XCTAssertEqual(evicted, [a], "cap 1: previous active evicted")
        XCTAssertEqual(lru.ids, [b], "the just-activated tab is always retained")
    }

    func test_remove_present_and_absent() {
        var lru = MountedPanesLRU(capacity: 4)
        let x = ids(3)
        for id in x { lru.activate(id) }                 // [2,1,0]
        XCTAssertTrue(lru.remove(x[1]))
        XCTAssertEqual(lru.ids, [x[2], x[0]], "closed tab dropped, order preserved")
        XCTAssertFalse(lru.remove(UUID()), "removing an absent id is a no-op")
    }

    func test_retainOnly_prunesClosed_preservesOrder() {
        var lru = MountedPanesLRU(capacity: 6)
        let x = ids(4)
        for id in x { lru.activate(id) }                 // [3,2,1,0]
        let dropped = lru.retainOnly(Set([x[0], x[2]]))
        XCTAssertEqual(Set(dropped), Set([x[1], x[3]]))
        XCTAssertEqual(lru.ids, [x[2], x[0]], "survivors keep MRU order")
    }

    func test_trim_collapsesToOne_andRegrows() {
        var lru = MountedPanesLRU(capacity: 4)
        let x = ids(4)
        for id in x { lru.activate(id) }                 // [3,2,1,0]
        let evicted = lru.trim(to: 1)                    // memory pressure
        XCTAssertEqual(evicted, [x[2], x[1], x[0]])
        XCTAssertEqual(lru.ids, [x[3]], "only the active pane survives")
        // Pressure passes → activating grows back toward capacity.
        let n = UUID()
        XCTAssertEqual(lru.activate(n), [])
        XCTAssertEqual(lru.ids, [n, x[3]])
    }

    func test_trim_clampedToAtLeastOne() {
        var lru = MountedPanesLRU(capacity: 4)
        let x = ids(3)
        for id in x { lru.activate(id) }
        let evicted = lru.trim(to: 0)                    // clamp → keep 1
        XCTAssertEqual(lru.ids.count, 1)
        XCTAssertEqual(lru.ids, [x[2]])
        XCTAssertEqual(Set(evicted), Set([x[0], x[1]]))
    }

    func test_equatable_sendable_value() {
        var a = MountedPanesLRU(capacity: 3)
        var b = MountedPanesLRU(capacity: 3)
        let id = UUID()
        a.activate(id); b.activate(id)
        XCTAssertEqual(a, b, "same capacity + same order ⇒ equal")
    }
}
