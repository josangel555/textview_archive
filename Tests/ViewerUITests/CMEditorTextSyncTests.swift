import XCTest
@testable import ViewerUI

/// O-6 flush-before-read — host semantics of the synchronous flush seam:
/// the bounded ack wait, the ack bus, and the headless no-op guarantee
/// (no live editor ⇒ immediate return, so every host suite that exercises
/// close/save/switch paths stays fast and window-free).
@MainActor
final class CMEditorTextSyncTests: XCTestCase {

    func test_waitForAck_alreadyAcked_returnsTrueWithoutPumping() {
        var pumps = 0
        let ok = CMEditorTextSync.waitForAck(
            nonce: 7, timeout: 1.0,
            isAcked: { _ in true },
            pump: { pumps += 1 })
        XCTAssertTrue(ok)
        XCTAssertEqual(pumps, 0, "an already-current mirror must not spin")
    }

    func test_waitForAck_ackArrivesWhilePumping_returnsTrue() {
        var pumps = 0
        let ok = CMEditorTextSync.waitForAck(
            nonce: 7, timeout: 1.0,
            isAcked: { _ in pumps >= 3 },
            pump: { pumps += 1 })
        XCTAssertTrue(ok)
        XCTAssertEqual(pumps, 3, "returns as soon as the ack lands")
    }

    func test_waitForAck_neverAcked_timesOutBounded() {
        // FAKE clock (the sleep ratchet: no real waiting in the suite) —
        // each pump advances time 10ms; the 50ms budget must cut the loop
        // off after ~5 pumps, never hang.
        var fakeNow = Date(timeIntervalSinceReferenceDate: 0)
        var pumps = 0
        let ok = CMEditorTextSync.waitForAck(
            nonce: 7, timeout: 0.05,
            isAcked: { _ in false },
            pump: { pumps += 1; fakeNow.addTimeInterval(0.010) },
            now: { fakeNow })
        XCTAssertFalse(ok, "a dead page must not hang the caller")
        XCTAssertLessThanOrEqual(pumps, 6, "the wait is BOUNDED by the deadline")
    }

    func test_ackBus_roundTrip_andPruneOnMint() {
        let bus = CMFlushAckBus.shared
        let a = bus.nextNonce()
        XCTAssertFalse(bus.isReceived(a))
        bus.received(a)
        XCTAssertTrue(bus.isReceived(a))
        // Minting the next nonce prunes stale acks (no unbounded growth,
        // and a late ack for a dead waiter can't satisfy a future one).
        let b = bus.nextNonce()
        XCTAssertFalse(bus.isReceived(a))
        XCTAssertFalse(bus.isReceived(b))
        XCTAssertNotEqual(a, b, "nonces are unique per mint")
    }

    func test_flushPendingEdits_headless_isAnImmediateNoOp() {
        // No registered editor WebView in a host test process ⇒ nothing can
        // be pending ⇒ true, instantly. This is the guarantee that lets the
        // flush sit at the TOP of close/save/switch paths without making
        // any host suite slow or window-bound.
        let started = Date()
        XCTAssertTrue(CMEditorTextSync.flushPendingEdits())
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.05)
    }
}
