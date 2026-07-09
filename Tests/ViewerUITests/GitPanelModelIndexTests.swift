import XCTest
import ViewerCore
import TestSupport
@testable import ViewerUI

/// TSK-1443 — GitPanelModel's index command path (stage / unstage / commit /
/// discard) pinned headless against a real temp repo: the mutation applies, the
/// outcome routes to a toast, commit clears the field, and — the load-bearing
/// one — a discard NEVER runs without passing through the confirm-gate. The
/// on-screen affordances are the VM pass; this is the model teeth.
@MainActor
final class GitPanelModelIndexTests: XCTestCase {

    private var repo: URL!

    override func setUp() async throws {
        try await super.setUp()
        repo = try GitTestRepo.makeRepo(prefix: "GitPanelModelIndexTests")
        // Seed a committed file so HEAD exists (discard/unstage exercise the
        // real-HEAD path, not just unborn).
        try "committed\n".write(to: repo.appendingPathComponent("a.txt"),
                                atomically: true, encoding: .utf8)
        try git(["add", "a.txt"]); try git(["commit", "-q", "-m", "init"])
    }

    override func tearDown() async throws {
        if let repo { try? FileManager.default.removeItem(at: repo) }
        try await super.tearDown()
    }

    private func makeModel() -> GitPanelModel {
        let m = GitPanelModel()
        m.setRepoRoot(repo)
        return m
    }

    // MARK: - stage / unstage / commit

    func test_stage_appliesToIndex() async throws {
        try "new\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let m = makeModel()
        let ok = await m.performIndexOp(.stage, path: "b.txt")
        XCTAssertTrue(ok)
        XCTAssertTrue(try git(["status", "--porcelain"]).contains("A  b.txt"))
    }

    func test_commit_success_clearsMessage_andToasts() async throws {
        try "new\n".write(to: repo.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let m = makeModel()
        _ = await m.performIndexOp(.stage, path: "b.txt")
        m.commitMessage = "add b"
        let before = ToastCenter.shared.toasts.count
        let ok = await m.performCommit(message: "add b")
        XCTAssertTrue(ok)
        XCTAssertEqual(m.commitMessage, "", "the field clears after a successful commit")
        XCTAssertTrue(try git(["log", "--oneline"]).contains("add b"))
        XCTAssertGreaterThan(ToastCenter.shared.toasts.count, before, "a success toast is posted")
        XCTAssertEqual(ToastCenter.shared.toasts.last?.kind, .success)
    }

    func test_commit_emptyMessage_refusedWithToast_noCommit() {
        let m = makeModel()
        m.commitMessage = "   "
        let before = ToastCenter.shared.toasts.count
        m.commit()  // synchronous empty-message guard
        XCTAssertGreaterThan(ToastCenter.shared.toasts.count, before)
        XCTAssertEqual(ToastCenter.shared.toasts.last?.kind, .error)
        XCTAssertEqual((try? git(["log", "--oneline"]))?.contains("HEAD") ?? false, false)
        // Only the seed commit exists.
        XCTAssertEqual(try? git(["rev-list", "--count", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines), "1")
    }

    // MARK: - discard confirm-gate (never silent data loss)

    func test_requestDiscard_opensGate_butDoesNotRevert() throws {
        try "local edit\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let m = makeModel()
        m.requestDiscard(path: "a.txt")
        XCTAssertEqual(m.pendingDiscard, "a.txt", "the confirm dialog is armed")
        // The file is NOT reverted just by requesting — that would be silent loss.
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8),
                       "local edit\n")
    }

    func test_cancelDiscard_clearsGate_noRevert() throws {
        try "local edit\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let m = makeModel()
        m.requestDiscard(path: "a.txt")
        m.cancelDiscard()
        XCTAssertNil(m.pendingDiscard)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8),
                       "local edit\n", "cancel must not revert")
    }

    func test_confirmDiscard_clearsGate() throws {
        try "local edit\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let m = makeModel()
        m.requestDiscard(path: "a.txt")
        m.confirmDiscard()
        XCTAssertNil(m.pendingDiscard, "confirming clears the gate (and dispatches the op)")
    }

    func test_performDiscard_reverts() async throws {
        try "local edit\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let m = makeModel()
        let ok = await m.performIndexOp(.discard, path: "a.txt")
        XCTAssertTrue(ok)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("a.txt"), encoding: .utf8),
                       "committed\n", "the file is back to its committed content")
    }

    @discardableResult
    private func git(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.currentDirectoryURL = repo
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
