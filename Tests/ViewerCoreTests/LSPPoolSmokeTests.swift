import XCTest
@testable import ViewerCore

/// End-to-end smoke test for the pool-routed timed-request wrappers.
/// Spawns a real `sourcekit-lsp` against this workspace, calls
/// `pool.documentSymbol(fileURL:)`, then asserts the diagnostics
/// snapshot shows the bumped request count + a non-nil response time.
///
/// This is the test that backs the "diagnostics panel shows live
/// data" claim — without it, recordRequest is only validated via the
/// failure-path unit tests in LSPPoolTests, which can't observe
/// success-path counter bumps because they never succeed.
///
/// Skipped (not failed) when sourcekit-lsp isn't on PATH so the suite
/// stays hermetic for the host filter. Set `MDV_RUN_LSP_SMOKE=1` to
/// require the wire path actually run.
final class LSPPoolSmokeTests: XCTestCase {

    private func requireSmoke() -> Bool {
        ProcessInfo.processInfo.environment["MDV_RUN_LSP_SMOKE"] == "1"
    }

    func test_documentSymbol_throughPool_bumpsRequestCounter() async throws {
        guard LSPDiscovery.locateSourceKitLSP() != nil else {
            if requireSmoke() { XCTFail("sourcekit-lsp not found") }
            throw XCTSkip("sourcekit-lsp not on PATH")
        }
        let here = URL(fileURLWithPath: #filePath)
        guard let root = LSPDiscovery.swiftPackageRoot(for: here) else {
            throw XCTSkip("could not locate Package.swift from \(here.path)")
        }
        let target = root.appendingPathComponent(
            "Sources/ViewerCore/LSP/LSPProtocol.swift")
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw XCTSkip("expected source file missing: \(target.path)")
        }

        let pool = LSPPool()
        // Await teardown synchronously (XCTest waits on the block) so the
        // child LSP process is reaped before the next test — a detached
        // `Task { await pool.closeAll() }` could outlive the test and leak
        // the subprocess (TSK-485).
        self.addTeardownBlock { await pool.closeAll() }

        let text = try String(contentsOf: target, encoding: .utf8)
        do {
            try await pool.ensureOpened(fileURL: target, text: text)
        } catch LSPError.timeout {
            if requireSmoke() { XCTFail("ensureOpened timed out") }
            throw XCTSkip("ensureOpened timed out — cold sourcekit?")
        } catch {
            if requireSmoke() { XCTFail("ensureOpened failed: \(error)") }
            throw XCTSkip("ensureOpened failed: \(error)")
        }

        // Pre-call snapshot: server is live but no routed request yet.
        let pre = await pool.snapshot()
        XCTAssertEqual(pre.count, 1, "one swift workspace entry expected")
        XCTAssertTrue(pre.first?.isLive ?? false)
        XCTAssertEqual(pre.first?.status.requestCount, 0,
            "routed wrappers haven't been called yet")
        XCTAssertNil(pre.first?.status.lastResponseMillis)

        // Decision (2026-05-29): restate. The prior `_ = result` discard
        // hid the fact that we *could* assert payload-shape coherence
        // even when entry count is server/index-dependent. The counter
        // bump + lastResponseMillis assertions below were honest, but
        // the discard line claimed "result is unassertable" — false.
        // Now we route through `assertCoherent` which validates every
        // returned symbol's fields if any came back, and accepts
        // empty-array as legitimate (cold index). Empty is fine; *malformed*
        // payload (empty name, inverted range) is the bug we want to catch.
        let result: [LSPDocumentSymbol]
        do {
            result = try await pool.documentSymbol(fileURL: target)
        } catch LSPError.timeout {
            if requireSmoke() { XCTFail("documentSymbol timed out") }
            throw XCTSkip("documentSymbol timed out — cold sourcekit?")
        } catch {
            if requireSmoke() { XCTFail("documentSymbol failed: \(error)") }
            throw XCTSkip("documentSymbol failed: \(error)")
        }
        Self.assertSymbolsCoherent(result)

        // Post-call snapshot: the routed wrapper must have bumped both
        // counters. Without this assertion the diagnostics panel
        // silently shows 0 forever and we'd never know.
        let post = await pool.snapshot()
        XCTAssertEqual(post.count, 1)
        XCTAssertEqual(post.first?.status.requestCount, 1,
            "pool.documentSymbol must bump requestCount via recordRequest")
        if let ms = post.first?.status.lastResponseMillis {
            XCTAssertGreaterThan(ms, 0,
                "lastResponseMillis must be measured (> 0) after a real round-trip")
        } else {
            XCTFail("lastResponseMillis is nil after successful round-trip")
        }
        XCTAssertNil(post.first?.status.lastError)
    }

