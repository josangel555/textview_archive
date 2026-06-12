import XCTest
@testable import ViewerCore

/// `textDocument/rename` (TSK-640 stage 1): WorkspaceEdit decode in both
/// spec forms, malformed-input tolerance, and the full pipeline against
/// the fake server — request → decode → `LSPTextEditApplier` (the
/// formatting path's proven applier; multi-edit reverse application).
final class LSPRenameTests: XCTestCase {

    // MARK: - decodeWorkspaceEdit (pure decode)

    private func decode(_ json: String) -> [String: [LSPTextEdit]] {
        LSPClient.decodeWorkspaceEdit(Data(json.utf8))
    }

    func test_decode_changesMap_form() {
        let out = decode("""
        { "changes": {
            "file:///a.swift": [
              { "range": { "start": { "line": 0, "character": 1 },
                           "end":   { "line": 0, "character": 3 } },
                "newText": "x" }
            ],
            "file:///b.swift": [
              { "range": { "start": { "line": 2, "character": 0 },
                           "end":   { "line": 2, "character": 4 } },
                "newText": "y" },
              { "range": { "start": { "line": 5, "character": 1 },
                           "end":   { "line": 5, "character": 2 } },
                "newText": "y" }
            ]
        } }
        """)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out["file:///a.swift"]?.count, 1)
        XCTAssertEqual(out["file:///a.swift"]?.first?.newText, "x")
        XCTAssertEqual(out["file:///a.swift"]?.first?.range.start.line, 0)
        XCTAssertEqual(out["file:///a.swift"]?.first?.range.end.character, 3)
        XCTAssertEqual(out["file:///b.swift"]?.count, 2)
    }

    func test_decode_documentChanges_form() {
        // The TextDocumentEdit array form (versions ignored — we re-read
        // before applying).
        let out = decode("""
        { "documentChanges": [
            { "textDocument": { "uri": "file:///c.swift", "version": 7 },
              "edits": [
                { "range": { "start": { "line": 1, "character": 0 },
                             "end":   { "line": 1, "character": 3 } },
                  "newText": "z" }
              ] }
        ] }
        """)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out["file:///c.swift"]?.count, 1)
        XCTAssertEqual(out["file:///c.swift"]?.first?.newText, "z")
    }

    func test_decode_mergesBothForms_sameURI() {
        // A server mixing both forms for one uri must append, not clobber.
        let out = decode("""
        { "changes": {
            "file:///d.swift": [
              { "range": { "start": { "line": 0, "character": 0 },
                           "end":   { "line": 0, "character": 1 } },
                "newText": "p" } ] },
          "documentChanges": [
            { "textDocument": { "uri": "file:///d.swift" },
              "edits": [
                { "range": { "start": { "line": 3, "character": 0 },
                             "end":   { "line": 3, "character": 1 } },
                  "newText": "q" } ] }
        ] }
        """)
        XCTAssertEqual(out["file:///d.swift"]?.count, 2)
        XCTAssertEqual(out["file:///d.swift"]?.map(\.newText).sorted(), ["p", "q"])
    }

    func test_decode_malformedEntries_drop() {
        // Missing newText, missing range, edits-not-an-array, and a
        // documentChanges entry without textDocument — all drop without
        // poisoning the valid sibling.
        let out = decode("""
        { "changes": {
            "file:///bad1.swift": [ { "newText": "no-range" } ],
            "file:///bad2.swift": [ { "range": { "start": { "line": 0, "character": 0 },
                                                 "end":   { "line": 0, "character": 1 } } } ],
            "file:///bad3.swift": "not-an-array",
            "file:///good.swift": [
              { "range": { "start": { "line": 0, "character": 0 },
                           "end":   { "line": 0, "character": 2 } },
                "newText": "ok" } ]
          },
          "documentChanges": [ { "edits": [] }, 42 ]
        }
        """)
        XCTAssertEqual(out.count, 1, "only the well-formed uri survives: \(out.keys)")
        XCTAssertEqual(out["file:///good.swift"]?.first?.newText, "ok")
    }

    func test_decode_nonObject_and_null_returnEmpty() {
        XCTAssertTrue(decode("null").isEmpty)
        XCTAssertTrue(decode("[1,2]").isEmpty)
        XCTAssertTrue(decode("not json at all").isEmpty)
        XCTAssertTrue(decode("{}").isEmpty)
    }

    // MARK: - End-to-end: fake server → decode → applier

    func test_rename_endToEnd_throughApplier() async throws {
        let (cfg, root) = try FakeLSPServerHelper.makeConfig()
        defer { FakeLSPServerHelper.cleanup(root) }
        let client = try LSPClient(config: cfg)
        try await client.initialize()

        let url = URL(fileURLWithPath: "/fake/x.swift")
        let edits = try await client.rename(
            url: url, line: 0, character: 4, newName: "renamed")
        XCTAssertEqual(edits.count, 1)
        let fileEdits = try XCTUnwrap(edits[url.absoluteString],
            "fixture renames within the requested file's uri")
        XCTAssertEqual(fileEdits.count, 2, "fixture returns two edits")
        XCTAssertTrue(fileEdits.allSatisfy { $0.newText == "renamed" })

        // Apply through the SHIPPING applier: line 0 chars 4–7 and
        // line 2 chars 8–11 are both "foo" in this document. Two edits
        // in one response prove reverse-order application holds.
        let original = """
        let foo = 1
        let unrelated = 2
        let y = foo
        """
        let applied = LSPTextEditApplier.apply(
            fileEdits, to: original, encoding: .utf16)
        XCTAssertEqual(applied, """
        let renamed = 1
        let unrelated = 2
        let y = renamed
        """)
        await client.shutdown()
    }

    func test_rename_beforeInitialize_throwsNotInitialized() async throws {
        let (cfg, root) = try FakeLSPServerHelper.makeConfig()
        defer { FakeLSPServerHelper.cleanup(root) }
        let client = try LSPClient(config: cfg)
        do {
            _ = try await client.rename(
                url: URL(fileURLWithPath: "/fake/x.swift"),
                line: 0, character: 0, newName: "n")
            XCTFail("rename before initialize must throw notInitialized")
        } catch LSPError.notInitialized {
            // expected
        }
        await client.shutdown()
    }
}
