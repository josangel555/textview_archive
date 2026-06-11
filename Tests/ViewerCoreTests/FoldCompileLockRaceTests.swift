import XCTest
@testable import ViewerCore

/// TSK-151 — the fold-path per-language compile serialization, pinned
/// deterministically.
///
/// THE RACE: `foldBundle(for:)` runs the expensive `Data` + `Query`
/// compile on first touch. Without the per-language lock + post-acquire
/// re-check, two concurrent first-touchers for the same language (two
/// JSON tabs whose detached fold computations land together) BOTH run
/// the compile and race to overwrite `foldBundles[lang]`. The
/// `foldCompileWindowHook` seam fires inside the compile window (lock
/// held, re-check missed), making the interleaving deterministic: with
/// the lock, the second toucher blocks and then hits the re-check —
/// exactly one compile. Strip the lock or the re-check and the second
/// toucher enters the window too — `foldCompileCount` reads 2.
final class FoldCompileLockRaceTests: XCTestCase {

    /// Multi-line JSON with an object + array — guaranteed non-empty
    /// fold regions, so the assertions can't pass vacuously.
    private let json = "{\n  \"a\": [\n    1,\n    2\n  ],\n  \"b\": {\n    \"c\": 3\n  }\n}\n"

    override func setUp() {
        super.setUp()
        TreeSitterEngine.foldCompileCount = 0
    }

    override func tearDown() {
        TreeSitterEngine.foldCompileWindowHook = nil
        TreeSitterEngine.foldCompileCount = 0
        super.tearDown()
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func set(_ key: String, _ n: Int) { lock.lock(); counts[key] = n; lock.unlock() }
        func get(_ key: String) -> Int? { lock.lock(); defer { lock.unlock() }; return counts[key] }
    }

    func test_concurrentFirstTouch_compilesExactlyOnce() {
        // Fresh engine = guaranteed-cold foldBundles (instance storage).
        let engine = TreeSitterEngine()
        let firstInWindow = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        // Only the FIRST window entry blocks — in the mutated (lockless)
        // build the second toucher must sail through and be counted.
        let gate = NSLock()
        var seenFirst = false
        TreeSitterEngine.foldCompileWindowHook = { _ in
            gate.lock()
            let mine = !seenFirst
            seenFirst = true
            gate.unlock()
            if mine {
                firstInWindow.signal()
                release.wait()
            }
        }

        let results = Box()
        let expA = expectation(description: "toucher A finished")
        let expB = expectation(description: "toucher B finished")

        Thread.detachNewThread { [json] in
            results.set("a", engine.computeFoldsSync(text: json, language: .json).count)
            expA.fulfill()
        }
        // A is now inside the compile window, holding the per-language lock.
        XCTAssertEqual(firstInWindow.wait(timeout: .now() + 10), .success,
                       "toucher A never reached the compile window")

        Thread.detachNewThread { [json] in
            results.set("b", engine.computeFoldsSync(text: json, language: .json).count)
            expB.fulfill()
        }
        // Give B time to reach the per-language lock (fixed build) or the
        // compile window (broken build) before letting A finish. With the
        // lock, ordering is guaranteed regardless of this sleep — A stores
        // the bundle before releasing, so B's re-check always hits.
        Thread.sleep(forTimeInterval: 0.3)
        release.signal()

        wait(for: [expA, expB], timeout: 15)

        XCTAssertEqual(TreeSitterEngine.foldCompileCount, 1,
            "concurrent same-language first-touch ran \(TreeSitterEngine.foldCompileCount) "
            + "compiles — the per-language lock / post-acquire re-check is broken")
        XCTAssertEqual(results.get("a"), results.get("b"),
                       "both touchers must see the same fold regions")
        XCTAssertGreaterThan(results.get("a") ?? 0, 0,
                             "fixture must produce real fold regions")
    }

    /// Control: sequential second touch reuses the cached bundle — pins
    /// the memoization itself (and proves the counter counts compiles,
    /// not calls).
    func test_sequentialSecondTouch_hitsCache() {
        let engine = TreeSitterEngine()
        let r1 = engine.computeFoldsSync(text: json, language: .json)
        XCTAssertFalse(r1.isEmpty, "fixture must produce fold regions")
        XCTAssertEqual(TreeSitterEngine.foldCompileCount, 1)

        let r2 = engine.computeFoldsSync(text: json, language: .json)
        XCTAssertEqual(r2.count, r1.count)
        XCTAssertEqual(TreeSitterEngine.foldCompileCount, 1,
                       "second touch recompiled — bundle memoization broken")
    }
}
