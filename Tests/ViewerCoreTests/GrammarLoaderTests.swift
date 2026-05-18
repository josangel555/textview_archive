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
        // No dylibs are wired into the xctest bundle yet (Phase 2),
        // so a real load attempt must fail gracefully rather than
        // crash. This locks in the "never throw, always return nil"
        // contract callers rely on.
        let result = GrammarLoader.load(.rust)
        XCTAssertNil(result, "rust dylib should not be present in test bundle yet")
    }

    func testFailureIsMemoized() {
        // First call misses (no dylib). Second call must not re-attempt
        // the expensive dlopen path — that's the "failed once, stay
        // failed" optimization that keeps highlighting cheap for
        // unsupported languages.
        _ = GrammarLoader.load(.rust)
        // We can't directly observe whether dlopen was called twice,
        // but we can verify the second call returns nil consistently
        // (no transient success) — and the implementation is wired so
        // the cache hit short-circuits before resolve().
        let second = GrammarLoader.load(.rust)
        XCTAssertNil(second)
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
