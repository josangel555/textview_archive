import XCTest
@testable import RustCore

/// Slice 3c-i (TSK-1202): the Swift→FFI→rust fold boundary. `mdvCoreFoldRegions`
/// encodes `{text, lang}`, calls the envelope (MDV_METHOD_FOLD_REGIONS = 15),
/// and decodes the positional `(start, end, kind)` fold-region tuples — exercised
/// through the real `.a`, so a relink/ABI break or a wire-shape drift fails here.
final class FoldRegionsBindingTests: XCTestCase {

    func test_foldRegions_roundTrips_json_object_and_array() throws {
        // 1:{  2:"a":1  3:"b":[  4:2  5:]  6:}  → object 1..6, array 3..5.
        let folds = try mdvCoreFoldRegions(
            text: "{\n  \"a\": 1,\n  \"b\": [\n    2\n  ]\n}", lang: "json")
        XCTAssertTrue(
            folds.contains { $0.kind == "object" && $0.startLine == 1 },
            "expected an object fold from line 1, got \(folds)")
        XCTAssertTrue(
            folds.contains { $0.kind == "array" },
            "expected an array fold, got \(folds)")
    }

    func test_foldRegions_swift_function_body() throws {
        let folds = try mdvCoreFoldRegions(
            text: "func f() {\n  let x = 1\n  return x\n}", lang: "swift")
        XCTAssertTrue(
            folds.contains { $0.kind == "function" },
            "expected a function-body fold, got \(folds)")
    }

    func test_foldRegions_unsupportedLanguage_throws() {
        // supported == false ⇒ throw, so RustFoldAdapter falls back to the Swift
        // engine rather than blanking the gutter.
        XCTAssertThrowsError(
            try mdvCoreFoldRegions(text: "anything", lang: "no-such-lang"))
    }
}
