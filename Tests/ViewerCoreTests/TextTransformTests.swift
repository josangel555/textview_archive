import XCTest
@testable import ViewerCore

/// Teeth for `TextTransform` (TSK-351 — TextEdit "Format ▸ Transformations"
/// parity: Make Upper Case / Make Lower Case / Capitalize).
///
/// The engine is a pure UTF-16-offset reducer that emits a `CMEdit`. Tests
/// pin both layers:
///  - the pure string transform (`apply`),
///  - the range/no-op/identity logic of `edit(for:in:from:to:)`,
///  - and an end-to-end round-trip through `CMEditApplier.apply` so the edit
///    a real CM6 transaction would apply is byte-verified against the
///    expected buffer.
final class TextTransformTests: XCTestCase {

    // MARK: pure string transform

    func testApplyUppercase() {
        XCTAssertEqual(TextTransform.apply(.uppercase, to: "Hello world"), "HELLO WORLD")
    }

    func testApplyLowercase() {
        XCTAssertEqual(TextTransform.apply(.lowercase, to: "Hello WORLD"), "hello world")
    }

    func testApplyCapitalize() {
        XCTAssertEqual(TextTransform.apply(.capitalize, to: "hello world foo"), "Hello World Foo")
    }

    func testApplyCapitalizeLowersInteriorCaps() {
        // TextEdit's Capitalize lowercases the rest of each word.
        XCTAssertEqual(TextTransform.apply(.capitalize, to: "hELLO wORLD"), "Hello World")
    }

    func testKindIsExhaustive() {
        // Guard: if a 4th transform is added, the apply switch must be updated.
        XCTAssertEqual(TextTransform.Kind.allCases.count, 3)
    }

    // MARK: edit() — selection span

    func testEditTransformsSelectionSpanOnly() {
        // "hello WORLD" — uppercase just "hello" (offsets 0..<5).
        let text = "hello WORLD"
        let edit = TextTransform.edit(for: .uppercase, in: text, from: 0, to: 5)
        XCTAssertEqual(edit, CMEdit(from: 0, to: 5, insert: "HELLO"))
        // Applying it yields the whole expected buffer.
        XCTAssertEqual(RustCMEditAdapter.apply([edit!], to: text), "HELLO WORLD")
    }

    func testEditTransformsInteriorSelection() {
        let text = "the quick brown fox"
        // Capitalize "quick brown" (offsets 4..<15).
        let edit = TextTransform.edit(for: .capitalize, in: text, from: 4, to: 15)
        XCTAssertNotNil(edit)
        XCTAssertEqual(RustCMEditAdapter.apply([edit!], to: text), "the Quick Brown fox")
    }

    // MARK: edit() — empty selection → whole document

    func testEmptySelectionTransformsWholeDocument() {
        let text = "mixed Case Text"
        // from == to (caret, no selection) → uppercase the whole buffer.
        let edit = TextTransform.edit(for: .uppercase, in: text, from: 3, to: 3)
        XCTAssertEqual(edit, CMEdit(from: 0, to: text.utf16.count, insert: "MIXED CASE TEXT"))
        XCTAssertEqual(RustCMEditAdapter.apply([edit!], to: text), "MIXED CASE TEXT")
    }

    // MARK: edit() — no-op / identity / bounds

    func testIdentityTransformReturnsNil() {
        // Already uppercase → no edit (don't dirty the buffer / undo stack).
        XCTAssertNil(TextTransform.edit(for: .uppercase, in: "ALREADY UP", from: 0, to: 10))
    }

    func testEmptyDocumentReturnsNil() {
        XCTAssertNil(TextTransform.edit(for: .uppercase, in: "", from: 0, to: 0))
    }

    func testOutOfBoundsReturnsNil() {
        let text = "abc"
        XCTAssertNil(TextTransform.edit(for: .uppercase, in: text, from: 0, to: 99))
        XCTAssertNil(TextTransform.edit(for: .uppercase, in: text, from: -1, to: 2))
    }

    func testInvertedRangeReturnsNil() {
        // from > to with from != to is an inverted (bogus) range → refuse.
        XCTAssertNil(TextTransform.edit(for: .uppercase, in: "abcdef", from: 4, to: 2))
    }

    // MARK: UTF-16 / surrogate-pair correctness

    func testAstralPlanePreservedAcrossTransform() {
        // "café 😀 END" — emoji is a surrogate pair in UTF-16; uppercasing the
        // whole doc must keep it intact and offset accounting correct.
        let text = "café 😀 end"
        let edit = TextTransform.edit(for: .uppercase, in: text, from: 0, to: 0)
        XCTAssertNotNil(edit)
        let result = RustCMEditAdapter.apply([edit!], to: text)
        XCTAssertEqual(result, "CAFÉ 😀 END")
    }

    func testSelectionAfterAstralCharUsesUTF16Offsets() {
        // "😀abc": the emoji occupies UTF-16 offsets 0..<2, so "abc" is 2..<5.
        let text = "😀abc"
        let edit = TextTransform.edit(for: .uppercase, in: text, from: 2, to: 5)
        XCTAssertEqual(edit, CMEdit(from: 2, to: 5, insert: "ABC"))
        XCTAssertEqual(RustCMEditAdapter.apply([edit!], to: text), "😀ABC")
    }

    // MARK: round-trip — lowercase reverses uppercase

    func testLowercaseReversesUppercaseRoundTrip() throws {
        let original = "Hello, World!"
        let upEdit = try XCTUnwrap(TextTransform.edit(for: .uppercase, in: original, from: 0, to: 0))
        let upped = try XCTUnwrap(RustCMEditAdapter.apply([upEdit], to: original))
        XCTAssertEqual(upped, "HELLO, WORLD!")
        let downEdit = try XCTUnwrap(TextTransform.edit(for: .lowercase, in: upped, from: 0, to: 0))
        let downed = try XCTUnwrap(RustCMEditAdapter.apply([downEdit], to: upped))
        XCTAssertEqual(downed, "hello, world!")
    }
}
