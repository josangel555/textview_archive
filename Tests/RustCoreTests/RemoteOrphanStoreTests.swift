import XCTest
@testable import RustCore

/// TSK-987 — the pre-registration orphan buffer (`RemoteTransport.OrphanStore`)
/// must be GLOBALLY bounded against a buggy/compromised `mdv-serve` that
/// streams events for monotonically-increasing, never-subscribed sub ids.
///
/// Pure-logic host test: drives the store directly with synthetic
/// `RemoteEvent`s — no socket, no spawned server (the orphan arm of
/// `RemoteTransport.route` is exactly `store.buffer(_:)`). On the UNFIXED
/// per-list-only cap the distinct-key count grew to K (one entry per attacker
/// sub id); these assertions pin the three independent ceilings + prove the
/// legitimate orphan-bridge round-trip still delivers.
final class RemoteOrphanStoreTests: XCTestCase {

    private typealias Store = RemoteTransport.OrphanStore

    private func event(sub: UInt64, seq: UInt64 = 1, bodyBytes: Int = 4) -> RemoteEvent {
        RemoteEvent(sub: sub, seq: seq, kind: "created",
                    body: [UInt8](repeating: 0xAB, count: bodyBytes))
    }

    /// The attack: K distinct never-subscribed sub ids, K >> keyCap. The dict
    /// must NEVER exceed the key cap. On unfixed code it grew to K (red).
    func test_distinctNeverSubscribedKeys_areCappedAtKeyCap() {
        var store = Store()
        let k = Store.keyCap * 100  // 6400 >> 64
        for sub in 0..<UInt64(k) {
            store.buffer(event(sub: sub, bodyBytes: 8))
        }
        XCTAssertLessThanOrEqual(store.keyCount, Store.keyCap,
            "orphan dict must never exceed keyCap; grew to \(store.keyCount) of attempted \(k)")
        XCTAssertLessThanOrEqual(store.totalBytes, Store.byteCap,
            "aggregate retained bytes must never exceed byteCap")
    }

    /// LRU/insertion-order eviction: once the key cap is full, a brand-new sub
    /// id evicts the OLDEST key — the most recent `keyCap` keys are retained.
    func test_newKeyPastCap_evictsOldestKey() {
        var store = Store()
        for sub in 0..<UInt64(Store.keyCap) {
            store.buffer(event(sub: sub, bodyBytes: 8))
        }
        XCTAssertEqual(store.keyCount, Store.keyCap)
        // Sub 0 is the oldest. Insert one more → it must be evicted.
        store.buffer(event(sub: 9999, bodyBytes: 8))
        XCTAssertEqual(store.keyCount, Store.keyCap, "still capped after the extra insert")
        XCTAssertTrue(store.take(0).isEmpty, "the oldest key (sub 0) must have been evicted")
        XCTAssertFalse(store.take(9999).isEmpty, "the newest key must be retained")
    }

    /// The byte budget bounds aggregate footprint independently of the key
    /// count: many big-body events on a single key are throttled.
    func test_byteBudget_boundsAggregateFootprint_singleKey() {
        var store = Store()
        let big = 1 * 1024 * 1024  // 1 MiB bodies; byteCap is 8 MiB
        var accepted = 0
        for seq in 0..<64 {
            if store.buffer(event(sub: 7, seq: UInt64(seq), bodyBytes: big)) { accepted += 1 }
        }
        XCTAssertLessThanOrEqual(store.totalBytes, Store.byteCap,
            "single-key big-body flood must not exceed the byte budget")
        XCTAssertLessThanOrEqual(accepted, Store.byteCap / big + 1,
            "no more bodies than the budget allows may be retained")
        XCTAssertGreaterThan(accepted, 0, "at least some bodies fit under the budget")
    }

    /// A single event larger than the whole byte budget is rejected outright
    /// — never retained, never used to evict the existing buffer.
    func test_oversizeSingleEvent_isRejected_withoutEvictingExisting() {
        var store = Store()
        XCTAssertTrue(store.buffer(event(sub: 1, bodyBytes: 16)), "small event accepted")
        let huge = Store.byteCap + 1
        XCTAssertFalse(store.buffer(event(sub: 2, bodyBytes: huge)),
            "an event larger than the whole budget must be dropped")
        XCTAssertFalse(store.take(1).isEmpty,
            "the oversize reject must NOT have evicted the legitimate small buffer")
        XCTAssertTrue(store.take(2).isEmpty, "the oversize event must not have been retained")
    }

    /// The pre-existing per-sub list cap still holds (no single sub buffers
    /// more than `listCap` events).
    func test_perListCap_stillHolds() {
        var store = Store()
        for seq in 0..<(Store.listCap + 50) {
            store.buffer(event(sub: 3, seq: UInt64(seq), bodyBytes: 1))
        }
        XCTAssertEqual(store.take(3).count, Store.listCap,
            "a single sub's buffer must not exceed listCap")
    }

    /// No-regression of the orphan-bridge feature: events buffered for a sub
    /// that LATER registers (the `subscribe()` flush path is `take(_:)`) are
    /// returned IN ORDER and the store is then empty for that key.
    func test_pendingSub_receivesBufferedEvents_inOrder_afterTake() {
        var store = Store()
        for seq in 1...5 {
            store.buffer(event(sub: 42, seq: UInt64(seq), bodyBytes: 4))
        }
        // A second, unrelated sub also buffered — taking 42 must not disturb it.
        store.buffer(event(sub: 7, seq: 1, bodyBytes: 4))

        let flushed = store.take(42)
        XCTAssertEqual(flushed.map(\.seq), [1, 2, 3, 4, 5],
            "buffered events must flush to the newly-registered handler in arrival order")
        XCTAssertTrue(store.take(42).isEmpty, "the key must be emptied after take")
        XCTAssertFalse(store.take(7).isEmpty, "an unrelated pending sub's buffer must survive")
        // Bytes accounting must stay consistent after takes.
        XCTAssertEqual(store.totalBytes, 0, "byte accounting must zero out once all keys are taken")
    }

    /// `drop` (unsubscribe) discards a buffer without delivering and keeps the
    /// byte accounting correct.
    func test_drop_discardsBuffer_andDecrementsBytes() {
        var store = Store()
        store.buffer(event(sub: 1, bodyBytes: 100))
        store.buffer(event(sub: 2, bodyBytes: 100))
        XCTAssertEqual(store.totalBytes, 200)
        store.drop(1)
        XCTAssertTrue(store.take(1).isEmpty, "dropped key must be gone")
        XCTAssertEqual(store.totalBytes, 100, "byte accounting must decrement on drop")
        XCTAssertEqual(store.keyCount, 1)
    }

    /// `removeAll` (reader teardown) clears every axis.
    func test_removeAll_clearsEverything() {
        var store = Store()
        for sub in 0..<UInt64(10) { store.buffer(event(sub: sub, bodyBytes: 8)) }
        store.removeAll()
        XCTAssertEqual(store.keyCount, 0)
        XCTAssertEqual(store.totalBytes, 0)
    }
}
