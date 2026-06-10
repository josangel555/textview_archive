import XCTest
@testable import ViewerUI
import ViewerCore

/// TSK-620 half B — REAL-event validation of the gesture/render halves
/// that hold TSK-313 / TSK-314 at `fixed`. These scenarios drive the
/// `ui-click` / `ui-double-click` verbs (UIEventSynth: genuine NSEvents
/// posted to the app's event queue) against the live bundle and assert
/// the cross-process outcome from the step dumps.
///
/// TIER-JUSTIFY: T4 — the observables are (1) SwiftUI GESTURE ROUTING in
/// the realized window: the strip's `.onTapGesture(count: 2)` and the +
/// button's tap must fire from real queued mouse events through AppKit
/// hit-testing (headless exact-closure tests prove the ACTIONS, not the
/// hit-area wiring), and (2) the RENDERED text of the GoTo prompt's
/// TextField (`nsTextField.stringValue` in the dump) — the on-appear
/// seed from `goToPathPrefill` has no host-observable. Self-skips on the
/// headless gate; runs on the VM GUI lane.
@MainActor
final class InteractionUATTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "InteractionUAT" }
    override class var defaultScenarioTimeout: TimeInterval { 60 }

    // MARK: - TSK-313 — double-click the empty strip area → instant ~ session

    func test_TSK313_doubleClickStripEmptyArea_opensHomeSession() throws {
        let arg = try harness.writeFile("arg.txt", "scratch\n")
        // 0.7 of the strip width: with the clean-room baseline (no pills)
        // that point is the strip's empty background, the surface the
        // double-click gesture owns (tab cells / + sit above it).
        let script = """
        ui-double-click mdv.sessionTabBar at 0.7 0.5
        delay 1.0
        """
        try runScenarios([
            Scenario(
                name: "strip-double-click-home",
                argFile: arg,
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    let roots = sessionRoots(last)
                    // The APP's home, not the harness's: under the root
                    // asuser bridge the app is spawned as the console user.
                    let home = AppLauncher.spawnUserHome
                        .resolvingSymlinksInPath().path
                    XCTAssertTrue(roots.contains(home),
                        "REAL double-click on the strip must create a session "
                        + "rooted at resolved home; roots=\(roots)",
                        file: file, line: line)
                    XCTAssertEqual(activeRoot(last), home,
                        "the ~ session must be ACTIVE", file: file, line: line)
                    // Differentiates the gesture from a stray + click: the
                    // home session opens IMMEDIATELY, no GoTo prompt.
                    XCTAssertNil(firstTextField(last, withValue: "~"),
                        "double-click must NOT open the GoTo prompt",
                        file: file, line: line)
                })
        ])
    }

    // MARK: - TSK-314 — + button → GoTo prompt with the field RENDERING "~"

    func test_TSK314_plusButton_rendersPromptPrefilledWithTilde() throws {
        let arg = try harness.writeFile("arg.txt", "scratch\n")
        let script = """
        ui-click mdv.sessionTab.new
        delay 0.6
        """
        try runScenarios([
            Scenario(
                name: "plus-prefilled-prompt",
                argFile: arg,
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    // The render-half evidence TSK-314 was held for: the
                    // realized NSTextField inside the GoTo panel SHOWS "~".
                    let field = firstTextField(last, withValue: "~")
                    XCTAssertNotNil(field,
                        "REAL + click must present the GoTo prompt with the "
                        + "field rendering the ~ prefill; fields seen: "
                        + "\(allTextFieldValues(last)) trace=\(dumpTrace(last))",
                        file: file, line: line)
                })
        ])
    }

    private func dumpTrace(_ dump: [String: Any]) -> String {
        (dump["uiClickTrace"] as? String) ?? "<no trace>"
    }

    // MARK: - Dump accessors

    private func model(_ dump: [String: Any]) -> [String: Any] {
        (dump["model"] as? [String: Any]) ?? [:]
    }
    private func sessionDicts(_ dump: [String: Any]) -> [[String: Any]] {
        (model(dump)["sessions"] as? [[String: Any]]) ?? []
    }
    private func sessionRoots(_ dump: [String: Any]) -> [String] {
        sessionDicts(dump).map { ($0["sidebarRootPath"] as? String) ?? "" }
    }
    private func activeRoot(_ dump: [String: Any]) -> String {
        let id = (model(dump)["activeSessionID"] as? String) ?? ""
        guard !id.isEmpty else { return "" }
        return sessionDicts(dump)
            .first { ($0["id"] as? String) == id }?["sidebarRootPath"] as? String ?? ""
    }

    /// Depth-first walk of the dumped view tree collecting `nsTextField`
    /// payloads (added to DiagnosticDump for exactly this suite).
    private func textFields(in node: [String: Any]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let tf = node["nsTextField"] as? [String: Any] { out.append(tf) }
        for sub in (node["subviews"] as? [[String: Any]]) ?? [] {
            out += textFields(in: sub)
        }
        return out
    }
    private func allTextFieldValues(_ dump: [String: Any]) -> [String] {
        guard let content = dump["contentView"] as? [String: Any] else { return [] }
        return textFields(in: content).compactMap { $0["stringValue"] as? String }
    }
    private func firstTextField(
        _ dump: [String: Any], withValue value: String
    ) -> [String: Any]? {
        guard let content = dump["contentView"] as? [String: Any] else { return nil }
        return textFields(in: content).first { ($0["stringValue"] as? String) == value }
    }
}
