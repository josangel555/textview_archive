import XCTest
@testable import ViewerKit

/// Extended value-semantics coverage for `HelpInfo` beyond the basic
/// equality checks in `HelpInfoTests`.
///
/// `HelpInfo: Equatable, Sendable` is load-bearing: the `HelpSink` setter
/// dedupes on `==` to avoid republishing the StatusBar on every pointer
/// move (REPUB-1), and the value is read on the render thread from
/// `.onHover`, so `Sendable` must hold without a lock. These tests pin
/// the corner cases the dedupe relies on — empty / whitespace / Unicode
/// fields, field-swap asymmetry, and the `Sendable` capture path — that
/// the existing happy-path suite doesn't exercise.
final class HelpInfoValueSemanticsTests: XCTestCase {

    // MARK: - Field-swap asymmetry
    //
    // A naive Equatable that compared "the set of two strings" rather than
    // (title, description) positionally would treat a title/description
    // swap as equal — and the sink would then fail to republish when the
    // hovered element's title and description are transposed. Pin that the
    // fields are positional.

    func test_titleDescriptionSwap_isNotEqual() {
        let a = HelpInfo(title: "Open", description: "Close")
        let b = HelpInfo(title: "Close", description: "Open")
        XCTAssertNotEqual(a, b,
            "title/description are positional — a swap must compare unequal")
    }

    func test_sameStringInBothFields_equalsOnlyItself() {
        let a = HelpInfo(title: "X", description: "X")
        let b = HelpInfo(title: "X", description: "X")
        XCTAssertEqual(a, b)
        // …but differs from one where only one field is "X".
        XCTAssertNotEqual(a, HelpInfo(title: "X", description: "Y"))
        XCTAssertNotEqual(a, HelpInfo(title: "Y", description: "X"))
    }

    // MARK: - Empty / whitespace fields

    func test_emptyFields_equalAndStored() {
        let a = HelpInfo(title: "", description: "")
        let b = HelpInfo(title: "", description: "")
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.title.isEmpty)
        XCTAssertTrue(a.description.isEmpty)
    }

    func test_emptyTitle_distinctFromNonEmpty() {
        XCTAssertNotEqual(HelpInfo(title: "", description: "D"),
                          HelpInfo(title: "T", description: "D"))
    }

    /// Whitespace is significant — `"A"` and `"A "` must NOT dedupe, else
    /// a trailing-space variant would silently suppress a republish.
    func test_whitespace_isSignificant() {
        XCTAssertNotEqual(HelpInfo(title: "A", description: "D"),
                          HelpInfo(title: "A ", description: "D"))
        XCTAssertNotEqual(HelpInfo(title: "T", description: "D"),
                          HelpInfo(title: "T", description: " D"))
    }

    // MARK: - Unicode / grapheme correctness

    func test_unicodeFields_compareByValue() {
        let a = HelpInfo(title: "Café \u{1F4C4}", description: "naïve")
        let b = HelpInfo(title: "Café \u{1F4C4}", description: "naïve")
        XCTAssertEqual(a, b)
    }

    /// NFC vs NFD forms of the same visual string are distinct `String`
    /// values only if not normalized; Swift's `String` compares by
    /// canonical equivalence, so an é (precomposed) equals e + combining
    /// acute. Pin the behavior we actually get so a future field-type
    /// change (e.g. to a byte-compared identifier) is caught.
    func test_canonicallyEquivalentForms_areEqual() {
        let precomposed = "e\u{0301}"      // e + combining acute
        let composed = "\u{00E9}"          // é
        XCTAssertEqual(HelpInfo(title: precomposed, description: "d"),
                       HelpInfo(title: composed, description: "d"),
                       "String compares by canonical equivalence")
    }

    // MARK: - Convenience-init parity
    //
    // The `helpInfo(title:description:)` View overload builds a HelpInfo
    // from two strings; the value it produces must equal the explicit
    // initializer so the two call styles dedupe against each other.

    func test_memberwiseInit_storesFieldsVerbatim() {
        let h = HelpInfo(title: "  Padded  ", description: "\tTabbed\n")
        XCTAssertEqual(h.title, "  Padded  ")
        XCTAssertEqual(h.description, "\tTabbed\n")
    }

    // MARK: - Sendable capture
    //
    // `HelpInfo` is sent into a `.onHover` closure that runs on the render
    // thread. Prove a value crosses a concurrency boundary and survives
    // unchanged — a compile-time + runtime assertion that the `Sendable`
    // conformance is real (this file would fail to compile if HelpInfo
    // lost Sendable).

    func test_sendableAcrossTask_roundTripsByValue() async {
        let original = HelpInfo(title: "Async", description: "boundary")
        let received: HelpInfo = await Task { original }.value
        XCTAssertEqual(received, original)
    }

    func test_optionalEquality_matchesSinkDedupeContract() {
        // The sink stores `HelpInfo?` and dedupes with `hovered != info`.
        // Mirror exactly that optional comparison here.
        let some: HelpInfo? = HelpInfo(title: "T", description: "D")
        let sameSome: HelpInfo? = HelpInfo(title: "T", description: "D")
        let none: HelpInfo? = nil
        XCTAssertEqual(some, sameSome)        // equal value → dedupe (no republish)
        XCTAssertNotEqual(some, none)         // value → nil → republish
        XCTAssertEqual(none, HelpInfo?.none)  // nil → nil → dedupe
    }
}
