import XCTest
@testable import ViewerUI
import ViewerCore

/// TSK-620 — live-app validation of the gesture/render halves that held
/// TSK-313 / TSK-314 at `fixed`.
///
/// These scenarios exercise the controls' EXACT action closures via
/// script verbs (`session-open-home` == the strip's double-click action,
/// `session-new-via-goto` == the "+" button's action) in the REAL
/// spawned app, then assert the cross-process outcome from the step
/// dumps — including the RENDERED text of the GoTo prompt's NSTextField,
/// the on-screen evidence TSK-314 was held for.
///
/// Why closures and not synthesized clicks: in-process real-event
/// synthesis for SwiftUI controls is IMPOSSIBLE — eight constraints
/// mapped empirically (queue routing, sendEvent non-key suppression,
/// un-fakeable key status, empty in-process AX tree, hosting-boundary
/// ids, denied activation for fork/exec'd and root processes, SwiftUI
/// ignoring responder dispatch, and finally: synthesized NSEvents do not
/// drive SwiftUI gestures even on a genuinely key+active LS-launched
/// window — the gesture pipeline wants WindowServer-backed events, which
/// need the owner-only AX grant). See LESSONS "in-process event
/// synthesis". The testing mandate's fallback for exactly this case:
/// "exercising the exact action closure the control is wired to."
/// Residual not covered here: the literal hit-area routing (does the
/// pixel under the cursor reach this control) — that requires entitled
/// event synthesis (XCUITest L4 / owner AX grant).
///
/// TIER-JUSTIFY: T4 — the observables are the live cross-process
/// coordinator outcome (session creation/activation in the spawned app)
/// and the RENDERED `nsTextField.stringValue` of the GoTo prompt, which
/// has no host observable (host tests cover the model layer only).
@MainActor
final class InteractionUATTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "InteractionUAT" }
    override class var defaultScenarioTimeout: TimeInterval { 60 }

    // MARK: - TSK-313 — strip double-click action → instant ~ session

    func test_TSK313_openHomeAction_createsAndActivatesHomeSession() throws {
        let arg = try harness.writeFile("arg.txt", "scratch\n")
        let script = """
        session-open-home
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
                        "the double-click action must create a session "
                        + "rooted at resolved home; roots=\(roots)",
                        file: file, line: line)
                    XCTAssertEqual(activeRoot(last), home,
                        "the ~ session must be ACTIVE", file: file, line: line)
                    // Differentiates this action from the + flow: the home
                    // session opens IMMEDIATELY, no GoTo prompt.
                    XCTAssertNil(firstTextField(last, withValue: "~"),
                        "the home action must NOT open the GoTo prompt",
                        file: file, line: line)
                })
        ])
    }

    // MARK: - TSK-314 — "+" action → GoTo prompt RENDERING "~"

    func test_TSK314_plusAction_rendersPromptPrefilledWithTilde() throws {
        let arg = try harness.writeFile("arg.txt", "scratch\n")
        let script = """
        session-new-via-goto
        delay 1.0
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
                        "the + action must present the GoTo prompt with the "
                        + "field rendering the ~ prefill; fields seen: "
                        + "\(allTextFieldValues(last))",
                        file: file, line: line)
                })
        ])
    }

    // MARK: - TSK-522/523 — Git Log row actions in the live app

    /// Build a 3-commit repo under the harness tmpdir and return
    /// (folder, short SHAs newest-first — graphLog's `%h` format, which
    /// is what the row closures receive).
    private func makeRepoFixture() throws -> (URL, [String]) {
        let repo = harness.tmpDir.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ args: String...) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = repo
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try p.run()
            let out = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "git \(args.joined(separator: " "))")
            return String(data: out, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        _ = try git("init", "-q", "-b", "main")
        _ = try git("config", "user.email", "t@t")
        _ = try git("config", "user.name", "t")
        for (i, body) in ["one\n", "one\ntwo\n", "one\ntwo\nthree\n"].enumerated() {
            try body.write(to: repo.appendingPathComponent("f.txt"),
                           atomically: true, encoding: .utf8)
            _ = try git("add", "f.txt")
            _ = try git("commit", "-q", "-m", "c\(i + 1)")
        }
        let shas = try git("log", "--pretty=%h").split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(shas.count, 3)
        return (repo, shas)
    }

    private func gitLog(_ dump: [String: Any]) -> [String: Any] {
        (model(dump)["gitLog"] as? [String: Any]) ?? [:]
    }

    func test_TSK522_cmdClickMultiSelect_thenCumulativeDiff() throws {
        let (repo, shas) = try makeRepoFixture()
        let script = """
        show-git-panel
        delay 2.5
        git-log-cmd-click \(shas[0])
        git-log-cmd-click \(shas[2])
        git-log-cumulative-diff
        delay 1.0
        """
        try runScenarios([
            Scenario(
                name: "git-log-multiselect-cumulative",
                argFile: repo,
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    let git = gitLog(last)
                    XCTAssertEqual(
                        (git["selectedLogSHAs"] as? [String])?.sorted(),
                        [shas[0], shas[2]].sorted(),
                        "REAL cmd-click closures must build the multi-selection; "
                        + "gitLog=\(git)", file: file, line: line)
                    let current = (model(last)["currentURL"] as? String) ?? ""
                    XCTAssertTrue(current.hasSuffix(".diff"),
                        "cumulative diff must open a .diff tab; currentURL=\(current)",
                        file: file, line: line)
                    XCTAssertTrue(current.contains(".."),
                        "the cumulative tab is the base..tip net diff; \(current)",
                        file: file, line: line)
                })
        ])
    }

    func test_TSK523_plainClick_opensCommitDiffTab() throws {
        let (repo, shas) = try makeRepoFixture()
        let script = """
        show-git-panel
        delay 2.5
        git-log-click \(shas[0])
        delay 1.0
        """
        try runScenarios([
            Scenario(
                name: "git-log-click-commit-diff",
                argFile: repo,
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    let git = gitLog(last)
                    XCTAssertEqual(git["selectedLogSHA"] as? String, shas[0],
                        "REAL click closure must select the row; gitLog=\(git)",
                        file: file, line: line)
                    let current = (model(last)["currentURL"] as? String) ?? ""
                    XCTAssertTrue(current.hasSuffix("\(shas[0]).diff"),
                        "the commit's structured diff tab must be OPEN and "
                        + "selected; currentURL=\(current)", file: file, line: line)
                })
        ])
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
