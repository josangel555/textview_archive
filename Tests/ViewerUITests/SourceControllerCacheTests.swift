import XCTest
@testable import ViewerUI

/// TSK-889 warm-reopen view-preservation LRU. The cache state machine is pure
/// main-actor host logic — these tests drive it with a fake controller (no
/// AppKit / `NSTextStorage`) and pin the EXACT teardown contract the fix
/// depends on:
///   - reuse (`acquire`) NEVER tears down (the whole point of preservation),
///   - `teardownStorage()` fires EXACTLY on count/byte eviction + `purge`,
///   - a plain deactivation (controller still resident) does NOT tear down,
///   - LRU recency: `acquire` promotes, so the freshly-used tab is never the
///     eviction victim,
///   - the byte budget evicts so N huge files can't blow the cap,
///   - the flag is default-OFF (disabled cache reuses nothing, tears down on
///     dismantle exactly as before).
@MainActor
final class SourceControllerCacheTests: XCTestCase {

    /// Lightweight stand-in for `SourceTextController` — records teardown calls
    /// and reports a configurable retained-byte count for budget eviction.
    private final class FakeController: PreservableSourceController {
        var bytes: Int
        private(set) var teardownCount = 0
        init(bytes: Int = 0) { self.bytes = bytes }
        var retainedByteCount: Int { bytes }
        func teardownStorage() { teardownCount += 1 }
    }

    private func enabledCache(maxCount: Int = 4, maxBytes: Int = .max) -> SourceControllerCache {
        SourceControllerCache(isEnabled: true, maxCount: maxCount, maxBytes: maxBytes)
    }

    // MARK: - Insert / reuse

    func testStoreThenAcquireReusesSameInstanceNoTeardown() {
        let cache = enabledCache()
        let id = UUID()
        let c = FakeController()
        cache.store(tabID: id, controller: c)

        let got = cache.acquire(tabID: id)
        XCTAssertTrue(got === c, "acquire must return the preserved instance")
        XCTAssertEqual(c.teardownCount, 0, "reuse must NOT tear down")
        XCTAssertEqual(cache.count, 1)
    }

    func testAcquireMissReturnsNil() {
        let cache = enabledCache()
        XCTAssertNil(cache.acquire(tabID: UUID()), "no entry → nil so caller makes fresh")
    }

    func testStoreSameTabIDSameInstanceIsIdempotentNoTeardown() {
        let cache = enabledCache()
        let id = UUID()
        let c = FakeController()
        cache.store(tabID: id, controller: c)
        cache.store(tabID: id, controller: c)   // same instance, refresh recency
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(c.teardownCount, 0, "re-storing the same instance must not tear it down")
    }

    func testStoreSameTabIDDifferentInstanceTearsDownOld() {
        let cache = enabledCache()
        let id = UUID()
        let old = FakeController()
        let new = FakeController()
        cache.store(tabID: id, controller: old)
        cache.store(tabID: id, controller: new)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(old.teardownCount, 1, "replacing a tab's controller logically closes the old one")
        XCTAssertEqual(new.teardownCount, 0)
        XCTAssertTrue(cache.acquire(tabID: id) === new)
    }

    // MARK: - LRU eviction (count cap)

