import XCTest
@testable import ViewerCore

/// Happy-path + edge-case tests for `LSPClient` against the
/// `MDVFakeLSPServer` stub. Closes the coverage gap flagged by
/// `docs/code-review/TESTS_2026-05-25.md` §5.1: the 821-LoC
/// `LSPClient` had only env-gated smoke tests against sourcekit-lsp.
///
/// These tests spawn the fake server (Swift target built alongside
/// `swift test`), drive the full wire path (initialize → notify →
/// request → response → shutdown), and assert on the structured
/// return values. Each test owns a fresh client + tmpdir.
///
/// Skipped (not failed) if the fake-server binary can't be located —
/// that's a missing-build-product situation, not a regression. CI is
/// expected to run `swift build --product MDVFakeLSPServer` before
/// `swift test`, or rely on the test bundle's transitive build phase.
final class LSPClientFakeServerTests: XCTestCase {

    // MARK: - Lifecycle helper

    /// Build, initialize, and return a client. On test exit the caller
    /// is responsible for `await client.shutdown()` — we don't wrap in
    /// a teardown because the client is an actor and tearDown isn't.
    private func makeInitializedClient(
        scenario: String? = nil,
        hoverDelayMs: Int? = nil,
        publishDiagnostics: Bool = false
    ) async throws -> (LSPClient, URL) {
        let (cfg, root) = try FakeLSPServerHelper.makeConfig(
            scenario: scenario,
            hoverDelayMs: hoverDelayMs,
            publishDiagnostics: publishDiagnostics)
        let client = try LSPClient(config: cfg)
        try await client.initialize()
        return (client, root)
    }

    // MARK: - Initialize

    func test_initialize_negotiates_utf16_by_default() async throws {
        let (client, root) = try await makeInitializedClient()
        defer { FakeLSPServerHelper.cleanup(root) }
        let pe = await client.positionEncoding
        XCTAssertEqual(pe, .utf16,
            "default fake server should advertise utf-16")
        await client.shutdown()
    }

    func test_initialize_honors_utf8_negotiation() async throws {
        let (client, root) = try await makeInitializedClient(scenario: "encoding_utf8")
        defer { FakeLSPServerHelper.cleanup(root) }
        let pe = await client.positionEncoding
        XCTAssertEqual(pe, .utf8,
            "client must adopt server-chosen positionEncoding")
        await client.shutdown()
    }

    func test_initialize_propagates_server_error() async throws {
        let (cfg, root) = try FakeLSPServerHelper.makeConfig(
            scenario: "fail_initialize")
        defer { FakeLSPServerHelper.cleanup(root) }
        let client = try LSPClient(config: cfg)
        do {
            try await client.initialize()
            XCTFail("expected initialize to throw a serverError")
        } catch LSPError.serverError(let code, _) {
            XCTAssertEqual(code, -32603,
                "fake server returns InternalError (-32603) when scenario=fail_initialize")
        } catch {
            XCTFail("expected LSPError.serverError, got \(error)")
        }
        await client.shutdown()
    }

    // MARK: - Hover (decoder shape proof)

    func test_hover_returns_markdown_content() async throws {
        let (client, root) = try await makeInitializedClient()
        defer { FakeLSPServerHelper.cleanup(root) }
        let url = URL(fileURLWithPath: "/fake/x.swift")
        let hover = try await client.hover(url: url, line: 3, character: 7)
        guard let hover = hover else {
            return XCTFail("fake server always returns a hover; got nil")
        }
        // The decoder must surface the markdown content and flag it.
        XCTAssertTrue(hover.isMarkdown)
        XCTAssertTrue(hover.contents.contains("**fake**"),
            "hover.contents should preserve markdown bold: got \(hover.contents)")
        XCTAssertTrue(hover.contents.contains("hover at 3:7"),
            "hover should round-trip the requested position: got \(hover.contents)")
        XCTAssertNotNil(hover.range,
            "fake server always populates `range` — decoder must surface it")
        await client.shutdown()
    }

    // MARK: - Definition / references / declaration / typeDefinition / implementation

    func test_definition_returns_single_location() async throws {
        let (client, root) = try await makeInitializedClient()
        defer { FakeLSPServerHelper.cleanup(root) }
        let url = URL(fileURLWithPath: "/fake/x.swift")
        let defs = try await client.definition(url: url, line: 0, character: 0)
        XCTAssertEqual(defs.count, 1)
        XCTAssertEqual(defs.first?.uri, url.absoluteString,
            "definition uri should mirror the requested file's URI")
        await client.shutdown()
    }

