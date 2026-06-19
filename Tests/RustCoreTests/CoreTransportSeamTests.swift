import XCTest
@testable import RustCore

/// The transport seam (TSK-652): every stateless wrapper must route through
/// `CoreTransportRegistry.current` — proven with a spy transport that
/// captures the method name and returns a canned frame body. This is what
/// makes remote a carrier swap: if a wrapper bypasses the registry, these
/// tests fail.
final class CoreTransportSeamTests: XCTestCase {

    /// Captures calls; replays a canned response (or throws). `rawResponse`
    /// feeds the aux path (raw bytes, not a frame); `response` feeds `call`.
    final class SpyTransport: CoreTransport, @unchecked Sendable {
        let lock = NSLock()
        private(set) var calls: [(method: String, body: [UInt8])] = []
        private(set) var auxCalls: [(method: String, body: [UInt8], aux: [UInt8])] = []
        var response: [UInt8]?
        var rawResponse: [UInt8]?
        var error: CoreError?

        init(response: MsgPackValue? = nil, rawResponse: [UInt8]? = nil) {
            self.response = response?.encode()
            self.rawResponse = rawResponse
        }

        func call(_ method: String, requestBody: [UInt8]) throws -> [UInt8]? {
            lock.lock()
            calls.append((method, requestBody))
            lock.unlock()
            if let error { throw error }
            return response
        }

        func callAux(_ method: String, requestBody: [UInt8], aux: [UInt8]) throws -> [UInt8]? {
            lock.lock()
            auxCalls.append((method, requestBody, aux))
            lock.unlock()
            if let error { throw error }
            return rawResponse
        }
    }

    override func tearDown() {
        CoreTransportRegistry.resetToInProcess()
        super.tearDown()
    }

    private struct WrapperCase {
        let method: String
        let canned: MsgPackValue
        let invoke: () throws -> Void
    }

    func test_everyStatelessWrapper_routesItsMethodName() throws {
        let emptyArray = MsgPackValue.array([])
        let cases: [WrapperCase] = [
            WrapperCase(
                method: "fuzzy_rank",
                canned: .map([(.string("matches"), emptyArray)]),
                invoke: { _ = try mdvCoreFuzzyRank(query: "q", candidates: ["a"]) }),
            WrapperCase(
                method: "find_search",
                canned: .map([(.string("matches"), emptyArray)]),
                invoke: {
                    _ = try mdvCoreFindSearch(
                        text: "t", pattern: "p", kind: "literal",
                        caseSensitive: false, wholeWord: false)
                }),
            WrapperCase(
                method: "transcript_parse",
                canned: .map([(.string("events"), emptyArray)]),
                invoke: { _ = try mdvCoreTranscriptParse(text: "", redacting: true) }),
            WrapperCase(
                method: "markdown_render",
                canned: .map([
                    (.string("html"), .string("<h1>x</h1>")),
                    (.string("chunks"), emptyArray),
                ]),
                invoke: { _ = try mdvCoreMarkdownRender(text: "# x") }),
            WrapperCase(
                method: "diff_hunk_marks",
                canned: .map([(.string("marks"), emptyArray)]),
                invoke: { _ = try mdvCoreDiffHunkMarks(text: "") }),
        ]
        for c in cases {
            let spy = SpyTransport(response: c.canned)
            CoreTransportRegistry.current = spy
            try c.invoke()
            XCTAssertEqual(spy.calls.count, 1, "\(c.method): exactly one transport call")
            XCTAssertEqual(spy.calls.first?.method, c.method)
            XCTAssertFalse(spy.calls.first?.body.isEmpty ?? true,
                           "\(c.method): request body must carry the encoded args")
        }
    }

    func test_indentDetect_routesThroughTheAuxSeam_withTextInAux() throws {
        // TSK-651: mdvCoreIndentDetect must route through the registry's
        // callAux, carrying the source text in `aux` (NOT `body`) so a remote
        // carrier sees the bulk channel. The spy returns the raw style string.
        let spy = SpyTransport(rawResponse: [UInt8]("Spaces (4)".utf8))
        CoreTransportRegistry.current = spy
        let result = try mdvCoreIndentDetect(text: "    a\n    b\n", sampleLines: 50)
        XCTAssertEqual(result, "Spaces (4)", "the raw aux response must pass through verbatim")
        XCTAssertEqual(spy.auxCalls.count, 1, "exactly one aux transport call")
        XCTAssertEqual(spy.auxCalls.first?.method, "indent_detect")
        XCTAssertEqual(spy.auxCalls.first?.aux, [UInt8]("    a\n    b\n".utf8),
                       "the source text must ride the aux side-channel")
        XCTAssertFalse(spy.auxCalls.first?.body.isEmpty ?? true,
                       "the {sample_lines} scalar must ride the request body")
        XCTAssertTrue(spy.calls.isEmpty, "indent_detect must NOT use the plain call path")
    }

    func test_transportFault_surfacesAsCoreError() {
        let spy = SpyTransport()
        spy.error = .wireError
        CoreTransportRegistry.current = spy
        XCTAssertThrowsError(try mdvCoreFuzzyRank(query: "q", candidates: ["a"])) { error in
            XCTAssertEqual(error as? CoreError, .wireError)
        }
    }

    func test_inProcessDefault_servesRealResults() throws {
        // The registry's default backend must hit the linked core — a real
        // round trip, no injection.
        CoreTransportRegistry.resetToInProcess()
        let matches = try mdvCoreFindSearch(
            text: "hello world", pattern: "hello", kind: "literal",
            caseSensitive: false, wholeWord: false)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.location, 0)
    }

    func test_inProcess_unknownMethod_isTypedFault() {
        XCTAssertThrowsError(
            try InProcessTransport().call("no_such_method", requestBody: [0x80])
        ) { error in
            guard case CoreError.decode(let msg)? = error as? CoreError else {
                return XCTFail("expected typed decode fault, got \(error)")
            }
            XCTAssertTrue(msg.contains("no_such_method"))
        }
    }
}
