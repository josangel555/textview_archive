import XCTest
import Foundation
import ViewerKit
import ViewerCore
import TestSupport
@testable import ViewerUI

/// Wiring coverage for the `git-file-history` verb that makes the shipped
/// `git.fileHistory` command Omni-invokable for the CURRENT file (it had
/// `scriptVerb: nil`, so File History was menu/⌥⇧⌘H-only). Opening history
/// for a tracked file appends a hosted-view tab; off-repo it's a no-op.
@MainActor
final class GitFileHistoryVerbTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!
    private var repo: URL!

    override func setUp() async throws {
        try await super.setUp()
        harness = HeadlessHarness(label: "GitFileHistoryVerbTests")
    }

    override func tearDown() async throws {
        if let repo { try? FileManager.default.removeItem(at: repo) }
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = dir
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// A fresh git repo with one committed file; returns that file's URL.
    private func makeRepoWithCommittedFile() throws -> URL {
        repo = try GitTestRepo.makeRepo(prefix: "GitFileHistoryVerbTests")
        let file = repo.appendingPathComponent("tracked.txt")
        try "v1\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "tracked.txt"], in: repo)
        try git(["commit", "-q", "-m", "init"], in: repo)
        return file
    }

    func test_gitFileHistoryVerb_opensHostedHistoryTabForTrackedFile() throws {
        let file = try makeRepoWithCommittedFile()
        let model = harness.model
        model.open(url: file)
        let before = model.tabs.tabs.count

        XCTAssertTrue(ScriptVerb.apply(verb: "git-file-history", to: model, sessions: harness.sessions))
        XCTAssertEqual(model.tabs.tabs.count, before + 1,
                       "history of a tracked file must open a new hosted-view tab")
        guard case .hostedView(_, let title) = model.tabs.tabs.last?.state else {
            return XCTFail("the new tab must be a hosted view")
        }
        XCTAssertTrue(title.contains("History"), "hosted tab title: \(title)")
    }

    func test_gitFileHistoryVerb_offRepo_isNoOp() throws {
        let url = try harness.writeFile("loose.txt", "not in a repo")
        let model = harness.model
        model.open(url: url)
        let before = model.tabs.tabs.count
        XCTAssertTrue(ScriptVerb.apply(verb: "git-file-history", to: model, sessions: harness.sessions))
        XCTAssertEqual(model.tabs.tabs.count, before,
                       "off-repo file history must be a graceful no-op")
    }

    func test_gitFileHistory_isPaletteInvokable() {
        let cmd = CommandRegistry.builtIn.command(id: "git.fileHistory")
        XCTAssertEqual(cmd?.scriptVerb, "git-file-history")
        XCTAssertTrue(CommandRegistry.builtIn.paletteInvokable.contains { $0.id == "git.fileHistory" })
    }
}
