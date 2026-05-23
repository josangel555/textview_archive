import XCTest
@testable import ViewerCore

/// Pure-logic tests for the `LSPLanguageRegistry` extension point.
final class LSPLanguageRegistryTests: XCTestCase {

    func test_default_registry_resolves_swift_extension() {
        let url = URL(fileURLWithPath: "/tmp/x/Foo.swift")
        let entry = LSPLanguageRegistry.default.language(for: url)
        XCTAssertEqual(entry?.language, .swift)
    }

    func test_default_registry_caseInsensitive() {
        let url = URL(fileURLWithPath: "/tmp/x/Foo.SWIFT")
        let entry = LSPLanguageRegistry.default.language(for: url)
        XCTAssertEqual(entry?.language, .swift)
    }

    func test_default_registry_unknownExtensionReturnsNil() {
        let url = URL(fileURLWithPath: "/tmp/x/Foo.md")
        XCTAssertNil(LSPLanguageRegistry.default.language(for: url))
    }

    func test_default_registry_noExtensionReturnsNil() {
        let url = URL(fileURLWithPath: "/tmp/x/Makefile")
        XCTAssertNil(LSPLanguageRegistry.default.language(for: url))
    }

    func test_custom_registry_lookup() {
        // Mock a fake "python" entry so we exercise the registry's
        // dispatch logic without needing pyright on disk. (The default
        // registry now has a real .python entry, so we use a custom
        // registry to isolate the lookup logic from it.)
        let pythonEntry = LSPLanguageEntry(
            language: .python,
            fileExtensions: ["py", "pyi"],
            rootFinder: { _ in URL(fileURLWithPath: "/tmp/root") },
            serverLauncher: { _ in nil }
        )
        let registry = LSPLanguageRegistry(entries: [pythonEntry])
        XCTAssertNotNil(registry.language(for: URL(fileURLWithPath: "/x/a.py")))
        XCTAssertNotNil(registry.language(for: URL(fileURLWithPath: "/x/a.pyi")))
        XCTAssertNil(registry.language(for: URL(fileURLWithPath: "/x/a.swift")))
    }

    // MARK: - Multi-language coverage

    func test_default_registry_resolves_typescript_extensions() {
        for ext in ["ts", "tsx", "js", "jsx", "mjs", "cjs"] {
            let url = URL(fileURLWithPath: "/tmp/x/Foo.\(ext)")
            let entry = LSPLanguageRegistry.default.language(for: url)
            XCTAssertEqual(entry?.language, .typescript,
                           "ext .\(ext) should map to .typescript")
        }
    }

    func test_default_registry_resolves_java_extension() {
        let url = URL(fileURLWithPath: "/tmp/x/Foo.java")
        let entry = LSPLanguageRegistry.default.language(for: url)
        XCTAssertEqual(entry?.language, .java)
    }

    func test_default_registry_resolves_python_extensions() {
        for ext in ["py", "pyi"] {
            let url = URL(fileURLWithPath: "/tmp/x/a.\(ext)")
            let entry = LSPLanguageRegistry.default.language(for: url)
            XCTAssertEqual(entry?.language, .python,
                           "ext .\(ext) should map to .python")
        }
    }

    // MARK: - Per-file languageID (TypeScript variants)

    func test_languageID_typescript_perExtension() {
        XCTAssertEqual(
            LSPLanguage.typescript.languageID(
                for: URL(fileURLWithPath: "/x/a.ts")),
            "typescript")
        XCTAssertEqual(
            LSPLanguage.typescript.languageID(
                for: URL(fileURLWithPath: "/x/a.tsx")),
            "typescriptreact")
        XCTAssertEqual(
            LSPLanguage.typescript.languageID(
                for: URL(fileURLWithPath: "/x/a.js")),
            "javascript")
        XCTAssertEqual(
            LSPLanguage.typescript.languageID(
                for: URL(fileURLWithPath: "/x/a.jsx")),
            "javascriptreact")
        XCTAssertEqual(
            LSPLanguage.typescript.languageID(
                for: URL(fileURLWithPath: "/x/a.mjs")),
            "javascript")
    }

    func test_languageID_swift_isStablePerFile() {
        // Swift only has the one extension — verify the per-file
        // accessor returns the same as the static.
        XCTAssertEqual(
            LSPLanguage.swift.languageID(
                for: URL(fileURLWithPath: "/x/a.swift")),
            "swift")
    }

    // MARK: - Install hints

    func test_installHint_presentForNonSwiftLanguages() {
        XCTAssertNotNil(LSPLanguage.typescript.installHint)
        XCTAssertNotNil(LSPLanguage.python.installHint)
        XCTAssertNotNil(LSPLanguage.java.installHint)
        // Swift ships with the toolchain — no install step.
        XCTAssertNil(LSPLanguage.swift.installHint)
    }

    func test_binaryName_setForAllLanguages() {
        XCTAssertEqual(LSPLanguage.swift.binaryName, "sourcekit-lsp")
        XCTAssertEqual(LSPLanguage.typescript.binaryName,
                       "typescript-language-server")
        XCTAssertEqual(LSPLanguage.java.binaryName, "jdtls")
        XCTAssertEqual(LSPLanguage.python.binaryName, "pyright-langserver")
    }
}
