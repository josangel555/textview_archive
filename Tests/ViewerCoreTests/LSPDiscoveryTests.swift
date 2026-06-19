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

    // MARK: - Binary ownership safety (S3.1, 2026-05-25)

    func test_isBinarySafeToSpawn_acceptsOwnerWritableDir() throws {
        let dir = tmpRoot.appendingPathComponent("safe-bin")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let bin = dir.appendingPathComponent("lsp-server")
        FileManager.default.createFile(atPath: bin.path, contents: Data("#!/bin/sh\n".utf8))
        XCTAssertTrue(LSPDiscovery.isBinarySafeToSpawn(atPath: bin.path))
    }

    func test_isBinarySafeToSpawn_refusesGroupOrWorldWritableFile() throws {
        // L-sec2 (TSK-998): even in a SAFE (0o755) dir, a group/world-writable
        // binary FILE can be overwritten in place by another user — refuse it.
        // The ancestor-dir walk passes here (dir is 0o755); the new file-perm
        // check is the teeth (pre-fix this returned true).
        let dir = tmpRoot.appendingPathComponent("safe-dir-writable-file")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let bin = dir.appendingPathComponent("lsp-server")
        FileManager.default.createFile(
            atPath: bin.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o777]
        )
        XCTAssertFalse(LSPDiscovery.isBinarySafeToSpawn(atPath: bin.path))
    }

    func test_isBinarySafeToSpawn_refusesGroupWritableDir() throws {
        let dir = tmpRoot.appendingPathComponent("group-write-bin")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o775]
        )
        let bin = dir.appendingPathComponent("lsp-server")
        FileManager.default.createFile(atPath: bin.path, contents: nil)
        // 0o775 = owner rwx, group rwx, other rx — group can drop in
        // a replacement binary. Refuse.
        XCTAssertFalse(LSPDiscovery.isBinarySafeToSpawn(atPath: bin.path))
    }

    func test_isBinarySafeToSpawn_refusesWorldWritableDir() throws {
        let dir = tmpRoot.appendingPathComponent("world-write-bin")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o777]
        )
        let bin = dir.appendingPathComponent("lsp-server")
        FileManager.default.createFile(atPath: bin.path, contents: nil)
        XCTAssertFalse(LSPDiscovery.isBinarySafeToSpawn(atPath: bin.path))
    }

    func test_isBinarySafeToSpawn_unknownPathConservativelyAllows() {
        // Path we can't stat → return true. The intent is "don't lock
        // out a user whose dev setup we don't understand"; we still
        // catch the obviously-bad world-writable case.
        XCTAssertTrue(
            LSPDiscovery.isBinarySafeToSpawn(
                atPath: "/definitely/not/here/lsp-\(UUID().uuidString)"
            )
        )
    }

    // MARK: - Ancestor-directory walk (TSK-963)

    func test_isBinarySafeToSpawn_refusesWorldWritableAncestor() throws {
        // FIX 2: a clean 0755 LEAF dir nested under a 0777 ANCESTOR must
        // be refused. The rename-swap vector: an attacker who can write
        // the 0777 ancestor can `rename` the leaf out from under us and
        // slip in a hostile tree, so the leaf is only as trustworthy as
        // the weakest dir above it.
        //
        //   tmpRoot/world-write-ancestor   (0777)
        //     └── clean-leaf               (0755)
        //           └── lsp-server         <- refused
        let ancestor = tmpRoot.appendingPathComponent("world-write-ancestor")
        let leaf = ancestor.appendingPathComponent("clean-leaf")
        try FileManager.default.createDirectory(
            at: leaf, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        // Set the ancestor world-writable AFTER creating the leaf
        // (createDirectory(withIntermediate:) would otherwise apply the
        // attrs only to the deepest created component).
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777], ofItemAtPath: ancestor.path)
        defer {
            // Restore so tearDown can remove the tree.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: ancestor.path)
        }
        let bin = leaf.appendingPathComponent("lsp-server")
        FileManager.default.createFile(atPath: bin.path, contents: nil)

        XCTAssertFalse(
            LSPDiscovery.isBinarySafeToSpawn(atPath: bin.path),
            "0755 leaf under a 0777 ancestor must be refused (rename-swap vector)")
    }

    func test_isBinarySafeToSpawn_refusesGroupWritableAncestor() throws {
        let ancestor = tmpRoot.appendingPathComponent("group-write-ancestor")
        let leaf = ancestor.appendingPathComponent("clean-leaf")
        try FileManager.default.createDirectory(
            at: leaf, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o775], ofItemAtPath: ancestor.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: ancestor.path)
        }
        let bin = leaf.appendingPathComponent("lsp-server")
        FileManager.default.createFile(atPath: bin.path, contents: nil)

        XCTAssertFalse(
            LSPDiscovery.isBinarySafeToSpawn(atPath: bin.path),
            "0755 leaf under a 0775 (group-writable) ancestor must be refused")
    }

    func test_isBinarySafeToSpawn_acceptsCleanAncestorChain() throws {
        // Sanity: a fully-clean chain (all 0755) under our user-owned
        // temp tree is accepted — the walk must not over-refuse.
        let a = tmpRoot.appendingPathComponent("a")
        let b = a.appendingPathComponent("b")
        let c = b.appendingPathComponent("c")
        try FileManager.default.createDirectory(
            at: c, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        // Re-apply 0755 to each created level (intermediate dirs may
        // inherit the process umask otherwise).
        for d in [a, b, c] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: d.path)
        }
        let bin = c.appendingPathComponent("lsp-server")
        FileManager.default.createFile(atPath: bin.path, contents: nil)
        XCTAssertTrue(LSPDiscovery.isBinarySafeToSpawn(atPath: bin.path))
    }

    // MARK: - sourcekit-lsp discovery is gated (TSK-963)

    func test_locateSourceKitLSP_appliesSafetyGate_xcrunPathInUnsafeDir() throws {
        // FIX 2: the xcrun-resolved sourcekit-lsp path is now run through
        // isBinarySafeToSpawn. We can't easily fake `xcrun -f`, but we
        // CAN prove the gate refuses an xcrun-style absolute path landing
        // in a world-writable dir — the exact check locateSourceKitLSP
        // applies before returning that path.
        let unsafeDir = tmpRoot.appendingPathComponent("xcode-toolchain")
        try FileManager.default.createDirectory(
            at: unsafeDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o777])
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: unsafeDir.path)
        }
        let fakeSourcekit = unsafeDir.appendingPathComponent("sourcekit-lsp")
        FileManager.default.createFile(
            atPath: fakeSourcekit.path, contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755])
        // The gate locateSourceKitLSP now applies to the xcrun result:
        XCTAssertFalse(
            LSPDiscovery.isBinarySafeToSpawn(atPath: fakeSourcekit.path),
            "an xcrun-resolved sourcekit-lsp in a 0777 dir must be refused")
    }
}
