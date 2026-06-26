import XCTest

import CMdvCore
@testable import RustCore

/// Cross-language tests: Swift calling the ACTUAL Rust `extern "C"` symbols via
/// the RustCore bridge, asserting the round-trips. Headless (no SwiftUI / no
/// NSApplication), so per the project's testing rules they are safe on the
/// host. Carried over from the validated PoC (`poc-snap-final`), adapted to the
/// shipping `mdvcore_*` symbols.
final class BridgeTests: XCTestCase {

    let csv = "name,city\nAlice,Paris\nBob,Parma\nCarol,Berlin\n"

    func testStage0Add() {
        XCTAssertEqual(mdvCoreAdd(2, 3), 5)
        // wrapping add over the boundary.
        XCTAssertEqual(mdvCoreAdd(Int32.max, 1), Int32.min)
    }

    func testABIVersion_linkedLibraryMatchesCompiledHeader() {
        // THE skew detector (TSK-579, audit R4): the cbindgen header bakes
        // MDV_WIRE_VERSION into this compilation; mdvcore_abi_version() reports
        // what the linked libmdvcore_ffi.a was built with. Inequality means the
        // staged header and the staticlib drifted (stale rust-core/link/ on the
        // host, stale rsync'd .a on the VM) — every other bridge call is then
        // crossing an undefined ABI. Runs in every gate, host and VM.
        XCTAssertEqual(mdvcore_abi_version(), UInt32(MDV_WIRE_VERSION),
                       "header/staticlib ABI skew — run scripts/build-rust-core.sh and rebuild")
        XCTAssertTrue(CoreABI.isCompatible)
        XCTAssertEqual(CoreABI.compiled, CoreABI.linked)
        // 0 is the guard-tripped sentinel — never a valid version.
        XCTAssertNotEqual(UInt32(MDV_WIRE_VERSION), 0)
    }

    func testABIVersion_assertCompatibleIsCallableAndIdempotent() {
        // The crash-fast entry-point hook must be a no-op on a healthy link,
        // repeatedly (static-let once semantics).
        CoreABI.assertCompatible()
        CoreABI.assertCompatible()
        XCTAssertTrue(CoreABI.isCompatible)
    }

    func testCapabilities_linkedLibraryAdvertisesShippedFamilies() {
        // TSK-634: feature negotiation above the wire version. The LINKED
        // library must advertise every family the shipping Swift adapters
        // consume; the cross-language pairing (header consts vs runtime mask)
        // is the same skew detector shape as the ABI version above.
        let caps = CoreABI.capabilities
        XCTAssertTrue(caps.contains(.requiredByShippingAdapters),
                      "linked core is missing shipped families: raw=\(caps.rawValue)")
        // The TSK-630..633 engine-port wave is COMPLETE — no reserved bits
        // remain; every assigned family must advertise. (A future port
        // pre-assigns its bit here OFF, and flips it with the port —
        // same-change rule, both sides.)
        XCTAssertTrue(caps.contains(.fuzzy))
        XCTAssertTrue(caps.contains(.find))
        XCTAssertTrue(caps.contains(.transcript))
        XCTAssertTrue(caps.contains(.markdown))
        // TSK-660: highlight is an ENGINE bit — the linked library exports
        // mdvcore_highlight_runs, so the in-process mask advertises it.
        XCTAssertTrue(caps.contains(.highlight))
        // TSK-543: cm-apply delta is an ENGINE bit (core-routable apply_delta_wire),
        // present in the in-process mask.
        XCTAssertTrue(caps.contains(.cmApplyDelta))
        // SERVER-ONLY bit: never in the in-process mask (no fs FFI export);
        // a remote mdv-serve hello sets it when a root is served (TSK-654).
        XCTAssertFalse(caps.contains(.fs))
        XCTAssertFalse(caps.contains(.git))
        XCTAssertFalse(caps.contains(.transcriptList))
        XCTAssertFalse(caps.contains(.lspPipe))
        XCTAssertFalse(caps.contains(.search))
    }

