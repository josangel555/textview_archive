import XCTest
@testable import ViewerCore
import ViewerKit

/// TSK-1476 — the structural-search help layer: every shipped example must
/// actually PARSE (a broken example is worse than none), plus error surfacing.
final class StructuralSearchHelpTests: XCTestCase {

    func test_everyShippedExample_parses() {
        // The whole point: a user clicks an example and it works. Assert each
        // one round-trips through the real parser, across every language +
        // the generic fallback.
        let langs: [HighlightLanguage?] = [
            .swift, .python, .javascript, .typescript, .tsx, .rust, .markdown, nil,
        ]
        for lang in langs {
            for ex in StructuralSearchHelp.examples(for: lang) {
                XCTAssertNoThrow(
                    try StructuralQueryParser.parse(ex.query),
                    "example '\(ex.label)' for \(String(describing: lang)) must parse: \(ex.query)")
            }
        }
    }

    func test_languageTailoring() {
        // Swift examples use Swift kind names; Rust uses Rust ones.
        XCTAssertTrue(StructuralSearchHelp.examples(for: .swift)
            .contains { $0.query.contains("function_declaration") })
        XCTAssertTrue(StructuralSearchHelp.examples(for: .rust)
            .contains { $0.query.contains("function_item") })
        // An unmapped language gets the generic set (non-empty).
        XCTAssertFalse(StructuralSearchHelp.examples(for: .yaml).isEmpty)
        XCTAssertFalse(StructuralSearchHelp.examples(for: nil).isEmpty)
    }

    func test_validationError_surfacesParseErrors() {
        // A well-formed query → no error.
        XCTAssertNil(StructuralSearchHelp.validationError(for: "function_declaration name=$X"))
        // Empty / whitespace → idle, not an error.
        XCTAssertNil(StructuralSearchHelp.validationError(for: "   "))
        // A malformed query → a position-annotated message.
        let err = StructuralSearchHelp.validationError(for: "function_declaration (")
        XCTAssertNotNil(err)
        XCTAssertTrue(err!.hasPrefix("Query error"), "got: \(err ?? "nil")")
    }

    func test_errorText_clampsPosition() {
        let e = StructuralQueryParser.ParseError("boom", at: 999)
        let text = StructuralSearchHelp.errorText(e, in: "abc")
        XCTAssertTrue(text.contains("at 3"), "position clamped to the query length: \(text)")
    }
}
