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
    //
    // Crash-detection is the primary signal these tests offer — the
    // cache is `nonisolated(unsafe)` + `NSLock`, so any race
    // surfaces as a malloc fault under TSan. But "no crash" is a
    // weak assertion on its own; the predicates below also confirm
    // every concurrent reader observed a coherent, well-formed
    // `FileTreeRecencyAttributes` value (rather than a partially-
    // initialized struct or a thread-local snapshot).

    func test_concurrentReads_acrossManyKeys_returnCoherentAttrs() async {
        let urls = fanOutURLs(count: 64)
        // Each task accumulates its observed attrs into an array.
        // After the join we assert every task saw the same number of
        // entries (no dropped reads) and that within a single task
        // every entry is well-formed (synthetic URLs → both fields nil).
        let readers = 8
        let collected: [[FileTreeRecencyAttributes]] = await withTaskGroup(
            of: [FileTreeRecencyAttributes].self
        ) { group in
            for _ in 0..<readers {
                group.addTask {
                    var local: [FileTreeRecencyAttributes] = []
                    local.reserveCapacity(urls.count)
                    for url in urls {
                        local.append(FileTreeRecencyCache.attributes(for: url))
                    }
                    return local
                }
            }
            var out: [[FileTreeRecencyAttributes]] = []
            for await arr in group { out.append(arr) }
            return out
        }
        XCTAssertEqual(collected.count, readers,
            "every reader task should have returned a result")
        for batch in collected {
            XCTAssertEqual(batch.count, urls.count,
                "no reader should have dropped a key")
            // Synthetic URLs don't exist; FileManager returns empty
            // attrs → both fields nil. A torn read would surface as a
            // non-nil garbage Date.
            for a in batch {
                XCTAssertNil(a.modifiedAt)
                XCTAssertNil(a.createdAt)
            }
        }
    }

    // MARK: - Read/write/invalidate contention

    func test_concurrentReadsAndInvalidates_returnCoherentAttrs() async {
        let urls = fanOutURLs(count: 32)
        // Same shape, but with half the tasks invalidating concurrently.
        // We can't predict per-key hit/miss interleaving, but every
        // returned value must still be coherent.
        let readers = 4
        let collected: [Int] = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<readers {
                group.addTask {
                    var coherentCount = 0
                    for _ in 0..<10 {
                        for url in urls {
                            let a = FileTreeRecencyCache.attributes(for: url)
                            // Both fields must be nil for a synthetic
                            // path; any non-nil indicates torn state.
                            if a.modifiedAt == nil && a.createdAt == nil {
                                coherentCount += 1
                            }
                        }
                    }
                    return coherentCount
                }
                group.addTask {
                    for _ in 0..<10 {
                        for url in urls {
                            FileTreeRecencyCache.invalidate(url)
                        }
                    }
                    return -1 // sentinel — invalidate tasks don't count
                }
            }
            var out: [Int] = []
            for await v in group { if v >= 0 { out.append(v) } }
            return out
        }
        XCTAssertEqual(collected.count, readers,
            "every reader task should have returned a count")
        for c in collected {
            XCTAssertEqual(c, urls.count * 10,
                "every read observed by a reader must be coherent under contention")
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
        // `removeAll(keepingCapacity:)`. Prove "still reachable + still
        // well-formed" by reading both a never-before-seen key and one
        // of the original burst keys.
        let fresh = FileTreeRecencyCache.attributes(
            for: anchorURL.appendingPathComponent("cap-key-after-drop"))
        XCTAssertNil(fresh.modifiedAt,
            "synthetic URL must produce nil modifiedAt; non-nil = torn read")
        XCTAssertNil(fresh.createdAt,
            "synthetic URL must produce nil createdAt; non-nil = torn read")
        let repeated = FileTreeRecencyCache.attributes(
            for: anchorURL.appendingPathComponent("cap-key-0"))
        XCTAssertNil(repeated.modifiedAt)
        XCTAssertNil(repeated.createdAt)
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
