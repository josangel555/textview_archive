import XCTest
import ViewerCore

/// TSK-1129 (security) — the workspace-local LSP-binary trust decision. Teeth on
/// the path-confinement primitive: a system binary is external, a sibling-prefix
/// dir does NOT count as inside, and a workspace symlink that resolves OUT of the
/// tree is judged external (so a repo can't dodge — or falsely trigger — the gate).
final class LSPBinaryTrustTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("LSPBinaryTrustTests-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func test_isWorkspaceLocal_insideVsSystem() throws {
        let ws = tmp.appendingPathComponent("ws")
        let binDir = ws.appendingPathComponent("node_modules/.bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let inside = binDir.appendingPathComponent("server")
        try Data().write(to: inside)
        XCTAssertTrue(LSPBinaryTrust.isWorkspaceLocal(binary: inside, workspaceRoot: ws),
                      "a binary under the workspace is workspace-local")
        XCTAssertFalse(LSPBinaryTrust.isWorkspaceLocal(binary: URL(fileURLWithPath: "/usr/bin/true"),
                                                       workspaceRoot: ws),
                       "a system binary is NOT workspace-local")
    }

    func test_siblingPrefix_notMatched() throws {
        let ws = tmp.appendingPathComponent("site")
        let sibling = tmp.appendingPathComponent("site-evil")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let evilBin = sibling.appendingPathComponent("server")
        try Data().write(to: evilBin)
        XCTAssertFalse(LSPBinaryTrust.isWorkspaceLocal(binary: evilBin, workspaceRoot: ws),
                       "/site-evil must NOT count as inside /site (trailing-separator boundary)")
    }

    func test_symlinkEscape_resolvesOutside() throws {
        let ws = tmp.appendingPathComponent("ws")
        let binDir = ws.appendingPathComponent("bin")
        let outsideDir = tmp.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let realOutside = outsideDir.appendingPathComponent("server")
        try Data().write(to: realOutside)
        let link = binDir.appendingPathComponent("server") // inside-looking path, symlinks out
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realOutside)
        XCTAssertFalse(LSPBinaryTrust.isWorkspaceLocal(binary: link, workspaceRoot: ws),
                       "a workspace symlink resolving OUTSIDE runs the real external binary — judged external")
    }

    func test_decision_trustGating() throws {
        let ws = tmp.appendingPathComponent("ws")
        let binDir = ws.appendingPathComponent("node_modules/.bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let local = binDir.appendingPathComponent("tsserver")
        try Data().write(to: local)
        XCTAssertEqual(LSPBinaryTrust.decision(binary: local, workspaceRoot: ws, trustedPaths: []),
                       .needsTrust, "untrusted workspace-local binary needs a confirm")
        let canon = LSPBinaryTrust.canonicalPath(for: local)
        XCTAssertEqual(LSPBinaryTrust.decision(binary: local, workspaceRoot: ws, trustedPaths: [canon]),
                       .allow, "once trusted (by canonical path) it spawns without friction")
        XCTAssertEqual(LSPBinaryTrust.decision(binary: URL(fileURLWithPath: "/usr/bin/true"),
                                               workspaceRoot: ws, trustedPaths: []),
                       .allow, "a system/PATH binary spawns without a trust prompt")
    }
}
