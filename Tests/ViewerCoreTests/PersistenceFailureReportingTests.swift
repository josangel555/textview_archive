import Foundation
import Testing
@testable import ViewerCore

/// Audit THEME 1: persistence failures were silent end-to-end — every caller
/// discards `JSONFileStore.write`'s Bool, so a full disk at quit lost sessions
/// and edits with no signal. The fix is a single hook at the choke point plus a
/// coalescing reporter; these pin both halves.
@Suite("Persistence failures are reported, not swallowed")
struct PersistenceFailureReportingTests {

    // MARK: the reporter (rate limiting)

    private let url = URL(fileURLWithPath: "/tmp/sessions-index.json")
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("the first failure reports immediately")
    func firstReportsImmediately() {
        let r = PersistenceFailureReporter(window: 60)
        let report = r.record(url: url, at: t0)
        #expect(report?.count == 1)
        #expect(report?.message.contains("sessions-index.json") == true,
                "the message names the file that failed")
    }

    /// A full disk fails EVERY write — the storm must coalesce, then surface
    /// as a count.
    @Test("failures inside the window coalesce into the next report")
    func windowCoalesces() {
        let r = PersistenceFailureReporter(window: 60)
        #expect(r.record(url: url, at: t0) != nil)
        // 30 more failures in the same minute: all silent.
        for i in 1...30 {
            #expect(r.record(url: url, at: t0.addingTimeInterval(Double(i))) == nil)
        }
        // Window elapsed: the next failure reports and folds in the backlog.
        let report = r.record(url: url, at: t0.addingTimeInterval(61))
        #expect(report?.count == 31)
        #expect(report?.message.contains("30 other") == true)
    }

    @Test("a failure after a quiet stretch reports fresh, count 1")
    func quietStretchResets() {
        let r = PersistenceFailureReporter(window: 60)
        _ = r.record(url: url, at: t0)
        #expect(r.record(url: url, at: t0.addingTimeInterval(300))?.count == 1)
    }

    // MARK: the hook (choke-point wiring)

    /// An unwritable destination must fire the hook; a good write must not.
    @Test("JSONFileStore.write fires onWriteFailure exactly on failure")
    func hookFiresOnFailure() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistFail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            JSONFileStore.onWriteFailure = nil
            try? FileManager.default.removeItem(at: dir)
        }

        nonisolated(unsafe) var failed: [URL] = []
        JSONFileStore.onWriteFailure = { failed.append($0) }

        // Success → no report.
        #expect(JSONFileStore.write(["ok"], to: dir.appendingPathComponent("good.json")))
        #expect(failed.isEmpty)

        // A directory sitting where the FILE should go makes the rename fail.
        let blocked = dir.appendingPathComponent("blocked.json")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        #expect(JSONFileStore.write(["x"], to: blocked) == false)
        #expect(failed == [blocked], "the failing URL reaches the hook")
    }

    /// The app must actually install the hook — an unwired hook is the old
    /// silence with extra steps.
    @Test("the launch path installs the failure hook")
    func launchInstallsTheHook() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let main = try String(
            contentsOf: root.appendingPathComponent("Sources/MarkdownViewer/main.swift"),
            encoding: .utf8)
        #expect(main.contains("JSONFileStore.onWriteFailure = {"))
        #expect(main.contains("PersistenceFailureReporter("))
    }
}
