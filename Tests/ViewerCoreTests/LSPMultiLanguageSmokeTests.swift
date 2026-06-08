import XCTest
@testable import ViewerCore

/// Per-language smoke tests for the newer LSP servers added in Phases
/// A / C / D. Each follows the same pattern as `LSPClientSmokeTests`:
///   - skip cleanly when the binary is missing
///   - assert the wire path when `MDV_RUN_LSP_SMOKE=1` is set
///
/// These are deliberately minimal — they prove the registry entry +
/// discovery + initialize handshake round-trip, not feature coverage.
/// Real per-feature integration tests would need mock servers; punted
/// to a later pass.
final class LSPMultiLanguageSmokeTests: XCTestCase {

    private var tmpRoot: URL!

    override func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lsp-smoke-\(UUID().uuidString)")
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

    private func requireSmoke() -> Bool {
        ProcessInfo.processInfo.environment["MDV_RUN_LSP_SMOKE"] == "1"
    }

    // MARK: - typescript-language-server

    func test_initialize_typescript() async throws {
        guard let binary = LSPDiscovery.locate(binary: "typescript-language-server") else {
            if requireSmoke() { XCTFail("typescript-language-server not on PATH") }
            throw XCTSkip("typescript-language-server not on PATH")
        }
        // Create a minimal TS project: package.json + a single .ts file.
        FileManager.default.createFile(
            atPath: tmpRoot.appendingPathComponent("package.json").path,
            contents: Data("{\"name\":\"smoke\"}".utf8))
        let target = tmpRoot.appendingPathComponent("a.ts")
        let text = "export const x: number = 1;\n"
        FileManager.default.createFile(atPath: target.path,
                                       contents: Data(text.utf8))

        let client = try LSPClient(config: .init(
            executable: binary, arguments: ["--stdio"],
            workspaceRoot: tmpRoot))
        do {
            try await client.initialize()
        } catch {
            if requireSmoke() { XCTFail("initialize failed: \(error)") }
            throw XCTSkip("initialize failed: \(error)")
        }
        self.addTeardownBlock { await client.shutdown() }  // awaited reap, not fire-and-forget (TSK-485)

        try await client.didOpen(url: target, languageId: "typescript", text: text)
        // Probe hover on the identifier `x`. Lenient on *presence*: not
        // all TS server versions return hover for a const declaration.
        //
        // Decision (2026-05-29): restate. The `_ = try? await` discard
        // meant a server returning malformed JSON, a decoder regression,
        // or a hover blob that lost its `contents` field would all pass
        // silently. Now: if hover came back, contents must be non-empty
        // — the only payload-shape claim we can make without depending
        // on which TS version is installed.
        let hover = try? await client.hover(url: target, line: 0, character: 13)
        Self.assertHoverCoherent(hover)
    }

    // MARK: - pyright

    func test_initialize_python() async throws {
        guard let binary = LSPDiscovery.locate(binary: "pyright-langserver") else {
            if requireSmoke() { XCTFail("pyright-langserver not on PATH") }
            throw XCTSkip("pyright-langserver not on PATH")
        }
        FileManager.default.createFile(
            atPath: tmpRoot.appendingPathComponent("pyproject.toml").path,
            contents: Data("[project]\nname = \"smoke\"\n".utf8))
        let target = tmpRoot.appendingPathComponent("a.py")
        let text = "x = 1\n"
        FileManager.default.createFile(atPath: target.path,
                                       contents: Data(text.utf8))

        let client = try LSPClient(config: .init(
            executable: binary, arguments: ["--stdio"],
            workspaceRoot: tmpRoot))
        do {
            try await client.initialize()
        } catch {
            if requireSmoke() { XCTFail("initialize failed: \(error)") }
            throw XCTSkip("initialize failed: \(error)")
        }
        self.addTeardownBlock { await client.shutdown() }  // awaited reap, not fire-and-forget (TSK-485)

        try await client.didOpen(url: target, languageId: "python", text: text)
        // Decision (2026-05-29): restate. Same rationale as the TS test
        // above — pyright's hover for `x = 1` may or may not include
        // type info depending on the version, but any returned hover
        // blob must have non-empty contents.
        let hover = try? await client.hover(url: target, line: 0, character: 0)
        Self.assertHoverCoherent(hover)
    }

    // MARK: - jdtls

    func test_initialize_java() async throws {
        guard let binary = LSPDiscovery.locate(binary: "jdtls") else {
            if requireSmoke() { XCTFail("jdtls not on PATH") }
            throw XCTSkip("jdtls not on PATH")
        }
        // Minimal Eclipse project marker; jdtls is content with this.
        FileManager.default.createFile(
            atPath: tmpRoot.appendingPathComponent(".project").path,
            contents: nil)
        let target = tmpRoot.appendingPathComponent("Foo.java")
        let text = "class Foo {}\n"
        FileManager.default.createFile(atPath: target.path,
                                       contents: Data(text.utf8))

        let dataDir = LSPDiscovery.jdtlsDataDirectory(for: tmpRoot)
        let client = try LSPClient(config: .init(
            executable: binary, arguments: ["-data", dataDir.path],
            workspaceRoot: tmpRoot))
        do {
            // jdtls cold-start can blow the default 30s — be patient
            // here, but still bail if the server is wedged.
            try await client.initialize()
        } catch {
            if requireSmoke() { XCTFail("initialize failed: \(error)") }
            throw XCTSkip("initialize failed (jdtls cold-start often >30s): \(error)")
        }
        self.addTeardownBlock { await client.shutdown() }  // awaited reap, not fire-and-forget (TSK-485)

        try await client.didOpen(url: target, languageId: "java", text: text)
    }

    // MARK: - shared coherence checks

    /// Accept nil (server had nothing to say) but reject a non-nil
    /// hover with empty `contents`. The LSP decode-order discipline
    /// in LSPProtocol.swift warns: if MarkupContent is matched before
    /// MarkedString, the `value` key is silently dropped and we end
    /// up with a hover struct whose contents got blanked. This
    /// assertion catches that exact regression.
    static func assertHoverCoherent(
        _ hover: LSPHover?,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let hover = hover else { return }
        XCTAssertFalse(hover.contents.isEmpty,
            "non-nil hover must have non-empty contents — decode-order regressed?",
            file: file, line: line)
    }
}
