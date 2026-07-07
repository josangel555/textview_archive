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

    // MARK: - TSK-1475 favorites editor: rename + reorder

    func test_rename_setsTitleInPlace_keepsOrder() {
        let s = store()
        s.add(command: "c1"); s.add(command: "c2"); s.add(command: "c3")
        // order: c3, c2, c1
        XCTAssertTrue(s.rename(command: "c2", to: "Build the thing"))
        XCTAssertEqual(s.all.map(\.command), ["c3", "c2", "c1"], "order unchanged")
        XCTAssertEqual(s.all[1].displayLabel, "Build the thing")
        // An empty title clears back to showing the command.
        XCTAssertTrue(s.rename(command: "c2", to: ""))
        XCTAssertEqual(s.all[1].displayLabel, "c2")
        XCTAssertFalse(s.rename(command: "nope", to: "x"), "absent command → false")
    }

    func test_move_reorders_andClamps() {
        let s = store()
        s.add(command: "c1"); s.add(command: "c2"); s.add(command: "c3")
        // order: c3, c2, c1 → move c1 to the front
        XCTAssertTrue(s.move(command: "c1", to: 0))
        XCTAssertEqual(s.all.map(\.command), ["c1", "c3", "c2"])
        // An out-of-range index clamps to the end.
        XCTAssertTrue(s.move(command: "c1", to: 99))
        XCTAssertEqual(s.all.map(\.command), ["c3", "c2", "c1"])
        // A negative index clamps to the front.
        XCTAssertTrue(s.move(command: "c2", to: -5))
        XCTAssertEqual(s.all.map(\.command), ["c2", "c3", "c1"])
        XCTAssertFalse(s.move(command: "nope", to: 0))
    }

    func test_fullEditorCRUD_persistenceRoundTrip() {
        // add + rename + reorder + delete all survive a fresh store instance
        // — the TSK-1475 "favorites editor" persistence bar in one flow.
        let s = store()
        s.add(command: "keep me")
        s.add(command: "rename me")
        s.add(command: "delete me")
        s.rename(command: "rename me", to: "Renamed")
        s.move(command: "keep me", to: 0)
        s.remove(command: "delete me")
        s.flush()

        let reloaded = store()
        XCTAssertEqual(reloaded.all.map(\.command), ["keep me", "rename me"])
        XCTAssertEqual(reloaded.all.map(\.displayLabel), ["keep me", "Renamed"],
                       "the rename survived the round-trip")
    }
}
