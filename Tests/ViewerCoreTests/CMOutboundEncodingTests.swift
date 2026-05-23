import XCTest
@testable import ViewerCore

/// Round-trip tests for the Swift → JS encoder. Each test encodes a
/// `CMOutboundMessage`, parses the result back via JSONSerialization,
/// and checks the envelope + payload fields. These are what the JS
/// side's `cmDispatch` switch will eat at runtime.
///
/// We can't run actual JS here on the host (per CLAUDE.md), but every
/// payload shape is exercised so that a JS-side regression in field
/// names surfaces at the boundary instead of as a silent no-op in the
/// WebView.
final class CMOutboundEncodingTests: XCTestCase {

    private func encodeAndParse(_ m: CMOutboundMessage) -> [String: Any] {
        let raw = CMBridgeCodec.encodeOutboundJSON(m)
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("Encoded JSON didn't parse: \(raw)")
            return [:]
        }
        XCTAssertEqual(dict["v"] as? Int, CMProtocol.currentVersion,
                       "every outbound message must stamp v=1")
        XCTAssertNotNil(dict["type"] as? String,
                        "every outbound message must carry `type`")
        return dict
    }

    // MARK: - Text mutations

    func testEncodeSetTextWithFlags() {
        let d = encodeAndParse(.setText(
            text: "hello", resetHistory: true, preserveSelection: false
        ))
        XCTAssertEqual(d["type"] as? String, "setText")
        XCTAssertEqual(d["text"] as? String, "hello")
        XCTAssertEqual(d["resetHistory"] as? Bool, true)
        XCTAssertEqual(d["preserveSelection"] as? Bool, false)
    }

    func testEncodeSetTextHandlesAwkwardCharacters() {
        // The encoder must produce valid JSON even when the doc contains
        // quotes / backslashes / control chars. Foundation does the
        // escaping; this just guards against a future hand-rolled
        // shortcut that breaks it.
        let weird = "a\"b\\c\n<script>alert(1)</script>"
        let d = encodeAndParse(.setText(text: weird, resetHistory: false, preserveSelection: true))
        XCTAssertEqual(d["text"] as? String, weird)
    }

    func testEncodeAppendText() {
        let d = encodeAndParse(.appendText(text: "more"))
        XCTAssertEqual(d["type"] as? String, "appendText")
        XCTAssertEqual(d["text"] as? String, "more")
    }

    func testEncodeReplaceRange() {
        let d = encodeAndParse(.replaceRange(from: 10, to: 20, insert: "x", version: 3))
        XCTAssertEqual(d["type"] as? String, "replaceRange")
        XCTAssertEqual(d["from"] as? Int, 10)
        XCTAssertEqual(d["to"] as? Int, 20)
        XCTAssertEqual(d["insert"] as? String, "x")
        XCTAssertEqual(d["version"] as? Int, 3)
    }

    // MARK: - Configuration

    func testEncodeSetLanguage() {
        let d = encodeAndParse(.setLanguage("python"))
        XCTAssertEqual(d["type"] as? String, "setLanguage")
        XCTAssertEqual(d["lang"] as? String, "python")
    }

    func testEncodeSetTheme() {
        let d = encodeAndParse(.setTheme(name: "dark"))
        XCTAssertEqual(d["type"] as? String, "setTheme")
        XCTAssertEqual(d["name"] as? String, "dark")
    }

    func testEncodeSetFontSize() {
        let d = encodeAndParse(.setFontSize(15))
        XCTAssertEqual(d["type"] as? String, "setFontSize")
        XCTAssertEqual(d["px"] as? Int, 15)
    }

    func testEncodeSetWordWrap() {
        let d = encodeAndParse(.setWordWrap(false))
        XCTAssertEqual(d["type"] as? String, "setWordWrap")
        XCTAssertEqual(d["enabled"] as? Bool, false)
    }

    func testEncodeSetReadOnly() {
        let d = encodeAndParse(.setReadOnly(true))
        XCTAssertEqual(d["type"] as? String, "setReadOnly")
        XCTAssertEqual(d["enabled"] as? Bool, true)
    }

    func testEncodeSetLineNumbers() {
        let d = encodeAndParse(.setLineNumbers(false))
        XCTAssertEqual(d["type"] as? String, "setLineNumbers")
        XCTAssertEqual(d["enabled"] as? Bool, false)
    }

    func testEncodeSetIndentationSpaces() {
        let d = encodeAndParse(.setIndentation(useTabs: false, size: 4))
        XCTAssertEqual(d["type"] as? String, "setIndentation")
        XCTAssertEqual(d["useTabs"] as? Bool, false)
        XCTAssertEqual(d["size"] as? Int, 4)
    }

    func testEncodeSetIndentationTabs() {
        let d = encodeAndParse(.setIndentation(useTabs: true, size: 8))
        XCTAssertEqual(d["useTabs"] as? Bool, true)
        XCTAssertEqual(d["size"] as? Int, 8)
    }

    // MARK: - Navigation

    func testEncodeGotoLineWithoutColumn() {
        let d = encodeAndParse(.gotoLine(line: 42, column: nil, select: false))
        XCTAssertEqual(d["type"] as? String, "gotoLine")
        XCTAssertEqual(d["line"] as? Int, 42)
        XCTAssertNil(d["column"], "column omitted when nil to keep payload tight")
        XCTAssertEqual(d["select"] as? Bool, false)
    }

    func testEncodeGotoLineWithColumnAndSelect() {
        let d = encodeAndParse(.gotoLine(line: 12, column: 4, select: true))
        XCTAssertEqual(d["column"] as? Int, 4)
        XCTAssertEqual(d["select"] as? Bool, true)
    }

    func testEncodeSetSelection() {
        let d = encodeAndParse(.setSelection(anchor: 5, head: 12, scroll: true))
        XCTAssertEqual(d["type"] as? String, "setSelection")
        XCTAssertEqual(d["anchor"] as? Int, 5)
        XCTAssertEqual(d["head"] as? Int, 12)
        XCTAssertEqual(d["scroll"] as? Bool, true)
    }

    // MARK: - Find / replace

    func testEncodeOpenSearchWithQuery() {
        let d = encodeAndParse(.openSearch(query: "foo", replace: true))
        XCTAssertEqual(d["type"] as? String, "openSearch")
        XCTAssertEqual(d["query"] as? String, "foo")
        XCTAssertEqual(d["replace"] as? Bool, true)
    }

    func testEncodeOpenSearchWithoutQuery() {
        let d = encodeAndParse(.openSearch(query: nil, replace: false))
        XCTAssertNil(d["query"])
        XCTAssertEqual(d["replace"] as? Bool, false)
    }

    func testEncodeVoidCommands() {
        for (msg, expected) in [
            (CMOutboundMessage.closeSearch,  "closeSearch"),
            (.findNext,     "findNext"),
            (.findPrev,     "findPrev"),
            (.replaceNext,  "replaceNext"),
            (.replaceAll,   "replaceAll"),
            (.foldAll,      "foldAll"),
            (.unfoldAll,    "unfoldAll"),
            (.undo,         "undo"),
            (.redo,         "redo"),
            (.focus,        "focus"),
            (.flushChanges, "flushChanges"),
        ] {
            let d = encodeAndParse(msg)
            XCTAssertEqual(d["type"] as? String, expected,
                           "wrong type for \(msg)")
            // Void commands carry no payload beyond `v` + `type`.
            XCTAssertEqual(d.count, 2, "\(msg) emitted extra fields: \(d.keys)")
        }
    }

    // MARK: - Request/reply

    func testEncodeGetDocument() {
        let d = encodeAndParse(.getDocument(replyId: "r-1"))
        XCTAssertEqual(d["type"] as? String, "getDocument")
        XCTAssertEqual(d["replyId"] as? String, "r-1")
    }

    func testEncodeGetSelectionAndScroll() {
        let d1 = encodeAndParse(.getSelection(replyId: "r-2"))
        XCTAssertEqual(d1["type"] as? String, "getSelection")
        XCTAssertEqual(d1["replyId"] as? String, "r-2")
        let d2 = encodeAndParse(.getScrollPosition(replyId: "r-3"))
        XCTAssertEqual(d2["type"] as? String, "getScrollPosition")
        XCTAssertEqual(d2["replyId"] as? String, "r-3")
    }

    // MARK: - JSON safety

    func testEncodedJSONIsAlwaysValid() {
        // Sample one of each kind through the JSON parser. Catches a
        // future regression where an encoder branch forgets to wrap a
        // string and emits raw text.
        let samples: [CMOutboundMessage] = [
            .setText(text: "x", resetHistory: false, preserveSelection: true),
            .setLanguage("javascript"),
            .gotoLine(line: 1, column: nil, select: false),
            .setIndentation(useTabs: true, size: 4),
            .openSearch(query: nil, replace: false),
        ]
        for m in samples {
            let raw = CMBridgeCodec.encodeOutboundJSON(m)
            XCTAssertNotNil(raw.data(using: .utf8))
            let parsed = try? JSONSerialization.jsonObject(
                with: raw.data(using: .utf8)!
            ) as? [String: Any]
            XCTAssertNotNil(parsed, "produced invalid JSON for \(m): \(raw)")
        }
    }
}
