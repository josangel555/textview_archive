import XCTest
@testable import ViewerCore

/// Coverage for the TODO-style annotation scanner (TSK-512). The whole-word /
/// case-sensitivity guards are the load-bearing ones (false-positive control).
final class SourceAnnotationScannerTests: XCTestCase {

    private func s(_ t: String) -> [SourceAnnotation] { SourceAnnotationScanner.scan(t) }

    func test_todoWithColon_messageAndLine() {
        XCTAssertEqual(s("// TODO: fix this\n"),
                       [SourceAnnotation(kind: .todo, message: "fix this", line: 1)])
    }

    func test_noColon_stillCapturesMessage() {
        XCTAssertEqual(s("# FIXME broken thing"),
                       [SourceAnnotation(kind: .fixme, message: "broken thing", line: 1)])
    }

    func test_markerAlone_emptyMessage() {
        XCTAssertEqual(s("   // TODO"),
                       [SourceAnnotation(kind: .todo, message: "", line: 1)])
    }

    func test_allKindsAndLineNumbers() {
        let out = s("a\n// HACK: h\nb\n// XXX x\n// NOTE: n\n// BUG b\n")
        XCTAssertEqual(out, [
            SourceAnnotation(kind: .hack, message: "h", line: 2),
            SourceAnnotation(kind: .xxx,  message: "x", line: 4),
            SourceAnnotation(kind: .note, message: "n", line: 5),
            SourceAnnotation(kind: .bug,  message: "b", line: 6),
        ])
    }

    func test_wholeWordOnly_noPartialMatches() {
        // 'TODOS', 'aTODO', 'methodObj' must NOT match.
        XCTAssertEqual(s("TODOS are great\naTODO here\nlet methodObj = 1"), [])
    }

    func test_caseSensitive_lowercaseIgnored() {
        // lowercase prose "todo"/"note"/"bug" must not flag.
        XCTAssertEqual(s("todo later\nthis is a note about a bug"), [])
    }

    func test_firstMarkerPerLineWins() {
        // Two markers on one line → only the first is reported.
        XCTAssertEqual(s("// TODO then FIXME"),
                       [SourceAnnotation(kind: .todo, message: "then FIXME", line: 1)])
    }

    func test_markerMidLineAfterCode() {
        XCTAssertEqual(s("let x = 1  // TODO refactor"),
                       [SourceAnnotation(kind: .todo, message: "refactor", line: 1)])
    }

    func test_crlf_handled() {
        XCTAssertEqual(s("// TODO: a\r\n// FIXME: b\r\n"), [
            SourceAnnotation(kind: .todo,  message: "a", line: 1),
            SourceAnnotation(kind: .fixme, message: "b", line: 2),
        ])
    }

    func test_maxLines_bound() {
        // A marker past the bound is not scanned.
        XCTAssertEqual(SourceAnnotationScanner.scan("ok\nok\n// TODO late", maxLines: 2), [])
        XCTAssertEqual(SourceAnnotationScanner.scan("// TODO early\nok", maxLines: 1),
                       [SourceAnnotation(kind: .todo, message: "early", line: 1)])
    }

    func test_empty_andNoMarkers() {
        XCTAssertEqual(s(""), [])
        XCTAssertEqual(s("just code\nmore code"), [])
    }
}