    func testCapabilityBits_areABIAndNeverRenumber() {
        // Bits are ABI — pinned on BOTH sides (Rust twin:
        // capability_bits_are_abi_and_never_renumber). A renumber silently
        // flips feature gates for skewed/remote clients.
        XCTAssertEqual(CoreCapabilities.csvSession.rawValue, 1 << 0)
        XCTAssertEqual(CoreCapabilities.diff.rawValue, 1 << 1)
        XCTAssertEqual(CoreCapabilities.hex.rawValue, 1 << 2)
        XCTAssertEqual(CoreCapabilities.indent.rawValue, 1 << 3)
        XCTAssertEqual(CoreCapabilities.cmApply.rawValue, 1 << 4)
        XCTAssertEqual(CoreCapabilities.find.rawValue, 1 << 5)
        XCTAssertEqual(CoreCapabilities.markdown.rawValue, 1 << 6)
        XCTAssertEqual(CoreCapabilities.transcript.rawValue, 1 << 7)
        XCTAssertEqual(CoreCapabilities.fuzzy.rawValue, 1 << 8)
        XCTAssertEqual(CoreCapabilities.fs.rawValue, 1 << 9)
        XCTAssertEqual(CoreCapabilities.git.rawValue, 1 << 10)
        XCTAssertEqual(CoreCapabilities.transcriptList.rawValue, 1 << 11)
        XCTAssertEqual(CoreCapabilities.lspPipe.rawValue, 1 << 12)
        XCTAssertEqual(CoreCapabilities.search.rawValue, 1 << 13)
        XCTAssertEqual(CoreCapabilities.highlight.rawValue, 1 << 14)
        XCTAssertEqual(CoreCapabilities.cmApplyDelta.rawValue, 1 << 15)
    }

    func testCapabilities_unknownBitsAreTolerated() {
        // Forward-compat contract: a NEWER library may set bits this build
        // doesn't know. OptionSet semantics must keep known-bit gating
        // working regardless — this is what lets client and core (or a
        // future remote mdv-serve) version independently.
        let future = CoreCapabilities(rawValue: CoreCapabilities.csvSession.rawValue | (1 << 63))
        XCTAssertTrue(future.contains(.csvSession))
        XCTAssertFalse(future.contains(.markdown))
    }

    func testForcePanicMapsToError() {
        // The core panics; the boundary catches it and returns .panic. The test
        // process must NOT crash (proves catch_unwind end-to-end into Swift,
        // and that the dist/unwind profile is the one being linked).
        XCTAssertEqual(mdvCoreForcePanic(), .panic)
        // Still alive:
        XCTAssertEqual(mdvCoreAdd(1, 1), 2)
    }

    func testTooLargeStatusMapsToDistinctError() {
        // TSK-548 stopgap: the encode-side overflow status must surface as
        // .tooLarge (caller can window / fall back), NOT the generic
        // .wireError that reads as a codec bug.
        XCTAssertEqual(CoreError(status: MDV_STATUS_TOO_LARGE), .tooLarge)
        XCTAssertNotEqual(CoreError(status: MDV_STATUS_TOO_LARGE), .wireError)
        XCTAssertEqual(CoreError(status: MDV_STATUS_WIRE_ERROR), .wireError)
    }

    func testHandleDeadStatusMapsToDistinctError() {
        // TSK-581: the core's poisoned-lock tri-state must surface as
        // .handleDead (permanent, drop & recreate) — NOT .busy (retryable).
        XCTAssertEqual(CoreError(status: MDV_STATUS_HANDLE_DEAD), .handleDead)
        XCTAssertNotEqual(CoreError(status: MDV_STATUS_HANDLE_DEAD), .busy)
    }

    func testUnknownMethodStatusMapsToDistinctError() {
        // TSK-982: a method-space skew (forward-compat / remote-skew) must
        // surface as .unknownMethod, NOT .internalError — so the host can tell
        // a version/capability mismatch (gate on capabilities / fall back)
        // apart from a genuine core fault that reads as a crash. On unfixed code
        // the unknown-method arm returned Internal → both these collapse and
        // the assertions go red.
        XCTAssertEqual(CoreError(status: MDV_STATUS_UNKNOWN_METHOD), .unknownMethod(method: nil))
        XCTAssertNotEqual(CoreError(status: MDV_STATUS_UNKNOWN_METHOD), .internalError)
        // The genuine internal fault stays distinct.
        XCTAssertEqual(CoreError(status: MDV_STATUS_INTERNAL), .internalError)
        XCTAssertNotEqual(CoreError(status: MDV_STATUS_INTERNAL), .unknownMethod(method: nil))
    }

