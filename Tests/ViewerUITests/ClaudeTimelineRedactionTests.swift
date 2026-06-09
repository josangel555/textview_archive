import XCTest
import ViewerCore
@testable import ViewerUI

/// SECURITY teeth for TSK-178 — the sidebar Claude timeline must surface only
/// REDACTED transcript content. `ClaudeTimelineSection` renders `event.summary`
/// directly (rows + `.help` tooltips), so its event loader MUST read through
/// the redaction barrier (`ClaudeLogParser.redactedEvents`), never the
/// non-redacting `events`.
///
/// The barrier was previously buried inline in a `Task.detached` closure with
/// no testable seam — reverting it to `.events` would have failed NO test. This
/// pins the extracted `ClaudeTimelineSection.timelineEvents` kernel: a secret
/// carried in a redacted tool-input key (`headers`) must NOT survive into any
/// rendered `event.summary`. TEETH: swapping the kernel back to
/// `parser.events(from:)` makes the first assertion fail (the raw secret leaks
/// into the tool-call summary).
///
/// Tier: window-free (a pure static kernel over a temp transcript) — host-safe.
final class ClaudeTimelineRedactionTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeTimelineRedaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeTranscript(_ records: [String]) throws -> URL {
        let url = dir.appendingPathComponent("session.jsonl")
        try (records.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: url)
        return url
    }

    /// A tool_use whose ONLY input key is the redacted `headers` secret — so the
    /// event's `summary` (which surfaces `input.values.first` when there's no
    /// file_path/path/command) deterministically carries the redacted value.
    func test_timelineEvents_redactSecretBeforeSurfacing() throws {
        let secret = "SECRETTOKEN123"
        let toolWithSecret = #"{"type":"assistant","uuid":"a","timestamp":"2026-06-04T07:01:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"WebFetch","input":{"headers":"\#(secret)"}}]}}"#
        let url = try writeTranscript([toolWithSecret])

        let events = ClaudeTimelineSection.timelineEvents(from: url)
        XCTAssertFalse(events.isEmpty, "the tool_use event must parse")

        let surfaced = events.map(\.summary).joined(separator: "\n")
        // TEETH: with the non-redacting `.events` path this contains the raw secret.
        XCTAssertFalse(surfaced.contains(secret),
                       "a redacted-key secret must NEVER surface in a timeline summary: \(surfaced)")
        XCTAssertTrue(surfaced.contains("[REDACTED]"),
                      "the redacted token should flow through to the summary: \(surfaced)")
    }

    /// Benign content still surfaces (redaction is targeted, not blanket): a
    /// plain user message is shown verbatim.
    func test_timelineEvents_benignContentStillSurfaces() throws {
        let msg = #"{"type":"user","uuid":"u","timestamp":"2026-06-04T07:00:00Z","message":{"role":"user","content":"please refactor the sidebar widget"}}"#
        let url = try writeTranscript([msg])
        let events = ClaudeTimelineSection.timelineEvents(from: url)
        XCTAssertTrue(events.map(\.summary).joined().contains("refactor"),
                      "benign user-message text must still be surfaced")
    }

    /// The cap + reverse-chrono ordering the kernel applies (most-recent-first,
    /// bounded) — pins the rest of the loader contract.
    func test_timelineEvents_reverseChronoAndCap() throws {
        let records = (1...250).map { i in
            #"{"type":"user","uuid":"u\#(i)","timestamp":"2026-06-04T07:00:00Z","message":{"role":"user","content":"msg \#(i)"}}"#
        }
        let url = try writeTranscript(records)
        let events = ClaudeTimelineSection.timelineEvents(from: url, cap: 200)
        XCTAssertEqual(events.count, 200, "events are capped")
        // Reversed: the highest-numbered (last-in-file) message is first.
        XCTAssertTrue(events.first!.summary.contains("msg 250"),
                      "most-recent-first ordering: \(events.first!.summary)")
    }
}
