import XCTest
@testable import ViewerCore

/// Pure-logic coverage of `LSPProblemsViewModel` — the unified roll-up
/// over (a) real diagnostics and (b) per-server health. All inputs are
/// plain values (`[(URL,[LSPDiagnostic])]` + `[LSPPool.StatusSnapshot]`),
/// so this runs fully host-side with no pool/actor/GUI.
///
/// Pins: count roll-ups, grouped-by-file ordering, severity filtering,
/// the empty-vs-unanalyzed message distinction (UAT LSP-01), and the
/// server-health summary strings.
final class LSPProblemsViewModelTests: XCTestCase {

    // MARK: - Fixtures

    private let urlA = URL(fileURLWithPath: "/tmp/a.swift")
    private let urlB = URL(fileURLWithPath: "/tmp/b.swift")

    private func diag(line: Int, char: Int = 0,
                      severity: LSPDiagnostic.Severity = .error,
                      message: String = "msg") -> LSPDiagnostic {
        LSPDiagnostic(
            range: .init(start: .init(line: line, character: char),
                         end: .init(line: line, character: char + 4)),
            severity: severity, code: nil, source: nil, message: message)
    }

    private func key(_ lang: LSPLanguage, _ root: String) -> LSPPool.Key {
        LSPPool.Key(language: lang, workspaceRoot: URL(fileURLWithPath: root))
    }

    private func status(crashCount: Int = 0, requestCount: Int = 0,
                        lastError: String? = nil,
                        lastResponseMillis: Double? = nil) -> LSPPool.LSPServerStatus {
        var s = LSPPool.LSPServerStatus()
        s.crashCount = crashCount
        s.requestCount = requestCount
        s.lastError = lastError
        s.lastResponseMillis = lastResponseMillis
        return s
    }

    private func snapshot(_ key: LSPPool.Key, isLive: Bool, isDead: Bool,
                          status: LSPPool.LSPServerStatus) -> LSPPool.StatusSnapshot {
        LSPPool.StatusSnapshot(key: key, isLive: isLive, isDead: isDead, status: status)
    }

    // MARK: - Count roll-ups

    func test_countRollups_acrossSeverities() {
        let vm = LSPProblemsViewModel(
            diagnosticsByFile: [
                (urlA, [diag(line: 0, severity: .error),
                        diag(line: 1, severity: .warning),
                        diag(line: 2, severity: .information)]),
                (urlB, [diag(line: 0, severity: .error),
                        diag(line: 1, severity: .hint)]),
            ],
            serverStatuses: [])
        XCTAssertEqual(vm.totalCount, 5)
        XCTAssertEqual(vm.errorCount, 2)
        XCTAssertEqual(vm.warningCount, 1)
        XCTAssertEqual(vm.informationCount, 1)
        XCTAssertEqual(vm.hintCount, 1)
        XCTAssertEqual(vm.fileCount, 2)
    }

    func test_emptyDiagnosticLists_areDropped() {
        // A file with an empty list (an empty publish) must not count as
        // a "file with problems".
        let vm = LSPProblemsViewModel(
            diagnosticsByFile: [(urlA, []), (urlB, [diag(line: 0)])],
            serverStatuses: [])
        XCTAssertEqual(vm.fileCount, 1)
        XCTAssertEqual(vm.totalCount, 1)
        XCTAssertEqual(vm.fileGroups.map(\.url), [urlB])
    }

    // MARK: - Grouped-by-file ordering

    func test_fileGroups_sortedByPath_thenDiagsByPosition() {
        // urlB inserted first + lines out of order → must come out
        // url-sorted (a < b) and line-sorted within each file.
        let vm = LSPProblemsViewModel(
            diagnosticsByFile: [
                (urlB, [diag(line: 5), diag(line: 1)]),
                (urlA, [diag(line: 10, char: 2), diag(line: 10, char: 0), diag(line: 0)]),
            ],
            serverStatuses: [])
        XCTAssertEqual(vm.fileGroups.map(\.url), [urlA, urlB])
        // Within urlA: line 0, then (line 10, char 0), then (line 10, char 2).
        let aLines = vm.fileGroups[0].diagnostics.map { ($0.range.start.line, $0.range.start.character) }
        XCTAssertEqual(aLines.map(\.0), [0, 10, 10])
        XCTAssertEqual(aLines.map(\.1), [0, 0, 2])
        // allFlat preserves the same order.
        let flat = vm.allFlat
        XCTAssertEqual(flat.count, 5)
        XCTAssertEqual(flat[0].url, urlA)
        XCTAssertEqual(flat[0].diagnostic.range.start.line, 0)
        XCTAssertEqual(flat[3].url, urlB)
        XCTAssertEqual(flat[3].diagnostic.range.start.line, 1)
    }

