import XCTest
@testable import ViewerCore

/// Foundation-slice behavior tests for the multi-window session model
/// (TSK-265). Drives `MultiWindowRegistry` through its public API and pins:
///
///   - distinct window-id allocation,
///   - the one-window-per-session ownership lease (no double-binding),
///   - lease release on window-close (and the session becoming re-adoptable),
///   - a window switching which session it drives,
///   - per-session write serialization ordering (two windows can't reorder
///     snapshot writes against the same session id).
///
/// Pure logic — no UI, no disk. Runs on host.
@MainActor
final class MultiWindowRegistryTests: XCTestCase {

    // Lazy fixture per the Swift-6.1-vs-6.3 setUp-isolation divergence
    // (see SessionsCoordinatorTests for the rationale).
    private lazy var registry = MultiWindowRegistry()

    // MARK: Allocation -----------------------------------------------

    func testAllocateAssignsDistinctWindowIDs() {
        let a = registry.allocateWindow()
        let b = registry.allocateWindow()
        let c = registry.allocateWindow()
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(b, c)
        XCTAssertNotEqual(a, c)
        XCTAssertTrue(registry.isKnownWindow(a))
        XCTAssertTrue(registry.isKnownWindow(b))
        XCTAssertTrue(registry.isKnownWindow(c))
    }

    func testAllocatedButUnboundWindowDrivesNoSession() {
        let w = registry.allocateWindow()
        XCTAssertNil(registry.session(for: w))
        XCTAssertEqual(registry.boundWindowCount, 0)
    }

    // MARK: Binding + ownership lease --------------------------------

    func testBindTakesSessionLease() throws {
        let w = registry.allocateWindow()
        let s = UUID()
        let binding = try registry.bind(window: w, toSession: s)
        XCTAssertEqual(binding.windowID, w)
        XCTAssertEqual(binding.sessionID, s)
        XCTAssertEqual(registry.session(for: w), s)
        XCTAssertEqual(registry.window(forSession: s), w)
        XCTAssertTrue(registry.isSessionBound(s))
        XCTAssertEqual(registry.boundWindowCount, 1)
    }

    func testBindRejectsUnknownWindow() {
        let stranger = WindowID()        // never allocated by this registry
        let s = UUID()
        XCTAssertThrowsError(try registry.bind(window: stranger, toSession: s)) { err in
            XCTAssertEqual(err as? WindowBindError, .unknownWindow(stranger))
        }
        XCTAssertFalse(registry.isSessionBound(s))
    }

    func testDoubleBindingSameSessionToTwoWindowsIsRefused() throws {
        let w1 = registry.allocateWindow()
        let w2 = registry.allocateWindow()
        let s = UUID()
        try registry.bind(window: w1, toSession: s)

        XCTAssertThrowsError(try registry.bind(window: w2, toSession: s)) { err in
            XCTAssertEqual(
                err as? WindowBindError,
                .sessionAlreadyBound(sessionID: s, heldBy: w1)
            )
        }
        // w1 keeps the lease; w2 stays sessionless.
        XCTAssertEqual(registry.window(forSession: s), w1)
        XCTAssertNil(registry.session(for: w2))
        XCTAssertEqual(registry.boundWindowCount, 1)
    }

