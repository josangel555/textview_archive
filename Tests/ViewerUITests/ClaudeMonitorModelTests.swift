import XCTest
import ViewerCore
@testable import ViewerUI

/// Headless coverage for the Claude monitor PoC (`--claude-monitor`). The view
/// shipped untested; this validates the monitor-specific glue — the
/// read→redact→parse transcript pipeline (`loadRedactedEvents`), the event cap,
/// and the master-pane filter/sort (`filteredSessions` via `loadSessions`).
/// Host-safe: no window is created (only the model + its `nonisolated static`
/// loader and a fixture `~/.claude`-shaped temp tree).
///
/// Redaction itself is a separately-tested ViewerCore primitive
/// (`ClaudeLogParser.redact`); the monitor only composes it in front of the
/// parser, which is what these tests exercise.
final class ClaudeMonitorModelTests: XCTestCase {

    // MARK: Fixtures

    /// Make a unique temp dir (per-user `/var/folders`, never ~/Documents).
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CMMTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write `lines` as a `.jsonl` file and return its URL.
    private func writeJSONL(_ lines: [String], to dir: URL, stem: String) throws -> URL {
        let url = dir.appendingPathComponent("\(stem).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Create `<root>/projects/<name>/` and return it.
    private func makeProjectDir(in root: URL, name: String) throws -> URL {
        let dir = root
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    override func tearDown() {
        super.tearDown()
    }

    // MARK: loadRedactedEvents — the transcript read→parse pipeline

    func test_loadRedactedEvents_readsAndParsesTranscript() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lines = [
            #"{"type":"user","uuid":"u1","timestamp":"2026-06-04T10:00:00Z","message":{"role":"user","content":"hello world"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"hi there"}]}}"#,
            #"{"type":"assistant","uuid":"a2","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"ls"}}]}}"#,
        ]
        let url = try writeJSONL(lines, to: dir, stem: "s")

        let (events, truncated) = ClaudeMonitorModel.loadRedactedEvents(url: url, cap: 20_000)
        XCTAssertFalse(truncated)
        XCTAssertEqual(events.count, 3)

        guard case .userMessage(let t0) = events[0].kind else {
            return XCTFail("expected userMessage, got \(events[0].kind)")
        }
        XCTAssertEqual(t0, "hello world")
        guard case .assistantMessage(let t1) = events[1].kind else {
            return XCTFail("expected assistantMessage, got \(events[1].kind)")
        }
        XCTAssertEqual(t1, "hi there")
        guard case .toolUse(_, let name, let input) = events[2].kind else {
            return XCTFail("expected toolUse, got \(events[2].kind)")
        }
        XCTAssertEqual(name, "Bash")
        XCTAssertEqual(input["command"], "ls")
    }

    func test_loadRedactedEvents_capTruncates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let line = #"{"type":"user","uuid":"u","message":{"role":"user","content":"x"}}"#
        let url = try writeJSONL(Array(repeating: line, count: 5), to: dir, stem: "many")

        let (events, truncated) = ClaudeMonitorModel.loadRedactedEvents(url: url, cap: 3)
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(truncated, "parsed.count (3) >= cap (3) ⇒ truncated")
    }

    func test_loadRedactedEvents_missingFileIsEmpty() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("__cmm_nope_\(UUID().uuidString).jsonl")
        let (events, truncated) = ClaudeMonitorModel.loadRedactedEvents(url: url, cap: 100)
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(truncated)
    }

    // MARK: filteredSessions — master-pane filter + recency sort

    @MainActor
    func test_loadSessions_filtersAndSortsByRecency() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // Two sessions in distinct project dirs with different last timestamps.
        let older = try makeProjectDir(in: root, name: "alpha-proj")
        _ = try writeJSONL([
            #"{"type":"user","uuid":"u1","timestamp":"2026-06-04T10:00:00Z","message":{"role":"user","content":"older session"}}"#,
        ], to: older, stem: "aaaa")
        let newer = try makeProjectDir(in: root, name: "beta-proj")
        _ = try writeJSONL([
            #"{"type":"user","uuid":"u2","timestamp":"2026-06-04T11:30:00Z","message":{"role":"user","content":"newer session"}}"#,
        ], to: newer, stem: "bbbb")

        let model = ClaudeMonitorModel(root: root)
        model.loadSessions()

        // loadSessions scans off-main and republishes; poll until settled.
        let exp = expectation(description: "sessions loaded")
        func poll() {
            if !model.isLoadingSessions && model.sessions.count == 2 {
                exp.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
            }
        }
        poll()
        wait(for: [exp], timeout: 5)

        // Sorted most-recent-first: beta (11:30) before alpha (10:00).
        let order = model.filteredSessions.map(\.projectDirName)
        XCTAssertEqual(order, ["beta-proj", "alpha-proj"])

        // Filter by projectDirName needle.
        model.searchText = "alpha"
        XCTAssertEqual(model.filteredSessions.map(\.projectDirName), ["alpha-proj"])

        // Empty needle restores both.
        model.searchText = "   "
        XCTAssertEqual(model.filteredSessions.count, 2)
    }

    // MARK: runContentSearch — full-text transcript search across sessions

    @MainActor
    private func waitForContentSearch(_ model: ClaudeMonitorModel) {
        let exp = expectation(description: "content search settled")
        func poll() {
            if !model.isContentSearching {
                exp.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
            }
        }
        poll()
        wait(for: [exp], timeout: 5)
    }

    @MainActor
    func test_runContentSearch_findsSnippetInTranscript() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let proj = try makeProjectDir(in: root, name: "search-proj")
        _ = try writeJSONL([
            #"{"type":"user","uuid":"u1","timestamp":"2026-06-04T10:00:00Z","message":{"role":"user","content":"the quick brown fox jumps"}}"#,
            #"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"a lazy dog reply"}]}}"#,
        ], to: proj, stem: "trans")

        let model = ClaudeMonitorModel(root: root)
        model.contentQuery = "quick"
        model.runContentSearch()
        waitForContentSearch(model)

        XCTAssertEqual(model.contentMatches.count, 1, "exactly the user event contains 'quick'")
        let match = try XCTUnwrap(model.contentMatches.first)
        XCTAssertTrue(match.snippet.lowercased().contains("quick"), "snippet carries the hit")
        XCTAssertEqual(match.role, "user")
        XCTAssertEqual(match.eventIndex, 0)
    }

    @MainActor
    func test_runContentSearch_noMatch_isEmpty() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let proj = try makeProjectDir(in: root, name: "p")
        _ = try writeJSONL([
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"hello world"}}"#,
        ], to: proj, stem: "t")

        let model = ClaudeMonitorModel(root: root)
        model.contentQuery = "zzzznotpresent"
        model.runContentSearch()
        waitForContentSearch(model)
        XCTAssertTrue(model.contentMatches.isEmpty)
    }

    @MainActor
    func test_runContentSearch_blankQuery_clearsResults() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let proj = try makeProjectDir(in: root, name: "p")
        _ = try writeJSONL([
            #"{"type":"user","uuid":"u1","message":{"role":"user","content":"findme token"}}"#,
        ], to: proj, stem: "t")

        let model = ClaudeMonitorModel(root: root)
        model.contentQuery = "findme"
        model.runContentSearch()
        waitForContentSearch(model)
        XCTAssertFalse(model.contentMatches.isEmpty, "precondition: a hit exists")

        // A blank query synchronously clears (no async round-trip).
        model.contentQuery = "   "
        model.runContentSearch()
        XCTAssertTrue(model.contentMatches.isEmpty)
        XCTAssertFalse(model.isContentSearching)
    }
}
