import XCTest
@testable import ViewerCore

/// Decode-side tests for `textDocument/completion` (TSK-463) — the pure
/// LSP-response → completion-items mapping. No subprocess: canned JSON
/// bytes feed `LSPClient.decodeCompletion` directly. Covers all three
/// result shapes (null / bare array / CompletionList), insert-text spec
/// precedence (textEdit > insertText > label), snippet detection, the
/// `isIncomplete` re-request flag, documentation flattening, and the
/// per-item drop-on-malformed tolerance.
///
/// These pin the BEHAVIOUR the editor wiring depends on, so a regression
/// in the mapping fails the host gate even though the popup pixels are
/// VM-only.
final class LSPCompletionDecodeTests: XCTestCase {

    // MARK: Result-shape polymorphism

    func test_null_result_isEmptyAndComplete() {
        let list = LSPClient.decodeCompletion(Data("null".utf8))
        XCTAssertFalse(list.isIncomplete)
        XCTAssertEqual(list.items.count, 0)
    }

    func test_garbage_result_isEmpty() {
        XCTAssertEqual(LSPClient.decodeCompletion(Data("not json".utf8)).items.count, 0)
        XCTAssertEqual(LSPClient.decodeCompletion(Data("42".utf8)).items.count, 0)
        XCTAssertEqual(LSPClient.decodeCompletion(Data(#""string""#.utf8)).items.count, 0)
    }

    func test_bareItemArray_defaultsToComplete() {
        let data = Data(#"""
        [
            {"label":"append","kind":2},
            {"label":"appending","kind":2}
        ]
        """#.utf8)
        let list = LSPClient.decodeCompletion(data)
        XCTAssertFalse(list.isIncomplete, "bare array ⇒ isIncomplete:false")
        XCTAssertEqual(list.items.map(\.label), ["append", "appending"])
        XCTAssertEqual(list.items[0].kind, .method)
    }

    func test_completionList_honorsIsIncomplete() {
        let data = Data(#"""
        {"isIncomplete":true,"items":[{"label":"foo"}]}
        """#.utf8)
        let list = LSPClient.decodeCompletion(data)
        XCTAssertTrue(list.isIncomplete,
                      "isIncomplete:true must propagate — UI re-requests, not just filters")
        XCTAssertEqual(list.items.count, 1)
    }

    func test_completionList_isIncompleteAbsent_defaultsFalse() {
        let data = Data(#"{"items":[{"label":"x"}]}"#.utf8)
        XCTAssertFalse(LSPClient.decodeCompletion(data).isIncomplete)
    }

    // MARK: insert-text spec precedence (textEdit > insertText > label)

    func test_insert_fallsBackToLabel_whenNoEditNoInsertText() {
        let data = Data(#"[{"label":"println"}]"#.utf8)
        let item = LSPClient.decodeCompletion(data).items[0]
        XCTAssertEqual(item.insert, "println")
        XCTAssertNil(item.editRange, "no textEdit ⇒ caret insertion (nil range)")
    }

    func test_insertText_overridesLabel() {
        let data = Data(#"[{"label":"foo (deprecated)","insertText":"foo"}]"#.utf8)
        let item = LSPClient.decodeCompletion(data).items[0]
        XCTAssertEqual(item.label, "foo (deprecated)")
        XCTAssertEqual(item.insert, "foo", "insertText wins over label")
        XCTAssertNil(item.editRange)
    }

    func test_textEdit_overridesInsertTextAndCarriesRange() {
        let data = Data(#"""
        [{
            "label":"description",
            "insertText":"WRONG",
            "textEdit":{
                "range":{"start":{"line":3,"character":4},"end":{"line":3,"character":8}},
                "newText":"description"
            }
        }]
        """#.utf8)
        let item = LSPClient.decodeCompletion(data).items[0]
        XCTAssertEqual(item.insert, "description",
                       "textEdit.newText wins over insertText")
        XCTAssertEqual(item.editRange?.start.line, 3)
        XCTAssertEqual(item.editRange?.start.character, 4)
        XCTAssertEqual(item.editRange?.end.character, 8)
    }

    func test_insertReplaceEdit_prefersReplaceRange() {
        // InsertReplaceEdit shape: no `range`, has `insert` + `replace`.
        // We prefer `replace` (the full span the item supersedes).
        let data = Data(#"""
        [{
            "label":"value",
            "textEdit":{
                "newText":"value",
                "insert":{"start":{"line":1,"character":0},"end":{"line":1,"character":2}},
                "replace":{"start":{"line":1,"character":0},"end":{"line":1,"character":5}}
            }
        }]
        """#.utf8)
        let item = LSPClient.decodeCompletion(data).items[0]
        XCTAssertEqual(item.insert, "value")
        XCTAssertEqual(item.editRange?.end.character, 5,
                       "InsertReplaceEdit ⇒ use the wider `replace` span")
    }

    func test_emptyResolvedInsert_isDropped() {
        // A server quirk: empty newText AND empty insertText AND empty
        // label would commit nothing — drop it. (label empty also drops
        // up front, so test the textEdit-empty path with a real label
        // that still resolves to label, plus an all-empty item.)
        let data = Data(#"""
        [
            {"label":"keep","textEdit":{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":""}},
            {"label":""}
        ]
        """#.utf8)
        let items = LSPClient.decodeCompletion(data).items
        // First item: empty newText ⇒ falls back to label "keep".
        // Second item: empty label ⇒ dropped.
        XCTAssertEqual(items.map(\.label), ["keep"])
        XCTAssertEqual(items[0].insert, "keep")
    }

    // MARK: snippet / kind / filter / sort / documentation

    func test_snippetFlag_setWhenInsertTextFormatIsTwo() {
        let data = Data(#"""
        [
            {"label":"for","insertText":"for ${1:i} in ${2:seq}","insertTextFormat":2},
            {"label":"plain","insertText":"plain","insertTextFormat":1},
            {"label":"default"}
        ]
        """#.utf8)
        let items = LSPClient.decodeCompletion(data).items
        XCTAssertTrue(items[0].isSnippet, "insertTextFormat:2 ⇒ snippet")
        XCTAssertFalse(items[1].isSnippet, "insertTextFormat:1 ⇒ plaintext")
        XCTAssertFalse(items[2].isSnippet, "absent ⇒ plaintext default")
    }

    func test_unknownKind_mapsToNil() {
        let data = Data(#"[{"label":"x","kind":999}]"#.utf8)
        let item = LSPClient.decodeCompletion(data).items[0]
        XCTAssertNil(item.kind, "unknown kind ⇒ nil (no crash, neutral icon)")
    }

    func test_filterAndSort_defaultToLabel() {
        let data = Data(#"[{"label":"alpha"}]"#.utf8)
        let item = LSPClient.decodeCompletion(data).items[0]
        XCTAssertEqual(item.filterText, "alpha")
        XCTAssertEqual(item.sortText, "alpha")
    }

    func test_filterAndSort_honoredWhenPresent() {
        let data = Data(#"""
        [{"label":"Foo.bar()","filterText":"bar","sortText":"0001"}]
        """#.utf8)
        let item = LSPClient.decodeCompletion(data).items[0]
        XCTAssertEqual(item.filterText, "bar")
        XCTAssertEqual(item.sortText, "0001")
    }

    func test_documentation_plainString() {
        let data = Data(#"[{"label":"x","documentation":"does a thing"}]"#.utf8)
        XCTAssertEqual(LSPClient.decodeCompletion(data).items[0].documentation, "does a thing")
    }

    func test_documentation_markupContent() {
        let data = Data(#"""
        [{"label":"x","documentation":{"kind":"markdown","value":"**bold** doc"}}]
        """#.utf8)
        XCTAssertEqual(LSPClient.decodeCompletion(data).items[0].documentation, "**bold** doc")
    }

    func test_documentation_absentIsNil() {
        let data = Data(#"[{"label":"x"}]"#.utf8)
        XCTAssertNil(LSPClient.decodeCompletion(data).items[0].documentation)
    }

    func test_detail_decoded() {
        let data = Data(#"[{"label":"map","detail":"(transform:) -> [T]"}]"#.utf8)
        XCTAssertEqual(LSPClient.decodeCompletion(data).items[0].detail, "(transform:) -> [T]")
    }

    // MARK: per-item tolerance

    func test_malformedItem_dropsAlone_notTheWholeList() {
        let data = Data(#"""
        [
            {"label":"good"},
            "not an object",
            {"kind":2},
            {"label":"alsoGood"}
        ]
        """#.utf8)
        let items = LSPClient.decodeCompletion(data).items
        XCTAssertEqual(items.map(\.label), ["good", "alsoGood"],
                       "non-object + label-less entries drop individually")
    }
}
