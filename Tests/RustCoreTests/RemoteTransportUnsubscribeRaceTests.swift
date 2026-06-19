#if DEBUG
import XCTest
import Foundation
@testable import RustCore

/// TSK-976 — pure-logic guard that `RemoteTransport` honors the
/// "no events after unsubscribe" contract, with NO socket and NO `mdv-serve`.
///
/// The bug (pre-fix): `route`'s event arm copied the handler out under the
/// `state` lock, RELEASED the lock, then called it OUTSIDE the lock. The
/// reader's local copy of the closure survived `unsubscribe` nilling
/// `subs[sub]`, so the handler could fire AFTER `unsubscribe` (and any
/// teardown of state the closure captured) had returned.
///
/// The fix: events are delivered on a per-transport SERIAL queue;
/// `unsubscribe` nils the handler under the lock then drains the queue with a
/// `sync` barrier; each delivery re-checks `subs[sub]` under the lock before
/// firing. So (a) no handler runs after unsubscribe returns, and (b) an event
/// the reader enqueued before the nil-out is dropped rather than delivered to
/// a torn-down handler.
///
/// These tests drive the state machine through the `#if DEBUG` socket-less
/// seam (`_testRegister` / `_testRoute` / `_testDropHandler` /
/// `_testDrainDelivery`). They exercise the EXACT production paths
/// (`subscribe`'s registration tail, `route`, `dropHandler`/`deliver`), not a
/// parallel reimplementation.
final class RemoteTransportUnsubscribeRaceTests: XCTestCase {

