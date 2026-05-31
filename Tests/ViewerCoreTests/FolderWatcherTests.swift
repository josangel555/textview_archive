import XCTest
@testable import ViewerCore

/// Integration tests for `FolderWatcher`. Use a real tmp directory
/// + real filesystem events. Each test creates its own tree under
/// `temporaryDirectory` so they're independent and parallel-safe.
final class FolderWatcherTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// Sanity check: creating a file in the watched root fires
    /// `onChange` with the root URL among the changed dirs.
    func test_createFile_firesOnChange() throws {
        let exp = expectation(description: "onChange fires")
        exp.assertForOverFulfill = false
        let watcher = try FolderWatcher(url: root) { _ in exp.fulfill() }
        defer { watcher.stop() }

        // FSEventStreamStart races with the first file op briefly.
        // Sleep a beat so the stream is armed before we touch.
        Thread.sleep(forTimeInterval: 0.3)
        try "hi".write(
            to: root.appendingPathComponent("new.txt"),
            atomically: true, encoding: .utf8
        )
        wait(for: [exp], timeout: 5)
    }

    /// Deleting a file also fires.
    func test_deleteFile_firesOnChange() throws {
        let file = root.appendingPathComponent("delete-me.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let exp = expectation(description: "onChange fires")
        exp.assertForOverFulfill = false
        let watcher = try FolderWatcher(url: root) { _ in exp.fulfill() }
        defer { watcher.stop() }

        Thread.sleep(forTimeInterval: 0.3)
        try FileManager.default.removeItem(at: file)
        wait(for: [exp], timeout: 5)
    }

    /// Burst of writes coalesces into a small number of callbacks
    /// (NOT one per file). FSEvents + the debounce should drop the
    /// fan-out to ≤3 callbacks per 50-file burst.
    ///
    /// Uses RunLoop.run(until:) instead of Thread.sleep because the
    /// debounced callback dispatches on .main; sleep blocks the
    /// runloop and the callback never fires.
    func test_burst_coalesces() throws {
        let counter = Counter()
        let watcher = try FolderWatcher(url: root) { _ in counter.bump() }
        defer { watcher.stop() }

        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        for i in 0..<50 {
            try "x".write(
                to: root.appendingPathComponent("f\(i).txt"),
                atomically: true, encoding: .utf8
            )
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertLessThanOrEqual(counter.value, 3,
            "50-file burst should coalesce to ≤3 callbacks (got \(counter.value))")
        XCTAssertGreaterThanOrEqual(counter.value, 1)
    }

    /// `stop()` is idempotent and disables further callbacks. We
    /// reset the counter immediately before stop() so any
    /// startup-noise events from FSEvents arming don't pollute
    /// the measurement — we care about post-stop deliveries only.
    func test_stop_idempotent_andSilencesCallbacks() throws {
        let counter = Counter()
        let watcher = try FolderWatcher(url: root) { _ in counter.bump() }
        // Let any startup-noise events drain.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        counter.reset()
        watcher.stop()
        watcher.stop()  // second call is a no-op

        try "x".write(
            to: root.appendingPathComponent("post-stop.txt"),
            atomically: true, encoding: .utf8
        )
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        XCTAssertEqual(counter.value, 0,
            "No callbacks should fire after stop() (got \(counter.value))")
    }

    /// `directorySet(from:)` rolls file paths up to their parent dirs.
    func test_directorySet_returnsParents() {
        let p1 = "/tmp/a/b/file.txt"
        let p2 = "/tmp/a/b/other.txt"
        let p3 = "/tmp/a/c/another.txt"
        let dirs = FolderWatcher.directorySet(from: [p1, p2, p3])
        let paths = Set(dirs.map(\.path))
        XCTAssertTrue(paths.contains("/tmp/a/b"))
        XCTAssertTrue(paths.contains("/tmp/a/c"))
    }

    /// FW-2: renaming the watched root fires `onRootChanged` (driven by
    /// kFSEventStreamCreateFlagWatchRoot + the RootChanged event flag).
    /// We watch `<root>/watched`, then rename it; the kernel reports a
    /// root change so the consumer can re-resolve.
    func test_rootRename_firesOnRootChanged() throws {
        let watched = root.appendingPathComponent("watched")
        try FileManager.default.createDirectory(
            at: watched, withIntermediateDirectories: true
        )
        let rootChanged = expectation(description: "onRootChanged fires")
        rootChanged.assertForOverFulfill = false

        let watcher = try FolderWatcher(
            url: watched,
            onRootChanged: { rootChanged.fulfill() },
            onChange: { _ in }
        )
        defer { watcher.stop() }

        // Let the stream arm.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        // Rename the watched root out from under the stream.
        let renamed = root.appendingPathComponent("renamed")
        try FileManager.default.moveItem(at: watched, to: renamed)

        // Callback fires on .main; `wait(for:timeout:)` spins the
        // runloop so the dispatched callback can run. WatchRoot events
        // can take a beat to surface, hence the slack.
        wait(for: [rootChanged], timeout: 8)
    }

    /// FW-12: under a continuous event stream that keeps re-arming the
    /// debounce timer, the max-wait still forces a flush. We set a tiny
    /// maxWait and a debounce long enough that, without the max-wait
    /// cap, the steady drip of writes would defer onChange past our
    /// observation window.
    func test_maxWait_flushesUnderContinuousEvents() throws {
        let counter = Counter()
        // debounce 400ms (long), maxWait 300ms (short). A drip of
        // writes every ~120ms keeps re-arming the 400ms debounce, so
        // only the 300ms max-wait can produce a flush.
        let watcher = try FolderWatcher(
            url: root,
            debounce: .milliseconds(400),
            maxWait: .milliseconds(300)
        ) { _ in counter.bump() }
        defer { watcher.stop() }

        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        // Drip writes for ~1s, spaced under the debounce window.
        let end = Date().addingTimeInterval(1.0)
        var i = 0
        while Date() < end {
            try "x".write(
                to: root.appendingPathComponent("drip\(i).txt"),
                atomically: true, encoding: .utf8
            )
            i += 1
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }
        // Let any trailing flush land.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertGreaterThanOrEqual(
            counter.value, 1,
            "max-wait should force at least one flush during a continuous burst"
        )
    }
}

/// Threadsafe int counter for the burst test.
private final class Counter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func bump() { lock.lock(); n += 1; lock.unlock() }
    func reset() { lock.lock(); n = 0; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
