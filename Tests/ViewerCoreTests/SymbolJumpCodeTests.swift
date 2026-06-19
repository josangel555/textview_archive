import XCTest
@testable import ViewerCore

/// TSK-727 (code-file `@`): the `documentSymbol` → palette jump-row mapping.
/// The palette list/jump render is the view tail; the flatten + rank contract
/// is pinned here so a logic regression fails on the host gate:
///   - flatten: pre-order DFS, 1-based jump line, dotted container path,
///     empty-name skip, kind labels;
///   - rank: empty query → doc order, query → fuzzy-ranked best-first,
///     non-matches dropped, jump line preserved.
final class SymbolJumpCodeTests: XCTestCase {

    /// Build an `LSPDocumentSymbol` whose `selectionRange` starts on the given
    /// 0-based line (the only field the jump cares about). `range` mirrors it.
    private func sym(
        _ name: String, kind: LSPSymbolKind, line: Int,
        children: [LSPDocumentSymbol] = []
    ) -> LSPDocumentSymbol {
        let r = LSPRange(start: LSPPosition(line: line, character: 0),
                         end: LSPPosition(line: line, character: name.utf16.count))
        return LSPDocumentSymbol(
            name: name, detail: nil, kind: kind,
            range: r, selectionRange: r, children: children, uri: nil)
    }

    // MARK: - flatten

    func testFlattenPreOrderDepthFirst() {
        // A struct with two nested methods, then a top-level func: the flat list
        // must be parent-then-children-then-next-sibling (document order).
        let tree = [
            sym("Foo", kind: .struct, line: 0, children: [
                sym("bar", kind: .method, line: 2),
                sym("baz", kind: .method, line: 5),
            ]),
            sym("topLevel", kind: .function, line: 10),
        ]
        let flat = SymbolJump.flatten(tree)
        XCTAssertEqual(flat.map { $0.name }, ["Foo", "bar", "baz", "topLevel"])
    }

    func testFlattenConvertsLineTo1Based() {
        // LSP selectionRange line is 0-based; jump targets are 1-based.
        let flat = SymbolJump.flatten([sym("Foo", kind: .class, line: 0),
                                       sym("Bar", kind: .class, line: 41)])
        XCTAssertEqual(flat[0].line, 1)
        XCTAssertEqual(flat[1].line, 42)
    }

    func testFlattenBuildsDottedContainerPath() {
        // A method two levels deep carries its ancestor names as `container`;
        // top-level symbols have an empty container.
        let tree = [
            sym("Outer", kind: .class, line: 0, children: [
                sym("Inner", kind: .struct, line: 1, children: [
                    sym("method", kind: .method, line: 2),
                ]),
            ]),
        ]
        let flat = SymbolJump.flatten(tree)
        let outer = flat.first { $0.name == "Outer" }
        let inner = flat.first { $0.name == "Inner" }
        let method = flat.first { $0.name == "method" }
        XCTAssertEqual(outer?.container, "")
        XCTAssertEqual(inner?.container, "Outer")
        XCTAssertEqual(method?.container, "Outer.Inner")
    }

    func testDetailLabelCombinesKindAndContainer() {
        let tree = [
            sym("Foo", kind: .struct, line: 0, children: [
                sym("bar", kind: .method, line: 1),
            ]),
        ]
        let flat = SymbolJump.flatten(tree)
        XCTAssertEqual(flat.first { $0.name == "Foo" }?.detail, "struct")
        XCTAssertEqual(flat.first { $0.name == "bar" }?.detail, "method · Foo")
    }

    func testFlattenSkipsEmptyNamedSymbolButKeepsTheirChildren() {
        // Some servers emit empty-named synthetic scopes; they must not render
        // as a blank un-jumpable row, but their children should still surface
        // (and skip the empty scope in the container path).
        let tree = [
            sym("", kind: .namespace, line: 0, children: [
                sym("realChild", kind: .function, line: 3),
            ]),
            sym("Visible", kind: .class, line: 10),
        ]
        let flat = SymbolJump.flatten(tree)
        XCTAssertEqual(flat.map { $0.name }, ["realChild", "Visible"])
        // The empty scope is skipped in the path: realChild is "top-level".
        XCTAssertEqual(flat.first { $0.name == "realChild" }?.container, "")
    }

    func testFlattenTrimsWhitespaceFromNames() {
        let flat = SymbolJump.flatten([sym("  spaced  ", kind: .function, line: 0)])
        XCTAssertEqual(flat.first?.name, "spaced")
    }

