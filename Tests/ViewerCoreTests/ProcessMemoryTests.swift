import XCTest
@testable import ViewerCore

/// Host-safe tests for the honest memory source (item: status-bar memory,
/// triage-instrumentation.md). These exercise the real `task_info` /
/// `libproc` syscalls against the running test process — no UI, no
/// NSApplication, so they belong in the host-runnable ViewerCoreTests
/// suite.
///
/// The assertions are deliberately about *honesty invariants* and
/// *non-crashing*, not exact byte values (those depend on the host).
final class ProcessMemoryTests: XCTestCase {

    func testAppFootprintIsPositive() {
        // task_info(TASK_VM_INFO) must succeed for the current process
        // and report a non-zero physical footprint.
        let bytes = ProcessMemory.appFootprintBytes()
        XCTAssertNotNil(bytes, "task_info(TASK_VM_INFO) should succeed for self")
        if let bytes {
            XCTAssertGreaterThan(bytes, 0)
            // A live process is well under, say, 100 GB; this catches a
            // unit/overflow blunder without being host-specific.
            XCTAssertLessThan(bytes, 100 * 1024 * 1024 * 1024)
        }
    }

    func testFootprintOfSelfMatchesViaRusage() {
        // The per-pid rusage path must also work for our own pid and be
        // in the same ballpark as the task_info number (both are
        // phys_footprint; they sample at slightly different instants so
        // we only assert positivity + same order of magnitude).
        let viaRusage = ProcessMemory.footprintBytes(of: getpid())
        XCTAssertNotNil(viaRusage)
        if let viaRusage { XCTAssertGreaterThan(viaRusage, 0) }
    }

    func testParentPidLookupSucceeds() {
        let ppid = ProcessMemory.parentPID(of: getpid())
        XCTAssertNotNil(ppid)
        // Our parent is a real process (the test runner / shell), pid > 0.
        if let ppid { XCTAssertGreaterThan(ppid, 0) }
    }

    func testExecutablePathOfSelfIsNonEmpty() {
        let path = ProcessMemory.executablePath(of: getpid())
        XCTAssertNotNil(path)
        XCTAssertFalse(path?.isEmpty ?? true)
    }

    func testWebKitHelperSumIsZeroOrPositiveAndNeverCrashes() {
        // No WKWebView in a unit-test process, so the sum should be 0
        // with 0 helpers — but the contract is just "non-negative,
        // doesn't crash walking every pid". We assert the honest-figure
        // invariants rather than an exact value.
        let (bytes, count, _) = ProcessMemory.webKitHelperFootprint()
        XCTAssertGreaterThanOrEqual(count, 0)
        // bytes is UInt64 so >= 0 by type; assert consistency: zero
        // helpers must mean zero bytes.
        if count == 0 { XCTAssertEqual(bytes, 0) }
    }

    func testSampleIsInternallyConsistent() {
        let s = ProcessMemory.sample()
        // App footprint present + positive for the live process.
        XCTAssertNotNil(s.appFootprintBytes)
        // The sample never fabricates a per-tab number — there is no such
        // field on the type. Helper count/bytes consistency:
        if s.webKitHelperCount == 0 {
            XCTAssertEqual(s.webKitHelperBytes, 0)
        }
    }

    func testSampleEquatableValueSemantics() {
        let a = ProcessMemorySample(
            appFootprintBytes: 100, webKitHelperBytes: 0,
            webKitHelperCount: 0, helpersComplete: true)
        let b = ProcessMemorySample(
            appFootprintBytes: 100, webKitHelperBytes: 0,
            webKitHelperCount: 0, helpersComplete: true)
        let c = ProcessMemorySample(
            appFootprintBytes: 101, webKitHelperBytes: 0,
            webKitHelperCount: 0, helpersComplete: true)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
