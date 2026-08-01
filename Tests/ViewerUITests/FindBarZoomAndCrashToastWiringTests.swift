import XCTest
@testable import ViewerUI

/// R9 wiring pins (source-level — both live in surfaces host tests can't
/// drive behaviorally: the app target's launch path and a ContentView call
/// site).
///
/// - I-18: the crash-guard "Starting fresh" toast must carry a "Restore Now"
///   action that re-runs the GUARDED restore (RestoreCrashGuardTests
///   `skipIsOneShot` pins the guard semantics the action relies on).
/// - I-11: the editor find bar scales with the CONTENT zoom, not just the
///   chrome scale.
final class FindBarZoomAndCrashToastWiringTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewerUITests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
    }

    func test_crashGuardToast_offersRestoreNow_runningTheGuardedRestore() throws {
        let main = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/MarkdownViewer/main.swift"),
            encoding: .utf8)
        let skipBranch = try XCTUnwrap(
            main.range(of: "case .skipRestore(let failures):").map {
                String(main[$0.lowerBound...].prefix(1400))
            })
        XCTAssertTrue(skipBranch.contains("actionLabel: \"Restore Now\""),
            "the skip toast must offer the Restore Now action (I-18)")
        XCTAssertTrue(skipBranch.contains("sessions.bootstrap()"),
            "Restore Now must run the actual restore")
        XCTAssertTrue(skipBranch.contains("beginAttempt()"),
            "the retry must stay UNDER the crash guard — a crash mid-restore "
            + "re-trips the breaker next launch")
    }

    func test_editorFindBar_scalesWithContentZoom() throws {
        let content = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/ViewerUI/ContentView.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            content.contains("uiSize: { model.uiSize($0) * CGFloat(model.zoom) })"),
            "EditorFindBar must scale with the content zoom (I-11)")
    }
}
