import XCTest
@testable import RustCore

/// TSK-978: a highlight run's `start`/`len` arrive on the wire as MessagePack
/// `u64`. The decode used `Int(try a[i].u64Value())`, a TRAPPING conversion —
/// a value > `Int.max` (e.g. `2^63`) crashes the process at DECODE time. Since
/// `.highlight` is a capability bit, a remote/loopback producer can route such
/// a value here, so this is reachable from untrusted input. The fix bounds the
/// conversion with `Int(exactly:)` and DROPS an over-range span rather than
/// synthesising a bogus one.
///
/// These run through a spy `CoreTransport` (the TSK-652 seam) that replays a
/// hand-built `highlight_runs` response frame, exercising the REAL
/// `mdvCoreHighlightRuns` decode path end-to-end. On the unfixed code the
/// `Int(UInt64)` conversion traps → the test process aborts (demonstrable red).
final class HighlightOffsetOverflowTests: XCTestCase {

    /// Replays a canned `highlight_runs` body for the `highlight_runs` method.
    private final class HighlightSpy: CoreTransport, @unchecked Sendable {
        let body: [UInt8]
        init(_ response: MsgPackValue) { self.body = response.encode() }
        func call(_ method: String, requestBody: [UInt8]) throws -> [UInt8]? { body }
    }

    override func tearDown() {
        CoreTransportRegistry.resetToInProcess()
        super.tearDown()
    }

    /// Build a `{supported:true, runs:[...]}` frame from positional tuples.
    private func supportedRuns(_ tuples: [(MsgPackValue, MsgPackValue, String)]) -> MsgPackValue {
        .map([
            (.string("supported"), .bool(true)),
            (.string("runs"), .array(tuples.map { t in
                .array([t.0, t.1, .string(t.2)])
            })),
        ])
    }

    private func decode(_ response: MsgPackValue) throws -> [CoreHighlightRun]? {
        CoreTransportRegistry.current = HighlightSpy(response)
        return try mdvCoreHighlightRuns(text: "anything", lang: "rust")
    }

    /// `start = Int.max + 1` (2^63) overflows `Int`. The trapping conversion
    /// would abort here; the fix DROPS the span and decodes gracefully.
    func test_startAboveIntMax_dropsSpan_doesNotTrap() throws {
        let overflowStart = UInt64(Int.max) + 1  // 0x8000_0000_0000_0000 == 2^63
        let runs = try decode(supportedRuns([
            (.uint(overflowStart), .uint(3), "keyword"),  // malformed: dropped
            (.uint(0), .uint(2), "keyword"),               // valid: kept
        ]))
        // No trap reached this line — the value is gracefully handled.
        let unwrapped = try XCTUnwrap(runs)
        XCTAssertEqual(unwrapped.count, 1, "the over-range span must be dropped, the valid one kept")
        XCTAssertEqual(unwrapped.first?.start, 0)
        XCTAssertEqual(unwrapped.first?.len, 2)
        XCTAssertEqual(unwrapped.first?.kind, "keyword")
    }

    /// The exact reviewer-named value: `start = 2^63`, the smallest `u64` that
    /// overflows a 64-bit signed `Int`.
    func test_startExactlyTwoToThe63_dropsSpan_doesNotTrap() throws {
        let twoToThe63: UInt64 = 1 << 63
        let runs = try decode(supportedRuns([
            (.uint(twoToThe63), .uint(1), "string"),
        ]))
        let unwrapped = try XCTUnwrap(runs)
        XCTAssertTrue(unwrapped.isEmpty, "the only span overflows Int.max → dropped, empty result")
    }

    /// `len` (not just `start`) must be bounded too — apply both fields.
    func test_lenAboveIntMax_dropsSpan_doesNotTrap() throws {
        let overflowLen = UInt64(Int.max) + 42
        let runs = try decode(supportedRuns([
            (.uint(0), .uint(overflowLen), "comment"),
        ]))
        let unwrapped = try XCTUnwrap(runs)
        XCTAssertTrue(unwrapped.isEmpty, "an over-range length must drop the span")
    }

    /// A `u64` at exactly `Int.max` is the largest representable `Int` — it must
    /// survive (the bound is `> Int.max`, not `>=`).
    func test_startAtIntMax_isPreserved() throws {
        let runs = try decode(supportedRuns([
            (.uint(UInt64(Int.max)), .uint(0), "keyword"),
        ]))
        let unwrapped = try XCTUnwrap(runs)
        XCTAssertEqual(unwrapped.count, 1)
        XCTAssertEqual(unwrapped.first?.start, Int.max)
    }

    /// Sanity: a well-formed tuple still decodes through the same path.
    func test_inRangeRun_decodesNormally() throws {
        let runs = try decode(supportedRuns([
            (.uint(4), .uint(7), "function"),
        ]))
        let unwrapped = try XCTUnwrap(runs)
        XCTAssertEqual(unwrapped.count, 1)
        XCTAssertEqual(unwrapped.first?.start, 4)
        XCTAssertEqual(unwrapped.first?.len, 7)
        XCTAssertEqual(unwrapped.first?.kind, "function")
    }

    /// A non-string `kind` is a genuine wire fault and must still THROW — the
    /// overflow fix must not swallow real type mismatches.
    func test_malformedKind_stillThrows() {
        CoreTransportRegistry.current = HighlightSpy(.map([
            (.string("supported"), .bool(true)),
            (.string("runs"), .array([.array([.uint(0), .uint(1), .uint(99)])])),
        ]))
        XCTAssertThrowsError(try mdvCoreHighlightRuns(text: "x", lang: "rust")) { error in
            guard case CoreError.decode = error else {
                return XCTFail("expected a decode fault for a non-string kind, got \(error)")
            }
        }
    }
}
