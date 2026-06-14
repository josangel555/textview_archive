import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-464 follow-up — the Navigate menu (Go to Definition/Declaration/Type/
/// Implementation) dispatches `DocumentModel.navigateViaLSPAtCursor`. The menu
/// is editor-mode-gated by `validateMenuItem`, but this pins the underlying
/// SAFETY contract that lets the menu exist: the action is a graceful no-op
/// (returns false, never crashes) in any non-editor / no-cursor context — so a
/// stray invocation (a forced ⌘-equivalent, a script verb) can't blow up.
///
/// Host-safe (T1m): drives the model directly; the menu RENDER + a live LSP jump
/// are the VM/live-tail. (Each kind's actual navigation is exercised by the
/// existing LSP nav tests + the script verbs editor-goto-*.)
@MainActor
final class LSPNavigateActionSafetyTests: XCTestCase {
    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LSPNavSafety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "LSPNavSafety-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults { defaults.removePersistentDomain(forName: suiteName) }
        try await super.tearDown()
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            bookmarks: BookmarksStore(storeURL: tmpDir.appendingPathComponent("bookmarks.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults))
    }

    func test_noTab_everyKind_isGracefulFalse() {
        let m = makeModel()
        for kind in DocumentModel.LSPNavigationKind.allCases {
            XCTAssertFalse(m.navigateViaLSPAtCursor(kind: kind),
                           "no selected tab → \(kind) must no-op safely (returns false)")
        }
    }

    func test_fileOpenButNoEditorCursor_isFalse() throws {
        let m = makeModel()
        let url = tmpDir.appendingPathComponent("a.swift")
        try "let x = 1\n".write(to: url, atomically: true, encoding: .utf8)
        m.open(url: url)  // opens in source mode — no CM6 editor cursor tracked
        XCTAssertFalse(m.navigateViaLSPAtCursor(kind: .definition),
                       "a file open without an editor cursor → safe false, not a crash")
    }

    func test_navigationKind_coversTheFourMenuItems() {
        // The Navigate menu wires exactly these four; guard against drift.
        XCTAssertEqual(Set(DocumentModel.LSPNavigationKind.allCases.map(\.rawValue)),
                       ["definition", "declaration", "typeDefinition", "implementation"])
    }
}