    func test_references_returns_two_locations() async throws {
        let (client, root) = try await makeInitializedClient()
        defer { FakeLSPServerHelper.cleanup(root) }
        let url = URL(fileURLWithPath: "/fake/x.swift")
        let refs = try await client.references(
            url: url, line: 0, character: 0, includeDeclaration: true)
        XCTAssertEqual(refs.count, 2)
        await client.shutdown()
    }

    func test_declaration_typeDefinition_implementation() async throws {
        let (client, root) = try await makeInitializedClient()
        defer { FakeLSPServerHelper.cleanup(root) }
        let url = URL(fileURLWithPath: "/fake/x.swift")
        let decl = try await client.declaration(url: url, line: 0, character: 0)
        let typd = try await client.typeDefinition(url: url, line: 0, character: 0)
        let impl = try await client.implementation(url: url, line: 0, character: 0)
        XCTAssertEqual(decl.count, 1)
        XCTAssertEqual(typd.count, 1)
        XCTAssertEqual(impl.count, 2)
        await client.shutdown()
    }

    // MARK: - documentSymbol (children hierarchy must survive decode)

    func test_documentSymbol_preserves_child_hierarchy() async throws {
        let (client, root) = try await makeInitializedClient()
        defer { FakeLSPServerHelper.cleanup(root) }
        let url = URL(fileURLWithPath: "/fake/x.swift")
        let syms = try await client.documentSymbol(url: url)
        XCTAssertEqual(syms.count, 1)
        XCTAssertEqual(syms.first?.name, "RootSym")
        XCTAssertEqual(syms.first?.kind, .class)
        XCTAssertEqual(syms.first?.children.count, 1)
        XCTAssertEqual(syms.first?.children.first?.name, "Child")
        XCTAssertEqual(syms.first?.children.first?.kind, .variable)
        await client.shutdown()
    }

    // MARK: - foldingRange

    func test_foldingRange_returns_canonical_region() async throws {
        let (client, root) = try await makeInitializedClient()
        defer { FakeLSPServerHelper.cleanup(root) }
        let url = URL(fileURLWithPath: "/fake/x.swift")
        let folds = try await client.foldingRange(url: url)
        XCTAssertEqual(folds.count, 1)
        XCTAssertEqual(folds.first?.startLine, 1)
        XCTAssertEqual(folds.first?.endLine, 3)
        XCTAssertEqual(folds.first?.kind, "region")
        await client.shutdown()
    }

    // MARK: - workspaceSymbol (query echo)

    func test_workspaceSymbol_round_trips_query() async throws {
        let (client, root) = try await makeInitializedClient()
        defer { FakeLSPServerHelper.cleanup(root) }
        let syms = try await client.workspaceSymbol(query: "MyQuery")
        XCTAssertEqual(syms.count, 1)
        XCTAssertEqual(syms.first?.name, "MyQuery",
            "fake server echoes the query as the symbol name")
        XCTAssertEqual(syms.first?.containerName, "FakeModule")
        await client.shutdown()
    }

    // MARK: - Concurrent requests (correlation table proof)

    func test_concurrent_requests_dont_cross_responses() async throws {
        // Fire N hovers in parallel against the same client. Each call
        // gets a unique JSON-RPC id; the response must come back to the
        // right awaiter. If the correlation table breaks, results
        // round-trip the wrong position.
        let (client, root) = try await makeInitializedClient()
        defer { FakeLSPServerHelper.cleanup(root) }
        let url = URL(fileURLWithPath: "/fake/x.swift")
        let n = 8
        let positions = (0..<n).map { ($0, $0 + 100) }

        // Run all in parallel and assert each result mentions its own
        // position in the canned hover text.
        try await withThrowingTaskGroup(of: (Int, Int, String).self) { group in
            for (line, character) in positions {
                group.addTask {
                    let h = try await client.hover(
                        url: url, line: line, character: character)
                    return (line, character, h?.contents ?? "")
                }
            }
            var seen = Set<String>()
            for try await (line, character, text) in group {
                let needle = "hover at \(line):\(character)"
                XCTAssertTrue(text.contains(needle),
                    "concurrent hover correlation broken: line=\(line) char=\(character) text=\(text)")
                XCTAssertTrue(seen.insert(text).inserted,
                    "duplicate hover text — different requests returned the same response")
            }
        }
        await client.shutdown()
    }

    // MARK: - Cancellation (token → $/cancelRequest)

