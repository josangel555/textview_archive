import XCTest
@testable import ViewerCore

/// TSK-591 (candidate 3) — teeth for the bounded cache that replaces the
/// wipe-on-overflow sidebar caches. The load-bearing test is
/// `test_overflow_isBoundedEviction_notWipe`: a full wipe would drop the count
/// to near zero and lose mid-recent keys, so it goes RED if eviction reverts to
/// `removeAll`.
final class InsertionOrderedCacheTests: XCTestCase {

    func test_insertAndGet() {
        var c = InsertionOrderedCache<Int, String>(cap: 4)
        c.insert("a", forKey: 1)
        XCTAssertEqual(c[1], "a")
        XCTAssertNil(c[2])
        XCTAssertEqual(c.count, 1)
    }

    func test_overflow_isBoundedEviction_notWipe() {
        var c = InsertionOrderedCache<Int, Int>(cap: 10)   // target 6
        for k in 0..<15 { c.insert(k, forKey: k) }
        XCTAssertLessThanOrEqual(c.count, 10, "never exceeds cap")
        XCTAssertGreaterThanOrEqual(c.count, 6,
            "shrinks to ~target on overflow, never a full wipe (a wipe drops near 0)")
        XCTAssertEqual(c[14], 14, "newest survives")
        XCTAssertEqual(c[5], 5, "a mid-recent key survives (a wipe would have dropped it)")
        XCTAssertNil(c[0], "oldest evicted")
    }

    func test_insert_returnsTrueOnlyOnOverflow() {
        var c = InsertionOrderedCache<Int, Int>(cap: 3)
        XCTAssertFalse(c.insert(0, forKey: 0))
        XCTAssertFalse(c.insert(1, forKey: 1))
        XCTAssertFalse(c.insert(2, forKey: 2), "at cap, no eviction yet")
        XCTAssertTrue(c.insert(3, forKey: 3), "past cap → eviction batch ran")
    }

    func test_updateExistingKey_doesNotGrow() {
        var c = InsertionOrderedCache<Int, Int>(cap: 4)
        c.insert(1, forKey: 0)
        c.insert(2, forKey: 0)
        XCTAssertEqual(c.count, 1, "updating a key is not a new entry")
        XCTAssertEqual(c[0], 2)
    }

    func test_remove_targeted() {
        var c = InsertionOrderedCache<Int, Int>(cap: 4)
        c.insert(9, forKey: 1)
        c.insert(8, forKey: 2)
        c.remove(1)
        XCTAssertNil(c[1])
        XCTAssertEqual(c[2], 8, "other keys untouched")
        XCTAssertEqual(c.count, 1)
        c.remove(99)   // absent → no-op, no crash
        XCTAssertEqual(c.count, 1)
    }

    func test_removeAll() {
        var c = InsertionOrderedCache<Int, Int>(cap: 4)
        c.insert(1, forKey: 1)
        c.insert(2, forKey: 2)
        c.removeAll()
        XCTAssertEqual(c.count, 0)
        XCTAssertNil(c[1])
    }

    func test_evictedKeyCanBeReinserted() {
        var c = InsertionOrderedCache<Int, Int>(cap: 10)
        for k in 0..<15 { c.insert(k, forKey: k) }
        XCTAssertNil(c[0], "evicted")
        c.insert(100, forKey: 0)
        XCTAssertEqual(c[0], 100, "re-insert after eviction works (order stays consistent)")
    }
}
