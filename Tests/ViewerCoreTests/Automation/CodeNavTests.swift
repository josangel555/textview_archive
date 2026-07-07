import XCTest
@testable import ViewerCore

/// TSK-1192 — the who_calls flow, host-tested without a language server:
/// the orchestration takes injected async closures, so canned LSP shapes
/// exercise symbol picking, reference mapping, definition-exclusion, the
/// caller cap, and the failure modes. The LIVE nav result (real LSP) is
/// integration-tier by nature — the ticket's validation note covers it.
final class CodeNavTests: XCTestCase {

    private func sym(_ name: String, _ path: String, _ line: Int) -> LSPWorkspaceSymbol {
        LSPWorkspaceSymbol(
            name: name, kind: .function, containerName: nil,
            location: LSPLocation(
                uri: "file://\(path)",
                range: LSPRange(
                    start: LSPPosition(line: line, character: 5),
                    end: LSPPosition(line: line, character: 5 + name.count))))
    }

    private func loc(_ path: String, _ line: Int) -> LSPLocation {
        LSPLocation(
            uri: "file://\(path)",
            range: LSPRange(
                start: LSPPosition(line: line, character: 0),
                end: LSPPosition(line: line, character: 1)))
    }

    func test_pickBest_prefersExactThenCaseThenPrefixThenShortest() {
        XCTAssertEqual(CodeNav.pickBest(query: "foo", names: ["fooBar", "foo", "Foo"]), 1)
        XCTAssertEqual(CodeNav.pickBest(query: "foo", names: ["fooBar", "Foo"]), 1, "case-insensitive exact")
        XCTAssertEqual(CodeNav.pickBest(query: "foo", names: ["afoo", "fooBar"]), 1, "prefix beats substring")
        XCTAssertEqual(CodeNav.pickBest(query: "foo", names: ["ratherLongName", "shrt"]), 1, "shortest as the fallback")
        XCTAssertNil(CodeNav.pickBest(query: "x", names: []))
    }

    func test_whoCalls_mapsReferences_excludesTheDefinition_and1basesLines() async {
        let result = await CodeNav.whoCalls(
            query: "render",
            workspaceSymbol: { _ in [self.sym("render", "/src/render.swift", 9)] },
            references: { url, line, char in
                XCTAssertEqual(url.path, "/src/render.swift")
                XCTAssertEqual(line, 9, "the definition's LSP position goes back verbatim")
                XCTAssertEqual(char, 5)
                return [
                    self.loc("/src/render.swift", 9),   // the definition itself → dropped
                    self.loc("/src/a.swift", 3),
                    self.loc("/src/b.swift", 41),
                ]
            })
        guard let result else { return XCTFail("expected a result") }
        XCTAssertEqual(result.definition, CodeNav.Location(path: "/src/render.swift", line: 10),
                       "definition is 1-based for humans/agents")
        XCTAssertEqual(result.callers, [
            CodeNav.Location(path: "/src/a.swift", line: 4),
            CodeNav.Location(path: "/src/b.swift", line: 42),
        ])
        XCTAssertFalse(result.truncated)
    }

    func test_whoCalls_capsCallers_andFlagsTruncation() async {
        let refs = (0..<300).map { loc("/src/big.swift", $0 + 100) }
        let result = await CodeNav.whoCalls(
            query: "hot",
            workspaceSymbol: { _ in [self.sym("hot", "/src/hot.swift", 1)] },
            references: { _, _, _ in refs })
        XCTAssertEqual(result?.callers.count, CodeNav.maxCallers)
        XCTAssertEqual(result?.truncated, true)
    }

    func test_whoCalls_nilOnNoSymbols_andOnThrowingBackend() async {
        let none = await CodeNav.whoCalls(
            query: "ghost",
            workspaceSymbol: { _ in [] },
            references: { _, _, _ in XCTFail("unreachable"); return [] })
        XCTAssertNil(none, "no symbol match → nil (the tool reports 'not found')")
        struct Down: Error {}
        let down = await CodeNav.whoCalls(
            query: "x",
            workspaceSymbol: { _ in throw Down() },
            references: { _, _, _ in [] })
        XCTAssertNil(down, "an LSP failure degrades to nil, never throws out")
    }

    /// The async tool lane end-to-end: who_calls is dispatched OFF the
    /// main actor via `dispatchAsync` with a host double, and the sync
    /// catalog refuses it (the two lanes never overlap).
    @MainActor
    func test_asyncLane_dispatchesWhoCalls_withHostDouble() async throws {
        XCTAssertTrue(MCPToolCatalog.isAsyncTool("who_calls"))
        XCTAssertFalse(MCPToolCatalog.isAsyncTool("find"))
        let fake = FakeAutomationHost()
        fake.whoCallsResult = CodeNav.WhoCalls(
            symbol: "known",
            definition: CodeNav.Location(path: "/x.swift", line: 1),
            callers: [CodeNav.Location(path: "/y.swift", line: 7)],
            truncated: false)
        let box = MCPToolCatalog.AsyncHostBox(fake)
        let value = try await MCPToolCatalog.dispatchAsync(
            name: "who_calls",
            args: .object(["symbol": .string("known")]),
            host: box)
        guard case .object(let o) = value else { return XCTFail("object result") }
        XCTAssertEqual(o["symbol"], .string("known"))
        XCTAssertEqual(o["callerCount"], .int(1))
        // The miss path surfaces the actionable LSP hint.
        fake.whoCallsResult = nil
        do {
            _ = try await MCPToolCatalog.dispatchAsync(
                name: "who_calls",
                args: .object(["symbol": .string("ghost")]),
                host: box)
            XCTFail("miss must throw")
        } catch let e as MCPError {
            XCTAssertTrue(e.message.contains("language server"), "hint: \(e.message)")
        }
    }
}