    func test_fileGroup_perFileCounts() {
        let vm = LSPProblemsViewModel(
            diagnosticsByFile: [
                (urlA, [diag(line: 0, severity: .error),
                        diag(line: 1, severity: .warning),
                        diag(line: 2, severity: .warning)]),
            ],
            serverStatuses: [])
        XCTAssertEqual(vm.fileGroups[0].errorCount, 1)
        XCTAssertEqual(vm.fileGroups[0].warningCount, 2)
    }

    // MARK: - Severity filtering

    func test_filtered_bySeverity() {
        let vm = LSPProblemsViewModel(
            diagnosticsByFile: [
                (urlA, [diag(line: 0, severity: .error),
                        diag(line: 1, severity: .warning),
                        diag(line: 2, severity: .warning),
                        diag(line: 3, severity: .information)]),
            ],
            serverStatuses: [])
        XCTAssertEqual(vm.filtered(by: .all).count, 4)
        XCTAssertEqual(vm.filtered(by: .errors).count, 1)
        XCTAssertEqual(vm.filtered(by: .warnings).count, 2)
        XCTAssertEqual(vm.filtered(by: .severity(.information)).count, 1)
        XCTAssertEqual(vm.filtered(by: .severity(.hint)).count, 0)
    }

    // MARK: - Empty-vs-unanalyzed message selection (UAT LSP-01)

    func test_emptyState_nonEmpty() {
        let vm = LSPProblemsViewModel(
            diagnosticsByFile: [(urlA, [diag(line: 0)])], serverStatuses: [])
        XCTAssertEqual(vm.emptyState(activeFileUnanalyzed: true), .nonEmpty)
        XCTAssertEqual(vm.emptyState(activeFileUnanalyzed: false), .nonEmpty)
    }

    func test_emptyState_notAnalyzed_vs_noProblems() {
        let empty = LSPProblemsViewModel(diagnosticsByFile: [], serverStatuses: [])
        XCTAssertEqual(empty.emptyState(activeFileUnanalyzed: true), .notAnalyzed)
        XCTAssertEqual(empty.emptyState(activeFileUnanalyzed: false), .noProblems)
    }

    func test_emptyMessage_unanalyzed_doesNotClaimClean() {
        let empty = LSPProblemsViewModel(diagnosticsByFile: [], serverStatuses: [])
        XCTAssertEqual(
            empty.emptyMessage(activeFileUnanalyzed: true, hasActiveFilter: false),
            "Not analyzed. Open in Editor to see problems.")
        XCTAssertEqual(
            empty.emptyMessage(activeFileUnanalyzed: false, hasActiveFilter: false),
            "No problems detected.")
    }

    func test_emptyMessage_activeFilterWithProblems_saysNoMatch() {
        // Non-empty store + an active severity filter that matched
        // nothing → "no match", NOT "no problems / not analyzed".
        let vm = LSPProblemsViewModel(
            diagnosticsByFile: [(urlA, [diag(line: 0, severity: .error)])],
            serverStatuses: [])
        XCTAssertEqual(
            vm.emptyMessage(activeFileUnanalyzed: false, hasActiveFilter: true),
            "No problems match this filter.")
        // No active filter on a non-empty store: there's nothing empty to
        // message about, but the "detected" copy is the safe default.
        XCTAssertEqual(
            vm.emptyMessage(activeFileUnanalyzed: true, hasActiveFilter: false),
            "No problems detected.")
    }

    // MARK: - Server-health roll-up

    func test_serverHealth_perServerFields_andSorting() {
        let kSwift = key(.swift, "/ws/proj")
        let kPy = key(.python, "/ws/api")
        let vm = LSPProblemsViewModel(
            diagnosticsByFile: [],
            serverStatuses: [
                // Insert python first; expect sorted by key.description.
                snapshot(kPy, isLive: false, isDead: true,
                         status: status(crashCount: 2, requestCount: 3,
                                        lastError: "boom")),
                snapshot(kSwift, isLive: true, isDead: false,
                         status: status(crashCount: 0, requestCount: 12,
                                        lastResponseMillis: 3.0)),
            ])
        // description sort: "python@/ws/api" < "swift@/ws/proj".
        XCTAssertEqual(vm.servers.map { $0.key.language }, [.python, .swift])

        let py = vm.servers[0]
        XCTAssertEqual(py.state, .dead)
        XCTAssertEqual(py.crashCount, 2)
        XCTAssertEqual(py.lastError, "boom")

        let sw = vm.servers[1]
        XCTAssertEqual(sw.state, .live)
        XCTAssertEqual(sw.requestCount, 12)
        XCTAssertEqual(sw.lastResponseMillis, 3.0)
    }

