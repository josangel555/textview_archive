import XCTest
@testable import ViewerCore

/// `LSPVSCodeExtensions` — discovery of language servers bundled inside an
/// installed VS Code-family editor's extensions (TSK-797). All I/O is
/// injected, so these run host-only against a fabricated tmp tree with no
/// real VS Code install.
final class LSPVSCodeExtensionsTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lsp-vscode-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        tmpRoot = base
    }

    override func tearDown() {
        if let tmpRoot { try? FileManager.default.removeItem(at: tmpRoot) }
        super.tearDown()
    }

    // MARK: - Recipe table (the homework: which languages we contribute)

    func test_recipes_javaHasRedHatExtension() {
        let r = LSPVSCodeExtensions.recipes(for: .java)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.extensionIDPrefix, "redhat.java")
        XCTAssertTrue(r.first?.relativeBinaryPaths.contains("bin/jdtls") ?? false)
    }

    func test_recipes_swiftIsEmpty_usesXcrunToolchain() {
        // Swift extension defers to the toolchain's sourcekit-lsp (xcrun),
        // so we deliberately contribute nothing here.
        XCTAssertTrue(LSPVSCodeExtensions.recipes(for: .swift).isEmpty)
    }

    func test_recipes_typescriptIsEmpty_builtinNotStandalone() {
        XCTAssertTrue(LSPVSCodeExtensions.recipes(for: .typescript).isEmpty)
    }

    func test_recipes_pythonIsEmpty_pylanceProprietary() {
        XCTAssertTrue(LSPVSCodeExtensions.recipes(for: .python).isEmpty)
    }

    // MARK: - Directory-name matching

    func test_matches_prefixWithTrailingDash() {
        XCTAssertTrue(LSPVSCodeExtensions.matches(
            dirName: "redhat.java-1.36.0", prefix: "redhat.java"))
        XCTAssertTrue(LSPVSCodeExtensions.matches(
            dirName: "redhat.java-1.36.0-darwin-arm64", prefix: "redhat.java"))
    }

    func test_matches_caseInsensitive() {
        XCTAssertTrue(LSPVSCodeExtensions.matches(
            dirName: "RedHat.Java-1.36.0", prefix: "redhat.java"))
    }

    func test_matches_requiresDash_soSiblingPublisherDoesNotLeak() {
        // `redhat.java` must NOT match a hypothetical `redhat.javaee-...`
        // — the dash boundary prevents the substring false-positive.
        XCTAssertFalse(LSPVSCodeExtensions.matches(
            dirName: "redhat.javaee-2.0.0", prefix: "redhat.java"))
        XCTAssertFalse(LSPVSCodeExtensions.matches(
            dirName: "extensions.json", prefix: "redhat.java"))
    }

    // MARK: - Version parsing

    func test_parseVersion_plainSemver() {
        XCTAssertEqual(
            LSPVSCodeExtensions.parseVersion(
                fromDirName: "redhat.java-1.36.0", prefix: "redhat.java"),
            [1, 36, 0])
    }

    func test_parseVersion_stripsPlatformTag() {
        // The real-world rust-analyzer naming: trailing `-darwin-arm64`.
        XCTAssertEqual(
            LSPVSCodeExtensions.parseVersion(
                fromDirName: "rust-lang.rust-analyzer-0.3.2937-darwin-arm64",
                prefix: "rust-lang.rust-analyzer"),
            [0, 3, 2937])
    }

    func test_parseVersion_unparseableIsEmpty() {
        XCTAssertEqual(
            LSPVSCodeExtensions.parseVersion(
                fromDirName: "redhat.java-snapshot", prefix: "redhat.java"),
            [])
    }

    // MARK: - Version ordering

    func test_versionLess_patchOrdering() {
        XCTAssertTrue(LSPVSCodeExtensions.versionLess([0, 3, 2929], [0, 3, 2937]))
        XCTAssertFalse(LSPVSCodeExtensions.versionLess([0, 3, 2937], [0, 3, 2929]))
    }

    func test_versionLess_majorBeatsMinor() {
        XCTAssertTrue(LSPVSCodeExtensions.versionLess([0, 9, 9], [1, 0, 0]))
    }

    func test_versionLess_zeroPadsShorter() {
        XCTAssertTrue(LSPVSCodeExtensions.versionLess([1, 0], [1, 0, 1]))
        XCTAssertFalse(LSPVSCodeExtensions.versionLess([1, 0, 0], [1, 0]))
    }

    func test_versionLess_emptyIsLowest() {
        XCTAssertTrue(LSPVSCodeExtensions.versionLess([], [0, 0, 1]))
        XCTAssertFalse(LSPVSCodeExtensions.versionLess([0, 0, 1], []))
    }

    // MARK: - End-to-end resolution (fabricated tmp HOME)

    /// Build `<tmpHome>/.vscode/extensions/redhat.java-<ver>/bin/jdtls`,
    /// executable + safe perms. Returns the binary URL.
    @discardableResult
    private func makeJdtls(version: String, in editorRoot: String = ".vscode/extensions",
                          binRel: String = "bin/jdtls") -> URL {
        let extDir = tmpRoot
            .appendingPathComponent(editorRoot, isDirectory: true)
            .appendingPathComponent("redhat.java-\(version)", isDirectory: true)
        let bin = extDir.appendingPathComponent(binRel)
        try? FileManager.default.createDirectory(
            at: bin.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        FileManager.default.createFile(
            atPath: bin.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755])
        return bin
    }

    func test_locateServer_findsJdtlsInVSCodeExtensions() {
        let bin = makeJdtls(version: "1.36.0")
        let found = LSPVSCodeExtensions.locateServer(for: .java, home: tmpRoot)
        XCTAssertEqual(found?.standardizedFileURL, bin.standardizedFileURL)
    }

    func test_locateServer_picksNewestVersion() {
        makeJdtls(version: "1.30.0")
        let newest = makeJdtls(version: "1.36.0")
        makeJdtls(version: "1.5.2") // lexically > "1.36" but numerically <
        let found = LSPVSCodeExtensions.locateServer(for: .java, home: tmpRoot)
        XCTAssertEqual(
            found?.standardizedFileURL, newest.standardizedFileURL,
            "must pick 1.36.0 numerically, not lexically (where 1.5.2 > 1.36.0)")
    }

    func test_locateServer_returnsNilWhenNoExtensionInstalled() {
        // Empty home — no .vscode at all.
        XCTAssertNil(LSPVSCodeExtensions.locateServer(for: .java, home: tmpRoot))
    }

    func test_locateServer_returnsNilForLanguageWithoutRecipe() {
        // Even if some extension dir exists, swift contributes no recipe.
        makeJdtls(version: "1.36.0")
        XCTAssertNil(LSPVSCodeExtensions.locateServer(for: .swift, home: tmpRoot))
        XCTAssertNil(LSPVSCodeExtensions.locateServer(for: .typescript, home: tmpRoot))
        XCTAssertNil(LSPVSCodeExtensions.locateServer(for: .python, home: tmpRoot))
    }

    func test_locateServer_searchesAlternateEditors() {
        // jdtls only under .cursor/extensions — still found.
        let bin = makeJdtls(version: "1.36.0", in: ".cursor/extensions")
        let found = LSPVSCodeExtensions.locateServer(for: .java, home: tmpRoot)
        XCTAssertEqual(found?.standardizedFileURL, bin.standardizedFileURL)
    }

    func test_locateServer_triesAlternateRelativePath() {
        // Server at `server/bin/jdtls` (the second recipe path), not `bin/jdtls`.
        let bin = makeJdtls(version: "1.36.0", binRel: "server/bin/jdtls")
        let found = LSPVSCodeExtensions.locateServer(for: .java, home: tmpRoot)
        XCTAssertEqual(found?.standardizedFileURL, bin.standardizedFileURL)
    }

    func test_locateServer_skipsNonExecutable() {
        // A present-but-not-executable file is not a valid server.
        let extDir = tmpRoot
            .appendingPathComponent(".vscode/extensions/redhat.java-1.36.0", isDirectory: true)
        let bin = extDir.appendingPathComponent("bin/jdtls")
        try? FileManager.default.createDirectory(
            at: bin.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        FileManager.default.createFile(
            atPath: bin.path, contents: nil, attributes: [.posixPermissions: 0o644])
        XCTAssertNil(LSPVSCodeExtensions.locateServer(for: .java, home: tmpRoot))
    }

    func test_locateServer_appliesSafetyGate() {
        // A discoverable, executable jdtls in a world-writable extension
        // dir must be refused by the spawn-safety gate (same as PATH).
        let bin = makeJdtls(version: "1.36.0")
        // Make the extension dir world-writable.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: bin.deletingLastPathComponent().path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: bin.deletingLastPathComponent().path)
        }
        XCTAssertNil(
            LSPVSCodeExtensions.locateServer(for: .java, home: tmpRoot),
            "a jdtls in a 0777 extension dir must be refused")
    }
}
