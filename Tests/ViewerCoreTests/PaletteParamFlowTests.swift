import XCTest
@testable import ViewerCore

/// TSK-1340 — the palette param-input state machine: validation per kind +
/// verb-line assembly for Go to Line / Apply jq / Convert Encoding.
final class PaletteParamFlowTests: XCTestCase {

    func test_builtIns_coverTheThreeParamCommands() {
        let ids = Set(PaletteParamFlow.builtIns.map(\.commandID))
        XCTAssertEqual(ids, ["view.goToLine", "view.applyJQ", "view.convertEncoding"])
        XCTAssertNotNil(PaletteParamFlow.command(forID: "view.goToLine"))
        XCTAssertNil(PaletteParamFlow.command(forID: "view.zoomIn"),
                     "a param-less command has no flow")
    }

    func test_integer_validation() {
        let k = PaletteParamFlow.ParamKind.integer(min: 1, max: nil)
        XCTAssertEqual(PaletteParamFlow.validate("42", kind: k), .success("42"))
        XCTAssertEqual(PaletteParamFlow.validate("  7 ", kind: k), .success("7"))
        XCTAssertEqual(PaletteParamFlow.validate("0", kind: k), .failure("Must be ≥ 1"))
        XCTAssertEqual(PaletteParamFlow.validate("x", kind: k), .failure("Enter a number"))
        XCTAssertEqual(PaletteParamFlow.validate("", kind: k), .failure("Enter a value"))
        // Upper bound honored when present.
        let bounded = PaletteParamFlow.ParamKind.integer(min: 1, max: 100)
        XCTAssertEqual(PaletteParamFlow.validate("101", kind: bounded), .failure("Must be ≤ 100"))
    }

    func test_text_validation_passesThrough() {
        let k = PaletteParamFlow.ParamKind.text(placeholder: "jq")
        XCTAssertEqual(PaletteParamFlow.validate(".items[].name", kind: k),
                       .success(".items[].name"))
        XCTAssertEqual(PaletteParamFlow.validate("   ", kind: k), .failure("Enter a value"))
    }

    func test_choice_exactAndUniquePrefix() {
        let k = PaletteParamFlow.ParamKind.choice(options: ["utf-8", "utf-16", "windows-1252"])
        XCTAssertEqual(PaletteParamFlow.validate("UTF-8", kind: k), .success("utf-8"))
        XCTAssertEqual(PaletteParamFlow.validate("win", kind: k), .success("windows-1252"),
                       "unique prefix resolves")
        XCTAssertEqual(PaletteParamFlow.validate("utf", kind: k),
                       .failure("Ambiguous: utf-8, utf-16"))
        XCTAssertEqual(PaletteParamFlow.validate("ebcdic", kind: k),
                       .failure("Not a valid option"))
    }

    func test_dispatchLine_assemblesVerbPlusValue() {
        let goto = PaletteParamFlow.command(forID: "view.goToLine")!
        XCTAssertEqual(PaletteParamFlow.dispatchLine(for: goto, rawInput: "128"),
                       "goto-line 128")
        let jq = PaletteParamFlow.command(forID: "view.applyJQ")!
        XCTAssertEqual(PaletteParamFlow.dispatchLine(for: jq, rawInput: ".a.b"),
                       "apply-jq .a.b")
        let enc = PaletteParamFlow.command(forID: "view.convertEncoding")!
        XCTAssertEqual(PaletteParamFlow.dispatchLine(for: enc, rawInput: "latin1"),
                       "convert-encoding latin1")
        // Invalid input → nil (row stays open).
        XCTAssertNil(PaletteParamFlow.dispatchLine(for: goto, rawInput: "abc"))
    }

    func test_placeholders_areInformative() {
        XCTAssertEqual(PaletteParamFlow.ParamKind.integer(min: 1, max: 500).placeholder,
                       "line (1–500)")
        XCTAssertTrue(PaletteParamFlow.ParamKind.choice(options: ["a", "b"]).placeholder
            .contains("a, b"))
    }
}
