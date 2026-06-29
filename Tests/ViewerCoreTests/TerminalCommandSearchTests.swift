import XCTest
@testable import ViewerCore

/// TSK-1176 — the unified favorites+history terminal command-search model (the
/// host-testable half; the palette UI is the render tail). Pins the merge/dedupe/
/// rank contract: favorites first, history-only after, a both-listed command shown
/// ONCE as the favorite.
final class TerminalCommandSearchTests: XCTestCase {

    private var favs: TerminalFavoritesStore!
    private var hist: TerminalCommandHistory!

    override func setUp() {
        super.setUp()
        let dir = FileManager.default.temporaryDirectory
        favs = TerminalFavoritesStore(
            storeURL: dir.appendingPathComponent("tcs-fav-\(UUID().uuidString).json"))
        hist = TerminalCommandHistory(
            storeURL: dir.appendingPathComponent("tcs-hist-\(UUID().uuidString).json"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: favs.storeURL)
        try? FileManager.default.removeItem(at: hist.storeURL)
        super.tearDown()
    }

    private func unified(_ q: String) -> [TerminalCommandSearch.Result] {
        TerminalCommandSearch.unified(query: q, favorites: favs, history: hist)
    }

    func test_favoritesFirst_thenHistory() {
        favs.add(command: "git status", title: "status")
        _ = hist.record("npm run build")
        let r = unified("")
        XCTAssertEqual(r.map(\.command), ["git status", "npm run build"])
        XCTAssertEqual(r.map(\.isFavorite), [true, false])
        XCTAssertEqual(r[0].displayLabel, "status")     // favorite title
        XCTAssertEqual(r[1].displayLabel, "npm run build")
    }

    func test_commandInBoth_shownOnce_asFavorite() {
        favs.add(command: "git push", title: "push")
        _ = hist.record("git push")    // same command, also in history
        let r = unified("git push")
        XCTAssertEqual(r.count, 1, "a both-listed command must appear once")
        XCTAssertTrue(r[0].isFavorite)
        XCTAssertEqual(r[0].title, "push")
    }

    func test_caseInsensitiveMatch_acrossBothStores() {
        favs.add(command: "Docker compose up")
        _ = hist.record("DOCKER ps")
        let r = unified("docker")
        XCTAssertEqual(Set(r.map(\.command)), ["Docker compose up", "DOCKER ps"])
    }

    func test_historyOnly_isNotFavorite() {
        _ = hist.record("ls -la")
        let r = unified("ls")
        XCTAssertEqual(r.count, 1)
        XCTAssertFalse(r[0].isFavorite)
        XCTAssertEqual(r[0].title, "")
        XCTAssertEqual(r[0].displayLabel, "ls -la")
    }

    func test_noMatch_empty() {
        favs.add(command: "git status")
        _ = hist.record("npm test")
        XCTAssertTrue(unified("zzz-nope").isEmpty)
    }

    func test_historyMRUOrder_preserved() {
        _ = hist.record("first")
        _ = hist.record("second")
        _ = hist.record("third")
        // History store is MRU (newest first): third, second, first.
        XCTAssertEqual(unified("").map(\.command), ["third", "second", "first"])
    }
}