    func test_cancellation_resumes_with_cancellationError() async throws {
        // Use a slow-hover server so we have a window to cancel inside.
        let (client, root) = try await makeInitializedClient(hoverDelayMs: 1_000)
        defer { FakeLSPServerHelper.cleanup(root) }
        let url = URL(fileURLWithPath: "/fake/slow.swift")
        let token = LSPCancellationToken()

        async let result: LSPHover? = client.hover(
            url: url, line: 0, character: 0, token: token)

        // Cancel after a brief moment so the request is in-flight.
        try await Task.sleep(for: .milliseconds(50))
        token.cancel()

        do {
            _ = try await result
            XCTFail("expected cancellation to throw")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
        await client.shutdown()
    }

    // MARK: - Crash detection

    func test_serverCrash_after_init_fires_onCrash_and_failsPending() async throws {
        // Start with crash_after_init; on the `initialized` notification
        // the fake server exits 1, which the reader sees as EOF →
        // failAllPending(.transportClosed). We can't directly observe
        // the timing of `initialize()` vs the crash, but we can wait
        // for the next request to bounce with `transportClosed`.
        let (client, root) = try await makeInitializedClient(scenario: "crash_after_init")
        defer { FakeLSPServerHelper.cleanup(root) }
        // Capture onCrash via the public setter. The callback is
        // @Sendable; hop into the actor via a detached Task.
        let crashed = AsyncOneShot()
        await client.setOnCrash { _ in
            Task { await crashed.fire() }
        }
        // The crash happens immediately on `initialized`. Poll: hover
        // calls should bounce with .transportClosed (or .notInitialized
        // if failAllPending already flipped the flag).
        let url = URL(fileURLWithPath: "/fake/x.swift")
        var caught = false
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            do {
                _ = try await client.hover(url: url, line: 0, character: 0)
            } catch LSPError.transportClosed, LSPError.notInitialized {
                caught = true
                break
            } catch {
                // Some other error (e.g. timeout) — try again briefly.
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(caught, "server crash should surface as transportClosed/notInitialized")
        let didFire = await crashed.waitOrTimeout(seconds: 2)
        XCTAssertTrue(didFire, "onCrash callback should fire when server EOFs after init")
        await client.shutdown()
    }

    // MARK: - publishDiagnostics push

    func test_publishDiagnostics_isForwardedToCallback() async throws {
        let (cfg, root) = try FakeLSPServerHelper.makeConfig(
            publishDiagnostics: true)
        defer { FakeLSPServerHelper.cleanup(root) }
        let client = try LSPClient(config: cfg)
        // Wire the onDiagnostics callback BEFORE initialize so the
        // push (which arrives right after `initialized` reaches the
        // server) is captured.
        let sink = DiagnosticsSink()
        await client.setOnDiagnostics { uri, diags in
            Task { await sink.append(uri: uri, diags: diags) }
        }
        try await client.initialize()
        let got = await sink.waitForFirst(seconds: 2)
        XCTAssertTrue(got, "publishDiagnostics push should reach onDiagnostics within 2s")
        let snapshot = await sink.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.diags.first?.message, "fake diagnostic")
        XCTAssertEqual(snapshot.first?.diags.first?.severity, .error)
        XCTAssertEqual(snapshot.first?.diags.first?.code, "FAKE001")
        await client.shutdown()
    }

    // MARK: - Shutdown idempotency

    func test_shutdown_twice_is_safe() async throws {
        let (client, root) = try await makeInitializedClient()
        defer { FakeLSPServerHelper.cleanup(root) }
        await client.shutdown()
        await client.shutdown() // second call must not crash
    }
}

// MARK: - Helpers (test-local sinks)

/// One-shot signal flag, actor-backed so we don't need to reach for
/// NSLock from async contexts (Swift 6 strict concurrency rejects it).
actor AsyncOneShot {
    private var didFire = false

    func fire() {
        didFire = true
    }

    /// Poll on a 20 ms cadence until either the flag flips or the
    /// timeout elapses. Acceptable here because the events we wait on
    /// are server-driven, not perf-critical — ~50 wakeups for a 1 s
    /// budget. Avoids the continuation-juggling that the lock-based
    /// version needed.
    func waitOrTimeout(seconds: TimeInterval) async -> Bool {
        let tick = UInt64(20_000_000) // 20 ms
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if didFire { return true }
            try? await Task.sleep(nanoseconds: tick)
        }
        return didFire
    }
}

/// Diagnostics sink used by the publishDiagnostics test. The callback
/// is @Sendable so we hop into the actor via a detached Task; tests
/// `await snapshot()` after `waitForFirst` returns.
actor DiagnosticsSink {
    struct Entry: Sendable {
        let uri: URL
        let diags: [LSPDiagnostic]
    }
    private var entries: [Entry] = []
    private let firstSignal = AsyncOneShot()

    func append(uri: URL, diags: [LSPDiagnostic]) async {
        entries.append(Entry(uri: uri, diags: diags))
        if entries.count == 1 {
            await firstSignal.fire()
        }
    }

    func waitForFirst(seconds: TimeInterval) async -> Bool {
        return await firstSignal.waitOrTimeout(seconds: seconds)
    }

    func snapshot() -> [Entry] {
        return entries
    }
}