    func test_serverHealth_startingState() {
        let k = key(.swift, "/ws")
        let vm = LSPProblemsViewModel(
            diagnosticsByFile: [],
            serverStatuses: [snapshot(k, isLive: false, isDead: false, status: status())])
        XCTAssertEqual(vm.servers[0].state, .starting)
        XCTAssertEqual(vm.servers[0].state.label, "starting")
    }

    func test_serverHealth_perServerSummaryString() {
        let kSwift = key(.swift, "/ws")
        let live = LSPProblemsViewModel(
            diagnosticsByFile: [],
            serverStatuses: [snapshot(kSwift, isLive: true, isDead: false,
                                      status: status(crashCount: 0, requestCount: 12,
                                                     lastResponseMillis: 3.0))])
        XCTAssertEqual(
            live.servers[0].summary,
            "Swift (sourcekit-lsp): live · 12 reqs · 3ms")

        let crashed = LSPProblemsViewModel(
            diagnosticsByFile: [],
            serverStatuses: [snapshot(kSwift, isLive: false, isDead: true,
                                      status: status(crashCount: 1, requestCount: 1,
                                                     lastError: "spawn failed"))])
        XCTAssertEqual(
            crashed.servers[0].summary,
            "Swift (sourcekit-lsp): dead · 1 req · 1 crash — spawn failed")
    }

    func test_fleetSummary_counts_and_emptyCase() {
        let empty = LSPProblemsViewModel(diagnosticsByFile: [], serverStatuses: [])
        XCTAssertEqual(empty.serverHealthSummary, "No language servers active.")
        XCTAssertEqual(empty.liveServerCount, 0)
        XCTAssertFalse(empty.hasUnhealthyServer)

        let kSwift = key(.swift, "/ws/a")
        let kPy = key(.python, "/ws/b")
        let vm = LSPProblemsViewModel(
            diagnosticsByFile: [],
            serverStatuses: [
                snapshot(kSwift, isLive: true, isDead: false, status: status()),
                snapshot(kPy, isLive: false, isDead: true,
                         status: status(crashCount: 1)),
            ])
        XCTAssertEqual(vm.liveServerCount, 1)
        XCTAssertEqual(vm.deadServerCount, 1)
        XCTAssertEqual(vm.totalCrashCount, 1)
        XCTAssertTrue(vm.hasUnhealthyServer)
        XCTAssertEqual(vm.serverHealthSummary, "2 servers · 1 live, 1 dead · 1 crash")
    }

    func test_fleetSummary_singularGrammar() {
        let k = key(.swift, "/ws")
        let vm = LSPProblemsViewModel(
            diagnosticsByFile: [],
            serverStatuses: [snapshot(k, isLive: true, isDead: false, status: status())])
        XCTAssertEqual(vm.serverHealthSummary, "1 server · 1 live")
        XCTAssertFalse(vm.hasUnhealthyServer)
    }

    func test_hasUnhealthyServer_liveButCrashedOnce() {
        // A server that recovered (live now) but crashed before is still
        // flagged unhealthy so the user sees the crash history.
        let k = key(.swift, "/ws")
        let vm = LSPProblemsViewModel(
            diagnosticsByFile: [],
            serverStatuses: [snapshot(k, isLive: true, isDead: false,
                                      status: status(crashCount: 1))])
        XCTAssertTrue(vm.hasUnhealthyServer)
    }

    // MARK: - Combined roll-up (both surfaces at once)

    func test_combined_diagnostics_and_serverHealth() {
        let kSwift = key(.swift, "/tmp")
        let vm = LSPProblemsViewModel(
            diagnosticsByFile: [(urlA, [diag(line: 0, severity: .error),
                                        diag(line: 1, severity: .warning)])],
            serverStatuses: [snapshot(kSwift, isLive: true, isDead: false,
                                      status: status(requestCount: 5))])
        XCTAssertEqual(vm.totalCount, 2)
        XCTAssertEqual(vm.errorCount, 1)
        XCTAssertEqual(vm.fileCount, 1)
        XCTAssertEqual(vm.servers.count, 1)
        XCTAssertEqual(vm.servers[0].state, .live)
        XCTAssertEqual(vm.emptyState(activeFileUnanalyzed: false), .nonEmpty)
    }
}
