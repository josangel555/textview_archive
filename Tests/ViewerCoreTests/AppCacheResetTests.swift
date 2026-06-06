import XCTest
@testable import ViewerCore

/// Headless coverage for `AppCacheReset` — the File → Reset escape hatch.
/// Everything runs against a throwaway temp tree (never the real Application
/// Support dir), per the project rule about not writing under ~/Library from
/// automated paths.
final class AppCacheResetTests: XCTestCase {

    private var root: URL!
    private var mvBase: URL!
    private var bundleBase: URL!
    private var backupRoot: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-reset-\(UUID().uuidString)", isDirectory: true)
        mvBase = root.appendingPathComponent("MarkdownViewer", isDirectory: true)
        bundleBase = root.appendingPathComponent("com.markdownviewer.MarkdownViewer", isDirectory: true)
        backupRoot = AppCacheReset.defaultBackupRoot(markdownViewerBase: mvBase)
        try FileManager.default.createDirectory(at: mvBase, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleBase, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ rel: String, under base: URL) throws {
        let url = base.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func exists(_ rel: String, under base: URL) -> Bool {
        FileManager.default.fileExists(atPath: base.appendingPathComponent(rel).path)
    }

    func test_plannedTargets_mapsDomainsToCorrectBases() {
        let urls = AppCacheReset.plannedTargets(
            [.sessions, .lspCache], markdownViewerBase: mvBase, bundleIDBase: bundleBase)
        XCTAssertTrue(urls.contains(mvBase.appendingPathComponent("Sessions")))
        XCTAssertTrue(urls.contains(bundleBase.appendingPathComponent("jdtls-data")),
                      "lspCache must resolve under the bundle-id base, not MarkdownViewer/")
    }

    func test_everyDomain_hasTargetsTitleDetail() {
        for d in CacheDomain.allCases {
            XCTAssertFalse(d.relativeTargets.isEmpty, "\(d) has no targets")
            XCTAssertFalse(d.title.isEmpty)
            XCTAssertFalse(d.detail.isEmpty)
        }
    }

    func test_reset_movesExistingTargetsToBackup_andClearsOriginals() throws {
        try write("Sessions/index.json", under: mvBase)
        try write("Sessions/abc.json", under: mvBase)
        try write("bookmarks.json", under: mvBase)
        try write("history.json", under: mvBase)        // recents, must survive (not selected)

        let res = AppCacheReset.reset(
            [.sessions, .bookmarks],
            markdownViewerBase: mvBase, bundleIDBase: bundleBase,
            backupRoot: backupRoot, timestamp: "STAMP")

        // Originals gone.
        XCTAssertFalse(exists("Sessions", under: mvBase))
        XCTAssertFalse(exists("bookmarks.json", under: mvBase))
        // Unselected domain untouched.
        XCTAssertTrue(exists("history.json", under: mvBase))
        // Recoverable: moved into the timestamped backup, path preserved.
        let bk = backupRoot.appendingPathComponent("STAMP/MarkdownViewer")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bk.appendingPathComponent("Sessions/index.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bk.appendingPathComponent("bookmarks.json").path))
        XCTAssertEqual(res.movedTargets.count, 2, "Sessions dir + bookmarks.json")
    }

    func test_reset_absentTargets_areNoOp_notError() {
        // Nothing on disk for these domains → no crash, nothing moved.
        let res = AppCacheReset.reset(
            [.workspaces, .recents, .lspCache],
            markdownViewerBase: mvBase, bundleIDBase: bundleBase,
            backupRoot: backupRoot, timestamp: "STAMP")
        XCTAssertEqual(res.movedTargets.count, 0)
    }

    func test_reset_lspCache_movesFromBundleIDBase() throws {
        try write("jdtls-data/index/foo.bin", under: bundleBase)
        AppCacheReset.reset([.lspCache],
                            markdownViewerBase: mvBase, bundleIDBase: bundleBase,
                            backupRoot: backupRoot, timestamp: "STAMP")
        XCTAssertFalse(exists("jdtls-data", under: bundleBase))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: backupRoot.appendingPathComponent(
                "STAMP/bundleID/jdtls-data/index/foo.bin").path))
    }
}
