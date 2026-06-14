import XCTest
@testable import ViewerCore

/// TSK-705 (slice 4) — user-defined snippet store: JSON persistence + merge over
/// the built-ins (user id wins). Host-safe (temp files). Mirrors the
/// BookmarksStore JSON round-trip pattern.
final class SnippetStoreTests: XCTestCase {

    private var dir: URL!
    private var url: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnippetStore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("snippets.json")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func writeJSON(_ snippets: [Snippet]) throws {
        try JSONEncoder().encode(snippets).write(to: url)
    }

    func test_emptyStore_isBuiltInsOnly() {
        let store = SnippetStore(storeURL: url)
        XCTAssertEqual(store.all, SnippetLibrary.builtIns)
        XCTAssertTrue(store.userDefined().isEmpty)
    }

    func test_userSnippet_appendsAfterBuiltIns() throws {
        try writeJSON([Snippet(id: "my.foo", name: "Foo", body: "foo$0")])
        let store = SnippetStore(storeURL: url)
        XCTAssertEqual(store.all.count, SnippetLibrary.builtIns.count + 1)
        XCTAssertEqual(store.all.last?.id, "my.foo")
        XCTAssertEqual(store.userDefined().map(\.id), ["my.foo"])
    }

    func test_userSnippet_overridesBuiltInById() throws {
        try writeJSON([Snippet(id: "md.link", name: "My Link", body: "<$1>")])
        let store = SnippetStore(storeURL: url)
        // No new row — the built-in md.link is replaced in place.
        XCTAssertEqual(store.all.count, SnippetLibrary.builtIns.count)
        let link = store.all.first { $0.id == "md.link" }!
        XCTAssertEqual(link.name, "My Link", "user snippet overrides the built-in")
        XCTAssertEqual(link.body, "<$1>")
    }

    func test_add_persists_roundTrip() throws {
        let store = SnippetStore(storeURL: url)
        store.add(Snippet(id: "my.bar", name: "Bar", body: "bar"))
        store.flush()
        let reloaded = SnippetStore(storeURL: url)
        XCTAssertEqual(reloaded.userDefined().map(\.id), ["my.bar"])
        XCTAssertTrue(reloaded.all.contains { $0.id == "my.bar" })
    }

    func test_add_sameId_replaces_notDuplicates() {
        let store = SnippetStore(storeURL: url)
        store.add(Snippet(id: "my.x", name: "X1", body: "1"))
        store.add(Snippet(id: "my.x", name: "X2", body: "2"))
        XCTAssertEqual(store.userDefined().count, 1)
        XCTAssertEqual(store.userDefined().first?.name, "X2")
    }

    func test_remove_persists() throws {
        let store = SnippetStore(storeURL: url)
        store.add(Snippet(id: "my.gone", name: "G", body: "g"))
        store.remove(id: "my.gone")
        store.flush()
        XCTAssertTrue(SnippetStore(storeURL: url).userDefined().isEmpty)
    }

    func test_malformedJSON_degradesToBuiltIns() throws {
        try Data("{ not valid snippets ]".utf8).write(to: url)
        let store = SnippetStore(storeURL: url)
        XCTAssertEqual(store.all, SnippetLibrary.builtIns, "a corrupt file → built-ins only, no crash")
    }
}
