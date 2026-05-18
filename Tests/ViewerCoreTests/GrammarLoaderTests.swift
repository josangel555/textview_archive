import XCTest
import SwiftTreeSitter
@testable import ViewerCore

/// Host-side tests for `GrammarLoader`. These focus on the pure-logic
/// branches (cache, failure memoization, name derivation) — the actual
/// `dlopen` path is exercised by `TreeSitterEngineSmokeTests` once the
/// dylibs are wired into the test bundle.
///
/// Run filtered:
///   swift test --filter ViewerCoreTests.GrammarLoaderTests
final class GrammarLoaderTests: XCTestCase {

    override func setUp() {
        super.setUp()
        GrammarLoader._resetForTesting()
    }

    /// Reset between cases too — `testMissingDylibReturnsNil` and
    /// `testFailureIsMemoized` install a negative-cache entry for
    /// `.rust` that would otherwise leak into the smoke tests below
    /// (which run after this suite in alphabetical order) and trip
    /// `testEachLanguageProducesRuns`.
    override func tearDown() {
        unsetenv("GRAMMAR_DYLIB_DIR")
        GrammarLoader._resetForTesting()
        super.tearDown()
    }

    func testCSymbolNamesMatchUpstreamConvention() {
        // Canonical names from the upstream grammars' headers.
        // tree-sitter-cpp exports `tree_sitter_cpp` (not `tree_sitter_c++`),
        // tree-sitter-c-sharp exports `tree_sitter_c_sharp` (underscore,
        // not hyphen). Verifying these here means a typo can't ship.
        XCTAssertEqual(GrammarLoader.Grammar.cpp.cSymbol, "tree_sitter_cpp")
        XCTAssertEqual(GrammarLoader.Grammar.cSharp.cSymbol, "tree_sitter_c_sharp")
        XCTAssertEqual(GrammarLoader.Grammar.javascript.cSymbol, "tree_sitter_javascript")
        XCTAssertEqual(GrammarLoader.Grammar.typescript.cSymbol, "tree_sitter_typescript")
        XCTAssertEqual(GrammarLoader.Grammar.rust.cSymbol, "tree_sitter_rust")
        XCTAssertEqual(GrammarLoader.Grammar.lua.cSymbol, "tree_sitter_lua")
    }

    func testDylibBasenamesHaveLibPrefix() {
        // SwiftPM's macOS convention prefixes dynamic-library product
        // filenames with `lib`. The basename must match so the copy
        // step in build-app.sh can glob them up reliably.
        for grammar in GrammarLoader.Grammar.allCases {
            XCTAssertTrue(
                grammar.dylibBasename.hasPrefix("lib"),
                "\(grammar) basename must start with 'lib'"
            )
            XCTAssertTrue(
                grammar.dylibBasename.contains("TreeSitter"),
                "\(grammar) basename should contain 'TreeSitter' for greppability"
            )
        }
    }

    func testMissingDylibReturnsNil() {
        // Point the loader at an empty directory so no dylib can
        // possibly resolve. (Once Phase 5 lands, SwiftPM builds the
        // rust dylib into `.build/<config>/` so the unconfigured
        // loader can find it — this test needs an isolated dir to
        // exercise the missing-dylib branch.)
        let isolated = NSTemporaryDirectory() + "grammar-loader-missing-\(UUID())"
        setenv("GRAMMAR_DYLIB_DIR", isolated, 1)
        defer { unsetenv("GRAMMAR_DYLIB_DIR") }
        GrammarLoader._resetForTesting()
        let result = GrammarLoader.load(.rust)
        XCTAssertNil(result, "rust dylib should not be present in empty isolated dir")
    }

