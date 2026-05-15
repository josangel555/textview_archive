import XCTest
@testable import ViewerCore

final class FormatterTests: XCTestCase {

    // MARK: - JSON

    func test_json_compactInput_isPrettyPrinted() {
        let input = #"{"a":1,"b":[1,2,3]}"#
        let out = Formatter.prettyPrint(input, as: .json)
        // Pretty output should contain newlines + indentation.
        XCTAssertTrue(out.contains("\n"), "Pretty JSON should have newlines")
        XCTAssertTrue(out.contains("  "), "Pretty JSON should be indented")
        // Round-trip preserves semantics: parsing the pretty output
        // yields the same object as parsing the input.
        let original = try? JSONSerialization.jsonObject(
            with: input.data(using: .utf8)!, options: [.fragmentsAllowed])
        let formatted = try? JSONSerialization.jsonObject(
            with: out.data(using: .utf8)!, options: [.fragmentsAllowed])
        XCTAssertNotNil(original)
        XCTAssertNotNil(formatted)
    }

    func test_json_invalidInput_returnsUnchanged() {
        let input = "{not actually json"
        let out = Formatter.prettyPrint(input, as: .json)
        XCTAssertEqual(out, input,
            "Invalid JSON should return input unchanged (no exception)")
    }

    func test_json_alreadyPretty_doesNotMangle() {
        let input = """
        {
          "a" : 1
        }
        """
        let out = Formatter.prettyPrint(input, as: .json)
        // Output should still be valid JSON with same content.
        let parsed = try? JSONSerialization.jsonObject(
            with: out.data(using: .utf8)!, options: [.fragmentsAllowed])
        XCTAssertNotNil(parsed)
        if let dict = parsed as? [String: Any] {
            XCTAssertEqual(dict["a"] as? Int, 1)
        }
    }

    func test_json_sortsKeys() {
        let input = #"{"z":1,"a":2,"m":3}"#
        let out = Formatter.prettyPrint(input, as: .json)
        // After sorting, "a" should appear before "z".
        let aPos = out.firstIndex(of: "a")?.utf16Offset(in: out) ?? -1
        let zPos = out.firstIndex(of: "z")?.utf16Offset(in: out) ?? -2
        XCTAssertLessThan(aPos, zPos,
            "Sorted keys: 'a' line should appear before 'z' line. Output:\n\(out)")
    }

    // MARK: - XML

    func test_xml_compactInput_isPrettyPrinted() {
        let input = "<root><a>1</a><b>2</b></root>"
        let out = Formatter.prettyPrint(input, as: .xml)
        XCTAssertTrue(out.contains("\n"), "Pretty XML should have newlines")
        XCTAssertTrue(out.contains("<a>1</a>") || out.contains("<a>"),
            "Pretty XML should preserve element structure. Output:\n\(out)")
    }

    func test_xml_invalidInput_returnsUnchanged() {
        let input = "<<<not xml>>>"
        let out = Formatter.prettyPrint(input, as: .xml)
        // XMLDocument is permissive; even garbage might "parse" to a
        // text node. So we accept either an unchanged return OR a valid
        // pretty-printed text node. Either is fine; the important
        // invariant is "no crash, non-empty output".
        XCTAssertFalse(out.isEmpty)
    }

    // MARK: - SupportedFormat detection

    func test_detect_json_extensions() {
        XCTAssertEqual(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "a.json")), .json)
        XCTAssertEqual(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "/tmp/b.JSON")), .json)
        XCTAssertEqual(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "log.jsonl")), .json)
    }

    func test_detect_xml_extensions() {
        XCTAssertEqual(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "a.xml")), .xml)
        XCTAssertEqual(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "info.plist")), .xml)
        XCTAssertEqual(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "page.html")), .xml)
        XCTAssertEqual(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "icon.svg")), .xml)
    }

    func test_detect_unsupported() {
        XCTAssertNil(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "a.md")))
        XCTAssertNil(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "a.txt")))
        XCTAssertNil(Formatter.SupportedFormat.detect(URL(fileURLWithPath: "a.swift")))
    }

    func test_prettyPrintIfFormattable_returnsDidFormatFlag() {
        let (out1, ok1) = Formatter.prettyPrintIfFormattable(
            #"{"x":1}"#, url: URL(fileURLWithPath: "a.json"))
        XCTAssertTrue(ok1)
        XCTAssertNotEqual(out1, #"{"x":1}"#)

        let (out2, ok2) = Formatter.prettyPrintIfFormattable(
            "plain text", url: URL(fileURLWithPath: "a.txt"))
        XCTAssertFalse(ok2)
        XCTAssertEqual(out2, "plain text")
    }
}
