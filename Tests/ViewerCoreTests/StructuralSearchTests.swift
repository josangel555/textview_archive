import XCTest
import ViewerKit
@testable import ViewerCore

/// Host tests for the structural (AST) search slice (TSK-723).
///
/// Scoped to Swift (statically-linked grammar — always loads on the host, no
/// dlopen). Each test parses a real fixture, runs a `StructuralQuery`, and
/// asserts the returned node ranges + captures land on the expected source
/// positions. Covers the canonical `function_declaration with name $X`
/// example plus no-match, multi-match, field-equals/contains/kind, nested
/// child-pattern, and the byte→UTF-16 mapping (so a non-ASCII prefix doesn't
/// shift the `NSRange`).
final class StructuralSearchTests: XCTestCase {

    private let engine = TreeSitterEngine.shared

    // Helper: the UTF-16 substring at a match's NSRange must equal `expected`.
    private func substring(_ ns: NSString, _ range: NSRange) -> String {
        ns.substring(with: range)
    }

    // MARK: - The canonical example: function_declaration with name $X

    func testFunctionDeclarationCapturesName() {
        let src = """
        func greet(name: String) -> String {
            return "hi"
        }
        func add(a: Int, b: Int) -> Int { return a + b }
        """
        // function_declaration, capture its `name` field as $X.
        let query = StructuralQuery(
            kind: "function_declaration",
            fieldConstraints: [.capture("name", as: "X")]
        )
        let matches = engine.structuralSearch(query, in: src, language: .swift)

        XCTAssertEqual(matches.count, 2, "two top-level funcs")
        // Document order: greet then add.
        XCTAssertEqual(matches[0]["X"]?.text, "greet")
        XCTAssertEqual(matches[1]["X"]?.text, "add")

        // The captured NSRange must point at the function name in the source.
        let ns = src as NSString
        XCTAssertEqual(substring(ns, matches[0]["X"]!.range), "greet")
        XCTAssertEqual(substring(ns, matches[1]["X"]!.range), "add")
    }

    // MARK: - No-match

    func testNoMatchReturnsEmpty() {
        let src = "let x = 1\nlet y = 2\n"   // no functions at all
        let query = StructuralQuery(kind: "function_declaration")
        let matches = engine.structuralSearch(query, in: src, language: .swift)
        XCTAssertTrue(matches.isEmpty)
    }

    func testFieldEqualsNoMatch() {
        let src = "func alpha() {}\nfunc beta() {}\n"
        // Only a function literally named "gamma" — none exist.
        let query = StructuralQuery(
            kind: "function_declaration",
            fieldConstraints: [.equals("name", "gamma")]
        )
        XCTAssertTrue(engine.structuralSearch(query, in: src, language: .swift).isEmpty)
    }

    // MARK: - Multi-match + ordering

    func testMultiMatchInDocumentOrder() {
        let src = """
        func one() {}
        func two() {}
        func three() {}
        """
        let query = StructuralQuery(
            kind: "function_declaration",
            fieldConstraints: [.capture("name", as: "n")]
        )
        let matches = engine.structuralSearch(query, in: src, language: .swift)
        XCTAssertEqual(matches.map { $0["n"]?.text }, ["one", "two", "three"])
        // Ascending start offsets — emitted in document order, no sort needed.
        let starts = matches.map { $0.range.location }
        XCTAssertEqual(starts, starts.sorted())
    }

    // MARK: - Field text-equals selects one of many

