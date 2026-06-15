import XCTest
@testable import ViewerCore

/// TSK-769 — user-curated terminal favorites store: add/dedupe/remove/cap +
/// a hand-editable JSON round-trip (the menu that lists them + the PTY insert
/// are the VM render tail).
final class TerminalFavoritesStoreTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermFav-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private func store() -> TerminalFavoritesStore { TerminalFavoritesStore(storeURL: tmp) }

    func test_add_prependsAndPersists() {
        let s = store()
        XCTAssertTrue(s.add(command: "git status"))
        XCTAssertTrue(s.add(command: "npm run build"))
        XCTAssertEqual(s.all.map(\.command), ["npm run build", "git status"],
            "most-recently-added is first")
        s.flush()
        // A fresh store over the same file sees the persisted list.
        XCTAssertEqual(store().all.map(\.command), ["npm run build", "git status"])
    }

    func test_add_blank_isRejected() {
        let s = store()
        XCTAssertFalse(s.add(command: "   \n "))
        XCTAssertTrue(s.all.isEmpty)
    }

    func test_add_dedupes_movesToFront() {
        let s = store()
        s.add(command: "a")
        s.add(command: "b")
        s.add(command: "a")   // re-add → moves to front, no duplicate
        XCTAssertEqual(s.all.map(\.command), ["a", "b"])
    }

    func test_add_trimsWhitespace() {
        let s = store()
        s.add(command: "  ls -la  ")
        XCTAssertEqual(s.all.first?.command, "ls -la")
    }

    func test_remove_byCommand() {
        let s = store()
        s.add(command: "a"); s.add(command: "b")
        XCTAssertTrue(s.remove(command: "a"))
        XCTAssertEqual(s.all.map(\.command), ["b"])
        XCTAssertFalse(s.remove(command: "nope"), "removing an absent command is a no-op")
    }

    func test_displayLabel_fallsBackToCommand() {
        XCTAssertEqual(TerminalFavoritesStore.Favorite(command: "ls").displayLabel, "ls")
        XCTAssertEqual(
            TerminalFavoritesStore.Favorite(title: "List", command: "ls").displayLabel, "List")
    }

    func test_cap_enforced() {
        let s = store()
        for i in 0..<(TerminalFavoritesStore.maxFavorites + 10) { s.add(command: "cmd\(i)") }
        XCTAssertEqual(s.all.count, TerminalFavoritesStore.maxFavorites)
    }

    func test_load_dropsBlanksAndDupes_fromHandEditedFile() throws {
        // Simulate a user hand-editing the JSON with a blank + a duplicate.
        let json = """
        [{"title":"","command":"a"},{"title":"","command":"  "},{"title":"x","command":"a"},{"title":"","command":"b"}]
        """
        try json.data(using: .utf8)!.write(to: tmp)
        let s = store()
        XCTAssertEqual(s.all.map(\.command), ["a", "b"],
            "blanks dropped, command-dupes collapsed (first wins)")
    }
}
