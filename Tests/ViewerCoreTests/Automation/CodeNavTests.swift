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

    // MARK: - TSK-1560: position-based nav (goto_definition / find_references)

    func test_navLocations_maps1based_skipsNonFileURIs_capsWithTruncation() {
        func loc(_ uri: String, _ line0: Int) -> LSPLocation {
            LSPLocation(uri: uri, range: LSPRange(
                start: LSPPosition(line: line0, character: 0),
                end: LSPPosition(line: line0, character: 1)))
        }
        // 1-basing + non-file skip.
        let mixed = CodeNav.navLocations(from: [
            loc("file:///a.swift", 0),
            loc("untitled:scratch", 3),   // non-file: skipped, not truncation
            loc("file:///b.swift", 9),
        ])
        XCTAssertEqual(mixed.locations, [
            CodeNav.Location(path: "/a.swift", line: 1),
            CodeNav.Location(path: "/b.swift", line: 10),
        ])
        XCTAssertFalse(mixed.truncated, "skipped URIs are not truncation")

        // The cap: 200 kept, the 201st real result flags truncation.
        let many = (0..<(CodeNav.maxCallers + 1)).map { loc("file:///f\($0).swift", $0) }
        let capped = CodeNav.navLocations(from: many)
        XCTAssertEqual(capped.locations.count, CodeNav.maxCallers)
        XCTAssertTrue(capped.truncated)
    }

    @MainActor
    func test_asyncLane_dispatchesPositionNav_1basedIn_0basedToHost() async throws {
        XCTAssertTrue(MCPToolCatalog.isAsyncTool("goto_definition"))
        XCTAssertTrue(MCPToolCatalog.isAsyncTool("find_references"))
        let fake = FakeAutomationHost()
        fake.navResult = CodeNav.NavLocations(
            locations: [CodeNav.Location(path: "/def.swift", line: 12)], truncated: false)
        let box = MCPToolCatalog.AsyncHostBox(fake)

        // goto_definition: the tool takes 1-based; the host must see 0-based.
        let value = try await MCPToolCatalog.dispatchAsync(
            name: "goto_definition",
            args: .object(["file": .string("/def.swift"), "line": .int(10), "column": .int(4)]),
            host: box)
        XCTAssertEqual(fake.navCall?.name, "definition")
        XCTAssertEqual(fake.navCall?.line, 9, "1-based tool input → 0-based LSP")
        XCTAssertEqual(fake.navCall?.character, 3)
        guard case .object(let o) = value else { return XCTFail("object result") }
        XCTAssertEqual(o["count"], .int(1))
        XCTAssertEqual(o["locations"], .array([.string("/def.swift:12")]))

        // find_references routes to the references hook.
        _ = try await MCPToolCatalog.dispatchAsync(
            name: "find_references",
            args: .object(["file": .string("/def.swift"), "line": .int(1), "column": .int(1)]),
            host: box)
        XCTAssertEqual(fake.navCall?.name, "references")

        // 0/negative positions are invalid params, not a silent off-by-one.
        do {
            _ = try await MCPToolCatalog.dispatchAsync(
                name: "goto_definition",
                args: .object(["file": .string("/x"), "line": .int(0), "column": .int(1)]),
                host: box)
            XCTFail("0-based input must be rejected")
        } catch let e as MCPError {
            XCTAssertTrue(e.message.contains("1-based"), "hint: \(e.message)")
        }

        // The no-server miss path carries the actionable hint.
        fake.navResult = nil
        do {
            _ = try await MCPToolCatalog.dispatchAsync(
                name: "find_references",
                args: .object(["file": .string("/x.zig"), "line": .int(1), "column": .int(1)]),
                host: box)
            XCTFail("no-server must throw")
        } catch let e as MCPError {
            XCTAssertTrue(e.message.contains("language server"), "hint: \(e.message)")
        }
    }

    // MARK: - TSK-1561: rename_symbol (dry-run default)

    func test_renameSummary_fileURIsOnly_sortedByPath() {
        let edit: [String: [LSPTextEdit]] = [
            "file:///z.swift": [makeEdit(), makeEdit()],
            "file:///a.swift": [makeEdit()],
            "untitled:scratch": [makeEdit()],   // non-file: dropped
            "file:///empty.swift": [],          // no edits: dropped
        ]
        let summary = CodeNav.renameSummary(from: edit)
        XCTAssertEqual(summary, [
            CodeNav.RenameOutcome.FileEdits(path: "/a.swift", editCount: 1),
            CodeNav.RenameOutcome.FileEdits(path: "/z.swift", editCount: 2),
        ])
    }

    private func makeEdit() -> LSPTextEdit {
        LSPTextEdit(
            range: LSPRange(start: LSPPosition(line: 0, character: 0),
                            end: LSPPosition(line: 0, character: 1)),
            newText: "x")
    }

    @MainActor
    func test_renameSymbol_dryRunByDefault_applyPassesThrough_blankNameRejected() async throws {
        XCTAssertTrue(MCPToolCatalog.isAsyncTool("rename_symbol"))
        let fake = FakeAutomationHost()
        fake.renameResult = CodeNav.RenameOutcome(
            files: [.init(path: "/a.swift", editCount: 3)], applied: false)
        let box = MCPToolCatalog.AsyncHostBox(fake)

        // DRY-RUN is the default: no `apply` arg → host sees apply=false.
        let value = try await MCPToolCatalog.dispatchAsync(
            name: "rename_symbol",
            args: .object(["file": .string("/a.swift"), "line": .int(5),
                           "column": .int(2), "new_name": .string("renamed")]),
            host: box)
        XCTAssertEqual(fake.renameCall?.apply, false, "dry-run is the DEFAULT")
        XCTAssertEqual(fake.renameCall?.line, 4, "1-based tool input → 0-based LSP")
        XCTAssertEqual(fake.renameCall?.newName, "renamed")
        guard case .object(let o) = value else { return XCTFail("object result") }
        XCTAssertEqual(o["applied"], .bool(false))
        XCTAssertEqual(o["totalEdits"], .int(3))
        XCTAssertNil(o["appliedFiles"], "dry-run carries no applied/skipped lists")

        // apply:true passes through and the payload carries both lists.
        fake.renameResult = CodeNav.RenameOutcome(
            files: [.init(path: "/a.swift", editCount: 3)], applied: true,
            appliedPaths: ["/a.swift"], skippedPaths: ["/closed.swift"])
        let appliedValue = try await MCPToolCatalog.dispatchAsync(
            name: "rename_symbol",
            args: .object(["file": .string("/a.swift"), "line": .int(1), "column": .int(1),
                           "new_name": .string("renamed"), "apply": .bool(true)]),
            host: box)
        XCTAssertEqual(fake.renameCall?.apply, true)
        guard case .object(let a) = appliedValue else { return XCTFail("object result") }
        XCTAssertEqual(a["appliedFiles"], .array([.string("/a.swift")]))
        XCTAssertEqual(a["skippedFiles"], .array([.string("/closed.swift")]),
                       "unopened files are REPORTED, never silently dropped")

        // A blank new_name is invalid params, before any host call.
        fake.renameCall = nil
        do {
            _ = try await MCPToolCatalog.dispatchAsync(
                name: "rename_symbol",
                args: .object(["file": .string("/a.swift"), "line": .int(1), "column": .int(1),
                               "new_name": .string("   ")]),
                host: box)
            XCTFail("blank new_name must be rejected")
        } catch let e as MCPError {
            XCTAssertTrue(e.message.contains("non-blank"), "hint: \(e.message)")
            XCTAssertNil(fake.renameCall, "rejected before reaching the host")
        }
    }
}