    func testCountCapEvictsLRUTailWithTeardown() {
        let cache = enabledCache(maxCount: 2)
        let ids = (0..<3).map { _ in UUID() }
        let cs = ids.map { _ in FakeController() }
        cache.store(tabID: ids[0], controller: cs[0])
        cache.store(tabID: ids[1], controller: cs[1])
        cache.store(tabID: ids[2], controller: cs[2])   // overflows → evict ids[0]

        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cs[0].teardownCount, 1, "LRU tail (oldest) must be evicted + torn down")
        XCTAssertEqual(cs[1].teardownCount, 0)
        XCTAssertEqual(cs[2].teardownCount, 0)
        XCTAssertNil(cache.acquire(tabID: ids[0]), "evicted tab is gone")
        XCTAssertEqual(cache.residentTabIDs, [ids[1], ids[2]])
    }

    func testAcquirePromotesSoLRUVictimIsTheTrulyOldest() {
        let cache = enabledCache(maxCount: 2)
        let a = UUID(), b = UUID(), c = UUID()
        let ca = FakeController(), cb = FakeController(), cc = FakeController()
        cache.store(tabID: a, controller: ca)
        cache.store(tabID: b, controller: cb)
        // Touch `a` via acquire → a becomes MRU, b becomes LRU.
        _ = cache.acquire(tabID: a)
        cache.store(tabID: c, controller: cc)   // overflow → evict b (now LRU), NOT a

        XCTAssertEqual(cb.teardownCount, 1, "b was promoted past by acquiring a → b is the LRU victim")
        XCTAssertEqual(ca.teardownCount, 0, "a was re-used recently → must survive")
        XCTAssertEqual(Set(cache.residentTabIDs), [a, c])
    }

    func testTouchPromotesRecency() {
        let cache = enabledCache(maxCount: 2)
        let a = UUID(), b = UUID(), c = UUID()
        let ca = FakeController(), cb = FakeController(), cc = FakeController()
        cache.store(tabID: a, controller: ca)
        cache.store(tabID: b, controller: cb)
        cache.touch(tabID: a)                   // a → MRU
        cache.store(tabID: c, controller: cc)   // evict b
        XCTAssertEqual(cb.teardownCount, 1)
        XCTAssertEqual(ca.teardownCount, 0)
    }

    // MARK: - Byte-budget eviction

    func testByteBudgetEvictsUntilWithinCap() {
        // maxBytes 100; three 40-byte files: storing the 3rd (total 120) evicts
        // the LRU tail (40) → total 80 ≤ 100. Count cap is generous (huge).
        let cache = enabledCache(maxCount: 99, maxBytes: 100)
        let a = UUID(), b = UUID(), c = UUID()
        let ca = FakeController(bytes: 40), cb = FakeController(bytes: 40), cc = FakeController(bytes: 40)
        cache.store(tabID: a, controller: ca)
        cache.store(tabID: b, controller: cb)
        cache.store(tabID: c, controller: cc)

        XCTAssertEqual(ca.teardownCount, 1, "oldest evicted to fit the byte budget")
        XCTAssertLessThanOrEqual(cache.totalRetainedBytes, 100)
        XCTAssertEqual(Set(cache.residentTabIDs), [b, c])
    }

    func testHugeFilesDoNotBlowByteBudget_NEvictedToOneWithinCount() {
        // Four 50 MiB files, count cap 4 (would all fit by count) but a 64 MiB
        // byte budget: only the MRU survives — huge files can't pin > budget.
        let mib = 1024 * 1024
        let cache = enabledCache(maxCount: 4, maxBytes: 64 * mib)
        var controllers: [FakeController] = []
        var ids: [UUID] = []
        for _ in 0..<4 {
            let id = UUID()
            let c = FakeController(bytes: 50 * mib)
            ids.append(id); controllers.append(c)
            cache.store(tabID: id, controller: c)
        }
        XCTAssertLessThanOrEqual(cache.totalRetainedBytes, 64 * mib,
                                 "byte budget must bound total retained bytes regardless of count cap")
        XCTAssertEqual(cache.count, 1, "only the MRU 50 MiB file fits under 64 MiB")
        XCTAssertEqual(cache.residentTabIDs, [ids[3]])
        // The three older ones were each torn down on eviction.
        XCTAssertEqual(controllers[0].teardownCount, 1)
        XCTAssertEqual(controllers[1].teardownCount, 1)
        XCTAssertEqual(controllers[2].teardownCount, 1)
        XCTAssertEqual(controllers[3].teardownCount, 0)
    }

    func testSingleEntryExceedingBudgetIsKept() {
        // A lone file bigger than the budget must NOT be torn down (we never
        // evict the only / just-activated tab to satisfy the byte budget).
        let cache = enabledCache(maxCount: 4, maxBytes: 10)
        let id = UUID()
        let c = FakeController(bytes: 1000)
        cache.store(tabID: id, controller: c)
        XCTAssertEqual(c.teardownCount, 0, "the sole entry is never byte-evicted out from under itself")
        XCTAssertEqual(cache.count, 1)
    }

    // MARK: - Purge on close / deactivate distinction

    func testPurgeOnCloseTearsDownAndRemoves() {
        let cache = enabledCache()
        let id = UUID()
        let c = FakeController()
        cache.store(tabID: id, controller: c)
        cache.purge(tabID: id)
        XCTAssertEqual(c.teardownCount, 1, "real close must tear down exactly once")
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.acquire(tabID: id))
    }

    func testPurgeAbsentTabIsNoOp() {
        let cache = enabledCache()
        cache.purge(tabID: UUID())   // never stored
        XCTAssertEqual(cache.count, 0)
    }

    func testResidentTabIsNotTornDownOnDeactivation() {
        // The dismantle decision: a resident controller is merely deactivated,
        // so it must report resident=true → caller skips teardown. `isResident`
        // never tears down; the entry survives for reuse.
        let cache = enabledCache()
        let id = UUID()
        let c = FakeController()
        cache.store(tabID: id, controller: c)
        XCTAssertTrue(cache.isResident(tabID: id), "deactivated-but-preserved tab is resident")
        XCTAssertEqual(c.teardownCount, 0, "checking residency must not tear down")
        XCTAssertTrue(cache.acquire(tabID: id) === c, "still reusable after the residency check")
    }

    func testPurgeAllTearsDownEveryEntry() {
        let cache = enabledCache()
        let cs = (0..<3).map { _ -> FakeController in
            let c = FakeController()
            cache.store(tabID: UUID(), controller: c)
            return c
        }
        cache.purgeAll()
        XCTAssertEqual(cache.count, 0)
        for c in cs { XCTAssertEqual(c.teardownCount, 1) }
    }

    // MARK: - Default-OFF flag

    func testDisabledCacheNeverStoresOrReuses() {
        let cache = SourceControllerCache(isEnabled: false)
        let id = UUID()
        let c = FakeController()
        cache.store(tabID: id, controller: c)
        XCTAssertEqual(cache.count, 0, "disabled cache stores nothing")
        XCTAssertNil(cache.acquire(tabID: id), "disabled cache reuses nothing")
        XCTAssertFalse(cache.isResident(tabID: id), "disabled → never resident → dismantle always tears down")
        XCTAssertEqual(c.teardownCount, 0, "disabled store is a pure no-op (controller stays SwiftUI-owned)")
    }

    func testFlagDefaultsOffWhenEnvAbsent() {
        XCTAssertFalse(SourceControllerCache.readFlag(environment: [:]),
                       "MDV_PRESERVE_RECENT_SOURCE_VIEWS defaults OFF")
    }

    func testFlagEnabledByEnv() {
        XCTAssertTrue(SourceControllerCache.readFlag(environment: ["MDV_PRESERVE_RECENT_SOURCE_VIEWS": "1"]))
        XCTAssertTrue(SourceControllerCache.readFlag(environment: ["MDV_PRESERVE_RECENT_SOURCE_VIEWS": "true"]))
        XCTAssertFalse(SourceControllerCache.readFlag(environment: ["MDV_PRESERVE_RECENT_SOURCE_VIEWS": "0"]))
        XCTAssertFalse(SourceControllerCache.readFlag(environment: ["MDV_PRESERVE_RECENT_SOURCE_VIEWS": "yes"]))
    }

    // MARK: - Teardown call-count invariant (the false-green killer)

    func testTeardownFiresExactlyOnceAcrossFullLifecycle() {
        // store → acquire (reuse, no teardown) → evict by count (1 teardown) →
        // re-store survivor → purge (1 teardown). Each controller tears down at
        // most once, only on eviction/purge, never on reuse/residency-check.
        let cache = enabledCache(maxCount: 1)
        let a = UUID(), b = UUID()
        let ca = FakeController(), cb = FakeController()

        cache.store(tabID: a, controller: ca)
        XCTAssertTrue(cache.acquire(tabID: a) === ca)
        XCTAssertEqual(ca.teardownCount, 0)

        cache.store(tabID: b, controller: cb)    // maxCount 1 → evict a
        XCTAssertEqual(ca.teardownCount, 1, "a evicted exactly once")
        XCTAssertEqual(cb.teardownCount, 0)

        _ = cache.isResident(tabID: b)
        XCTAssertEqual(cb.teardownCount, 0, "residency check never tears down")

        cache.purge(tabID: b)
        XCTAssertEqual(cb.teardownCount, 1, "b torn down exactly once on close")
        XCTAssertEqual(ca.teardownCount, 1, "a stays at one — no double teardown")
    }
}