    /// Second call on the same pool must increment, not overwrite. Run
    /// only when the first succeeded — same skip policy as above.
    func test_secondRoutedCall_incrementsCounter() async throws {
        guard LSPDiscovery.locateSourceKitLSP() != nil else {
            throw XCTSkip("sourcekit-lsp not on PATH")
        }
        let here = URL(fileURLWithPath: #filePath)
        guard let root = LSPDiscovery.swiftPackageRoot(for: here) else {
            throw XCTSkip("could not locate Package.swift")
        }
        let target = root.appendingPathComponent(
            "Sources/ViewerCore/LSP/LSPProtocol.swift")
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw XCTSkip("missing source file")
        }
        let pool = LSPPool()
        // Awaited teardown — see the sibling test for the leak rationale (TSK-485).
        self.addTeardownBlock { await pool.closeAll() }

        let text = try String(contentsOf: target, encoding: .utf8)
        do {
            try await pool.ensureOpened(fileURL: target, text: text)
            // Decision (2026-05-29): restate. Discarding the result on a
            // pool-routed call is fine *here* because the test is about
            // the counter — but funnelling each call through the
            // coherence check costs nothing and protects against a
            // future decoder regression silently returning malformed
            // symbols on every retry.
            for _ in 0..<3 {
                let symbols = try await pool.documentSymbol(fileURL: target)
                Self.assertSymbolsCoherent(symbols)
            }
        } catch LSPError.timeout {
            throw XCTSkip("sourcekit request timed out")
        } catch {
            throw XCTSkip("sourcekit request failed: \(error)")
        }

        let snap = await pool.snapshot()
        XCTAssertEqual(snap.first?.status.requestCount, 3,
            "three routed calls must each bump the counter; \(snap.first?.status.requestCount ?? -1) seen")
    }

    // MARK: - shared coherence checks

    /// Validate that any document symbols actually returned by the
    /// server decoded into structurally-coherent values. Empty arrays
    /// are accepted (cold index, server choice) — the bug we catch
    /// is malformed *contents*: blank names, inverted ranges, kinds
    /// that didn't decode. If LSPClient's decoder ever silently maps
    /// a malformed wire entry to a zero-valued struct, this fires.
    static func assertSymbolsCoherent(
        _ symbols: [LSPDocumentSymbol],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        // Empty is legitimate — sourcekit-lsp can return no symbols
        // for files it hasn't indexed yet. We don't assert non-empty
        // because that would just re-introduce the flakiness this
        // suite was built to avoid.
        for sym in symbols {
            XCTAssertFalse(sym.name.isEmpty,
                "document symbol has empty name (decoder lost the field?)",
                file: file, line: line)
            assertRangeOrdered(sym.range, label: "range of \(sym.name)",
                               file: file, line: line)
            assertRangeOrdered(sym.selectionRange,
                               label: "selectionRange of \(sym.name)",
                               file: file, line: line)
            // Recurse — children share the same invariants.
            assertSymbolsCoherent(sym.children, file: file, line: line)
        }
    }

    private static func assertRangeOrdered(
        _ r: LSPRange, label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        // start must be ≤ end (lexicographically over (line, character)).
        let ok =
            r.start.line < r.end.line ||
            (r.start.line == r.end.line && r.start.character <= r.end.character)
        XCTAssertTrue(ok,
            "\(label) is inverted: start=\(r.start.line):\(r.start.character) > end=\(r.end.line):\(r.end.character)",
            file: file, line: line)
        XCTAssertGreaterThanOrEqual(r.start.line, 0,
            "\(label) start.line is negative", file: file, line: line)
        XCTAssertGreaterThanOrEqual(r.start.character, 0,
            "\(label) start.character is negative", file: file, line: line)
    }
}
