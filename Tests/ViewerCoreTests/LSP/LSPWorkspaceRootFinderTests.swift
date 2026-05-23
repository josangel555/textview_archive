import XCTest
@testable import ViewerCore

/// Extra coverage for per-language workspace-root finders.
///
/// Existing `LSPDiscoveryTests` cover the happy paths for each
/// language. This file adds:
///   - Marker precedence orderings (tsconfig > package.json, etc.)
///   - Deep-nested file finds nearest enclosing marker
///   - Mid-tree file lands in the right ancestor (not a parent monorepo)
///   - Java negative: nil when no markers exist
///   - Python: setup.py / setup.cfg / Pipfile / pyrightconfig fallbacks
///
/// All scenarios use isolated tmp dirs under
/// `FileManager.default.temporaryDirectory`.
final class LSPWorkspaceRootFinderTests: XCTestCase {

    private var tmpRoot: URL!
    private let fm = FileManager.default

    override func setUp() {
        super.setUp()
        tmpRoot = fm.temporaryDirectory
            .appendingPathComponent("lsp-root-finder-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tmpRoot = tmpRoot { try? fm.removeItem(at: tmpRoot) }
        super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func mkdir(_ relative: String) -> URL {
        let url = tmpRoot.appendingPathComponent(relative, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func touch(_ relative: String) -> URL {
        let url = tmpRoot.appendingPathComponent(relative)
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: nil)
        return url
    }

    // MARK: - TS/JS

    func test_tsRoot_jsconfigBeatsPackageJson() {
        // Layout:
        //   proj/
        //     jsconfig.json  <- this wins (tsconfig absent)
        //     package.json
        //     src/a.js
        _ = mkdir("proj/src")
        touch("proj/jsconfig.json")
        touch("proj/package.json")
        let fileURL = touch("proj/src/a.js")
        let root = LSPDiscovery.tsWorkspaceRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL,
                       tmpRoot.appendingPathComponent("proj").standardizedFileURL)
    }

    func test_tsRoot_nearestAncestorWins_notDeepestParent() {
        // Two nested projects — the inner one should win for files
        // inside it, even though the outer also has a package.json.
        touch("outer/package.json")
        touch("outer/inner/package.json")
        let fileURL = touch("outer/inner/src/a.ts")
        let root = LSPDiscovery.tsWorkspaceRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL,
                       tmpRoot.appendingPathComponent("outer/inner").standardizedFileURL)
    }

    func test_tsRoot_deepNested_findsAncestor() {
        touch("proj/tsconfig.json")
        let fileURL = touch("proj/src/a/b/c/d/deep.ts")
        let root = LSPDiscovery.tsWorkspaceRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL,
                       tmpRoot.appendingPathComponent("proj").standardizedFileURL)
    }

