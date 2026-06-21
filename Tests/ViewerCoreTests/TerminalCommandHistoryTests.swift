import XCTest
@testable import ViewerCore

/// TSK-1176 — teeth for the terminal command-history model + favorites search.
final class TerminalCommandHistoryTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("termhist-\(UUID().uuidString).json")
    }

    func test_record_isMRUDedupedAndCapped() {
        let h = TerminalCommandHistory(storeURL: tempURL())
        defer { try? FileManager.default.removeItem(at: h.storeURL); h.flush() }
        h.record("ls")
        h.record("git status")
        h.record("ls")   // re-run → moves to front, not duplicated
        XCTAssertEqual(h.all, ["ls", "git status"])
        XCTAssertFalse(h.record("   "), "blank is ignored")
    }

    func test_search_filtersCaseInsensitive() {
        let h = TerminalCommandHistory(storeURL: tempURL())
        defer { try? FileManager.default.removeItem(at: h.storeURL); h.flush() }
        h.record("git commit")
        h.record("git push")
        h.record("ls -la")
        XCTAssertEqual(Set(h.search("GIT")), ["git commit", "git push"])
        XCTAssertEqual(h.search("").count, 3, "blank query → all")
    }

    func test_persistence_roundTrips() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = TerminalCommandHistory(storeURL: url)
        a.record("make build")
        a.record("make test")
        a.flush()
        let b = TerminalCommandHistory(storeURL: url)   // reloads from disk
        XCTAssertEqual(b.all, ["make test", "make build"])
    }

    func test_favorites_search() {
        let store = TerminalFavoritesStore(storeURL: tempURL())
        defer { try? FileManager.default.removeItem(at: store.storeURL); store.flush() }
        store.add(command: "git push", title: "Push")
        store.add(command: "npm run dev", title: "Dev server")
        XCTAssertEqual(store.search("git").map(\.command), ["git push"])
        XCTAssertEqual(store.search("server").map(\.command), ["npm run dev"], "matches title too")
    }
}
