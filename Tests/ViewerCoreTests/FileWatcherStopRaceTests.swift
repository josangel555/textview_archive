import XCTest
@testable import ViewerCore

/// TSK-147 — the FW-S3 stop-races-reattach guard, pinned deterministically.
///
/// THE RACE: `attach()` opens the fd and resumes a fresh DispatchSource;
/// if `stop()` lands before attach takes the commit lock, the stopped
/// watcher must NOT store the fresh source — storing it leaks the source
/// + fd forever (nothing will ever cancel them). The guard re-checks
/// `_stopped` under the commit lock and cancels the fresh source instead.
/// The `attachWindowHook` seam fires INSIDE that window, making the race
/// a deterministic interleaving rather than a stress loop.
final class FileWatcherStopRaceTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FWStopRace-\(UUID().uuidString).txt")
        try "seed\n".write(to: tmp, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        FileWatcher.attachWindowHook = nil
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    private func openFDCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    func test_stopInsideAttachWindow_cancelsFreshSource_noFdLeak_noFires() throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func bump() { lock.lock(); n += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let baseline = openFDCount()
        let fires = Counter()

        FileWatcher.attachWindowHook = { watcher in
            // stop() lands exactly between resume() and the commit lock.
            watcher.stop()
        }
        let q = DispatchQueue(label: "fw-stop-race")
        let watcher = try FileWatcher(url: tmp, queue: q, debounce: 0) {
            fires.bump()
        }
        FileWatcher.attachWindowHook = nil

        XCTAssertTrue(watcher.isStopped,
            "stop() inside the window must leave the watcher stopped")

        // The guard cancels the fresh source; its cancel handler (async on
        // the watcher queue) closes the fd. Poll back to baseline — a
        // stored-but-orphaned source keeps the fd open forever (the leak).
        let deadline = Date().addingTimeInterval(3)
        while openFDCount() > baseline, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertLessThanOrEqual(openFDCount(), baseline,
            "fd not released — the fresh source leaked into the stopped watcher")

        // And the orphaned source must never drive the handler.
        try "changed\n".write(to: tmp, atomically: false, encoding: .utf8)
        q.sync {}  // drain any pending event delivery
        Thread.sleep(forTimeInterval: 0.1)
        q.sync {}
        XCTAssertEqual(fires.value, 0,
            "a watcher stopped mid-attach must never fire its handler")
    }

    /// Control: without the mid-window stop, the same construction attaches
    /// normally and fires on change — proves the seam itself doesn't break
    /// the happy path (and that this fixture genuinely produces events).
    func test_control_normalAttachStillFires() throws {
        let exp = expectation(description: "fired")
        exp.assertForOverFulfill = false
        let q = DispatchQueue(label: "fw-stop-race-control")
        let watcher = try FileWatcher(url: tmp, queue: q, debounce: 0) {
            exp.fulfill()
        }
        defer { watcher.stop() }
        try "changed\n".write(to: tmp, atomically: false, encoding: .utf8)
        wait(for: [exp], timeout: 3)
    }
}
