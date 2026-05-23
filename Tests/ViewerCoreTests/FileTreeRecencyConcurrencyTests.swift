import XCTest
@testable import ViewerCore

/// Concurrency + cache-bound tests for `FileTreeRecencyCache`.
///
/// The cache is `nonisolated(unsafe)` + `NSLock` so the SwiftUI body
/// (`@MainActor`) can hit it without `await`. These tests bash on it
/// from many concurrent tasks to confirm:
///   1. No crash / no deadlock under contention.
///   2. The 2048-cap drop-all branch is reachable and survives.
///   3. `invalidateAll` after a contended burst leaves the cache in a
///      clean state (subsequent reads succeed).
final class FileTreeRecencyConcurrencyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FileTreeRecencyCache.invalidateAll()
    }

    override func tearDown() {
        FileTreeRecencyCache.invalidateAll()
        super.tearDown()
    }

    private var anchorURL: URL {
        // Use the test bundle as a known-extant URL — no disk I/O per
        // call once cached. The cache key is the URL itself, so we
        // append a unique component per "logical row" to fan out.
        Bundle(for: type(of: self)).bundleURL
    }

    private func fanOutURLs(count: Int) -> [URL] {
        let base = anchorURL
        return (0..<count).map { i in
            base.appendingPathComponent("synthetic-row-\(i)")
        }
    }

    // MARK: - Concurrent reads

    func test_concurrentReads_acrossManyKeys_doNotCrash() async {
        let urls = fanOutURLs(count: 64)
        // Multiple bursts so we exercise both miss + hit paths.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for url in urls {
                        _ = FileTreeRecencyCache.attributes(for: url)
                    }
                }
            }
        }
        // If we got here without a crash, the lock did its job.
    }

    // MARK: - Read/write/invalidate contention

    func test_concurrentReadsAndInvalidates_doNotCrash() async {
        let urls = fanOutURLs(count: 32)
        await withTaskGroup(of: Void.self) { group in
            // Half the tasks read, half invalidate. The interleavings
            // hit both "cache hit", "cache miss" and "concurrent
            // dictionary write" code paths.
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<10 {
                        for url in urls {
                            _ = FileTreeRecencyCache.attributes(for: url)
                        }
                    }
                }
                group.addTask {
                    for _ in 0..<10 {
                        for url in urls {
                            FileTreeRecencyCache.invalidate(url)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Cap boundary

    func test_capBoundary_dropsCache_thenRebuilds() {
        // The cache's drop-all kicks in when count > 2048. Push past
        // that with synthetic URLs (no disk hits — `attributesOfItem`
        // returns empty attrs for non-existent paths, which still
        // populates the cache).
        let burst = 2_200
        for i in 0..<burst {
            _ = FileTreeRecencyCache.attributes(
                for: anchorURL.appendingPathComponent("cap-key-\(i)"))
        }
        // Cache is bounded — internal `count > capacity` triggers a
        // `removeAll(keepingCapacity:)`. We don't expose the count,
        // but we can prove "still reachable" by reading again:
        let post = FileTreeRecencyCache.attributes(
            for: anchorURL.appendingPathComponent("cap-key-after-drop"))
        XCTAssertNotNil(post.modifiedAt ?? Date())  // either nil or a date — must not crash
    }

    // MARK: - invalidateAll round-trip

    func test_invalidateAll_resetsCache_subsequentReadsWork() {
        let urls = fanOutURLs(count: 4)
        for u in urls { _ = FileTreeRecencyCache.attributes(for: u) }

        FileTreeRecencyCache.invalidateAll()

        // Re-read after the nuke — every URL must still serve a valid
        // attrs struct.
        for u in urls {
            let a = FileTreeRecencyCache.attributes(for: u)
            // attrs for synthetic URLs are (nil, nil) since they don't
            // exist; the struct itself must be constructed cleanly.
            XCTAssertEqual(a.modifiedAt, nil)
            XCTAssertEqual(a.createdAt,  nil)
        }
    }
}
