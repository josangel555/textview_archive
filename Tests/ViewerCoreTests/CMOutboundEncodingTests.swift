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
        let d = encodeAndParse(.setTheme(name: "dark", palette: nil))
        XCTAssertEqual(d["type"] as? String, "setTheme")
        XCTAssertEqual(d["name"] as? String, "dark")
        XCTAssertNil(d["palette"], "nil palette must omit the key (stale-bundle compat)")
    }

    /// TSK-602: the SyntaxTheme-derived palette rides setTheme so the
    /// CM6 editor colors match the ViewOnly source view.
    func testEncodeSetTheme_withPalette() {
        let d = encodeAndParse(.setTheme(
            name: "light",
            palette: ["keyword": "#AD3DA4", "background": "#FFFFFF"]))
        XCTAssertEqual(d["type"] as? String, "setTheme")
        let palette = d["palette"] as? [String: String]
        XCTAssertEqual(palette?["keyword"], "#AD3DA4")
        XCTAssertEqual(palette?["background"], "#FFFFFF")
    }

    func testEncodeSetFontSize() {
        // TSK-1151: px rides as Double (fractional zoom, no Int rounding) and the
        // line-height multiple is carried for the CM6 scroller.
        let d = encodeAndParse(.setFontSize(px: 15.5, lineHeight: 1.2))
        XCTAssertEqual(d["type"] as? String, "setFontSize")
        XCTAssertEqual(d["px"] as? Double, 15.5)
        XCTAssertEqual(d["lineHeight"] as? Double, 1.2)
    }

    /// TSK-259 slice 2: the family rides when set; an explicit nil omits
    /// the key (the JS side reads absent/empty as "bundle default").
    func testEncodeSetFontFamily() {
        let d = encodeAndParse(.setFontFamily("Monaco"))
        XCTAssertEqual(d["type"] as? String, "setFontFamily")
        XCTAssertEqual(d["family"] as? String, "Monaco")
        let cleared = encodeAndParse(.setFontFamily(nil))
        XCTAssertEqual(cleared["type"] as? String, "setFontFamily")
        XCTAssertNil(cleared["family"],
                     "nil family must OMIT the key — JS restores the default stack")
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

    // MARK: - Phase 2: search query + diagnostics + invisibles

    func testEncodeSetSearchQuery() {
        let d = encodeAndParse(.setSearchQuery(
            query: "foo", caseSensitive: true, regex: false
        ))
        XCTAssertEqual(d["type"] as? String, "setSearchQuery")
        XCTAssertEqual(d["query"] as? String, "foo")
        XCTAssertEqual(d["caseSensitive"] as? Bool, true)
        XCTAssertEqual(d["regex"] as? Bool, false)
    }

    func testEncodeSetSearchQueryEmpty() {
        let d = encodeAndParse(.setSearchQuery(query: "", caseSensitive: false, regex: true))
        XCTAssertEqual(d["query"] as? String, "")
        XCTAssertEqual(d["regex"] as? Bool, true)
    }

    /// UX-G: find-and-replace seeds `SearchQuery.replace` through the
    /// same `setSearchQuery` envelope. The JS side reads `msg.replace`,
    /// so the field must always be present (default "" when find-only).
    func testEncodeSetSearchQueryCarriesReplace() {
        let d = encodeAndParse(.setSearchQuery(
            query: "foo", caseSensitive: false, regex: false, replace: "bar"
        ))
        XCTAssertEqual(d["query"] as? String, "foo")
        XCTAssertEqual(d["replace"] as? String, "bar")
    }

    func testEncodeSetSearchQueryReplaceDefaultsEmpty() {
        let d = encodeAndParse(.setSearchQuery(
            query: "foo", caseSensitive: false, regex: false
        ))
        XCTAssertEqual(d["replace"] as? String, "",
                       "replace must be present (empty) even in find-only mode")
    }

    func testEncodeSetShowInvisibles() {
        let d = encodeAndParse(.setShowInvisibles(true))
        XCTAssertEqual(d["type"] as? String, "setShowInvisibles")
        XCTAssertEqual(d["enabled"] as? Bool, true)
    }

    /// Vim mode (TSK-679). The JS host's `setVimMode` case reads `msg.enabled`
    /// to reconfigure the vimCompartment — the field name must stay in lockstep.
    func testEncodeSetVimMode() {
        let on = encodeAndParse(.setVimMode(true))
        XCTAssertEqual(on["type"] as? String, "setVimMode")
        XCTAssertEqual(on["enabled"] as? Bool, true)
        XCTAssertEqual(encodeAndParse(.setVimMode(false))["enabled"] as? Bool, false)
    }

    func testEncodeSetDiagnosticsEmpty() {
        let d = encodeAndParse(.setDiagnostics([]))
        XCTAssertEqual(d["type"] as? String, "setDiagnostics")
        let arr = d["diagnostics"] as? [[String: Any]]
        XCTAssertEqual(arr?.count, 0)
    }

    func testEncodeSetDiagnosticsRoundtrip() {
        let diags = [
            CMDiagnostic(
                from: 10, to: 14, severity: .error,
                message: "missing semicolon", source: "swift", code: "1"
            ),
            CMDiagnostic(
                from: 100, to: 105, severity: .warning,
                message: "unused", source: nil, code: nil
            ),
        ]
        let d = encodeAndParse(.setDiagnostics(diags))
        let arr = d["diagnostics"] as? [[String: Any]]
        XCTAssertEqual(arr?.count, 2)
        XCTAssertEqual(arr?[0]["from"] as? Int, 10)
        XCTAssertEqual(arr?[0]["to"] as? Int, 14)
        XCTAssertEqual(arr?[0]["severity"] as? String, "error")
        XCTAssertEqual(arr?[0]["message"] as? String, "missing semicolon")
        XCTAssertEqual(arr?[0]["source"] as? String, "swift")
        XCTAssertEqual(arr?[0]["code"] as? String, "1")
        XCTAssertEqual(arr?[1]["severity"] as? String, "warning")
        XCTAssertNil(arr?[1]["source"], "source omitted when nil")
        XCTAssertNil(arr?[1]["code"], "code omitted when nil")
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

    // MARK: - Phase 2 large-file cap

    func testCodeMirrorEditorCapMatchesDesignDoc() {
        // Design doc §17.5 + BACKLOG: "50 MB hard cap" for CM6 editor
        // mode. Lock the constant so a casual bump (which would push
        // JS-heap pressure into pathology territory on the user's box)
        // requires editing this test too.
        XCTAssertEqual(codeMirrorEditorMaxBytes, 50 * 1024 * 1024)
        XCTAssertGreaterThan(codeMirrorEditorMaxBytes, markdownRenderMaxBytes,
                             "editor cap must be ≥ rendered cap")
    }

    // MARK: - Phase 3 additions

    func testEncodeHoverResponse() {
        let d = encodeAndParse(.hoverResponse(
            replyId: "h-7", contents: "**Foo** docs", from: 10, to: 25))
        XCTAssertEqual(d["type"] as? String, "hoverResponse")
        XCTAssertEqual(d["replyId"] as? String, "h-7")
        XCTAssertEqual(d["contents"] as? String, "**Foo** docs")
        XCTAssertEqual(d["from"] as? Int, 10)
        XCTAssertEqual(d["to"] as? Int, 25)
    }

    func testEncodeHoverResponseEmptyContentsDismisses() {
        // Empty contents = JS dismisses the popover. Encoder should
        // still ship the string field (not omit it), otherwise the
        // JS-side `String(msg.contents || "")` works but a future
        // strict-decode would break.
        let d = encodeAndParse(.hoverResponse(
            replyId: "h-8", contents: "", from: 0, to: 0))
        XCTAssertEqual(d["contents"] as? String, "")
    }

    func testEncodeSetSaveOnBlur() {
        let d = encodeAndParse(.setSaveOnBlur(enabled: true))
        XCTAssertEqual(d["type"] as? String, "setSaveOnBlur")
        XCTAssertEqual(d["enabled"] as? Bool, true)
    }

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
            .hoverResponse(replyId: "h-1", contents: "doc", from: 0, to: 3),
            .setSaveOnBlur(enabled: false),
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
