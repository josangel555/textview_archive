import XCTest
@testable import ViewerCore
import ViewerKit

/// A/B parity (TSK-1202): the Rust fold engine (via `RustFoldAdapter.rustFolds`
/// → the real `.a`) vs the SHIPPING Swift `TreeSitterEngine.computeFoldsSync`,
/// across the six fold languages. The Rust port must produce the SAME fold
/// regions — the strongest validation that the engine slices (1–3) match the
/// incumbent. Forces the Rust path (no gate); fold-region identity is the
/// `(startLine, endLine, kind)` triple, so a Set compare ignores any tie-break.
final class RustFoldParityTests: XCTestCase {

    private func assertParity(
        _ lang: HighlightLanguage, _ text: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rust = try RustFoldAdapter.rustFolds(text, language: lang)
        let swift = TreeSitterEngine.shared.computeFoldsSync(text: text, language: lang)
        XCTAssertEqual(
            Set(rust), Set(swift),
            "fold parity diverged for \(lang.rawValue): rust=\(rust) swift=\(swift)",
            file: file, line: line)
    }

    func test_json_fold_parity() throws {
        try assertParity(.json, "{\n  \"a\": 1,\n  \"b\": [\n    2,\n    3\n  ]\n}")
    }

    func test_javascript_fold_parity() throws {
        try assertParity(.javascript, "function f() {\n  const o = {\n    a: 1\n  };\n  return o;\n}")
    }

    func test_typescript_fold_parity() throws {
        try assertParity(.typescript, "interface Foo {\n  a: number;\n  b: string;\n}\nclass C {\n  m() {\n    return 1;\n  }\n}")
    }

    func test_xml_fold_parity() throws {
        try assertParity(.xml, "<root>\n  <child>\n    <leaf/>\n  </child>\n</root>")
    }

    func test_swift_folds_directly() throws {
        // The Swift TreeSitterEngine returns [] for swift in the HOST TEST context
        // (its swift grammar is a lazily-loaded dylib not on the test's rpath) — a
        // fragility the rust port's STATICALLY-bundled grammar eliminates, which is
        // a core motivation for TSK-1202. So assert the rust folds DIRECTLY rather
        // than against an empty incumbent: the function body + the if's control-flow
        // statements both fold.
        let rust = try RustFoldAdapter.rustFolds(
            "func f() {\n  if x {\n    a()\n    b()\n  }\n  return 1\n}", language: .swift)
        XCTAssertTrue(rust.contains { $0.kind == .function }, "function-body fold, got \(rust)")
        XCTAssertTrue(rust.contains { $0.kind == .other }, "if control-flow fold, got \(rust)")
    }

    func test_markdown_fold_parity() throws {
        try assertParity(.markdown, "# A\nintro\n## B\nbody text\n# C\ntail\n")
    }
}
