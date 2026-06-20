import XCTest
@testable import ViewerUI

/// TSK-991 — teeth for the children-cache eviction decision. The bug: when the
/// PINNED working set (root + expanded dirs, which can't be evicted without
/// collapsing the visible tree) exceeds the cap, the old prune re-walked the
/// whole LRU list on every store and evicted nothing new — the cap "couldn't be
/// enforced." The fix floors both the trigger and the target at `pinned.count`:
/// every cold entry is still evicted, but no thrash on an impossible target.
final class SidebarChildrenCacheEvictionTests: XCTestCase {

    private func urls(_ prefix: String, _ n: Int) -> [URL] {
        (0..<n).map { URL(fileURLWithPath: "/\(prefix)/\($0)") }
    }

    func test_underCap_evictsNothing() {
        let order = urls("d", 100)
        XCTAssertTrue(SidebarModel.childrenCacheEvictions(
            order: order, pinned: [], count: 100, max: 256).isEmpty)
    }

    func test_normalCase_evictsColdDownToTwoThirds() {
        // 257 entries, a few pinned among the cold prefix, cap 256.
        let order = urls("d", 257)
        let pinned = Set(order.prefix(10))
        let evict = SidebarModel.childrenCacheEvictions(
            order: order, pinned: pinned, count: 257, max: 256)
        XCTAssertEqual(257 - evict.count, 256 * 2 / 3,
                       "normal case: evict cold down to the 2/3 target (170)")
        XCTAssertTrue(evict.allSatisfy { !pinned.contains($0) }, "never evict pinned")
    }

    func test_pinnedExceedsCap_evictsOnlyCold_noThrash() {
        // THE bug case: 300 pinned + 20 cold = 320, cap 256. Can't go below the
        // pinned working set → evict exactly the 20 cold, retain all pinned.
        let cold = urls("c", 20)
        let pinned = urls("p", 300)
        let order = cold + pinned          // cold are the oldest
        let evict = SidebarModel.childrenCacheEvictions(
            order: order, pinned: Set(pinned), count: 320, max: 256)
        XCTAssertEqual(Set(evict), Set(cold),
                       "evict exactly the cold entries; every pinned dir retained")
    }

    func test_allPinnedAtCap_evictsNothing_noImpossibleTarget() {
        // count == pinned, no cold → nothing evictable; must NOT loop/thrash.
        let pinned = urls("p", 300)
        let evict = SidebarModel.childrenCacheEvictions(
            order: pinned, pinned: Set(pinned), count: 300, max: 256)
        XCTAssertTrue(evict.isEmpty,
                      "all-pinned at/over cap → evict nothing (no impossible-target thrash)")
    }
}
