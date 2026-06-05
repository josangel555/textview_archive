import XCTest
import RustCore
@testable import ViewerCore

/// Regression coverage for the audit finding "RustCoreFallback swallows the
/// Rust bridge fault with zero observability" (`RustCoreFallback.swift:53`).
///
/// The fail-safe degradation to the Swift path must remain intact, but a
/// caught bridge fault must now also surface a structured `Obs.shared` event
/// so a gate flipped ON in the field can't mask an always-failing or
/// repeatedly-panicking core. A `.panic` (handle dead-flagged, FFI corruption
/// smell) escalates to `.error`; every other fault is a `.warn`.
///
/// This installs a capturing `RingBufferSink` into the process-wide `Obs`
/// seam and restores the no-op default in `tearDown`, mirroring
/// `ObservabilitySinkTests`.
final class Audit_Sources_ViewerCore_RustCoreFallback_swift_ObservabilityTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var sink: RingBufferSink!

    override func setUp() {
        super.setUp()
        suiteName = "RustCoreFallbackObs-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        sink = RingBufferSink(capacity: 64)
        Obs.install(sink)
    }

    override func tearDown() {
        Obs.resetToNoop()
        defaults.removePersistentDomain(forName: suiteName)
        sink = nil
        super.tearDown()
    }

    // MARK: Fail-safe degradation is preserved

    func test_rustThrows_stillFallsBackToSwift() {
        struct Boom: Error {}
        let o = RustCoreFallback.run(.diff, defaults: defaults, environment: ["MDV_RUST_DIFF": "1"],
                                     rust: { throw Boom() }, swift: { "S" })
        XCTAssertEqual(o.value, "S")
        XCTAssertEqual(o.source, .swiftFallback)
    }

    // MARK: The fault is now observable

    func test_rustThrows_emitsObsEvent_taggedWithCapability() {
        struct Boom: Error {}
        _ = RustCoreFallback.run(.diff, defaults: defaults, environment: ["MDV_RUST_DIFF": "1"],
                                 rust: { throw Boom() }, swift: { "S" })

        let events = sink.snapshotEvents()
        XCTAssertEqual(events.count, 1, "a caught bridge fault must emit exactly one event")
        let e = try! XCTUnwrap(events.first)
        XCTAssertEqual(e.subsystem, "rust-core")
        XCTAssertEqual(e.fields["capability"], "diff")
        XCTAssertTrue(e.message.contains("diff"), "message should name the capability")
        XCTAssertTrue(e.message.contains("fell back"), "message should describe the fallback")
    }

    func test_genericError_isWarn() {
        struct Boom: Error {}
        _ = RustCoreFallback.run(.hex, defaults: defaults, environment: ["MDV_RUST_HEX": "1"],
                                 rust: { throw Boom() }, swift: { 0 })

        let e = try! XCTUnwrap(sink.snapshotEvents().first)
        XCTAssertEqual(e.level, .warn, "a non-panic fault degrades to a warning")
    }

    func test_corePanic_escalatesToError() {
        _ = RustCoreFallback.run(.csv, defaults: defaults, environment: ["MDV_RUST_CSV": "1"],
                                 rust: { throw CoreError.panic }, swift: { "S" })

        let e = try! XCTUnwrap(sink.snapshotEvents().first)
        XCTAssertEqual(e.level, .error,
                       "a caught FFI panic dead-flags the handle and must escalate to .error")
        XCTAssertEqual(e.fields["capability"], "csv")
    }

    // MARK: No event on the success / gate-off paths

    func test_rustSucceeds_emitsNothing() {
        _ = RustCoreFallback.run(.diff, defaults: defaults, environment: ["MDV_RUST_DIFF": "1"],
                                 rust: { "R" }, swift: { "S" })
        XCTAssertTrue(sink.snapshotEvents().isEmpty, "the success path must stay quiet")
    }

    func test_gateOff_emitsNothing() {
        _ = RustCoreFallback.run(.diff, defaults: defaults, environment: [:],
                                 rust: { "R" }, swift: { "S" })
        XCTAssertTrue(sink.snapshotEvents().isEmpty, "the gate-off path must stay quiet")
    }
}