    func testUnknownMethodEnrichedInitCarriesTheSkewedId() {
        // The envelope call sites know which method id they dispatched, so the
        // enriched init threads it through for host-side logging/branching.
        XCTAssertEqual(
            CoreError(status: MDV_STATUS_UNKNOWN_METHOD, method: 9999),
            .unknownMethod(method: 9999))
        // The id-distinguishing equality holds (a different id is a different
        // value), so a regression that dropped the id would be caught.
        XCTAssertNotEqual(
            CoreError(status: MDV_STATUS_UNKNOWN_METHOD, method: 9999),
            .unknownMethod(method: 1))
        // The enriched init is transparent for every OTHER status — it must not
        // hijack a real fault into .unknownMethod.
        XCTAssertEqual(CoreError(status: MDV_STATUS_PANIC, method: 12), .panic)
        XCTAssertEqual(CoreError(status: MDV_STATUS_INTERNAL, method: 12), .internalError)
    }

    func testOpenAndTableRoundTrip() throws {
        let session = try CsvSession(csv: csv)
        let table = try session.table()
        XCTAssertEqual(table.delimiter, ",")
        XCTAssertEqual(table.header, ["name", "city"])
        XCTAssertEqual(table.rows, [["Alice", "Paris"], ["Bob", "Parma"], ["Carol", "Berlin"]])
        XCTAssertFalse(table.truncated)
    }

    func testBadUTF8Throws() {
        let bad: [UInt8] = [0x61, 0xFF, 0x62]
        XCTAssertThrowsError(try CsvSession(bytes: bad)) { error in
            XCTAssertEqual(error as? CoreError, .badUTF8)
        }
    }

    func testSetFilterAndSnapshot() throws {
        let session = try CsvSession(csv: csv)

        let snap0 = try session.snapshot()
        XCTAssertEqual(snap0.totalRows, 3)
        XCTAssertEqual(snap0.rows.count, 3)
        XCTAssertEqual(snap0.version, 1)

        try session.setFilter("par")
        let snap1 = try session.snapshot()
        XCTAssertEqual(snap1.rows.count, 2)  // Paris, Parma
        XCTAssertEqual(snap1.indices, [0, 1])
        XCTAssertEqual(snap1.totalRows, 3)
        XCTAssertEqual(snap1.version, 2)
        XCTAssertEqual(snap1.query, "par")
    }

    func testColumnScopedFilter() throws {
        let session = try CsvSession(csv: csv)
        try session.setFilter("a", scope: .column(0))  // name col: Alice, Carol
        let snap = try session.snapshot()
        XCTAssertEqual(snap.indices, [0, 2])
    }

    func testLevelTriggeredSnapshotIsFullState() throws {
        // Successive filter changes; the snapshot reflects ONLY the latest
        // query as complete current state, not an accumulation of deltas.
        let session = try CsvSession(csv: csv)
        try session.setFilter("par")
        try session.setFilter("berlin")
        let snap = try session.snapshot()
        XCTAssertEqual(snap.query, "berlin")
        XCTAssertEqual(snap.rows.count, 1)
        XCTAssertEqual(snap.rows.first?.last, "Berlin")

        // Re-pulling without a mutation yields an identical snapshot.
        let again = try session.snapshot()
        XCTAssertEqual(snap, again)
    }

    func testEmptyInputOpens() throws {
        let session = try CsvSession(bytes: [])
        let table = try session.table()
        XCTAssertTrue(table.header.isEmpty)
        XCTAssertTrue(table.rows.isEmpty)
    }

    func testHandleLifecycleManyOpens() throws {
        // ARC frees each handle in deinit; a leak/double-free would surface
        // under ASan. Here we just prove the loop is stable.
        for _ in 0..<500 {
            let session = try CsvSession(csv: csv)
            _ = try session.snapshot()
        }
    }

    func testQuotedAndCRLF() throws {
        let session = try CsvSession(csv: "a,b\r\n\"x,y\",z\r\n")
        let table = try session.table()
        XCTAssertEqual(table.rows, [["x,y", "z"]])
    }
}
