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
}
