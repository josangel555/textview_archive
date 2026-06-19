import XCTest
import ViewerKit
@testable import ViewerCore

/// End-to-end test of `MCPServer`: write a framed JSON-RPC request
/// into a pipe, read the framed response off another pipe, parse it.
/// Uses the same `FakeAutomationHost` shape as `MCPToolCatalogTests`
/// — but those types are file-private there, so we re-declare a
/// minimal one here.
@MainActor
private final class StubHost: AutomationHost {
    var stateResult = AutomationState(
        tabs: [], selectedTabIndex: nil, viewMode: "rendered",
        zoom: 1.0, sidebarRoot: nil, isPalettePresented: false
    )
    var setZoomArg: Double?
    func automationOpenPath(_ url: URL, newTab: Bool) -> UUID { UUID() }
    func automationSelectTab(byIndex index: Int?, byId id: UUID?) -> Bool { true }
    func automationSetViewMode(_ mode: ViewMode) {}
    func automationSetZoom(_ zoom: Double) { setZoomArg = zoom }
    func automationGotoLine(_ line: Int, column: Int?) {}
    func automationFind(_ query: FindQuery) -> [FindMatch] { [] }
    func automationVisibleText() -> String { "" }
    func automationCurrentState() -> AutomationState { stateResult }
    func automationToggleBookmark(line: Int?) {}
    func automationListBookmarks() -> [BookmarkEntry] { [] }
    func automationSnapshotPNG() throws -> Data { Data() }
}

@MainActor
final class MCPServerTests: XCTestCase {

