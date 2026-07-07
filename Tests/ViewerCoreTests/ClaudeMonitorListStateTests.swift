import XCTest
@testable import ViewerCore

/// TSK-1477 — the monitor's empty-state classification + refresh fingerprint,
/// on real fixture dirs (the ticket's validate bar).
final class ClaudeMonitorListStateTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-monitor-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeProjects() throws -> URL {
        let projects = root.appendingPathComponent("projects/-Users-x-proj")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        return projects
    }

    // MARK: - empty classification

    func test_missingRoot_classifiesRootMissing() {
        let state = ClaudeMonitorListState.classify(root: root, transcriptCount: 0)
        XCTAssertEqual(state, .empty(.rootMissing(path: root.path)))
    }

    func test_rootWithoutProjectsDir_classifiesNotAClaudeDir() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = ClaudeMonitorListState.classify(root: root, transcriptCount: 0)
        XCTAssertEqual(state, .empty(.notAClaudeDir(path: root.path)))
    }

    func test_projectsButNoTranscripts_classifiesNoTranscripts() throws {
        _ = try makeProjects()
        let state = ClaudeMonitorListState.classify(root: root, transcriptCount: 0)
        XCTAssertEqual(state, .empty(.noTranscripts(path: root.path)))
    }

    func test_withTranscripts_classifiesSessions_withoutStatting() {
        // transcriptCount > 0 short-circuits (no fs probes needed) — even a
        // nonexistent root reports sessions when the index found some.
        let state = ClaudeMonitorListState.classify(root: root, transcriptCount: 3)
        XCTAssertEqual(state, .sessions(count: 3))
    }

    // MARK: - refresh fingerprint (end-to-end with the real index scan)

    func test_fingerprint_changesOnAdd_append_remove_stableOtherwise() throws {
        let projects = try makeProjects()
        let index = ClaudeSessionIndex()

        let f0 = ClaudeMonitorListState.fingerprint(of: index.transcriptURLs(root: root))
        XCTAssertEqual(f0.fileCount, 0)

        // ADD a transcript → fingerprint moves.
        let t1 = projects.appendingPathComponent("s1.jsonl")
        try #"{"type":"user"}"#.write(to: t1, atomically: true, encoding: .utf8)
        let f1 = ClaudeMonitorListState.fingerprint(of: index.transcriptURLs(root: root))
        XCTAssertTrue(ClaudeMonitorListState.needsRescan(previous: f0, current: f1))
        XCTAssertEqual(f1.fileCount, 1)

        // UNTOUCHED → stable (the no-op-poll guard).
        let f1again = ClaudeMonitorListState.fingerprint(of: index.transcriptURLs(root: root))
        XCTAssertFalse(ClaudeMonitorListState.needsRescan(previous: f1, current: f1again),
                       "an idle poll tick must not trigger a rescan")

        // APPEND (a live session writing) → size moves even if mtime
        // granularity hides the touch.
        let handle = try FileHandle(forWritingTo: t1)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"assistant"}"#.utf8))
        try handle.close()
        let f2 = ClaudeMonitorListState.fingerprint(of: index.transcriptURLs(root: root))
        XCTAssertTrue(ClaudeMonitorListState.needsRescan(previous: f1again, current: f2),
                      "an append must be detected (totalBytes moved)")

        // REMOVE → count moves.
        try FileManager.default.removeItem(at: t1)
        let f3 = ClaudeMonitorListState.fingerprint(of: index.transcriptURLs(root: root))
        XCTAssertTrue(ClaudeMonitorListState.needsRescan(previous: f2, current: f3))
        XCTAssertEqual(f3.fileCount, 0)
    }

    func test_firstTick_alwaysRescans() {
        let f = ClaudeMonitorListState.Fingerprint(
            fileCount: 0, newestModification: nil, totalBytes: 0)
        XCTAssertTrue(ClaudeMonitorListState.needsRescan(previous: nil, current: f),
                      "no previous fingerprint → scan")
    }
}
