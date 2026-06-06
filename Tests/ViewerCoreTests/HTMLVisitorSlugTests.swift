import XCTest
@testable import ViewerCore

/// Coverage for `HTMLVisitor.uniqueSlug(for:used:)` (in HTMLRenderer.swift)
/// — the heading-anchor slug generator + in-document dedup. Was untested.
/// Pins: alnum-lowercase + dash-collapse + edge trim, the empty→"section"
/// fallback, numbers kept, the duplicate counter (`x`, `x-1`, `x-2`), and
/// the actual Unicode behavior (the impl uses `isLetter`/`isNumber`, so
/// accented letters survive — the "ASCII" in the doc comment is aspirational).
final class HTMLVisitorSlugTests: XCTestCase {

    private func slug(_ text: String, _ used: inout [String: Int]) -> String {
        HTMLVisitor.uniqueSlug(for: text, used: &used)
    }
    private func slug1(_ text: String) -> String {
        var used: [String: Int] = [:]
        return HTMLVisitor.uniqueSlug(for: text, used: &used)
    }

    func test_basicSlugify_lowercaseAndDashes() {
        XCTAssertEqual(slug1("Hello World"), "hello-world")
        XCTAssertEqual(slug1("HELLO"), "hello")
    }

    func test_punctuationCollapsesToSingleDash() {
        XCTAssertEqual(slug1("Foo: Bar!!  Baz"), "foo-bar-baz")
    }

    func test_leadingAndTrailingSeparatorsTrimmed() {
        XCTAssertEqual(slug1("  Hi there  "), "hi-there")
        XCTAssertEqual(slug1("## Heading ##"), "heading")
    }

    func test_numbersArePreserved() {
        XCTAssertEqual(slug1("Section 2"), "section-2")
        XCTAssertEqual(slug1("v1.2.3"), "v1-2-3")
    }

    func test_emptyOrAllPunctuation_fallsBackToSection() {
        XCTAssertEqual(slug1(""), "section")
        XCTAssertEqual(slug1("!!! ???"), "section")
    }

    func test_unicodeLettersSurvive_perActualImplementation() {
        // The impl keeps any Unicode letter/number (not just ASCII).
        XCTAssertEqual(slug1("Café déjà"), "café-déjà")
    }

    func test_duplicateHeadings_getIncrementingSuffix() {
        var used: [String: Int] = [:]
        XCTAssertEqual(slug("Intro", &used), "intro")
        XCTAssertEqual(slug("Intro", &used), "intro-1")
        XCTAssertEqual(slug("Intro", &used), "intro-2")
        // A different heading is independent.
        XCTAssertEqual(slug("Other", &used), "other")
        XCTAssertEqual(slug("Intro", &used), "intro-3")
    }

    func test_dedupKeyedAfterSlugify_notRawText() {
        // "A B" and "a-b" slugify to the same key → second is suffixed.
        var used: [String: Int] = [:]
        XCTAssertEqual(slug("A B", &used), "a-b")
        XCTAssertEqual(slug("a b", &used), "a-b-1")
    }
}
