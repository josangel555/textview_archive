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
        // dispatch logic without needing pyright on disk.
        let pythonEntry = LSPLanguageEntry(
            language: .swift, // reuse — there's only one case today
            fileExtensions: ["py", "pyi"],
            rootFinder: { _ in URL(fileURLWithPath: "/tmp/root") },
            serverLauncher: { _ in nil }
        )
        let registry = LSPLanguageRegistry(entries: [pythonEntry])
        XCTAssertNotNil(registry.language(for: URL(fileURLWithPath: "/x/a.py")))
        XCTAssertNotNil(registry.language(for: URL(fileURLWithPath: "/x/a.pyi")))
        XCTAssertNil(registry.language(for: URL(fileURLWithPath: "/x/a.swift")))
    }
}
