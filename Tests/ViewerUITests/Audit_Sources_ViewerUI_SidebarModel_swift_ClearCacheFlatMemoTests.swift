import XCTest
import ViewerCore
@testable import ViewerUI

/// Regression coverage for the audit finding that `clearCache()` dropped the
/// children cache + LRU + sorted cache but LEFT `cachedFlatRows` stale, so the
/// flat-row memo could desync from the children cache it is derived from.
///
/// The desync is reachable in production: `DocumentModel`'s git-checkout path
/// calls `sidebar.clearCache()` and CANNOT call the private
/// `invalidateFlatCache()` — it has no way to drop the memo, so after a branch
/// switch `flatVisibleRows()` kept serving the pre-checkout flattened tree.
/// Folding `cachedFlatRows = nil` into `clearCache()` makes the two impossible
/// to drift; these tests pin that via the public surface only.
@MainActor
final class Audit_Sources_ViewerUI_SidebarModel_swift_ClearCacheFlatMemoTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarClearCacheFlatMemo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @discardableResult
    private func touch(_ relativePath: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    private func mkdir(_ relativePath: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The core regression: prime the flat-row memo, then `clearCache()`.
    /// Because `clearCache()` now also drops `cachedFlatRows`, the next
    /// `flatVisibleRows()` re-walks against the (now-empty) children cache and
    /// reflects that the previously-listed children are gone. With the bug,
    /// the stale memo would still report the pre-clear rows.
    func test_clearCache_dropsFlatRowMemo() async throws {
        let model = SidebarModel()
        try touch("a.md")
        try touch("b.md")
        model.setRoot(tmpDir)

        // Prime the memo — root auto-expanded → root + a.md + b.md = 3 rows.
        let primed = model.flatVisibleRows()
        XCTAssertEqual(primed.count, 3,
            "precondition: root + 2 files must be in the primed flat memo")

        // Drop the children cache. `clearCache()` must also invalidate the
        // flat-row memo so it can't keep serving the stale tree.
        model.clearCache()

        // `children(of:)` is cache-only (no IO), so after clearCache the root's
        // children read empty — and the freshly-recomputed flat memo must agree:
        // only the root row survives (its children cache is empty).
        let afterClear = model.flatVisibleRows()
        XCTAssertEqual(afterClear.map { $0.node.name },
                       [model.rootURL!.lastPathComponent],
            "clearCache must drop the flat-row memo: after clearing the children "
            + "cache the flat list must reflect the empty cache, not the stale tree")
    }

    /// After `clearCache()`, re-loading the root's children must make
    /// `flatVisibleRows()` reflect them again — proving the memo tracks the
    /// children cache through a clear→reload cycle rather than being stuck.
    func test_clearCache_thenReload_flatMemoReflectsFreshChildren() async throws {
        let model = SidebarModel()
        try touch("a.md")
        model.setRoot(tmpDir)
        _ = model.flatVisibleRows()   // prime

        model.clearCache()
        XCTAssertEqual(model.flatVisibleRows().count, 1,
            "post-clear flat memo must show root only (children cache empty)")

        // Re-load the root's children and confirm the memo grows again.
        model.ensureLoaded(url: model.rootURL!)
        XCTAssertEqual(model.flatVisibleRows().map { $0.node.name },
                       [model.rootURL!.lastPathComponent, "a.md"],
            "after reload the flat memo must reflect the freshly-read children")
    }

    /// `includeHidden.didSet` clears + repopulates the cache; the flat memo must
    /// track the visible-set change through that path (it now relies on
    /// `clearCache()` dropping the memo rather than a separate invalidate call).
    func test_includeHiddenToggle_flatMemoTracksVisibleSet() async throws {
        let model = SidebarModel()
        try touch("visible.md")
        try touch(".hidden")
        model.setRoot(tmpDir)

        // Default includeHidden = true → both files in the flat memo.
        XCTAssertEqual(Set(model.flatVisibleRows().map { $0.node.name }),
                       [model.rootURL!.lastPathComponent, "visible.md", ".hidden"])

        model.includeHidden = false
        XCTAssertEqual(Set(model.flatVisibleRows().map { $0.node.name }),
                       [model.rootURL!.lastPathComponent, "visible.md"],
            "turning hidden OFF must update the flat memo (no stale .hidden row)")

        model.includeHidden = true
        XCTAssertEqual(Set(model.flatVisibleRows().map { $0.node.name }),
                       [model.rootURL!.lastPathComponent, "visible.md", ".hidden"],
            "turning hidden back ON must restore the dotfile in the flat memo")
    }
}
