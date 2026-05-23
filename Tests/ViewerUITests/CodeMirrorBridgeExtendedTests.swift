import XCTest
@testable import ViewerUI

/// Extended decoder tests for `CodeMirrorBridge.decode`.
///
/// The bridge is the single point of contact between JS and Swift —
/// any decode bug here either drops user keystrokes silently or
/// crashes the host app via a force-unwrap. The existing
/// `CodeMirrorBundleTests` cover positive paths for each known
/// action; this file extends with negative-case + forward-compat
/// coverage.
final class CodeMirrorBridgeExtendedTests: XCTestCase {

    // MARK: - Negative cases: malformed bodies

    func test_decode_nilType_returnsNil() {
        XCTAssertNil(CodeMirrorBridge.decode(["type": NSNull()]))
    }

    func test_decode_nonStringType_returnsNil() {
        XCTAssertNil(CodeMirrorBridge.decode(["type": 42]))
        XCTAssertNil(CodeMirrorBridge.decode(["type": ["nested": "dict"]]))
        XCTAssertNil(CodeMirrorBridge.decode(["type": NSNumber(value: 3.14)]))
    }

    func test_decode_emptyDictionary_returnsNil() {
        XCTAssertNil(CodeMirrorBridge.decode([String: Any]()))
    }

    func test_decode_emptyTypeString_returnsNil() {
        XCTAssertNil(CodeMirrorBridge.decode(["type": ""]))
    }

    func test_decode_arrayBody_returnsNil() {
        // JS could mistakenly pass an array — must not crash.
        XCTAssertNil(CodeMirrorBridge.decode([1, 2, 3] as [Any]))
        XCTAssertNil(CodeMirrorBridge.decode(["ready"] as [Any]))
    }

    func test_decode_stringBody_returnsNil() {
        XCTAssertNil(CodeMirrorBridge.decode("ready"))
    }

    func test_decode_numericBody_returnsNil() {
        XCTAssertNil(CodeMirrorBridge.decode(0))
        XCTAssertNil(CodeMirrorBridge.decode(-1))
        XCTAssertNil(CodeMirrorBridge.decode(NSNumber(value: 0)))
    }

    func test_decode_booleanBody_returnsNil() {
        XCTAssertNil(CodeMirrorBridge.decode(true))
        XCTAssertNil(CodeMirrorBridge.decode(false))
    }

    // MARK: - Change-action payload edge cases

    func test_decode_change_withNullText_treatsAsEmpty() {
        // Bridge documented behavior: missing/non-string text decodes
        // to empty document, never crashes the host.
        XCTAssertEqual(
            CodeMirrorBridge.decode(["type": "change", "text": NSNull()]),
            .change(text: "")
        )
    }

    func test_decode_change_withNumericText_treatsAsEmpty() {
        XCTAssertEqual(
            CodeMirrorBridge.decode(["type": "change", "text": 42]),
            .change(text: "")
        )
    }

    func test_decode_change_withArrayText_treatsAsEmpty() {
        XCTAssertEqual(
            CodeMirrorBridge.decode(["type": "change", "text": ["a", "b"]]),
            .change(text: "")
        )
    }

    func test_decode_change_withUnicodeText_roundTrips() {
        let payload = "héllo 🌟 — café\nwith\ttabs and 漢字"
        XCTAssertEqual(
            CodeMirrorBridge.decode(["type": "change", "text": payload]),
            .change(text: payload)
        )
    }

    func test_decode_change_withEmptyString_isEmpty() {
        XCTAssertEqual(
            CodeMirrorBridge.decode(["type": "change", "text": ""]),
            .change(text: "")
        )
    }

    func test_decode_change_withVeryLargeText_doesNotTruncate() {
        // 1 MB string — bridge must not silently cap.
        let payload = String(repeating: "x", count: 1_048_576)
        guard case let .change(text) = CodeMirrorBridge.decode(["type": "change", "text": payload]) else {
            return XCTFail("expected .change")
        }
        XCTAssertEqual(text.count, payload.count)
    }

    // MARK: - Forward compatibility

    func test_decode_changeWithExtraFields_stillDecodes() {
        // Future versions may add { selectionStart, scrollY, ... } —
        // decoder must ignore unknown fields, not bail to nil.
        let body: [String: Any] = [
            "type": "change",
            "text": "hello",
            "selectionStart": 5,
            "selectionEnd": 10,
            "scrollY": 200.0,
            "viewport": ["from": 0, "to": 100]
        ]
        XCTAssertEqual(
            CodeMirrorBridge.decode(body),
            .change(text: "hello")
        )
    }

    func test_decode_readyWithExtraFields_stillDecodes() {
        XCTAssertEqual(
            CodeMirrorBridge.decode(["type": "ready", "version": "6.21", "extensions": ["foldGutter"]]),
            .ready
        )
    }

    func test_decode_saveRequestedWithExtraFields_stillDecodes() {
        XCTAssertEqual(
            CodeMirrorBridge.decode(["type": "saveRequested", "source": "keyboard"]),
            .saveRequested
        )
    }

    func test_decode_unknownTypeWithChangeShapedPayload_returnsNil() {
        // Adding a new "type" must not be accidentally aliased to .change
        // just because it carries a text field.
        XCTAssertNil(CodeMirrorBridge.decode(["type": "unknownAction", "text": "foo"]))
    }

    // MARK: - Case sensitivity

    func test_decode_typeIsCaseSensitive() {
        XCTAssertNil(CodeMirrorBridge.decode(["type": "Ready"]))
        XCTAssertNil(CodeMirrorBridge.decode(["type": "READY"]))
        XCTAssertNil(CodeMirrorBridge.decode(["type": "Change"]))
        XCTAssertNil(CodeMirrorBridge.decode(["type": "saverequested"]))
    }

    // MARK: - Action equality semantics

    func test_changeActions_equalWhenTextMatches() {
        XCTAssertEqual(CodeMirrorBridge.Action.change(text: "abc"),
                       CodeMirrorBridge.Action.change(text: "abc"))
        XCTAssertNotEqual(CodeMirrorBridge.Action.change(text: "abc"),
                          CodeMirrorBridge.Action.change(text: "abd"))
    }

    func test_distinctActionVariants_areNotEqual() {
        XCTAssertNotEqual(CodeMirrorBridge.Action.ready,
                          CodeMirrorBridge.Action.saveRequested)
        XCTAssertNotEqual(CodeMirrorBridge.Action.ready,
                          CodeMirrorBridge.Action.change(text: ""))
    }
}
