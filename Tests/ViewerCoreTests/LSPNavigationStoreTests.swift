import XCTest
@testable import ViewerCore

/// Pure-logic coverage of the shared `LSPNavigationStore`. Verifies
/// mode transitions, row formatting, and the loading/error state
/// machine — none of which require a live LSP server.
@MainActor
final class LSPNavigationStoreTests: XCTestCase {

    func test_setWorkspaceSymbols_replacesRows() {
        let store = LSPNavigationStore()
        let symbol = LSPWorkspaceSymbol(
            name: "doStuff",
            kind: .function,
            containerName: "Foo",
            location: LSPLocation(
                uri: "file:///tmp/foo.swift",
                range: .init(start: .init(line: 4, character: 8),
                             end: .init(line: 4, character: 14))))
        store.setWorkspaceSymbols(query: "do", symbols: [symbol])

        XCTAssertEqual(store.mode, .workspaceSymbols)
        XCTAssertEqual(store.query, "do")
        XCTAssertEqual(store.rows.count, 1)
        XCTAssertEqual(store.rows.first?.displayName, "doStuff")
        XCTAssertEqual(store.rows.first?.containerName, "Foo")
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.errorMessage)
    }

    func test_setReferences_formatsRowsWithFileAndLine() {
        let store = LSPNavigationStore()
        let loc = LSPLocation(
            uri: "file:///tmp/a/Foo.swift",
            range: .init(start: .init(line: 41, character: 4),
                         end: .init(line: 41, character: 10)))
        store.setReferences(originLabel: "Definition of Foo", locations: [loc])

        XCTAssertEqual(store.mode, .references)
        XCTAssertEqual(store.rows.count, 1)
        XCTAssertEqual(store.rows.first?.displayName, "Foo.swift:42")
        XCTAssertEqual(store.contextDescription, "Definition of Foo")
    }

    func test_startLoading_keepsExistingRowsForResponsiveness() {
        let store = LSPNavigationStore()
        let initial = LSPWorkspaceSymbol(
            name: "x", kind: .variable, containerName: nil,
            location: .init(uri: "file:///x.swift",
                            range: .init(start: .init(line: 0, character: 0),
                                         end: .init(line: 0, character: 1))))
        store.setWorkspaceSymbols(query: "x", symbols: [initial])
        XCTAssertEqual(store.rows.count, 1)

        // While the next query is loading, the previous rows should
        // remain — feels less janky than blanking the panel mid-type.
        store.startLoading(mode: .workspaceSymbols, query: "xy")
        XCTAssertTrue(store.isLoading)
        XCTAssertEqual(store.rows.count, 1)
        XCTAssertNil(store.errorMessage)
    }

    func test_setError_clearsLoading() {
        let store = LSPNavigationStore()
        store.startLoading(mode: .workspaceSymbols, query: "x")
        store.setError("server timed out")
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.errorMessage, "server timed out")
    }

    func test_clear_wipesRowsAndState() {
        let store = LSPNavigationStore()
        store.setWorkspaceSymbols(
            query: "x",
            symbols: [LSPWorkspaceSymbol(
                name: "x", kind: .variable, containerName: nil,
                location: .init(uri: "file:///x.swift",
                                range: .init(start: .init(line: 0, character: 0),
                                             end: .init(line: 0, character: 1))))])
        store.clear()
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(store.query, "")
        XCTAssertNil(store.contextDescription)
    }

    func test_iconName_perKind() {
        XCTAssertEqual(LSPNavigationStore.iconName(for: .function), "function")
        XCTAssertEqual(LSPNavigationStore.iconName(for: .class), "c.square")
        XCTAssertEqual(LSPNavigationStore.iconName(for: .struct), "s.square")
        // Unknown kinds fall back to a generic icon.
        XCTAssertEqual(LSPNavigationStore.iconName(for: .other),
                       "questionmark.square.dashed")
    }
}
