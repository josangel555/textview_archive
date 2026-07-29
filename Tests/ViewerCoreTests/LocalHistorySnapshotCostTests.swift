import XCTest
@testable import ViewerCore

/// TSK-1608 (owner 2026-07-26: "saves are choking and I'm seeing a beach ball
/// every so often when I save") — MEASURES the per-save cost of the
/// snapshot-on-save Local History write, which runs SYNCHRONOUSLY on the main
/// actor inside `EditorCoordinator.saveEditor`.
///
/// Each snapshot does, on the calling thread: enumerate the file's history
/// dir, `Data(contentsOf:)` EVERY existing `.rev` record, reconstruct the
/// newest version (diff-chain replay) for the dedup check, run a line-diff,
/// write the new record, then prune under the byte cap. That work grows with
/// history depth, which matches "every so often" — the stalls get worse the
/// longer you keep editing one file.
///
/// This is a measurement harness, not a wall-clock gate: it asserts only a
/// generous ceiling (CI machines vary) and prints the curve so the fix can be
/// compared against it.
final class LocalHistorySnapshotCostTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LHCost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A realistic source file (~80 KB) edited repeatedly, as in a real session.
    private func body(_ revision: Int) -> String {
        var s = "// revision \(revision)\n"
        for i in 0..<2000 {
            s += "let value\(i) = compute(\(i), \(revision % 7))  // line \(i)\n"
        }
        return s
    }

    func test_snapshotOnSave_costGrowsWithHistoryDepth() throws {
        let store = LocalHistoryStore(directory: dir)
        let path = "/Users/tester/project/Source.swift"
        var timings: [Double] = []

        for rev in 0..<40 {
            let text = body(rev)
            let t0 = Date()
            _ = store.snapshot(path: path, content: text, at: Date())
            timings.append(Date().timeIntervalSince(t0) * 1000)
        }

        let first5 = timings.prefix(5).reduce(0, +) / 5
        let last5 = timings.suffix(5).reduce(0, +) / 5
        let worst = timings.max() ?? 0
        print("[LH-COST] first5 avg = \(String(format: "%.1f", first5)) ms · "
              + "last5 avg = \(String(format: "%.1f", last5)) ms · "
              + "worst = \(String(format: "%.1f", worst)) ms")
        print("[LH-COST] per-save ms: "
              + timings.map { String(format: "%.0f", $0) }.joined(separator: ","))

        // A single ⌘S must never approach the beachball threshold (~250 ms of
        // blocked main thread is where the spinner shows).
        XCTAssertLessThan(worst, 2000,
            "a single snapshot-on-save took \(String(format: "%.0f", worst)) ms — "
            + "this runs on the MAIN actor during ⌘S")
    }

    /// TSK-1608 THE FIX: the save path now calls `snapshotInBackground`, which
    /// must return to the caller essentially instantly (the ~220 ms of record
    /// reading / diffing / pruning happens on a serial utility queue). This is
    /// the regression guard for "⌘S beach-balls".
    func test_backgroundSnapshot_returnsImmediatelyToTheCaller() throws {
        let store = LocalHistoryStore(directory: dir)
        let path = "/Users/tester/project/Async.swift"
        // Seed history so the synchronous cost would be at its worst.
        for rev in 0..<20 { _ = store.snapshot(path: path, content: body(rev), at: Date()) }

        var callerMs: [Double] = []
        for rev in 100..<110 {
            let text = body(rev)
            let t0 = Date()
            store.snapshotInBackground(path: path, content: text, at: Date())
            callerMs.append(Date().timeIntervalSince(t0) * 1000)
        }
        LocalHistoryStore.drainBackgroundSnapshots()

        let worst = callerMs.max() ?? 0
        print("[LH-COST] background enqueue worst = \(String(format: "%.2f", worst)) ms")
        XCTAssertLessThan(worst, 20,
            "the SAVE path must not block on snapshotting — enqueue took "
            + "\(String(format: "%.1f", worst)) ms (was ~220 ms synchronous)")

        // And the work must still actually happen.
        let versions = store.versions(for: path)
        XCTAssertGreaterThan(versions.count, 20,
            "background snapshots must still land in the history store")
    }

    /// Isolates the read half: how long the pre-write bookkeeping takes once a
    /// file has accumulated history (this is the part that scales).
    func test_snapshotCost_onDeepHistory() throws {
        let store = LocalHistoryStore(directory: dir)
        let path = "/Users/tester/project/Deep.swift"
        for rev in 0..<60 { _ = store.snapshot(path: path, content: body(rev), at: Date()) }

        let t0 = Date()
        _ = store.snapshot(path: path, content: body(999), at: Date())
        let ms = Date().timeIntervalSince(t0) * 1000
        print("[LH-COST] snapshot #61 on deep history = \(String(format: "%.1f", ms)) ms")
        XCTAssertLessThan(ms, 2000, "deep-history snapshot cost: \(ms) ms")
    }
}
