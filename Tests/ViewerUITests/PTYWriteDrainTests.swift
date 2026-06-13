import XCTest
@testable import ViewerUI

/// TSK-741: PTYProcess.write used to run its blocking drain loop on the caller
/// (sendInput is @MainActor), so a large paste into a slow reader beachballed
/// the app. The drain now runs on a serial writeQueue; PTYProcess.drain is the
/// extracted, sink-injected loop — these pin its correctness (the off-main
/// dispatch + ANR relief is the structural change, VM/manual-confirmable).
@MainActor
final class PTYWriteDrainTests: XCTestCase {

    func test_drain_writesAllBytesInOrder_acrossPartialWrites() {
        let data = Data("hello world".utf8)
        var collected = [UInt8]()
        var calls = 0
        let written = PTYProcess.drain(data) { ptr, len in
            calls += 1
            let take = min(3, len)   // a sink that only accepts 3 bytes per call
            collected.append(contentsOf: UnsafeRawBufferPointer(start: ptr, count: take))
            return take
        }
        XCTAssertEqual(written, data.count)
        XCTAssertEqual(Data(collected), data, "all bytes drained, in order, despite partial writes")
        XCTAssertGreaterThan(calls, 1, "partial writes required multiple sink calls")
    }

    func test_drain_bailsOnHardError() {
        let data = Data("abcdef".utf8)
        var calls = 0
        let written = PTYProcess.drain(data) { _, _ in
            calls += 1
            errno = EIO          // a hard error (not EINTR/EAGAIN)
            return -1
        }
        XCTAssertEqual(written, 0, "a hard write error bails immediately")
        XCTAssertEqual(calls, 1)
    }

    func test_drain_retriesOnEINTR() {
        let data = Data("xy".utf8)
        var calls = 0
        let written = PTYProcess.drain(data) { ptr, len in
            calls += 1
            if calls == 1 { errno = EINTR; return -1 }   // interrupted once
            return len                                    // then accepts the rest
        }
        XCTAssertEqual(written, data.count, "EINTR is retried, not fatal")
        XCTAssertGreaterThanOrEqual(calls, 2)
    }

    func test_drain_emptyData_noSinkCalls() {
        var calls = 0
        let written = PTYProcess.drain(Data()) { _, _ in calls += 1; return 0 }
        XCTAssertEqual(written, 0)
        XCTAssertEqual(calls, 0, "nothing to drain → the sink is never called")
    }
}
