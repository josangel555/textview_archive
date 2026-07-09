import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1475 — the favorites editor view-model (host), over an isolated store.
@MainActor
final class TerminalFavoritesEditorModelTests: XCTestCase {

    private func makeModel() throws -> (TerminalFavoritesEditorModel, TerminalFavoritesStore) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-fav-\(UUID().uuidString).json")
        let store = TerminalFavoritesStore(storeURL: url)
        store.add(command: "git status", title: "Status")
        store.add(command: "npm run build")   // added → front (newest-first)
        store.add(command: "swift test", title: "Tests")
        // Stored order is newest-first: swift test, npm run build, git status.
        return (TerminalFavoritesEditorModel(store: store), store)
    }

    func test_rowsMirrorStore() throws {
        let (m, _) = try makeModel()
        XCTAssertEqual(m.rows.map(\.command),
                       ["swift test", "npm run build", "git status"])
        XCTAssertFalse(m.isEmpty)
    }

    func test_rename_keepsOrder() throws {
        let (m, _) = try makeModel()
        XCTAssertTrue(m.rename(command: "npm run build", to: "Build"))
        XCTAssertEqual(m.rows.map(\.command),
                       ["swift test", "npm run build", "git status"], "order unchanged")
        XCTAssertEqual(m.rows.first(where: { $0.command == "npm run build" })?.title, "Build")
    }

    func test_moveUp_moveDown_clampAtEnds() throws {
        let (m, _) = try makeModel()
        // "git status" is last → down is a clamp no-op.
        XCTAssertFalse(m.moveDown(command: "git status"))
        // Move it up one → middle.
        XCTAssertTrue(m.moveUp(command: "git status"))
        XCTAssertEqual(m.rows.map(\.command),
                       ["swift test", "git status", "npm run build"])
        // "swift test" is first → up is a clamp no-op.
        XCTAssertFalse(m.moveUp(command: "swift test"))
    }

    func test_remove() throws {
        let (m, _) = try makeModel()
        XCTAssertTrue(m.remove(command: "npm run build"))
        XCTAssertEqual(m.rows.map(\.command), ["swift test", "git status"])
        XCTAssertFalse(m.remove(command: "not there"))
    }

    func test_visibleRows_filter() throws {
        let (m, _) = try makeModel()
        m.filterQuery = "git"
        XCTAssertEqual(m.visibleRows.map(\.command), ["git status"])
        m.filterQuery = "Tests"   // matches the title of "swift test"
        XCTAssertEqual(m.visibleRows.map(\.command), ["swift test"])
        m.filterQuery = ""
        XCTAssertEqual(m.visibleRows.count, 3)
    }
}