    // Helper: round-trip one request through a live server. The server
    // runs on a background thread; the test's main-thread RunLoop
    // services the @MainActor dispatch via DispatchQueue.main.sync —
    // so we must drive the run loop while waiting for the framed
    // response or we deadlock.
    @MainActor
    private func roundTrip(_ requestBody: Data) throws -> MCP.Response {
        let inPipe = Pipe()
        let outPipe = Pipe()
        let host = StubHost()
        let server = MCPServer(
            host: host,
            input: inPipe.fileHandleForReading,
            output: outPipe.fileHandleForWriting,
            logger: nil
        )
        server.start()
        defer { server.stop() }

        // Write framed request.
        let framed = MCPFraming.encode(body: requestBody)
        try inPipe.fileHandleForWriting.write(contentsOf: framed)

        // Read the response on a background queue (which can block on
        // availableData), but keep pumping the main run loop so the
        // server's DispatchQueue.main.sync handler can land. The
        // response Data is filled in by a callback dispatched back
        // onto main.
        let expectation = XCTestExpectation(description: "framed response arrives")
        let received = ResponseHolder()
        DispatchQueue.global(qos: .userInitiated).async {
            var reader = MCPFraming.FileHandleReader(outPipe.fileHandleForReading)
            do {
                if let body = try MCPFraming.decode(from: &reader) {
                    DispatchQueue.main.async {
                        received.body = body
                        expectation.fulfill()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    received.error = error
                    expectation.fulfill()
                }
            }
        }

        // XCTestExpectation.wait services the main run loop, which
        // lets the server's MainActor.assumeIsolated dispatch run.
        wait(for: [expectation], timeout: 3.0)

        if let error = received.error { throw error }
        guard let body = received.body else {
            XCTFail("no response body"); throw TestErr.noResponse
        }
        return try JSONDecoder().decode(MCP.Response.self, from: body)
    }

    /// Mutable holder so the background queue can hand a captured
    /// value back to the main thread. We don't need atomicity because
    /// the expectation fence orders the read-after-write.
    @MainActor
    private final class ResponseHolder {
        var body: Data?
        var error: Error?
    }

    private enum TestErr: Error { case noResponse }

    // MARK: - Tests

    func test_initialize_returnsServerInfoAndCapabilities() throws {
        let req = Data(#"""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
        """#.utf8)
        let resp = try roundTrip(req)
        XCTAssertEqual(resp.id, .int(1))
        XCTAssertNil(resp.error)
        guard case .object(let o)? = resp.result else {
            return XCTFail("no result object")
        }
        XCTAssertEqual(o["protocolVersion"], .string("2024-11-05"))
        guard case .object(let info)? = o["serverInfo"] else {
            return XCTFail("no serverInfo")
        }
        XCTAssertEqual(info["name"], .string("TextView"))
    }

    func test_toolsList_returnsFullCatalog() throws {
        let req = Data(#"""
        {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
        """#.utf8)
        let resp = try roundTrip(req)
        XCTAssertNil(resp.error)
        guard case .object(let o)? = resp.result,
              case .array(let tools)? = o["tools"] else {
            return XCTFail("missing tools array")
        }
        // Pin to the catalog itself rather than a magic literal so adding a
        // tool can't silently drift this expectation out of sync.
        XCTAssertEqual(tools.count, MCPToolCatalog.all.count)
        XCTAssertEqual(tools.count, 12)
    }

    func test_unknownMethod_returnsMethodNotFound() throws {
        let req = Data(#"""
        {"jsonrpc":"2.0","id":3,"method":"does/not/exist"}
        """#.utf8)
        let resp = try roundTrip(req)
        XCTAssertNotNil(resp.error)
        XCTAssertEqual(resp.error?.code, MCP.ErrorCode.methodNotFound)
    }

    func test_toolsCall_currentState_succeeds() throws {
        let req = Data(#"""
        {"jsonrpc":"2.0","id":4,"method":"tools/call",
         "params":{"name":"current_state","arguments":{}}}
        """#.utf8)
        let resp = try roundTrip(req)
        XCTAssertNil(resp.error)
        // tools/call wraps the structured result in a single-text content block.
        guard case .object(let o)? = resp.result,
              case .array(let content)? = o["content"],
              case .object(let block)? = content.first,
              case .string(let text)? = block["text"] else {
            return XCTFail("unexpected tools/call shape")
        }
        XCTAssertEqual(o["isError"], .bool(false))
        // The text is JSON of AutomationState.
        XCTAssertTrue(text.contains("\"viewMode\""))
    }

    func test_toolsCall_pathDeniedSurfacesAsIsError() throws {
        // open_path with a path outside $HOME should come back as a
        // tools/call result with isError=true, NOT as a JSON-RPC error.
        let req = Data(#"""
        {"jsonrpc":"2.0","id":5,"method":"tools/call",
         "params":{"name":"open_path","arguments":{"path":"/etc/hosts"}}}
        """#.utf8)
        let resp = try roundTrip(req)
        XCTAssertNil(resp.error, "expected success envelope with isError flag")
        guard case .object(let o)? = resp.result else { return XCTFail() }
        XCTAssertEqual(o["isError"], .bool(true))
    }

    func test_toolsCall_setZoom_roundTripsAppliedAndClamped() throws {
        // End-to-end through the framed server: an over-max zoom comes
        // back clamped, with the clamp visible on the wire. Proves the
        // new tool is dispatchable (not just unit-testable in isolation).
        let req = Data(#"""
        {"jsonrpc":"2.0","id":6,"method":"tools/call",
         "params":{"name":"set_zoom","arguments":{"zoom":99}}}
        """#.utf8)
        let resp = try roundTrip(req)
        XCTAssertNil(resp.error, "expected success envelope")
        // tools/call wraps the structured result in a single-text block.
        guard case .object(let o)? = resp.result,
              case .array(let content)? = o["content"],
              case .object(let block)? = content.first,
              case .string(let text)? = block["text"] else {
            return XCTFail("unexpected tools/call shape")
        }
        XCTAssertEqual(o["isError"], .bool(false))
        // The JSON payload reports the clamped value + the clamp flag.
        XCTAssertTrue(text.contains("\"clamped\""), "missing clamped flag: \(text)")
        XCTAssertTrue(text.contains("true"), "expected clamped:true: \(text)")
    }
}
