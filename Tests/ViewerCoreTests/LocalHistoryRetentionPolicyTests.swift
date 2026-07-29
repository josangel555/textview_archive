import Foundation
import XCTest
@testable import ViewerCore

/// Owner instruction (2026-07-29): *"I don't want it to be cleared, unless say
/// 100MB or so for that file. even then evict old, or do some compaction."*
///
/// Pins the retention CONTRACT so a future tidy-up can't quietly reintroduce
/// age-based expiry or shrink the budget: history is bounded ONLY by a
/// per-file byte budget, evicted oldest-first, newest always retained.
final class LocalHistoryRetentionPolicyTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LHRetention-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func test_perFileBudgetIs100MiB() {
        XCTAssertEqual(LocalHistoryStore.maxFileHistoryBytes, 100 * 1024 * 1024,
                       "owner-set per-file history budget")
    }

    /// AGE alone must never delete a version. A decade-old version stays as
    /// long as the file is under budget.
    func test_ageNeverEvicts_onlyTheByteBudgetDoes() throws {
        let store = LocalHistoryStore(directory: dir, isEnabled: { true })
        let path = dir.appendingPathComponent("doc.md").path
        let ancient = Date(timeIntervalSince1970: 0)          // 1970
        _ = store.capture(path: path, content: "ancient\n", at: ancient)
        for i in 1...5 {
            _ = store.capture(path: path, content: "v\(i)\n",
                              at: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        let all = store.versions(for: path)
        XCTAssertEqual(all.count, 6, "nothing expires by age")
        let restored = all.compactMap { store.contentString(of: $0, for: path) }
        XCTAssertTrue(restored.contains("ancient\n"),
                      "a 1970 version must still be recoverable")
    }

    // MARK: thinning (owner: "We don't want to lose the oldest ones")

    /// The original draft and the newest state are never thinning candidates.
    func test_thinning_neverPicksTheFirstOrLastVersion() {
        let evenly: [Int64] = [0, 10, 20, 30, 40]
        let victim = try? XCTUnwrap(LocalHistoryStore.thinningVictimIndex(millis: evenly))
        XCTAssertNotNil(victim)
        XCTAssertNotEqual(victim, 0, "the oldest version must survive")
        XCTAssertNotEqual(victim, evenly.count - 1, "the newest must survive")
    }

    /// A burst of rapid saves is thinned before anything from long ago — the
    /// whole point of not evicting oldest-first.
    func test_thinning_dropsFromTheDensestStretch_notTheOldest() {
        // Three versions spread over months, then five within one minute.
        let millis: [Int64] = [0, 2_600_000_000, 5_200_000_000,
                               9_000_000_000, 9_000_010_000, 9_000_020_000,
                               9_000_030_000, 9_000_040_000]
        let victim = LocalHistoryStore.thinningVictimIndex(millis: millis)
        XCTAssertNotNil(victim)
        XCTAssertGreaterThanOrEqual(victim!, 4,
            "must thin the dense recent burst, not the widely-spaced old versions")
    }

    func test_thinning_needsAnInteriorVersion() {
        XCTAssertNil(LocalHistoryStore.thinningVictimIndex(millis: []))
        XCTAssertNil(LocalHistoryStore.thinningVictimIndex(millis: [1]))
        XCTAssertNil(LocalHistoryStore.thinningVictimIndex(millis: [1, 2]),
                     "with two versions there is nothing interior to thin")
    }

    /// End-to-end: hammer a file with many saves and confirm the FIRST version
    /// is still recoverable after the budget forced evictions.
    func test_overBudget_theOriginalVersionSurvives() throws {
        let store = LocalHistoryStore(directory: dir, isEnabled: { true },
                                      capBytes: 4_096, diffInputCap: 1_024)
        let path = dir.appendingPathComponent("thin.md").path
        let chunk = String(repeating: "y", count: 900)
        _ = store.capture(path: path, content: "THE ORIGINAL\n",
                          at: Date(timeIntervalSince1970: 0))
        for i in 1...12 {
            _ = store.capture(path: path, content: "\(i)-\(chunk)\n",
                              at: Date(timeIntervalSince1970: TimeInterval(1000 + i)))
        }
        let restored = store.versions(for: path).compactMap {
            store.contentString(of: $0, for: path)
        }
        XCTAssertLessThan(restored.count, 13, "the budget must have evicted")
        XCTAssertTrue(restored.contains("THE ORIGINAL\n"),
                      "the oldest version must NOT be the first thing dropped")
    }

    /// Over budget: the NEWEST is always kept — recovery reaches for it first.
    func test_overBudget_evictsAndAlwaysKeepsNewest() throws {
        // Small injected cap so the eviction path runs without writing 100 MiB.
        let store = LocalHistoryStore(directory: dir, isEnabled: { true },
                                      capBytes: 4_096, diffInputCap: 1_024)
        let path = dir.appendingPathComponent("big.md").path
        let chunk = String(repeating: "x", count: 900)
        for i in 1...12 {
            _ = store.capture(path: path, content: "\(i)-\(chunk)\n",
                              at: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        let versions = store.versions(for: path)
        XCTAssertGreaterThan(versions.count, 0, "pruning must never empty the history")
        XCTAssertLessThan(versions.count, 12, "the budget must actually evict")

        // versions(for:) is newest-first — the last write must have survived.
        let newest = try XCTUnwrap(versions.first)
        XCTAssertEqual(store.contentString(of: newest, for: path), "12-\(chunk)\n",
                       "the newest version is never the one evicted")
    }

    /// Compaction: a small follow-up edit is stored as a DIFF, not a second full
    /// copy, so the budget buys many more versions than naive full snapshots.
    func test_smallEditsAreStoredAsDiffs_notFullCopies() throws {
        let store = LocalHistoryStore(directory: dir, isEnabled: { true })
        let path = dir.appendingPathComponent("compact.md").path
        let base = String(repeating: "line of text\n", count: 400)   // ~5 KB
        _ = store.capture(path: path, content: base, at: Date(timeIntervalSince1970: 1))
        _ = store.capture(path: path, content: base + "one more line\n",
                          at: Date(timeIntervalSince1970: 2))

        let versions = store.versions(for: path)
        XCTAssertEqual(versions.count, 2)
        // The second record must be far smaller than a second full copy.
        let onDisk = totalBytes(in: dir)
        XCTAssertLessThan(onDisk, base.utf8.count * 2,
                          "a one-line edit must not cost another full snapshot")
        // …and must still reconstruct exactly.
        XCTAssertEqual(store.contentString(of: versions[0], for: path),
                       base + "one more line\n")
        XCTAssertEqual(store.contentString(of: versions[1], for: path), base)
    }

    private func totalBytes(in root: URL) -> Int {
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in e {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) as? Int ?? 0
        }
        return total
    }
}
