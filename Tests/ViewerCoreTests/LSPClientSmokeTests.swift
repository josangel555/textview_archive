import XCTest
@testable import ViewerCore

/// Best-effort end-to-end smoke test: spawn `sourcekit-lsp`, initialize,
/// open this very test file, request `textDocument/hover` on a known
/// identifier, request `textDocument/definition`.
///
/// Skipped if:
///   - the binary can't be located, OR
///   - the SwiftPM root can't be inferred, OR
///   - `initialize` times out (sourcekit-lsp on first run is occasionally
///     slow on cold machines — we don't want a flaky CI signal).
///
/// Set `MDV_RUN_LSP_SMOKE=1` to require the test to actually exercise
/// the wire path (will fail instead of skip). Default-off so the rest
/// of the suite stays hermetic.
final class LSPClientSmokeTests: XCTestCase {

    private func requireSmoke() -> Bool {
        ProcessInfo.processInfo.environment["MDV_RUN_LSP_SMOKE"] == "1"
    }

    func test_initialize_andHover_swiftFile() async throws {
        guard let binary = LSPDiscovery.locateSourceKitLSP() else {
            if requireSmoke() { XCTFail("sourcekit-lsp not found") }
            throw XCTSkip("sourcekit-lsp not on PATH")
        }
        // Resolve the test file relative to the package root via the
        // current source location. We walk up from #filePath to find
        // a Package.swift; this is the SwiftPM root we'll hand to LSP.
        let here = URL(fileURLWithPath: #filePath)
        guard let root = LSPDiscovery.swiftPackageRoot(for: here) else {
            throw XCTSkip("could not locate Package.swift from \(here.path)")
        }
        // Pick a small Swift source file that's actually in the build
        // graph so sourcekit-lsp's indexer has metadata to respond with.
        let target = root.appendingPathComponent(
            "Sources/ViewerCore/LSP/LSPProtocol.swift")
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw XCTSkip("expected source file missing: \(target.path)")
        }

        let client = try LSPClient(config: .init(
            executable: binary, workspaceRoot: root))

        do {
            try await client.initialize()
        } catch LSPError.timeout {
            if requireSmoke() { XCTFail("initialize timed out") }
            throw XCTSkip("initialize timed out (likely cold sourcekit index)")
        } catch {
            if requireSmoke() { XCTFail("initialize failed: \(error)") }
            throw XCTSkip("initialize failed: \(error)")
        }
        defer { Task { await client.shutdown() } }

        let text = try String(contentsOf: target, encoding: .utf8)
        try await client.didOpen(url: target, languageId: "swift", text: text)

        // Probe a position inside a known identifier. `LSPPosition`
        // declaration line is stable in the source we just authored.
        // Use line 7 char 16 — that puts the cursor on `LSPPosition`
        // in the type name (0-indexed UTF-16). Cold/uncached sourcekit
        // can legitimately return nil for either; we don't gate on a
        // positive response (would re-introduce flakiness).
        //
        // Decision (2026-05-29): restate. The prior `_ = hover` / `_ =
        // defs` discards turned the request/response loop into the only
        // thing this test exercised — if `decodeHover` ever silently
        // dropped fields or returned a struct with an empty `contents`
        // blob, this test would still pass. Now: if the server *does*
        // respond, the response must be coherent. Nil/empty stays
        // legitimate (cold indexer); malformed is a real bug.
        let hover = try? await client.hover(url: target, line: 7, character: 16)
        if let hover = hover {
            // Per LSPHover.contents docs: "pre-flattened to a markdown/
            // plaintext blob". A non-nil hover with empty contents means
            // the decode-order discipline regressed and dropped the
            // value field — the bug the LSPProtocol.swift comment
            // explicitly warns about.
            XCTAssertFalse(hover.contents.isEmpty,
                "non-nil hover must have non-empty contents — decoder regressed?")
        }

        // Definition: same lenient policy on presence, but if results
        // came back they must point at *something* — empty uri or
        // inverted range means the decoder broke.
        let defs = try? await client.definition(url: target, line: 7, character: 16)
        if let defs = defs {
            for loc in defs {
                XCTAssertFalse(loc.uri.isEmpty,
                    "definition location with empty uri — decoder regressed?")
                // file:// or untitled: are the realistic shapes
                // sourcekit-lsp emits. Reject obvious garbage.
                XCTAssertTrue(loc.uri.contains(":"),
                    "definition uri '\(loc.uri)' is not a URI shape")
            }
        }
    }
}
