import XCTest
@testable import ViewerCore

/// TSK-901 — conservative content sniff for unknown/misnamed files. STRICT by
/// design: prose must NOT be mistaken for data (a false positive is worse than a
/// miss). JSON requires a real parse; CSV requires a consistent delimiter.
final class ContentTypeSnifferTests: XCTestCase {

    // MARK: JSON

    func test_json_object_detected() {
        XCTAssertEqual(ContentTypeSniffer.detect("{\"a\": 1, \"b\": [2,3]}"), .json)
    }

    func test_json_array_detected() {
        XCTAssertEqual(ContentTypeSniffer.detect("[1, 2, {\"x\": true}]"), .json)
    }

    func test_json_leadingWhitespace_stillDetected() {
        XCTAssertEqual(ContentTypeSniffer.detect("\n\n   {\"a\":1}\n"), .json)
    }

    func test_json_bracketButNotValid_rejected() {
        // Leads with a bracket but is NOT valid JSON → must NOT be called JSON.
        XCTAssertNil(ContentTypeSniffer.detect("[TODO] fix the thing later"))
        XCTAssertNil(ContentTypeSniffer.detect("{ this is a note, not json }"))
    }

    func test_prose_isNotJSON() {
        XCTAssertNil(ContentTypeSniffer.detect("Hello world.\nThis is a paragraph."))
    }

    // MARK: CSV

    func test_csv_consistentCommas_detected() {
        XCTAssertEqual(ContentTypeSniffer.detect("a,b,c\n1,2,3\n4,5,6\n"), .csv)
    }

    func test_tsv_tabs_detected() {
        XCTAssertEqual(ContentTypeSniffer.detect("a\tb\tc\n1\t2\t3\n"), .csv)
    }

    func test_csv_inconsistentColumns_rejected() {
        // Prose-with-commas: per-line comma counts vary → not CSV.
        XCTAssertNil(ContentTypeSniffer.detect("Hello, world\nThis is a longer, run-on, sentence\nShort"))
    }

    func test_csv_singleColumn_rejected() {
        // One field per line (no delimiter giving ≥2) → not CSV (it's a word list).
        XCTAssertNil(ContentTypeSniffer.detect("apple\nbanana\ncherry\n"))
    }

    func test_csv_singleRow_rejected() {
        // Needs ≥2 data rows to be confident.
        XCTAssertNil(ContentTypeSniffer.detect("a,b,c\n"))
    }

    func test_empty_isNil() {
        XCTAssertNil(ContentTypeSniffer.detect(""))
        XCTAssertNil(ContentTypeSniffer.detect("   \n  \n"))
    }

    // MARK: precedence — a valid multiline JSON array is JSON, not CSV

    func test_multilineJsonArray_isJSON() {
        // Valid JSON (one array spread over lines) must classify as JSON. Its
        // leading-bracket + successful parse beats the CSV heuristic.
        XCTAssertEqual(ContentTypeSniffer.detect("[\n  1,\n  2,\n  3\n]"), .json)
    }
}
