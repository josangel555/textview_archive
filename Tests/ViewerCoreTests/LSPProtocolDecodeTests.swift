import XCTest
@testable import ViewerCore

/// Decode-side tests for the polymorphic LSP unions we care about
/// in the PoC. No subprocess — feeds canned JSON bytes directly to
/// `LSPClient.decodeHover` / `decodeDefinition`.
final class LSPProtocolDecodeTests: XCTestCase {

    // MARK: Hover

    func test_hover_markupContentMarkdown() {
        let data = Data(#"""
        {"contents":{"kind":"markdown","value":"`Foo` — a thing"},"range":{"start":{"line":1,"character":2},"end":{"line":1,"character":5}}}
        """#.utf8)
        let h = LSPClient.decodeHover(data)
        XCTAssertNotNil(h)
        XCTAssertEqual(h?.contents, "`Foo` — a thing")
        XCTAssertTrue(h!.isMarkdown)
        XCTAssertEqual(h?.range?.start.line, 1)
        XCTAssertEqual(h?.range?.end.character, 5)
    }

    func test_hover_plainStringContents() {
        let data = Data(#"{"contents":"raw text"}"#.utf8)
        let h = LSPClient.decodeHover(data)
        XCTAssertEqual(h?.contents, "raw text")
        XCTAssertEqual(h?.isMarkdown, false)
    }

    func test_hover_markedStringWithLanguage_wrapsInFencedBlock() {
        let data = Data(#"{"contents":{"language":"swift","value":"let x = 1"}}"#.utf8)
        let h = LSPClient.decodeHover(data)
        XCTAssertEqual(h?.contents, "```swift\nlet x = 1\n```")
        XCTAssertEqual(h?.isMarkdown, true)
    }

    func test_hover_emptyResultReturnsNil() {
        let data = Data(#"null"#.utf8)
        XCTAssertNil(LSPClient.decodeHover(data))
    }

    // MARK: Definition

    func test_definition_null() {
        XCTAssertEqual(LSPClient.decodeDefinition(Data("null".utf8)), [])
    }

    func test_definition_singleLocation() {
        let data = Data(#"""
        {"uri":"file:///a.swift","range":{"start":{"line":3,"character":4},"end":{"line":3,"character":7}}}
        """#.utf8)
        let locs = LSPClient.decodeDefinition(data)
        XCTAssertEqual(locs.count, 1)
        XCTAssertEqual(locs.first?.uri, "file:///a.swift")
        XCTAssertEqual(locs.first?.range.start.line, 3)
    }

    func test_definition_arrayOfLocations() {
        let data = Data(#"""
        [{"uri":"file:///a.swift","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":3}}},
         {"uri":"file:///b.swift","range":{"start":{"line":9,"character":2},"end":{"line":9,"character":5}}}]
        """#.utf8)
        let locs = LSPClient.decodeDefinition(data)
        XCTAssertEqual(locs.count, 2)
        XCTAssertEqual(locs[1].uri, "file:///b.swift")
        XCTAssertEqual(locs[1].range.end.character, 5)
    }

    func test_definition_locationLinkShape_usesTargetSelectionRange() {
        // LocationLink (per LSP 3.17): `targetUri` + `targetRange` +
        // `targetSelectionRange`. We prefer `targetSelectionRange`.
        let data = Data(#"""
        [{"targetUri":"file:///c.swift",
          "originSelectionRange":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},
          "targetRange":{"start":{"line":10,"character":0},"end":{"line":12,"character":0}},
          "targetSelectionRange":{"start":{"line":10,"character":4},"end":{"line":10,"character":9}}}]
        """#.utf8)
        let locs = LSPClient.decodeDefinition(data)
        XCTAssertEqual(locs.count, 1)
        XCTAssertEqual(locs[0].uri, "file:///c.swift")
        XCTAssertEqual(locs[0].range.start.line, 10)
        XCTAssertEqual(locs[0].range.start.character, 4)
    }

    func test_definition_emptyArray() {
        XCTAssertEqual(LSPClient.decodeDefinition(Data("[]".utf8)), [])
    }
}
