import XCTest
@testable import ViewerCore

/// `LSPDiscovery` — exercise the generic `walkUp` helper without
/// touching the live filesystem heuristics (which the smoke test covers).
final class LSPDiscoveryTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lsp-disc-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        tmpRoot = base
    }

    override func tearDown() {
        if let tmpRoot = tmpRoot {
            try? FileManager.default.removeItem(at: tmpRoot)
        }
        super.tearDown()
    }

    func test_walkUp_findsMarkerInOwnDir() {
        let dir = tmpRoot.appendingPathComponent("proj")
        let marker = dir.appendingPathComponent("MARKER")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        let fileURL = dir.appendingPathComponent("a.swift")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        let root = LSPDiscovery.walkUp(from: fileURL) { dir in
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("MARKER").path)
        }
        XCTAssertEqual(root?.standardizedFileURL, dir.standardizedFileURL)
    }

    func test_walkUp_findsMarkerInAncestor() {
        let root = tmpRoot.appendingPathComponent("proj")
        let sub = root.appendingPathComponent("sub").appendingPathComponent("deep")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("MARKER").path, contents: nil)
        let fileURL = sub.appendingPathComponent("a.swift")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        let found = LSPDiscovery.walkUp(from: fileURL) { dir in
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("MARKER").path)
        }
        XCTAssertEqual(found?.standardizedFileURL, root.standardizedFileURL)
    }

    func test_walkUp_returnsNilWhenNoMatch() {
        // Search for a marker that doesn't exist anywhere up the tree.
        let dir = tmpRoot.appendingPathComponent("proj")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("a.swift")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        // The walk stops at the home dir / fs root; our tmpRoot is
        // somewhere under /var/folders, so we should hit the fs-root
        // bail-out (or home-dir bail-out — both fine).
        let found = LSPDiscovery.walkUp(from: fileURL) { dir in
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("NONEXISTENT_MARKER").path)
        }
        XCTAssertNil(found)
    }

    func test_swiftPackageRoot_findsPackageSwift() {
        let dir = tmpRoot.appendingPathComponent("proj")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("Package.swift").path, contents: nil)
        let fileURL = dir.appendingPathComponent("Sources").appendingPathComponent("a.swift")
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let root = LSPDiscovery.swiftPackageRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL, dir.standardizedFileURL)
    }

    // MARK: - TS / JS workspace root

    func test_tsWorkspaceRoot_picks_tsconfig_overPackageJson() {
        // Layout:
        //   proj/
        //     tsconfig.json   <- this wins
        //     package.json
        //     src/a.ts
        let dir = tmpRoot.appendingPathComponent("proj")
        let src = dir.appendingPathComponent("src")
        try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("tsconfig.json").path, contents: nil)
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("package.json").path, contents: nil)
        let fileURL = src.appendingPathComponent("a.ts")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        let root = LSPDiscovery.tsWorkspaceRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL, dir.standardizedFileURL)
    }

    func test_tsWorkspaceRoot_picks_packageJsonWhenNoTsconfig() {
        let dir = tmpRoot.appendingPathComponent("proj")
        let src = dir.appendingPathComponent("src")
        try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("package.json").path, contents: nil)
        let fileURL = src.appendingPathComponent("a.js")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        let root = LSPDiscovery.tsWorkspaceRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL, dir.standardizedFileURL)
    }

    func test_tsWorkspaceRoot_singleFile_fallsBackToParent() {
        // No markers anywhere — single-file mode returns the file's
        // immediate parent so we still spin up an LSP session.
        let dir = tmpRoot.appendingPathComponent("loose")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("scratch.ts")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        let root = LSPDiscovery.tsWorkspaceRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL, dir.standardizedFileURL)
    }

    // MARK: - Java workspace root

    func test_javaWorkspaceRoot_findsPomXml() {
        let dir = tmpRoot.appendingPathComponent("mvn")
        let src = dir.appendingPathComponent("src/main/java/com/example")
        try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("pom.xml").path, contents: nil)
        let fileURL = src.appendingPathComponent("Foo.java")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        let root = LSPDiscovery.javaWorkspaceRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL, dir.standardizedFileURL)
    }

    func test_javaWorkspaceRoot_findsBuildGradleKts() {
        let dir = tmpRoot.appendingPathComponent("gradle")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("build.gradle.kts").path, contents: nil)
        let fileURL = dir.appendingPathComponent("Foo.java")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        let root = LSPDiscovery.javaWorkspaceRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL, dir.standardizedFileURL)
    }

    func test_javaWorkspaceRoot_returnsNilWhenNoMarkers() {
        // Java without a build file is degenerate for jdtls — single-file
        // mode is documented as not supported (the server needs a real
        // source root to index against).
        let dir = tmpRoot.appendingPathComponent("loose")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("Foo.java")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        XCTAssertNil(LSPDiscovery.javaWorkspaceRoot(for: fileURL))
    }

    // MARK: - Python workspace root

    func test_pythonWorkspaceRoot_findsPyprojectToml() {
        let dir = tmpRoot.appendingPathComponent("py")
        let src = dir.appendingPathComponent("src/mypkg")
        try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("pyproject.toml").path, contents: nil)
        let fileURL = src.appendingPathComponent("a.py")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        let root = LSPDiscovery.pythonWorkspaceRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL, dir.standardizedFileURL)
    }

    func test_pythonWorkspaceRoot_fallsBackToParent() {
        let dir = tmpRoot.appendingPathComponent("loose")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("scratch.py")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)

        let root = LSPDiscovery.pythonWorkspaceRoot(for: fileURL)
        XCTAssertEqual(root?.standardizedFileURL, dir.standardizedFileURL)
    }

    // MARK: - jdtls data directory

    func test_jdtlsDataDirectory_isDeterministicPerWorkspace() {
        let ws = tmpRoot.appendingPathComponent("workspace-A")
        try? FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let dir1 = LSPDiscovery.jdtlsDataDirectory(for: ws)
        let dir2 = LSPDiscovery.jdtlsDataDirectory(for: ws)
        XCTAssertEqual(dir1.path, dir2.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir1.path))
    }

    func test_jdtlsDataDirectory_differsAcrossWorkspaces() {
        let a = tmpRoot.appendingPathComponent("workspace-A")
        let b = tmpRoot.appendingPathComponent("workspace-B")
        try? FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        XCTAssertNotEqual(
            LSPDiscovery.jdtlsDataDirectory(for: a).path,
            LSPDiscovery.jdtlsDataDirectory(for: b).path)
    }

    // MARK: - Augmented PATH

    func test_augmentedSearchPaths_includesHomebrewAndNpmDirs() {
        let paths = LSPDiscovery.augmentedSearchPaths()
        XCTAssertTrue(paths.contains("/opt/homebrew/bin"))
        XCTAssertTrue(paths.contains("/usr/local/bin"))
        // de-dup: no path appears twice
        XCTAssertEqual(paths.count, Set(paths).count)
    }
}
