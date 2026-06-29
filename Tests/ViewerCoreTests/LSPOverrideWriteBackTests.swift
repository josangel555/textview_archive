import XCTest
@testable import ViewerCore

/// TSK-1128 — the `lsp.json` write-back behind the Settings ▸ LSP binary picker.
/// Host-tested (the picker UI is the render-VM follow-on): write→load round-trip,
/// preserve other entries / env / unknown keys, update-by-alias in place (no
/// duplicate), create-if-absent, refuse-malformed (never clobber an unparseable file).
final class LSPOverrideWriteBackTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LSPWriteBack-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func seed(_ json: String) {
        try! Data(json.utf8).write(to: root.appendingPathComponent("lsp.json"))
    }

    private func rawFile() throws -> String {
        try String(contentsOf: root.appendingPathComponent("lsp.json"), encoding: .utf8)
    }

    func test_createsFileAndRoundTrips() throws {
        try LSPWorkspaceOverrides.setServerCommand(
            "/usr/bin/sourcekit-lsp", for: .swift, workspaceRoot: root)
        let loaded = LSPWorkspaceOverrides.load(workspaceRoot: root)
        XCTAssertEqual(loaded?.servers[.swift]?.command, "/usr/bin/sourcekit-lsp")
    }

    func test_writesArgs() throws {
        try LSPWorkspaceOverrides.setServerCommand(
            "/opt/bin/tsserver", args: ["--stdio"], for: .typescript, workspaceRoot: root)
        let loaded = LSPWorkspaceOverrides.load(workspaceRoot: root)
        XCTAssertEqual(loaded?.servers[.typescript]?.command, "/opt/bin/tsserver")
        XCTAssertEqual(loaded?.servers[.typescript]?.arguments, ["--stdio"])
    }

    func test_preservesOtherLanguages_env_andUnknownKeys() throws {
        seed("""
        { "version": 7, "servers": { "python": { "command": "/old/pyright", "env": { "MYVAR": "1" } } } }
        """)
        try LSPWorkspaceOverrides.setServerCommand("/new/sourcekit", for: .swift, workspaceRoot: root)
        let loaded = LSPWorkspaceOverrides.load(workspaceRoot: root)
        // swift added; python (incl its env) preserved verbatim.
        XCTAssertEqual(loaded?.servers[.swift]?.command, "/new/sourcekit")
        XCTAssertEqual(loaded?.servers[.python]?.command, "/old/pyright")
        XCTAssertEqual(loaded?.servers[.python]?.environment["MYVAR"], "1")
        // The unknown top-level "version" key survives on disk (raw-object merge).
        XCTAssertTrue(try rawFile().contains("\"version\""))
    }

    func test_updatesExistingAliasInPlace_noDuplicate_preservingArgs() throws {
        // Existing entry under the "sourcekitLSP" ALIAS (not the canonical "swift").
        seed("""
        { "servers": { "sourcekitLSP": { "command": "/old/sk", "args": ["--keep"] } } }
        """)
        try LSPWorkspaceOverrides.setServerCommand("/new/sk", for: .swift, workspaceRoot: root)
        let loaded = LSPWorkspaceOverrides.load(workspaceRoot: root)
        XCTAssertEqual(loaded?.servers[.swift]?.command, "/new/sk")
        // args not passed → the existing ["--keep"] is preserved (only command changed).
        XCTAssertEqual(loaded?.servers[.swift]?.arguments, ["--keep"])
        // Updated IN PLACE under the original alias — no duplicate canonical "swift" key.
        let raw = try rawFile()
        XCTAssertTrue(raw.contains("sourcekitLSP"))
        XCTAssertFalse(raw.contains("\"swift\""))
    }

    func test_refusesMalformedFile() {
        seed("{ not valid json ")
        XCTAssertThrowsError(
            try LSPWorkspaceOverrides.setServerCommand("/x", for: .swift, workspaceRoot: root),
            "must refuse to clobber an unparseable lsp.json")
    }
}
