import XCTest
@testable import RustCore
import ViewerCore

/// A/B parity (TSK-630): the Rust core's `mdvcore_find_search` (via
/// `mdvCoreFindSearch`) vs the SHIPPING Swift `FindEngine`, over texts
/// exercising the documented hazards (LF/CR/CRLF line accounting, astral
/// UTF-16 offsets, multi-match sweeps) and the regex COMMON SUBSET both
/// engines support (classes, quantifiers, alternation, anchors, \b).
///
/// Out of corpus by design (documented divergences): non-ASCII
/// case-insensitivity (ICU folds, regex-lite doesn't), ICU-only constructs
/// (lookaround → `.invalidPattern` and Swift-engine fallback), zero-length
/// match advancement.
final class FindSearchABTests: XCTestCase {

    private let texts = [
        "hello world hello HELLO\nsecond hello line\nthird",
        "a\rcr-only\rclassic mac hello\r",
        "crlf line one\r\nhello two\r\nhello\r\n",
        "mixed\nunix\r\nwindows\rmac hello",
        "😀 astral hello 😀 hello",
        "no matches here at all",
        "",
        "x.y x.y (paren) [brack] a+b",
    ]

    private func swiftSearch(
        _ text: String, _ pattern: String, kind: FindQuery.Kind,
        cs: Bool, ww: Bool
    ) throws -> [FindMatch] {
        try FindEngine().search(
            in: text,
            query: FindQuery(pattern: pattern, kind: kind, caseSensitive: cs, wholeWord: ww))
    }

    private func assertParity(
        _ pattern: String, kind: FindQuery.Kind, cs: Bool = false, ww: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for text in texts {
            let swift = try swiftSearch(text, pattern, kind: kind, cs: cs, ww: ww)
            let rust = try mdvCoreFindSearch(
                text: text, pattern: pattern,
                kind: kind == .literal ? "literal" : "regex",
                caseSensitive: cs, wholeWord: ww)
            XCTAssertEqual(
                rust.map { [$0.location, $0.length, $0.line, $0.column] },
                swift.map { [$0.range.location, $0.range.length, $0.line, $0.column] },
                "parity diverged: pattern '\(pattern)' kind \(kind) cs=\(cs) ww=\(ww) text=\(text.debugDescription)",
                file: file, line: line)
        }
    }

    func test_literal_parity_incl_lineAccounting_and_astral() throws {
        try assertParity("hello", kind: .literal)
        try assertParity("hello", kind: .literal, cs: true)
        try assertParity("HELLO", kind: .literal)
        try assertParity("x.y", kind: .literal)      // metachars stay literal
        try assertParity("(paren)", kind: .literal)
        try assertParity("a+b", kind: .literal)
        try assertParity("😀", kind: .literal)        // astral needle
        try assertParity("zzz-no-hit", kind: .literal)
    }

    func test_wholeWord_parity() throws {
        try assertParity("hello", kind: .literal, ww: true)
        try assertParity("two", kind: .literal, ww: true)
    }

    func test_regex_commonSubset_parity() throws {
        try assertParity(#"h\w+o"#, kind: .regex)
        try assertParity(#"[a-z]+ic"#, kind: .regex)
        try assertParity("hello|two", kind: .regex)
        try assertParity("^third$", kind: .regex)     // anchors: note multiline
        try assertParity(#"\bhello\b"#, kind: .regex)
    }

    func test_invalidPattern_surfacesAsTypedError_notBridgeFault() {
        XCTAssertThrowsError(
            try mdvCoreFindSearch(text: "x", pattern: "(unclosed",
                                  kind: "regex", caseSensitive: false, wholeWord: false)
        ) { error in
            guard case CoreError.invalidPattern = error else {
                return XCTFail("expected .invalidPattern, got \(error)")
            }
        }
        // ICU-only construct → same typed channel (the Swift-fallback path).
        XCTAssertThrowsError(
            try mdvCoreFindSearch(text: "x", pattern: "(?=look)",
                                  kind: "regex", caseSensitive: false, wholeWord: false)
        ) { error in
            guard case CoreError.invalidPattern = error else {
                return XCTFail("expected .invalidPattern, got \(error)")
            }
        }
    }

    func test_capability_bit_advertised() {
        XCTAssertTrue(CoreABI.capabilities.contains(.find))
    }
}