    /// Thread-safe counter (handlers run on the delivery queue).
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// Thread-safe ordered collector of observed seqs.
    private final class SeqLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seqs: [UInt64] = []
        func append(_ s: UInt64) { lock.lock(); seqs.append(s); lock.unlock() }
        var snapshot: [UInt64] { lock.lock(); defer { lock.unlock() }; return seqs }
    }

    private func event(sub: UInt64, seq: UInt64) -> RemoteEvent {
        RemoteEvent(sub: sub, seq: seq, kind: "created", body: [])
    }

    /// The headline contract: deliver one event, unsubscribe, deliver a second
    /// for the SAME sub id — the handler must NOT fire the second time.
    func test_noDelivery_afterUnsubscribe() {
        let t = RemoteTransport(testSocketlessCapabilities: 0)
        let count = Counter()
        let sub: UInt64 = 7

        t._testRegister(sub) { _ in count.bump() }
        t._testRoute(event(sub: sub, seq: 1))
        t._testDrainDelivery()
        XCTAssertEqual(count.value, 1, "the live event must be delivered once")

        t._testDropHandler(sub)
        t._testRoute(event(sub: sub, seq: 2))   // post-unsubscribe event
        t._testDrainDelivery()
        XCTAssertEqual(count.value, 1,
                       "no handler invocation may happen after unsubscribe")
    }

    /// A stale in-flight event for a sub id that was unsubscribed and then
    /// RE-USED (server reissues the same id to a new handler) must reach the
    /// NEW handler — never the dropped one. Guards the re-check oracle.
    func test_reusedSubId_routesToNewHandler_notOld() {
        let t = RemoteTransport(testSocketlessCapabilities: 0)
        let old = Counter()
        let new = Counter()
        let sub: UInt64 = 42

        t._testRegister(sub) { _ in old.bump() }
        t._testDropHandler(sub)
        // Same id handed to a fresh handler (a re-subscribe on a reused id).
        t._testRegister(sub) { _ in new.bump() }
        t._testRoute(event(sub: sub, seq: 1))
        t._testDrainDelivery()

        XCTAssertEqual(old.value, 0, "the unsubscribed handler must never fire")
        XCTAssertEqual(new.value, 1, "the re-subscribed handler must receive it")
    }

    /// Deterministic race: park the FIRST delivery inside the handler (gated on
    /// a semaphore), enqueue a SECOND event behind it, then call
    /// `dropHandler` from another thread — its `sync` barrier must block until
    /// the parked handler finishes, and the second (post-nil-out) event must be
    /// dropped by the live re-check. Asserts the handler fired exactly once and
    /// that `dropHandler` did not return until delivery drained.
    func test_dropHandler_barrier_blocksInflight_andDropsLaterEvent() {
        let t = RemoteTransport(testSocketlessCapabilities: 0)
        let count = Counter()
        let sub: UInt64 = 3

        let handlerEntered = DispatchSemaphore(value: 0)
        let releaseHandler = DispatchSemaphore(value: 0)
        let handlerFinished = Counter()
        // One-shot park: ONLY the first invocation blocks. A buggy SECOND
        // delivery (which the fix must drop) then fails the count assertion
        // cleanly instead of deadlocking on a second `releaseHandler.wait()`.
        let parked = Counter()

        t._testRegister(sub) { _ in
            if parked.value == 0 {
                parked.bump()
                handlerEntered.signal()   // tell the test we're inside
                releaseHandler.wait()     // park until the test lets us go
            }
            count.bump()
            handlerFinished.bump()
        }

        // First event: the delivery block dequeues and parks inside the handler.
        t._testRoute(event(sub: sub, seq: 1))
        XCTAssertEqual(handlerEntered.wait(timeout: .now() + 5), .success,
                       "the first delivery must reach the handler")

        // Second event enqueued behind the parked one (still subscribed).
        t._testRoute(event(sub: sub, seq: 2))

        // dropHandler on a background thread: it nils the sub, then BLOCKS on
        // the barrier behind the parked handler + the second delivery block.
        let dropReturned = DispatchSemaphore(value: 0)
        let dropOrdering = Counter()      // 0 while blocked, becomes 1 on return
        DispatchQueue.global().async {
            t._testDropHandler(sub)
            dropOrdering.bump()
            dropReturned.signal()
        }

        // Give the background dropHandler a moment to nil the sub and block on
        // the barrier. It must NOT have returned yet — the handler is parked.
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(dropOrdering.value, 0,
                       "dropHandler must not return while a delivery is in flight")
        XCTAssertEqual(count.value, 0, "the parked handler hasn't completed yet")

        // Release the parked handler; the barrier should now drain and return.
        releaseHandler.signal()
        XCTAssertEqual(dropReturned.wait(timeout: .now() + 5), .success,
                       "dropHandler's barrier must drain and return")

        // The first (in-flight) event ran exactly once; the second, routed
        // before the nil-out but dequeued AFTER it, was dropped by the
        // under-lock re-check in deliver().
        XCTAssertEqual(handlerFinished.value, 1,
                       "the in-flight handler ran exactly once")
        XCTAssertEqual(count.value, 1,
                       "the second (post-nil-out) event must be dropped, not delivered")

        // And nothing fires after dropHandler returned.
        t._testRoute(event(sub: sub, seq: 3))
        t._testDrainDelivery()
        XCTAssertEqual(count.value, 1, "no delivery after unsubscribe returned")
    }

    /// Pre-registration orphan events (the buffered race the reader sees
    /// before `subscribe` registers) must flush to the handler in order — and
    /// a dropHandler before registration must purge them so they never fire.
    func test_orphanFlush_deliversBufferedEvents_inOrder() {
        let t = RemoteTransport(testSocketlessCapabilities: 0)
        let log = SeqLog()
        let sub: UInt64 = 9

        // Two events arrive before any handler is registered → buffered.
        t._testRoute(event(sub: sub, seq: 1))
        t._testRoute(event(sub: sub, seq: 2))

        t._testRegister(sub) { e in log.append(e.seq) }
        t._testDrainDelivery()

        XCTAssertEqual(log.snapshot, [1, 2], "buffered events flush in arrival order")
    }

    func test_orphanFlush_purgedByDropHandler_neverFires() {
        let t = RemoteTransport(testSocketlessCapabilities: 0)
        let count = Counter()
        let sub: UInt64 = 11

        t._testRoute(event(sub: sub, seq: 1))   // buffered orphan
        t._testDropHandler(sub)                 // purges orphanEvents[sub]
        t._testRegister(sub) { _ in count.bump() }
        t._testDrainDelivery()

        XCTAssertEqual(count.value, 0,
                       "an orphan purged by dropHandler must not flush to a later handler")
    }
}
#endif
