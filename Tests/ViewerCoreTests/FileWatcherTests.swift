import XCTest
@testable import ViewerCore

final class FileWatcherTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func test_throwsOnMissingFile() {
        let url = tmpDir.appendingPathComponent("nope.txt")
        XCTAssertThrowsError(
            try FileWatcher(url: url, queue: .global()) {}
        ) { error in
            XCTAssertEqual(error as? FileWatcherError, .cannotOpen)
        }
    }

    func test_writeFiresHandler() throws {
        let url = tmpDir.appendingPathComponent("watch.txt")
        try "initial".write(to: url, atomically: false, encoding: .utf8)

        let exp = expectation(description: "watcher fires")
        exp.assertForOverFulfill = false

        let watcher = try FileWatcher(url: url, queue: .global()) {
            exp.fulfill()
        }
        defer { watcher.stop() }

        // Brief wait to let the source register, then a non-atomic append
        // (atomic writes trigger via rename — also covered below).
        Thread.sleep(forTimeInterval: 0.1)
        let fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(" more".utf8))
        try fh.close()

        wait(for: [exp], timeout: 2.0)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func tick() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
        func read() -> Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    func test_atomicWrite_thenSubsequentEdit_bothFire() throws {
        let url = tmpDir.appendingPathComponent("atomic.txt")
        try "v1".write(to: url, atomically: false, encoding: .utf8)

        let exp = expectation(description: "first event")
        let exp2 = expectation(description: "second event after re-attach")
        let counter = Counter()

        // T3: reattachDelay=0 makes the test deterministic — we wait on
        // expectations rather than guessing at the 50ms internal delay.
        let watcher = try FileWatcher(url: url, queue: .global(), reattachDelay: 0) {
            let n = counter.tick()
            if n == 1 { exp.fulfill() }
            else if n >= 2 { exp2.fulfill() }
        }
        defer { watcher.stop() }

        // Atomic write — replaces inode via rename.
        try "v2".write(to: url, atomically: true, encoding: .utf8)
        wait(for: [exp], timeout: 2.0)

        // After the watcher has reattached (no fixed wait — we just expect it
        // to be ready by the time we issue the next write). Spin briefly to
        // give the queue a chance to run reattach.
        let reattachExpectation = expectation(description: "give queue a tick")
        DispatchQueue.global().async { reattachExpectation.fulfill() }
        wait(for: [reattachExpectation], timeout: 1.0)

        let fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(" more".utf8))
        try fh.close()

        wait(for: [exp2], timeout: 2.0)
    }

    // B1/B2: deleting the watched file without re-creating it should
    // eventually exhaust reattach attempts and call onLost.
    func test_deletedFile_eventuallyCallsOnLost() throws {
        let url = tmpDir.appendingPathComponent("gone.txt")
        try "x".write(to: url, atomically: false, encoding: .utf8)

        let lost = expectation(description: "onLost fires after max attempts")
        let watcher = try FileWatcher(
            url: url,
            queue: .global(),
            reattachDelay: 0.005,    // fast backoff for tests
            maxReattachAttempts: 3,
            onLost: { lost.fulfill() },
            handler: {}
        )
        defer { watcher.stop() }

        // Brief wait so the source is fully attached, then delete the file.
        Thread.sleep(forTimeInterval: 0.05)
        try FileManager.default.removeItem(at: url)

        wait(for: [lost], timeout: 2.0)
        XCTAssertTrue(watcher.isStopped, "watcher should mark itself stopped after giving up")
    }

    // After a delete + recreate, the watcher reattaches successfully and
    // future writes still fire.
    func test_deletedThenRecreated_watcherReattaches() throws {
        let url = tmpDir.appendingPathComponent("recreate.txt")
        try "v1".write(to: url, atomically: false, encoding: .utf8)

        let counter = Counter()
        let firstEvent = expectation(description: "delete event")
        let secondEvent = expectation(description: "post-recreate write event")

        let watcher = try FileWatcher(
            url: url,
            queue: .global(),
            reattachDelay: 0.01,
            maxReattachAttempts: 20,
            handler: {
                let n = counter.tick()
                if n == 1 { firstEvent.fulfill() }
                else if n >= 2 { secondEvent.fulfill() }
            }
        )
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.05)
        try FileManager.default.removeItem(at: url)
        wait(for: [firstEvent], timeout: 2.0)

        // Recreate before retries exhaust. The watcher reattaches and the
        // next write should fire normally.
        try "v2".write(to: url, atomically: false, encoding: .utf8)
        Thread.sleep(forTimeInterval: 0.05)  // let reattach succeed
        let fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(" more".utf8))
        try fh.close()
        wait(for: [secondEvent], timeout: 2.0)
        XCTAssertFalse(watcher.isStopped)
    }

    func test_stop_preventsFurtherFires() throws {
        let url = tmpDir.appendingPathComponent("stop.txt")
        try "initial".write(to: url, atomically: false, encoding: .utf8)

        let firstExpectation = expectation(description: "first event")
        let stoppedFlag = Flag()
        let firedAfterStop = Flag()

        let watcher = try FileWatcher(url: url, queue: .global()) {
            if stoppedFlag.get() { firedAfterStop.set(true) }
            firstExpectation.fulfill()
        }
        firstExpectation.assertForOverFulfill = false

        Thread.sleep(forTimeInterval: 0.1)
        let fh = try FileHandle(forWritingTo: url)
        try fh.write(contentsOf: Data("a".utf8))
        try fh.close()
        wait(for: [firstExpectation], timeout: 2.0)

        stoppedFlag.set(true)
        watcher.stop()

        let fh2 = try FileHandle(forWritingTo: url)
        try fh2.write(contentsOf: Data("b".utf8))
        try fh2.close()
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertFalse(firedAfterStop.get(), "handler should not fire after stop()")
    }
}
