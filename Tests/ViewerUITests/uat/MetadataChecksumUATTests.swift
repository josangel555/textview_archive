import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-505 part B — live-app validation of the MetadataPanel checksum
/// section in the REAL spawned app: open a media-preview file (PNG), drive
/// the EXACT `compute()` the "Compute SHA-256" button is wired to via the
/// `metadata-compute-checksum` verb, and assert the cross-process outcome
/// from the step dump (state `done` + the file's REAL SHA-256, computed
/// independently in the TEST process via the host-tested FileChecksum core).
///
/// Why a closure-verb and not a synthesized click: in-process real-event
/// synthesis for SwiftUI controls is impossible (LESSONS "in-process event
/// synthesis"; the eight constraints) — this is the testing mandate's
/// sanctioned fallback, the same shape as `InteractionUATTests`.
///
/// TIER-JUSTIFY: T4 — the observables are the live app's mounted
/// MetadataPanel (the projection is empty unless the panel actually
/// mounted with the Info toggle on) and the cross-process compute outcome.
/// Host tests (`MetadataChecksumModelTests`) pin the state machine + verb +
/// projection in-process; this proves the real-app wiring.
@MainActor
final class MetadataChecksumUATTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "MetadataChecksumUAT" }
    override class var defaultScenarioTimeout: TimeInterval { 60 }

    /// Minimal valid 1×1 PNG (fixed bytes ⇒ deterministic SHA-256).
    private static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNg" +
        "YGBgAAAABQABh6FO1AAAAABJRU5ErkJggg==")!

    func test_TSK505_computeChecksum_landsRealHashInLivePanel() throws {
        let png = harness.tmpDir.appendingPathComponent("pixel.png")
        try Self.onePixelPNG.write(to: png)
        // Independent expectation: the TEST process hashes the same file
        // through the host-tested core; the app must agree cross-process.
        let expected = try FileChecksum.sha256Hex(ofFileAt: png)

        let script = """
        delay 1.5
        metadata-compute-checksum
        delay 2.0
        """
        try runScenarios([
            Scenario(
                name: "metadata-compute-checksum",
                argFile: png,
                script: script,
                assert: { dumps, file, line in
                    guard let last = dumps.last,
                          let model = last["model"] as? [String: Any] else {
                        XCTFail("no model dump", file: file, line: line); return
                    }
                    let proj = model["metadataChecksum"] as? [String: Any] ?? [:]
                    XCTAssertFalse(proj.isEmpty,
                        "empty checksum projection — the MetadataPanel never "
                        + "MOUNTED in the live app (preview routing or the Info "
                        + "toggle regressed). dump keys: \(model.keys.sorted())",
                        file: file, line: line)
                    XCTAssertEqual(proj["state"] as? String, "done",
                        "the Compute action must finish in the live app; "
                        + "projection: \(proj)", file: file, line: line)
                    XCTAssertEqual(proj["hash"] as? String, expected,
                        "the live panel's hash must equal the test-side "
                        + "FileChecksum result for the same bytes",
                        file: file, line: line)
                })
        ])
    }
}
