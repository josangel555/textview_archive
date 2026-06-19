import XCTest
@testable import ViewerCore

/// `WalkthroughHistory` is the durable completion log behind TSK-316's
/// "history" facet — the "have I shown the user this before" ledger.
/// These tests pin record/query/cap/persist behavior.
final class WalkthroughHistoryTests: XCTestCase {

    private var storeURL: URL!

    override func setUpWithError() throws {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-history-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeURL)
    }

    private func run(
        scriptID: String,
        title: String = "T",
        schema: WalkthroughScript.SchemaVersion = .v1,
        steps: Int = 5,
        completed: Int = 5,
        outcome: WalkthroughRun.Outcome = .completed,
        started: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> WalkthroughRun {
        WalkthroughRun(
            scriptID: scriptID,
            schema: schema,
            title: title,
            startedAt: started,
            endedAt: started.addingTimeInterval(60),
            stepsCompleted: completed,
            totalSteps: steps,
            outcome: outcome
        )
    }

    // MARK: - Record + order

    func test_record_newestFirst() {
        let h = WalkthroughHistory(storeURL: storeURL)
        h.record(run(scriptID: "a", title: "First"))
        h.record(run(scriptID: "b", title: "Second"))
        XCTAssertEqual(h.allRuns().map(\.title), ["Second", "First"])
        XCTAssertEqual(h.count, 2)
    }

    func test_runsForScriptID_filters() {
        let h = WalkthroughHistory(storeURL: storeURL)
        h.record(run(scriptID: "a", title: "a1"))
        h.record(run(scriptID: "b", title: "b1"))
        h.record(run(scriptID: "a", title: "a2"))
        XCTAssertEqual(h.runs(forScriptID: "a").map(\.title), ["a2", "a1"])
        XCTAssertEqual(h.runs(forScriptID: "missing"), [])
    }

    func test_mostRecentRun_returnsNewest() {
        let h = WalkthroughHistory(storeURL: storeURL)
        h.record(run(scriptID: "a", title: "old"))
        h.record(run(scriptID: "a", title: "new"))
        XCTAssertEqual(h.mostRecentRun(ofScriptID: "a")?.title, "new")
        XCTAssertNil(h.mostRecentRun(ofScriptID: "never"))
    }

    // MARK: - "Have I shown this" semantics

    func test_hasCompleted_onlyCountsCompletedOutcome() {
        let h = WalkthroughHistory(storeURL: storeURL)
        h.record(run(scriptID: "a", completed: 2, outcome: .exited))
        XCTAssertFalse(h.hasCompleted(scriptID: "a"),
                       "An exited-early run must not count as completed")
        h.record(run(scriptID: "a", outcome: .completed))
        XCTAssertTrue(h.hasCompleted(scriptID: "a"))
    }

    func test_run_didCompleteHelper() {
        XCTAssertTrue(run(scriptID: "a", outcome: .completed).didComplete)
        XCTAssertFalse(run(scriptID: "a", outcome: .exited).didComplete)
    }

    // MARK: - Versioning ledger

    func test_record_capturesSchemaForVersioningLedger() {
        let h = WalkthroughHistory(storeURL: storeURL)
        h.record(run(scriptID: "tour", title: "old version", schema: .v1))
        h.record(run(scriptID: "tour", title: "new version", schema: .v2))
        // The history shows which schema the user actually ran each time.
        let runs = h.runs(forScriptID: "tour")
        XCTAssertEqual(runs.map(\.schema), [.v2, .v1])
    }

    // MARK: - FIFO cap

    func test_record_fifoTrimToMaxEntries() {
        let h = WalkthroughHistory(storeURL: storeURL, maxEntries: 3)
        for i in 0..<5 { h.record(run(scriptID: "s\(i)", title: "t\(i)")) }
        XCTAssertEqual(h.count, 3)
        // Newest-first, oldest trimmed → t4, t3, t2 survive; t0/t1 gone.
        XCTAssertEqual(h.allRuns().map(\.title), ["t4", "t3", "t2"])
    }

    // MARK: - Clear

    func test_clear_emptiesLog() {
        let h = WalkthroughHistory(storeURL: storeURL)
        h.record(run(scriptID: "a"))
        h.clear()
        XCTAssertEqual(h.count, 0)
        XCTAssertEqual(h.allRuns(), [])
    }

    // MARK: - Persistence round-trip

    func test_persistence_roundTrip() {
        do {
            let h = WalkthroughHistory(storeURL: storeURL)
            h.record(run(scriptID: "a", title: "kept", schema: .v2,
                         steps: 7, completed: 7, outcome: .completed))
            h.flush()
        }
        // Reopen with a fresh store → same record survives.
        let reopened = WalkthroughHistory(storeURL: storeURL)
        XCTAssertEqual(reopened.count, 1)
        let r = reopened.allRuns().first
        XCTAssertEqual(r?.title, "kept")
        XCTAssertEqual(r?.schema, .v2)
        XCTAssertEqual(r?.totalSteps, 7)
        XCTAssertEqual(r?.outcome, .completed)
    }

    func test_load_capsAtMaxEntriesEvenIfFileHasMore() {
        // Write a file with more entries than a later, smaller cap.
        do {
            let h = WalkthroughHistory(storeURL: storeURL, maxEntries: 10)
            for i in 0..<8 { h.record(run(scriptID: "s\(i)", title: "t\(i)")) }
            h.flush()
        }
        let capped = WalkthroughHistory(storeURL: storeURL, maxEntries: 3)
        XCTAssertEqual(capped.count, 3)
    }

    func test_missingFile_startsEmpty() {
        let h = WalkthroughHistory(storeURL: storeURL)
        XCTAssertEqual(h.count, 0)
    }
}