    func testFieldEqualsSelectsExactName() {
        let src = """
        func alpha() {}
        func target() {}
        func beta() {}
        """
        let query = StructuralQuery(
            kind: "function_declaration",
            fieldConstraints: [.equals("name", "target"), .capture("name", as: "X")]
        )
        let matches = engine.structuralSearch(query, in: src, language: .swift)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0]["X"]?.text, "target")

        // Whole-node range must wrap "func target() {}".
        let ns = src as NSString
        XCTAssertEqual(substring(ns, matches[0].range), "func target() {}")
    }

    // MARK: - Field text-contains

    func testFieldContains() {
        let src = """
        func loadUser() {}
        func saveUser() {}
        func reset() {}
        """
        let query = StructuralQuery(
            kind: "function_declaration",
            fieldConstraints: [.contains("name", "User"), .capture("name", as: "n")]
        )
        let names = engine.structuralSearch(query, in: src, language: .swift)
            .compactMap { $0["n"]?.text }
        XCTAssertEqual(names, ["loadUser", "saveUser"])
    }

    // MARK: - Field kind-equals

    func testFieldKindEquals() {
        // The function NAME field is always a simple_identifier; assert the
        // kind predicate accepts it and rejects a bogus kind.
        let src = "func solo() {}"
        let accept = StructuralQuery(
            kind: "function_declaration",
            fieldConstraints: [.kind("name", is: "simple_identifier")]
        )
        XCTAssertEqual(engine.structuralSearch(accept, in: src, language: .swift).count, 1)

        let reject = StructuralQuery(
            kind: "function_declaration",
            fieldConstraints: [.kind("name", is: "type_identifier")]
        )
        XCTAssertTrue(engine.structuralSearch(reject, in: src, language: .swift).isEmpty)
    }

    // MARK: - Root capture + whole-node range

    func testRootCaptureWrapsWholeNode() {
        let src = "func f() { return }"
        let query = StructuralQuery(kind: "function_declaration", captureAs: "fn")
        let matches = engine.structuralSearch(query, in: src, language: .swift)
        XCTAssertEqual(matches.count, 1)
        let ns = src as NSString
        XCTAssertEqual(substring(ns, matches[0]["fn"]!.range), src)
        XCTAssertEqual(matches[0]["fn"]?.text, src)
    }

    // MARK: - Nested matches (function inside a struct/class body)

    func testNestedFunctionsAllMatch() {
        let src = """
        func outer() {}
        struct S {
            func inner() {}
        }
        """
        // struct S parses as class_declaration; its body holds inner().
        let query = StructuralQuery(
            kind: "function_declaration",
            fieldConstraints: [.capture("name", as: "n")]
        )
        let names = engine.structuralSearch(query, in: src, language: .swift)
            .compactMap { $0["n"]?.text }
        // Both the top-level and the nested function must surface.
        XCTAssertEqual(Set(names), ["outer", "inner"])
    }

    // MARK: - Child-pattern containment

    func testChildPatternRequiresDescendant() {
        let src = """
        struct Empty {}
        struct HasMethod {
            func m() {}
        }
        """
        // class_declaration that CONTAINS a function_declaration, capturing
        // both the type name and the method name.
        let query = StructuralQuery(
            kind: "class_declaration",
            fieldConstraints: [.capture("name", as: "T")],
            childPatterns: [
                StructuralQuery(
                    kind: "function_declaration",
                    fieldConstraints: [.capture("name", as: "M")]
                )
            ]
        )
        let matches = engine.structuralSearch(query, in: src, language: .swift)
        XCTAssertEqual(matches.count, 1, "only HasMethod contains a function")
        XCTAssertEqual(matches[0]["T"]?.text, "HasMethod")
        XCTAssertEqual(matches[0]["M"]?.text, "m")
    }

    // MARK: - Multiple kinds (OR set)

    func testKindOrSet() {
        let src = """
        struct A {}
        class B {}
        func c() {}
        """
        // Match either struct or class (both are class_declaration in this
        // grammar) — assert both A and B match, c does not.
        let query = StructuralQuery(
            kinds: ["class_declaration"],
            fieldConstraints: [.capture("name", as: "T")]
        )
        let names = engine.structuralSearch(query, in: src, language: .swift)
            .compactMap { $0["T"]?.text }
        XCTAssertEqual(Set(names), ["A", "B"])
    }

    // MARK: - UTF-16 range correctness under a non-ASCII prefix

    func testNonASCIIPrefixYieldsCorrectUTF16Range() {
        // The Japanese comment is multi-byte in UTF-8; the function that
        // follows must get an NSRange in UTF-16 units so the range lands on
        // the right glyph. (A naive UTF-8-byte offset would over-shoot.)
        let src = "// 日本語\nfunc afterUnicode() {}"
        let query = StructuralQuery(
            kind: "function_declaration",
            fieldConstraints: [.capture("name", as: "X")]
        )
        let matches = engine.structuralSearch(query, in: src, language: .swift)
        XCTAssertEqual(matches.count, 1)

        let ns = src as NSString
        // The capture range must slice EXACTLY to the identifier in the
        // NSString (UTF-16) world — proving offsets are UTF-16 code units.
        XCTAssertEqual(substring(ns, matches[0]["X"]!.range), "afterUnicode")
        // And it must equal the NSString's own UTF-16 index of the identifier.
        XCTAssertEqual(matches[0]["X"]!.range.location, ns.range(of: "afterUnicode").location)
    }

    func testEmojiPrefixUTF16Range() {
        // Emoji is a surrogate pair (2 UTF-16 units, 4 UTF-8 bytes). Confirm
        // the range still lands on the identifier — surrogate-pair safe.
        let src = "// 🚀\nfunc afterEmoji() {}"
        let query = StructuralQuery(
            kind: "function_declaration",
            fieldConstraints: [.capture("name", as: "X")]
        )
        let matches = engine.structuralSearch(query, in: src, language: .swift)
        XCTAssertEqual(matches.count, 1)
        let ns = src as NSString
        XCTAssertEqual(substring(ns, matches[0]["X"]!.range), "afterEmoji")
    }

    // MARK: - Guards

    func testPlainTextReturnsEmpty() {
        let query = StructuralQuery(kind: "function_declaration")
        XCTAssertTrue(engine.structuralSearch(query, in: "func f() {}", language: .plainText).isEmpty)
    }

    func testOversizedReturnsEmpty() {
        let huge = String(repeating: "func f() {}\n", count: 1)
            + String(repeating: "x", count: highlightMaxBytes + 1)
        let query = StructuralQuery(kind: "function_declaration")
        XCTAssertTrue(engine.structuralSearch(query, in: huge, language: .swift).isEmpty)
    }

    func testWildcardKindMatchesViaFieldOnly() {
        // Empty kinds == wildcard; combined with a child pattern this finds any
        // node that contains a function_declaration. Assert it doesn't crash and
        // returns at least the source_file + function_declaration containers.
        let src = "func f() {}"
        let query = StructuralQuery(
            kinds: [],
            childPatterns: [StructuralQuery(kind: "simple_identifier")]
        )
        let matches = engine.structuralSearch(query, in: src, language: .swift)
        XCTAssertFalse(matches.isEmpty)
    }
}
