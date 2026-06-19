import XCTest
import Foundation
@testable import ViewerCore

/// Pins the folder-size scan that backs the bundle-analyzer treemap
/// (TSK-506): per-child recursive byte totals, descending sort, hidden /
/// skip-dir / symlink-loop handling, and the entry-budget truncation.
/// Pure filesystem I/O over a temp dir → host-tested.
final class FolderSizeStatsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fss-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func writeFile(_ rel: String, bytes: Int) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func entry(_ stats: FolderSizeStats, _ name: String) -> FolderSizeEntry? {
        stats.entries.first { $0.name == name }
    }

    // MARK: - Tests

    func test_emptyFolder_yieldsNoEntries() {
        let stats = FolderSizeStats.scan(folder: root)
        XCTAssertTrue(stats.entries.isEmpty)
        XCTAssertEqual(stats.totalBytes, 0)
        XCTAssertEqual(stats.totalFiles, 0)
        XCTAssertFalse(stats.truncated)
    }

    func test_unreadableFolder_returnsEmptyNotCrash() {
        let missing = root.appendingPathComponent("does-not-exist", isDirectory: true)
        let stats = FolderSizeStats.scan(folder: missing)
        XCTAssertTrue(stats.entries.isEmpty)
        XCTAssertEqual(stats.totalBytes, 0)
    }

    func test_topLevelFiles_sizeAndTotals() throws {
        try writeFile("a.txt", bytes: 100)
        try writeFile("b.bin", bytes: 250)
        let stats = FolderSizeStats.scan(folder: root)
        XCTAssertEqual(stats.entries.count, 2)
        XCTAssertEqual(stats.totalBytes, 350)
        XCTAssertEqual(stats.totalFiles, 2)
        XCTAssertEqual(entry(stats, "a.txt")?.byteSize, 100)
        XCTAssertEqual(entry(stats, "a.txt")?.isDirectory, false)
        XCTAssertEqual(entry(stats, "a.txt")?.fileCount, 1)
        XCTAssertEqual(entry(stats, "b.bin")?.byteSize, 250)
    }

    func test_directoryChild_sumsSubtreeRecursively() throws {
        try writeFile("src/one.swift", bytes: 30)
        try writeFile("src/nested/two.swift", bytes: 70)
        try writeFile("src/nested/deep/three.swift", bytes: 5)
        let stats = FolderSizeStats.scan(folder: root)
        let src = try XCTUnwrap(entry(stats, "src"))
        XCTAssertTrue(src.isDirectory)
        XCTAssertEqual(src.byteSize, 105)        // 30 + 70 + 5
        XCTAssertEqual(src.fileCount, 3)
        XCTAssertEqual(stats.totalBytes, 105)
        XCTAssertEqual(stats.totalFiles, 3)
    }

    func test_entriesSortedBySizeDescending() throws {
        try writeFile("small.txt", bytes: 10)
        try writeFile("big.bin", bytes: 1000)
        try writeFile("mid/x", bytes: 200)
        let stats = FolderSizeStats.scan(folder: root)
        XCTAssertEqual(stats.entries.map(\.name), ["big.bin", "mid", "small.txt"])
    }

    func test_equalSize_tieBrokenByName() throws {
        try writeFile("zeta.txt", bytes: 50)
        try writeFile("alpha.txt", bytes: 50)
        let stats = FolderSizeStats.scan(folder: root)
        XCTAssertEqual(stats.entries.map(\.name), ["alpha.txt", "zeta.txt"])
    }

    func test_hiddenFiles_skippedByDefault_includedWhenAsked() throws {
        try writeFile("visible.txt", bytes: 10)
        try writeFile(".hidden", bytes: 999)
        let def = FolderSizeStats.scan(folder: root)
        XCTAssertEqual(def.entries.map(\.name), ["visible.txt"])
        XCTAssertEqual(def.totalBytes, 10)

        let withHidden = FolderSizeStats.scan(
            folder: root, options: .init(skipsHiddenFiles: false, skipDirNames: []))
        XCTAssertEqual(withHidden.entries.count, 2)
        XCTAssertEqual(withHidden.totalBytes, 1009)
    }

    func test_skipDirNames_topLevelExcluded() throws {
        try writeFile(".git/objects/pack", bytes: 5000)
        try writeFile("keep.txt", bytes: 20)
        // .git is hidden so default skip already drops it; force-include
        // hidden but still skip by NAME to prove the name rule.
        let stats = FolderSizeStats.scan(
            folder: root, options: .init(skipsHiddenFiles: false, skipDirNames: [".git"]))
        XCTAssertEqual(stats.entries.map(\.name), ["keep.txt"])
        XCTAssertEqual(stats.totalBytes, 20)
    }

    func test_skipDirNames_nestedExcludedFromSubtreeSum() throws {
        try writeFile("pkg/real.js", bytes: 40)
        try writeFile("pkg/node_modules/dep/index.js", bytes: 9000)
        let stats = FolderSizeStats.scan(
            folder: root, options: .init(skipDirNames: ["node_modules"]))
        let pkg = try XCTUnwrap(entry(stats, "pkg"))
        XCTAssertEqual(pkg.byteSize, 40)         // node_modules subtree excluded
        XCTAssertEqual(pkg.fileCount, 1)
    }

    func test_symlinkLoop_doesNotHang() throws {
        try writeFile("dir/file.txt", bytes: 12)
        // dir/loop -> ..  (points back at dir's parent → would recurse forever)
        let loop = root.appendingPathComponent("dir/loop")
        try FileManager.default.createSymbolicLink(
            at: loop, withDestinationURL: root.appendingPathComponent("dir"))
        let stats = FolderSizeStats.scan(folder: root)   // must terminate
        let dir = try XCTUnwrap(entry(stats, "dir"))
        XCTAssertEqual(dir.fileCount, 1)                 // counted once, not looped
        XCTAssertEqual(dir.byteSize, 12)
    }

    func test_maxEntries_truncatesAndFlags() throws {
        for i in 0..<20 { try writeFile("f\(i).txt", bytes: 1) }
        let stats = FolderSizeStats.scan(
            folder: root, options: .init(maxEntries: 5))
        XCTAssertTrue(stats.truncated)
        XCTAssertLessThan(stats.totalFiles, 20)          // stopped early
    }

    func test_cancellation_stopsScan() throws {
        for i in 0..<10 { try writeFile("c\(i).txt", bytes: 1) }
        var calls = 0
        let stats = FolderSizeStats.scan(folder: root, isCancelled: {
            calls += 1
            return calls > 2                              // cancel after a couple
        })
        XCTAssertTrue(stats.truncated)
    }

    func test_zeroByteFile_keptAsEntry() throws {
        try writeFile("empty", bytes: 0)
        try writeFile("nonempty", bytes: 5)
        let stats = FolderSizeStats.scan(folder: root)
        XCTAssertEqual(stats.entries.count, 2)
        XCTAssertEqual(entry(stats, "empty")?.byteSize, 0)
    }

    /// End-to-end glue with the layout core: scanned entry sizes become
    /// proportional treemap tiles. This is the exact pipeline the Canvas
    /// view runs, so it guards the model→layout contract on the host.
    func test_entriesFeedSquarifyProportionally() throws {
        try writeFile("a.txt", bytes: 100)
        try writeFile("b.txt", bytes: 300)
        let stats = FolderSizeStats.scan(folder: root)
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        let tiles = TreemapLayout.squarify(
            stats.entries.map { (id: $0.id, weight: Double($0.byteSize)) }, in: bounds)
        XCTAssertEqual(tiles.count, 2)
        let byID = Dictionary(uniqueKeysWithValues: tiles.map { ($0.id, $0.rect) })
        let areaA = Double(byID["a.txt"]!.width) * Double(byID["a.txt"]!.height)
        let areaB = Double(byID["b.txt"]!.width) * Double(byID["b.txt"]!.height)
        // b is 3× a → its tile area is ~3× a's.
        XCTAssertEqual(areaB / areaA, 3.0, accuracy: 0.05)
    }
}