    func testRebindingSamePairIsIdempotentAndRefreshesTimestamp() throws {
        let w = registry.allocateWindow()
        let s = UUID()
        let first = try registry.bind(window: w, toSession: s,
                                      at: Date(timeIntervalSince1970: 1_000))
        let second = try registry.bind(window: w, toSession: s,
                                       at: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(second.sessionID, s)
        XCTAssertGreaterThan(second.boundAt, first.boundAt)
        XCTAssertEqual(registry.boundWindowCount, 1)
        XCTAssertEqual(registry.window(forSession: s), w)
    }

    func testWindowSwitchingSessionsReleasesOldLease() throws {
        let w = registry.allocateWindow()
        let s1 = UUID(), s2 = UUID()
        try registry.bind(window: w, toSession: s1)
        try registry.bind(window: w, toSession: s2)

        // The window now drives s2; s1's lease is freed and re-adoptable.
        XCTAssertEqual(registry.session(for: w), s2)
        XCTAssertFalse(registry.isSessionBound(s1))
        XCTAssertNil(registry.window(forSession: s1))
        XCTAssertEqual(registry.window(forSession: s2), w)
        XCTAssertEqual(registry.boundWindowCount, 1)

        // A second window may now adopt the freed s1.
        let w2 = registry.allocateWindow()
        XCTAssertNoThrow(try registry.bind(window: w2, toSession: s1))
        XCTAssertEqual(registry.window(forSession: s1), w2)
    }

    // MARK: Release on close -----------------------------------------

    func testReleaseWindowFreesSessionAndForgetsWindow() throws {
        let w = registry.allocateWindow()
        let s = UUID()
        try registry.bind(window: w, toSession: s)

        registry.releaseWindow(w)

        XCTAssertFalse(registry.isKnownWindow(w))
        XCTAssertNil(registry.session(for: w))
        XCTAssertFalse(registry.isSessionBound(s))
        XCTAssertEqual(registry.boundWindowCount, 0)

        // The freed session is re-bindable by a brand-new window.
        let w2 = registry.allocateWindow()
        XCTAssertNoThrow(try registry.bind(window: w2, toSession: s))
        XCTAssertEqual(registry.window(forSession: s), w2)
    }

    func testReleaseUnknownWindowIsNoOp() {
        // Releasing an id the registry never handed out must not crash or
        // disturb other state.
        let bound = registry.allocateWindow()
        let s = UUID()
        try? registry.bind(window: bound, toSession: s)

        registry.releaseWindow(WindowID())   // stranger

        XCTAssertTrue(registry.isKnownWindow(bound))
        XCTAssertEqual(registry.window(forSession: s), bound)
    }

    func testReleaseAfterRebindDoesNotStealNewOwnersLease() throws {
        // w1 holds s, then w1 switches to a different session and w2 adopts
        // s. A stale double-release of w1 must NOT clear w2's lease on s.
        let w1 = registry.allocateWindow()
        let w2 = registry.allocateWindow()
        let s = UUID(), other = UUID()
        try registry.bind(window: w1, toSession: s)
        try registry.bind(window: w1, toSession: other)   // w1 leaves s
        try registry.bind(window: w2, toSession: s)        // w2 adopts s

        registry.releaseWindow(w1)   // closing w1 must not touch s's lease

        XCTAssertEqual(registry.window(forSession: s), w2)
        XCTAssertTrue(registry.isSessionBound(s))
    }

    // MARK: Write serialization (clobber guard) ----------------------

    func testSerializeSaveOrdersConcurrentWritesForSameSession() {
        let s = UUID()
        var order: [Int] = []
        let seq1 = registry.serializeSave(sessionID: s) { order.append(1) }
        let seq2 = registry.serializeSave(sessionID: s) { order.append(2) }
        let seq3 = registry.serializeSave(sessionID: s) { order.append(3) }

        // Monotonic, gap-free sequence numbers prove a single FIFO ordering.
        XCTAssertEqual([seq1, seq2, seq3], [1, 2, 3])
        // Writes ran in claim order — no reorder/clobber.
        XCTAssertEqual(order, [1, 2, 3])
        XCTAssertEqual(registry.lastWriteSeq(for: s), 3)
    }

    func testSerializeSaveSequencesAreIndependentPerSession() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(registry.serializeSave(sessionID: a) {}, 1)
        XCTAssertEqual(registry.serializeSave(sessionID: b) {}, 1)
        XCTAssertEqual(registry.serializeSave(sessionID: a) {}, 2)
        XCTAssertEqual(registry.lastWriteSeq(for: a), 2)
        XCTAssertEqual(registry.lastWriteSeq(for: b), 1)
    }

    func testTwoWindowsSavingSameSessionDoNotClobber() throws {
        // Simulate two windows that (against the lease invariant) attempt to
        // write the same session id: the per-session FIFO still serializes
        // them in claim order, so index.json / <uuid>.json can't be torn.
        let s = UUID()
        let w1 = registry.allocateWindow()
        let w2 = registry.allocateWindow()
        try registry.bind(window: w1, toSession: s)

        var writes: [String] = []
        let seqA = registry.serializeSave(sessionID: s) { writes.append("w1-A") }
        let seqB = registry.serializeSave(sessionID: s) { writes.append("w2-B") }
        let seqC = registry.serializeSave(sessionID: s) { writes.append("w1-C") }

        XCTAssertEqual([seqA, seqB, seqC], [1, 2, 3])
        XCTAssertEqual(writes, ["w1-A", "w2-B", "w1-C"])
        // Lease is still w1's regardless of who issued saves.
        XCTAssertEqual(registry.window(forSession: s), w1)
        XCTAssertFalse(registry.isSessionBound(UUID()))
        _ = w2
    }

    // MARK: Value-type round-trips -----------------------------------

    func testWindowSessionBindingCodableRoundTrip() throws {
        let binding = WindowSessionBinding(
            windowID: WindowID(),
            sessionID: UUID(),
            boundAt: Date(timeIntervalSince1970: 12_345)
        )
        let data = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(WindowSessionBinding.self, from: data)
        XCTAssertEqual(binding, decoded)
    }
}
