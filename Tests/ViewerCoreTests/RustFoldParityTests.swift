import XCTest
@testable import ViewerCore
import ViewerKit

/// Fold-engine behavior pins (STAGE-B, TSK-649: the Swift fold twin —
/// TreeSitterEngine's queries + computeFolds — is deleted; rust is the only
/// engine). The fixtures below are the retired A/B parity corpus; the
/// expected structures are the CONTRACT both engines agreed on before
/// deletion. Fold identity is the `(startLine, endLine, kind)` triple.
final class RustFoldParityTests: XCTestCase {

    private func folds(
        _ lang: HighlightLanguage, _ text: String
    ) throws -> [FoldRegion] {
        try RustFoldAdapter.rustFolds(text, language: lang)
    }

    func test_json_folds() throws {
        let r = try folds(.json, "{\n  \"a\": 1,\n  \"b\": [\n    2,\n    3\n  ]\n}")
        XCTAssertTrue(r.contains { $0.kind == .object && $0.startLine == 1 }, "\(r)")
        XCTAssertTrue(r.contains { $0.kind == .array && $0.startLine == 3 }, "\(r)")
    }

    func test_javascript_folds() throws {
        let r = try folds(.javascript, "function f() {\n  const o = {\n    a: 1\n  };\n  return o;\n}")
        XCTAssertTrue(r.contains { $0.kind == .function && $0.startLine == 1 }, "\(r)")
        XCTAssertTrue(r.contains { $0.kind == .object }, "\(r)")
    }

    func test_typescript_folds() throws {
        let r = try folds(.typescript, "interface Foo {\n  a: number;\n  b: string;\n}\nclass C {\n  m() {\n    return 1;\n  }\n}")
        XCTAssertTrue(r.contains { $0.kind == .type }, "interface/class fold: \(r)")
        XCTAssertTrue(r.contains { $0.kind == .function }, "method fold: \(r)")
    }

    func test_xml_folds() throws {
        let r = try folds(.xml, "<root>\n  <child>\n    <leaf/>\n  </child>\n</root>")
        XCTAssertTrue(r.contains { $0.kind == .element && $0.startLine == 1 }, "\(r)")
        XCTAssertTrue(r.contains { $0.kind == .element && $0.startLine == 2 }, "\(r)")
    }

    func test_swift_folds() throws {
        // The rust grammar is STATICALLY bundled (no dylib/rpath fragility —
        // a core motivation for the port): function body + control-flow fold.
        let r = try folds(.swift, "func f() {\n  if x {\n    a()\n    b()\n  }\n  return 1\n}")
        XCTAssertTrue(r.contains { $0.kind == .function }, "function-body fold, got \(r)")
        XCTAssertTrue(r.contains { $0.kind == .other }, "if control-flow fold, got \(r)")
    }

    func test_markdown_heading_folds() throws {
        let r = try folds(.markdown, "# A\nintro\n## B\nbody text\n# C\ntail\n")
        XCTAssertTrue(r.contains { $0.kind == .heading && $0.startLine == 1 }, "\(r)")
        XCTAssertTrue(r.contains { $0.kind == .heading && $0.startLine == 3 }, "\(r)")
    }

    // MARK: - Production entry (rust-only routing + degraded shape)

    func test_productionEntry_servesRust() {
        let r = RustFoldAdapter.foldRegions("{\n  \"a\": 1,\n  \"b\": 2\n}", language: .json)
        XCTAssertFalse(r.isEmpty, "the production entry serves the rust folds")
    }

    func test_unsupportedLanguage_degradesToEmpty_notCrash() {
        // plainText has no grammar on either side of history: the production
        // entry degrades to [] (observable log), never a throw or crash.
        XCTAssertTrue(RustFoldAdapter.foldRegions("just prose\n", language: .plainText).isEmpty)
    }
}