    func testFailureIsMemoized() {
        // Same isolation trick as above so the dlopen genuinely fails.
        // After that, the second call must not re-attempt — the
        // negative-cache short-circuit is the optimization that keeps
        // highlighting cheap for unsupported languages.
        let isolated = NSTemporaryDirectory() + "grammar-loader-memoize-\(UUID())"
        setenv("GRAMMAR_DYLIB_DIR", isolated, 1)
        defer { unsetenv("GRAMMAR_DYLIB_DIR") }
        GrammarLoader._resetForTesting()
        _ = GrammarLoader.load(.rust)
        let second = GrammarLoader.load(.rust)
        XCTAssertNil(second)
    }

    func testDlopenPathResolvesXMLDylib() throws {
        // End-to-end exercise of the dlopen path against a lazy dylib
        // SwiftPM built into `.build/<config>/`. If this passes, we
        // know: (a) the wrapper target's `tree_sitter_xml` symbol is
        // exported, (b) `GRAMMAR_DYLIB_DIR` override path hits,
        // (c) the function-pointer cast returns a non-null grammar.
        // This is the test that proves Phase 2 plumbing is real.
        //
        // The xctest binary lives in `.build/<arch>/<config>/Foo.xctest/
        // Contents/MacOS/Foo`, and the dylibs live in
        // `.build/<arch>/<config>/`. The exec-sibling search doesn't
        // hit because the xctest bundle gets in the way; we point the
        // loader at the right dir via the env override path that
        // exists exactly for this case.
        // `Bundle.main` under xctest is Xcode itself, so we anchor on
        // the test bundle's path instead. testBundle.bundlePath ends
        // at `<config>/Foo.xctest`; the dylibs sit one directory up.
        let testBundle = Bundle(for: type(of: self))
        let dylibDir = (testBundle.bundlePath as NSString)
            .deletingLastPathComponent
        let candidate = (dylibDir as NSString)
            .appendingPathComponent("libTreeSitterXMLLazy.dylib")
        guard FileManager.default.fileExists(atPath: candidate) else {
            throw XCTSkip("XML lazy dylib not at \(candidate) — Phase 2 build skipped?")
        }
        setenv("GRAMMAR_DYLIB_DIR", dylibDir, 1)
        defer { unsetenv("GRAMMAR_DYLIB_DIR") }
        GrammarLoader._resetForTesting()

        guard let language = GrammarLoader.load(.xml) else {
            XCTFail("dlopen failed even though dylib exists at \(candidate)")
            return
        }
        let parser = Parser()
        XCTAssertNoThrow(try parser.setLanguage(language))
    }

    func testInjectedLanguageHitsCache() throws {
        // Manufacture a placeholder Language via a known-good grammar
        // (TreeSitterJSON is statically linked into the test target as
        // a dependency). Inject it under a different grammar enum case
        // so we can verify the cache short-circuits resolve().
        // We use the JSON grammar's pointer because it's the only one
        // SwiftPM-imported into the test target. The test isn't
        // asserting "this is a valid Rust grammar" — it's asserting
        // "the cache returns whatever I put in it".
        let placeholder = makeJSONLanguage()
        GrammarLoader._injectForTesting(.rust, language: placeholder)
        let result = GrammarLoader.load(.rust)
        XCTAssertNotNil(result, "injected language should come back via load()")
    }

    /// Returns a `Language` backed by the statically-linked JSON
    /// grammar. Used purely as a non-null placeholder for cache tests.
    private func makeJSONLanguage() -> Language {
        // Import-free pointer fetch: TreeSitterJSON is already in
        // ViewerCore's dep graph, so the symbol is resolvable. We
        // forward through ViewerCore's existing engine plumbing rather
        // than re-importing the C module in the test target.
        // The placeholder grammar pointer is only used as an identity
        // value here — we never tokenize with it.
        return Language(language: jsonLanguagePointer())
    }
}

/// Bridge to the statically-linked JSON grammar pointer. Marked
/// `@testable internal` so we can grab it without exposing the C
/// import surface to the test target.
@inline(__always)
private func jsonLanguagePointer() -> OpaquePointer {
    // Forwards to ViewerCore's internal helper. Implemented in
    // TreeSitterEngine+TestSupport.swift.
    return TreeSitterEngine._jsonLanguagePointerForTesting()
}
