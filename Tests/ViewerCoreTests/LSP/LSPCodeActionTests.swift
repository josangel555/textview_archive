import XCTest
@testable import ViewerCore

/// `textDocument/codeAction` (TSK-640): decode of the spec's
/// `(Command | CodeAction)[]` union, the nested-WorkspaceEdit form, and
/// the client+pool round trip against the fake server.
final class LSPCodeActionTests: XCTestCase {

    // MARK: - decodeCodeActions (pure decode)

    private func decode(_ json: String) -> [LSPCodeAction] {
        LSPClient.decodeCodeActions(Data(json.utf8))
    }

    func test_decode_editBearingAction() {
        let out = decode("""
        [ { "title": "Fix it", "kind": "quickfix", "isPreferred": true,
            "edit": { "changes": { "file:///a.swift": [
              { "range": { "start": { "line": 0, "character": 0 },
                           "end":   { "line": 0, "character": 2 } },
                "newText": "ok" } ] } } } ]
        """)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.title, "Fix it")
        XCTAssertEqual(out.first?.kind, "quickfix")
        XCTAssertEqual(out.first?.isPreferred, true)
        XCTAssertEqual(out.first?.edit["file:///a.swift"]?.first?.newText, "ok")
    }

    func test_decode_commandOnly_andDocumentChangesForm() {
        let out = decode("""
        [ { "title": "Run cmd", "command": { "title": "c", "command": "x.y" } },
          { "title": "DC form",
            "edit": { "documentChanges": [
              { "textDocument": { "uri": "file:///b.swift" },
                "edits": [ { "range": { "start": { "line": 1, "character": 0 },
                                        "end":   { "line": 1, "character": 1 } },
                             "newText": "z" } ] } ] } } ]
        """)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].title, "Run cmd")
        XCTAssertTrue(out[0].edit.isEmpty, "command-only action carries no edit")
        XCTAssertEqual(out[1].edit["file:///b.swift"]?.count, 1)
    }

    func test_decode_malformed_drops() {
        let out = decode("""
        [ { "kind": "no-title-drops" },
          { "title": "ok-no-edit" },
          42 ]
        """)
        XCTAssertEqual(out.map(\.title), ["ok-no-edit"])
        XCTAssertTrue(decode("null").isEmpty)
        XCTAssertTrue(decode("{}").isEmpty)
    }

    // MARK: - Fake-server round trip (client)

    func test_codeActions_endToEnd_clientDecodesFixture() async throws {
        let (cfg, root) = try FakeLSPServerHelper.makeConfig()
        defer { FakeLSPServerHelper.cleanup(root) }
        let client = try LSPClient(config: cfg)
        try await client.initialize()
        let url = URL(fileURLWithPath: "/fake/x.swift")
        let pos = LSPPosition(line: 0, character: 1)
        let actions = try await client.codeActions(
            url: url, range: LSPRange(start: pos, end: pos))
        XCTAssertEqual(actions.count, 2, "fixture returns edit-bearing + command-only")
        let fix = try XCTUnwrap(actions.first { $0.title == "Fix the thing" })
        XCTAssertEqual(fix.kind, "quickfix")
        XCTAssertTrue(fix.isPreferred)
        XCTAssertEqual(fix.edit[url.absoluteString]?.first?.newText, "FIXED")
        let cmd = try XCTUnwrap(actions.first { $0.title == "Run a server command" })
        XCTAssertTrue(cmd.edit.isEmpty)
        await client.shutdown()
    }
}
