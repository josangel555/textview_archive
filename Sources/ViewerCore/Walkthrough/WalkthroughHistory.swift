import Foundation

/// One recorded walkthrough run — the unit of the completion log
/// (`WALKTHROUGH.md` §8 "Completion log"). Durable but disposable: it
/// lets an agent answer "have I shown the user this before, and how far
/// did they get?" without guessing, and lets the library panel mark a
/// tour as "completed" / "in progress".
///
/// `schema` is captured at record time so the history doubles as a
/// **versioning** ledger: if a tour is re-authored under a newer schema,
/// the log shows which version the user actually saw (TSK-316's
/// "versioning" facet).
public struct WalkthroughRun: Codable, Sendable, Equatable, Identifiable {

    /// How the run ended. Distinguishing completed from exited-early is
    /// what makes "have I finished showing this" answerable.
    public enum Outcome: String, Codable, Sendable, Equatable {
        /// Reached the final step.
        case completed
        /// Closed/exited before the final step.
        case exited
    }

    /// Unique per-run id (so two runs of the same script are distinct
    /// rows). Defaults to a fresh UUID string.
    public let runID: String
    /// `WalkthroughScript.id` — correlates to the catalog entry.
    public let scriptID: String
    /// Schema the user actually ran (versioning ledger).
    public let schema: WalkthroughScript.SchemaVersion
    /// Human title at record time (denormalized so history reads don't
    /// have to re-open the script, which may since have been deleted).
    public let title: String
    public let startedAt: Date
    public let endedAt: Date
    /// Number of steps the user got through (1-based count, not index).
    public let stepsCompleted: Int
    /// Total steps in the script at run time.
    public let totalSteps: Int
    public let outcome: Outcome

    public var id: String { runID }

    /// True iff the run reached the end. Cheap helper for "have I shown
    /// this" queries.
    public var didComplete: Bool { outcome == .completed }

    public init(
        runID: String = UUID().uuidString,
        scriptID: String,
        schema: WalkthroughScript.SchemaVersion,
        title: String,
        startedAt: Date,
        endedAt: Date,
        stepsCompleted: Int,
        totalSteps: Int,
        outcome: Outcome
    ) {
        self.runID = runID
        self.scriptID = scriptID
        self.schema = schema
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.stepsCompleted = stepsCompleted
        self.totalSteps = totalSteps
        self.outcome = outcome
    }
}

/// Append-only, FIFO-capped record of completed/exited walkthrough runs
/// — the durable completion log behind TSK-316's "history".
///
/// Pure ViewerCore logic, host-testable. Persists via `JSONFileStore`
/// (same encoder/atomic-write/size-cap posture as the other stores) to a
/// single JSON array file. The design sketches JSONL; we use a JSON array
/// for parity with every other store in the codebase
/// (`GoToPathHistoryStore`, `HistoryStore`, `BookmarksStore`) and to get
/// `JSONFileStore`'s lenient-per-element decode + coalesced off-main
/// writes for free. A capped array re-encoded on each append is trivially
/// cheap at this scale (≤1000 small records).
///
/// Thread-safety: callers touch this from the main actor (the engine /
/// player is `@MainActor`); writes go through `JSONFileStore.enqueueWrite`
/// (off-main, ordered, coalesced).
public final class WalkthroughHistory {

    public let storeURL: URL
    public let maxEntries: Int
    public let maxStoreFileBytes: Int

    /// Newest-first in memory (index 0 = most recent run). Persisted in
    /// the same order.
    private var runs: [WalkthroughRun] = []

    /// - Parameters:
    ///   - maxEntries: FIFO cap (design says 1000). Oldest runs are
    ///     trimmed once this is exceeded.
    ///   - maxStoreFileBytes: hard ceiling on the persisted file before
    ///     we refuse to load it (tamper guard). 1000 records of a few
    ///     hundred bytes each is well under 1 MiB; 4 MiB is generous.
    public init(
        storeURL: URL,
        maxEntries: Int = 1000,
        maxStoreFileBytes: Int = 4 * 1024 * 1024
    ) {
        self.storeURL = storeURL
        self.maxEntries = max(1, maxEntries)
        self.maxStoreFileBytes = maxStoreFileBytes
        load()
    }

    /// Default completion-log path:
    /// `~/Library/Application Support/MarkdownViewer/walkthrough-history.json`.
    /// (The design names `walkthrough-log.jsonl`; we keep the `.json`
    /// array form for store parity — see the type docstring.)
    public static func defaultStoreURL() -> URL {
        // TSK-1288: markdownViewerDir() redirects to tmp under XCTest (real dir in prod).
        return TestStateRedirect.markdownViewerDir()
            .appendingPathComponent("walkthrough-history.json", isDirectory: false)
    }

    // MARK: - Reads

    /// All recorded runs, newest first. Read-only snapshot.
    public func allRuns() -> [WalkthroughRun] { runs }

    public var count: Int { runs.count }

    /// Runs for one script id, newest first.
    public func runs(forScriptID scriptID: String) -> [WalkthroughRun] {
        runs.filter { $0.scriptID == scriptID }
    }

    /// The most recent run of `scriptID`, or nil if the user has never
    /// run it. The primary "have I shown this before" query.
    public func mostRecentRun(ofScriptID scriptID: String) -> WalkthroughRun? {
        // `runs` is newest-first, so the first match is the most recent.
        runs.first { $0.scriptID == scriptID }
    }

    /// True iff the user has ever *completed* (reached the end of) this
    /// script. Distinct from "has ever started" — an exited run doesn't
    /// count.
    public func hasCompleted(scriptID: String) -> Bool {
        runs.contains { $0.scriptID == scriptID && $0.didComplete }
    }

    // MARK: - Mutations

    /// Append a run to the front of the log, then FIFO-trim to
    /// `maxEntries`. Persists asynchronously.
    public func record(_ run: WalkthroughRun) {
        runs.insert(run, at: 0)
        if runs.count > maxEntries {
            runs = Array(runs.prefix(maxEntries))
        }
        save()
    }

    /// Drop every recorded run (e.g. `File → Reset` / privacy clear).
    public func clear() {
        guard !runs.isEmpty else { return }
        runs.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() {
        // Lenient per-element decode: one malformed record (e.g. an
        // unknown future schema string) must not nuke the whole history.
        guard let decoded = JSONFileStore.readLenientArray(
            WalkthroughRun.self, from: storeURL, maxSize: maxStoreFileBytes
        ) else { return }
        // Cap on load too — a tampered file could carry more than the cap.
        runs = Array(decoded.prefix(maxEntries))
    }

    private func save() {
        JSONFileStore.enqueueWrite(runs, to: storeURL)
    }

    /// Block until pending writes land — for terminate-drain + tests.
    public func flush() {
        JSONFileStore.flushSync()
    }
}
