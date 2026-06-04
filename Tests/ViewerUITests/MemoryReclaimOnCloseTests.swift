import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Tier 1 (T1m, host-safe) regression guard for UX-overhaul item **L1**:
/// per-tab / per-file caches must be RECLAIMED when a tab closes, so memory
/// doesn't ratchet up over a long session of opening and closing files.
///
/// The dominant post-close residual is WKWebView / WebKit-XPC memory (rendered
/// markdown + CM6 editor + Mermaid web-content processes) — that's the
/// architectural #191 peak-bound, an owner-deferred UX trade-off (tear the
/// WebView down on close vs. pay re-render latency on reopen) and not testable
/// headlessly. What IS our Swift heap, and IS bounded here, is the family of
/// per-tab dictionaries on `TabCoordinator` and the per-URL LSP diagnostics on
/// `DocumentModel`. These tests pin that the close fan-out empties them.
@MainActor
final class MemoryReclaimOnCloseTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemReclaim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "MemReclaim-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String = "x") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func diag(_ message: String) -> LSPDiagnostic {
        LSPDiagnostic(
            range: LSPRange(start: LSPPosition(line: 0, character: 0),
                            end: LSPPosition(line: 0, character: 1)),
            severity: .error, code: nil, source: "test", message: message)
    }

    // MARK: - LSP diagnostics reclaim (the L1 fix)

    func test_closeTab_clearsClosedFilesLspDiagnostics() throws {
        let model = makeModel()
        let a = try writeFile("a.swift", "let x = 1\n")
        model.open(url: a)
        model.lspDiagnostics.replace(url: a, with: [diag("boom")])
        XCTAssertNotNil(model.lspDiagnostics.byURL[a], "precondition: diagnostic seeded")

        model.closeTab(at: 0)
        XCTAssertNil(model.lspDiagnostics.byURL[a],
                     "closing the only tab on a file must drop its LSP diagnostics")
    }

    func test_closeTab_keepsDiagnosticsForFilesStillOpen() throws {
        // The clear is guarded on "no surviving tab still shows this URL", so
        // closing A must NOT collaterally drop B's diagnostics.
        let model = makeModel()
        let a = try writeFile("a.swift", "let x = 1\n")
        let b = try writeFile("b.swift", "let y = 2\n")
        model.open(url: a)
        model.open(url: b)
        model.lspDiagnostics.replace(url: a, with: [diag("a-problem")])
        model.lspDiagnostics.replace(url: b, with: [diag("b-problem")])

        let aIndex = try XCTUnwrap(model.tabs.tabs.firstIndex { $0.url == a })
        model.closeTab(at: aIndex)

        XCTAssertNil(model.lspDiagnostics.byURL[a], "closed file's diagnostics cleared")
        XCTAssertNotNil(model.lspDiagnostics.byURL[b],
                        "still-open file's diagnostics must survive a sibling close")
    }

    // MARK: - Per-tab coordinator dictionaries reclaim

    func test_closeTab_dropsPerTabCoordinatorState() throws {
        let model = makeModel()
        let a = try writeFile("data.bin", "abc")
        model.open(url: a)
        let id = try XCTUnwrap(model.tabs.tabs.first?.id)

        // Seed a non-default per-tab value (default hex width is 16).
        model.tabCoordinator.setHexWidth(32, forTabID: id)
        XCTAssertEqual(model.tabCoordinator.hexBytesPerRow[id], 32)

        model.closeTab(at: 0)
        XCTAssertNil(model.tabCoordinator.hexBytesPerRow[id],
                     "per-tab hex width must be dropped when the tab closes")
        XCTAssertNil(model.tabCoordinator.csvFilterStates[id])
        XCTAssertNil(model.tabCoordinator.editorBuffers[id])
        XCTAssertNil(model.tabCoordinator.languageOverrides[id])
    }

    func test_closeAllTabs_leavesPerTabDictsEmpty() throws {
        let model = makeModel()
        for i in 0..<3 {
            let u = try writeFile("f\(i).bin", "payload-\(i)")
            model.open(url: u)
            if let id = model.tabs.tabs.last?.id {
                model.tabCoordinator.setHexWidth(24, forTabID: id)
            }
        }
        XCTAssertEqual(model.tabs.tabs.count, 3)
        XCTAssertFalse(model.tabCoordinator.hexBytesPerRow.isEmpty)

        // Close from the right so indices stay valid.
        while !model.tabs.tabs.isEmpty {
            model.closeTab(at: model.tabs.tabs.count - 1)
        }

        XCTAssertTrue(model.tabs.tabs.isEmpty)
        XCTAssertTrue(model.tabCoordinator.hexBytesPerRow.isEmpty,
                      "no per-tab hex-width entries may survive closing every tab")
        XCTAssertTrue(model.tabCoordinator.csvFilterStates.isEmpty)
        XCTAssertTrue(model.tabCoordinator.editorBuffers.isEmpty)
        XCTAssertTrue(model.tabCoordinator.languageOverrides.isEmpty)
        XCTAssertTrue(model.tabCoordinator.formattedTextCache.isEmpty)
    }
}
