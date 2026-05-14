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

        let watcher = try FileWatcher(url: url, queue: .global()) {
            let n = counter.tick()
            if n == 1 { exp.fulfill() }
            else if n >= 2 { exp2.fulfill() }
        }
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.1)
        // Atomic write — replaces inode via rename.
        try "v2".write(to: url, atomically: true, encoding: .utf8)
        wait(for: [exp], timeout: 2.0)

        // Give the watcher time to re-attach (≈50 ms by design), then edit.
        Thread.sleep(forTimeInterval: 0.2)
        let fh = try FileHandle(forWritingTo: url)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(" more".utf8))
        try fh.close()

        wait(for: [exp2], timeout: 2.0)
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