    func testFlattenEmptyTreeYieldsEmpty() {
        XCTAssertTrue(SymbolJump.flatten([]).isEmpty)
    }

    // MARK: - kindLabel mapping

    func testKindLabelMapping() {
        XCTAssertEqual(SymbolJump.kindLabel(.function), "func")
        XCTAssertEqual(SymbolJump.kindLabel(.method), "method")
        XCTAssertEqual(SymbolJump.kindLabel(.struct), "struct")
        XCTAssertEqual(SymbolJump.kindLabel(.class), "class")
        XCTAssertEqual(SymbolJump.kindLabel(.enum), "enum")
        XCTAssertEqual(SymbolJump.kindLabel(.enumMember), "case")
        XCTAssertEqual(SymbolJump.kindLabel(.constructor), "init")
        XCTAssertEqual(SymbolJump.kindLabel(.variable), "var")
        XCTAssertEqual(SymbolJump.kindLabel(.constant), "const")
        // Server-vendored / unrecognized kinds collapse to a generic label.
        XCTAssertEqual(SymbolJump.kindLabel(.other), "symbol")
    }

    // MARK: - rank (over flattened symbols)

    private func cs(_ name: String, _ line: Int, _ kind: String = "func",
                    _ container: String = "") -> SymbolJump.CodeSymbol {
        SymbolJump.CodeSymbol(name: name, container: container, kindLabel: kind, line: line)
    }

    func testRankEmptyQueryReturnsAllInDocumentOrder() {
        let syms = [cs("alpha", 1), cs("beta", 8), cs("gamma", 20)]
        XCTAssertEqual(SymbolJump.rank(symbols: syms, query: ""), syms)
        XCTAssertEqual(SymbolJump.rank(symbols: syms, query: "   "), syms)
    }

    func testRankFiltersToMatchesOnly() {
        let syms = [cs("loadConfig", 1), cs("saveConfig", 8),
                    cs("render", 14), cs("dispose", 20)]
        let r = SymbolJump.rank(symbols: syms, query: "config")
        XCTAssertFalse(r.isEmpty)
        XCTAssertTrue(r.allSatisfy { $0.name.lowercased().contains("config") })
        XCTAssertFalse(r.contains(cs("render", 14)), "non-match dropped")
        XCTAssertFalse(r.contains(cs("dispose", 20)), "non-match dropped")
    }

    func testRankNoMatchYieldsEmpty() {
        XCTAssertTrue(SymbolJump.rank(symbols: [cs("a", 1), cs("b", 8)],
                                      query: "zzzznope").isEmpty)
    }

    func testRankPreservesJumpLine() {
        let syms = [cs("alpha", 3), cs("targetSymbol", 42), cs("beta", 50)]
        let r = SymbolJump.rank(symbols: syms, query: "targetSymbol")
        XCTAssertEqual(r.first?.line, 42)
        XCTAssertEqual(r.first?.name, "targetSymbol")
    }

    func testRankEmptySymbolsYieldsEmpty() {
        XCTAssertTrue(SymbolJump.rank(symbols: [], query: "anything").isEmpty)
        XCTAssertTrue(SymbolJump.rank(symbols: [], query: "").isEmpty)
    }

    // MARK: - rank(documentSymbols:) convenience composition

    func testRankDocumentSymbolsFlattensThenRanks() {
        // End-to-end: the exact composition the palette's code `@` mode runs.
        let tree = [
            sym("ConfigStore", kind: .class, line: 0, children: [
                sym("loadConfig", kind: .method, line: 5),
                sym("saveConfig", kind: .method, line: 12),
                sym("reset", kind: .method, line: 20),
            ]),
        ]
        let r = SymbolJump.rank(documentSymbols: tree, query: "config")
        // Matches the class + the two *Config methods; "reset" is dropped.
        let names = Set(r.map { $0.name })
        XCTAssertTrue(names.contains("ConfigStore"))
        XCTAssertTrue(names.contains("loadConfig"))
        XCTAssertTrue(names.contains("saveConfig"))
        XCTAssertFalse(names.contains("reset"))
        // Jump line for a method is its 1-based selectionRange line.
        XCTAssertEqual(r.first { $0.name == "loadConfig" }?.line, 6)
    }

    func testRankDocumentSymbolsEmptyQueryIsDocumentOrder() {
        let tree = [
            sym("A", kind: .function, line: 0),
            sym("B", kind: .function, line: 5),
        ]
        let r = SymbolJump.rank(documentSymbols: tree, query: "")
        XCTAssertEqual(r.map { $0.name }, ["A", "B"])
    }
}
