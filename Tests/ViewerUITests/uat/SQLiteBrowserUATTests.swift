import XCTest
import Foundation
import ViewerCore

/// UAT (usability audit 2026-07-02, TSK-1411): the SQLite browser is a real,
/// polished feature (3-pane schema/query/results, off-main query + cancel,
/// error/empty/loading states, row cap) with a host-tested engine
/// (SQLiteReader) — but it had NO real-app UI-drive coverage. This is the
/// on-screen confirmation the host engine tests can't give: open a REAL,
/// enumerable `.sqlite` in the assembled app and prove the FULL live path
/// (FileTypeDetector routing → native-preview mount → SQLite browser) fires
/// without erroring on the real running app.
///
/// TIER-JUSTIFY: T4 — the observable is the assembled bundle's real open →
/// route → mount path via `--script`; self-skips off the VM GUI lane.
/// (Internal browser render — table list / results grid PIXELS — is the
/// TSK-1334-gated tail; this confirms the routing + mount + no-error behavior,
/// which is the load-bearing "does it open for the user".)
@MainActor
final class SQLiteBrowserUATTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "SQLiteBrowserUAT" }

    private func modelString(_ dump: [String: Any], _ key: String) -> String {
        (dump["model"] as? [String: Any])?[key] as? String ?? ""
    }

    /// SQL-UAT-01 — open a real enumerable `.sqlite`; the app routes it to the
    /// native SQLite browser and mounts as a PREVIEW tab WITHOUT an error state
    /// (native-preview categories — sqlite/image/pdf — report currentStateKind
    /// "preview", NOT "loaded"; the browser's own guard surfaces an unenumerable
    /// DB as an "error" state, so "preview" on a valid fixture proves
    /// enumeration + mount fired live — confirmed on the real app 2026-07-02).
    func test_SQL01_realDbOpensAndMountsWithoutError() throws {
        let db = try UATSQLiteFixture.write("demo.sqlite", in: harness.tmpDir)
        let script = """
        delay
        delay
        delay
        """
        try runScenarios([
            Scenario(
                name: "sqlite-opens-and-mounts",
                argFile: db,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty, "[sql01] no dumps — app may not have launched",
                                   file: file, line: line)
                    let dbDumps = dumps.filter { modelString($0, "currentURL").hasSuffix("demo.sqlite") }
                    XCTAssertFalse(dbDumps.isEmpty,
                        "[sql01] demo.sqlite never committed currentURL (open/route didn't land)",
                        file: file, line: line)
                    guard let last = dbDumps.last else { return }
                    XCTAssertNotEqual(modelString(last, "currentStateKind"), "error",
                        "[sql01] the .sqlite mounted in an ERROR state — routing or enumeration failed live",
                        file: file, line: line)
                    XCTAssertEqual(modelString(last, "currentStateKind"), "preview",
                        "[sql01] expected a native-preview tab (SQLite browser) for the valid DB; got "
                        + "\(modelString(last, "currentStateKind"))",
                        file: file, line: line)
                })
        ])
    }
}