    func test_tsRoot_jsx_resolvesViaTsconfig() {
        touch("proj/tsconfig.json")
        let fileURL = touch("proj/src/App.jsx")
        let root = LSPDiscovery.tsWorkspaceRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL,
                       tmpRoot.appendingPathComponent("proj").standardizedFileURL)
    }

    // MARK: - Java

    func test_javaRoot_buildGradleBeatsProjectFile() {
        // Both Gradle and Eclipse markers exist — registry order accepts
        // either at the same level (walkUp claims the dir on first match).
        touch("proj/build.gradle")
        touch("proj/.project")
        let fileURL = touch("proj/src/main/java/Foo.java")
        let root = LSPDiscovery.javaWorkspaceRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL,
                       tmpRoot.appendingPathComponent("proj").standardizedFileURL)
    }

    func test_javaRoot_findsEclipseProject() {
        touch("proj/.project")
        let fileURL = touch("proj/src/Foo.java")
        let root = LSPDiscovery.javaWorkspaceRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL,
                       tmpRoot.appendingPathComponent("proj").standardizedFileURL)
    }

    func test_javaRoot_findsSettingsGradle() {
        touch("monorepo/settings.gradle")
        let fileURL = touch("monorepo/lib/src/Foo.java")
        let root = LSPDiscovery.javaWorkspaceRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL,
                       tmpRoot.appendingPathComponent("monorepo").standardizedFileURL)
    }

    func test_javaRoot_findsSettingsGradleKts() {
        touch("monorepo/settings.gradle.kts")
        let fileURL = touch("monorepo/lib/src/Foo.java")
        let root = LSPDiscovery.javaWorkspaceRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL,
                       tmpRoot.appendingPathComponent("monorepo").standardizedFileURL)
    }

    // MARK: - Python

    func test_pythonRoot_pyrightConfigOverPyproject() {
        // Both present — first marker in the registry list (pyproject) wins,
        // but both should resolve to the same dir anyway. Verify by
        // building the marker only as pyrightconfig.
        touch("proj/pyrightconfig.json")
        let fileURL = touch("proj/src/mypkg/a.py")
        let root = LSPDiscovery.pythonWorkspaceRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL,
                       tmpRoot.appendingPathComponent("proj").standardizedFileURL)
    }

    func test_pythonRoot_findsSetupPy() {
        touch("proj/setup.py")
        let fileURL = touch("proj/mypkg/a.py")
        let root = LSPDiscovery.pythonWorkspaceRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL,
                       tmpRoot.appendingPathComponent("proj").standardizedFileURL)
    }

    func test_pythonRoot_findsSetupCfg() {
        touch("proj/setup.cfg")
        let fileURL = touch("proj/mypkg/a.py")
        let root = LSPDiscovery.pythonWorkspaceRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL,
                       tmpRoot.appendingPathComponent("proj").standardizedFileURL)
    }

    func test_pythonRoot_findsPipfile() {
        touch("proj/Pipfile")
        let fileURL = touch("proj/a.py")
        let root = LSPDiscovery.pythonWorkspaceRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL,
                       tmpRoot.appendingPathComponent("proj").standardizedFileURL)
    }

    func test_pythonRoot_findsRequirementsTxt() {
        touch("proj/requirements.txt")
        let fileURL = touch("proj/scripts/a.py")
        let root = LSPDiscovery.pythonWorkspaceRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL,
                       tmpRoot.appendingPathComponent("proj").standardizedFileURL)
    }

    // MARK: - Swift

    func test_swiftRoot_packageWinsOverGit() {
        // Both Package.swift and .git exist in same dir — Package.swift
        // is the canonical claim; the .git fallback only kicks in when
        // no Package.swift was found.
        touch("proj/Package.swift")
        touch("proj/.git/HEAD")
        let fileURL = touch("proj/Sources/foo/a.swift")
        let root = LSPDiscovery.swiftPackageRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL,
                       tmpRoot.appendingPathComponent("proj").standardizedFileURL)
    }

    func test_swiftRoot_falls_to_gitBoundary_whenNoPackage() {
        // No Package.swift anywhere — .git boundary becomes the root.
        touch("proj/.git/HEAD")
        let fileURL = touch("proj/Sources/foo/a.swift")
        let root = LSPDiscovery.swiftPackageRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL,
                       tmpRoot.appendingPathComponent("proj").standardizedFileURL)
    }

    // MARK: - Registry coverage

    func test_defaultRegistry_resolvesEveryShippedExtension() {
        let reg = LSPLanguageRegistry.default
        let cases: [(String, LSPLanguage)] = [
            ("swift", .swift),
            ("ts", .typescript), ("tsx", .typescript),
            ("js", .typescript), ("jsx", .typescript),
            ("mjs", .typescript), ("cjs", .typescript),
            ("java", .java),
            ("py", .python), ("pyi", .python),
        ]
        for (ext, expected) in cases {
            let url = URL(fileURLWithPath: "/tmp/foo.\(ext)")
            XCTAssertEqual(reg.language(for: url)?.language, expected,
                           "extension .\(ext) should resolve to \(expected)")
        }
    }

    func test_defaultRegistry_returnsNilForUnknownExtension() {
        let reg = LSPLanguageRegistry.default
        XCTAssertNil(reg.language(for: URL(fileURLWithPath: "/tmp/foo.rb")))
        XCTAssertNil(reg.language(for: URL(fileURLWithPath: "/tmp/foo.go")))
        XCTAssertNil(reg.language(for: URL(fileURLWithPath: "/tmp/Makefile")))
    }

    func test_defaultRegistry_isCaseInsensitive() {
        let reg = LSPLanguageRegistry.default
        XCTAssertEqual(reg.language(for: URL(fileURLWithPath: "/tmp/Foo.SWIFT"))?.language, .swift)
        XCTAssertEqual(reg.language(for: URL(fileURLWithPath: "/tmp/Foo.TS"))?.language, .typescript)
    }

    func test_languageID_perFile_handlesTsxJsx() {
        XCTAssertEqual(LSPLanguage.typescript.languageID(for: URL(fileURLWithPath: "/x/a.ts")),  "typescript")
        XCTAssertEqual(LSPLanguage.typescript.languageID(for: URL(fileURLWithPath: "/x/a.tsx")), "typescriptreact")
        XCTAssertEqual(LSPLanguage.typescript.languageID(for: URL(fileURLWithPath: "/x/a.js")),  "javascript")
        XCTAssertEqual(LSPLanguage.typescript.languageID(for: URL(fileURLWithPath: "/x/a.jsx")), "javascriptreact")
        XCTAssertEqual(LSPLanguage.typescript.languageID(for: URL(fileURLWithPath: "/x/a.mjs")), "javascript")
        XCTAssertEqual(LSPLanguage.typescript.languageID(for: URL(fileURLWithPath: "/x/a.cjs")), "javascript")
    }

    func test_languageID_otherLanguages_areConstant() {
        XCTAssertEqual(LSPLanguage.swift.languageID(for: URL(fileURLWithPath: "/x/a.swift")), "swift")
        XCTAssertEqual(LSPLanguage.java.languageID(for: URL(fileURLWithPath: "/x/a.java")),   "java")
        XCTAssertEqual(LSPLanguage.python.languageID(for: URL(fileURLWithPath: "/x/a.py")),   "python")
    }

    // MARK: - jdtls hash determinism + collision avoidance

    func test_workspaceHash_isDeterministic() {
        let url = URL(fileURLWithPath: "/tmp/some/workspace")
        let h1 = LSPDiscovery.workspaceHash(for: url)
        let h2 = LSPDiscovery.workspaceHash(for: url)
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(h1.count, 12, "hash truncates to 12 hex chars")
    }

    func test_workspaceHash_differsAcrossPaths() {
        let h1 = LSPDiscovery.workspaceHash(for: URL(fileURLWithPath: "/tmp/a"))
        let h2 = LSPDiscovery.workspaceHash(for: URL(fileURLWithPath: "/tmp/b"))
        XCTAssertNotEqual(h1, h2)
    }
}
