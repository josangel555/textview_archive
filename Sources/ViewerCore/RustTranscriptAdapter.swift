import Foundation
import RustCore

/// Routes Claude-transcript EVENT PROJECTION through the Rust core
/// (TSK-647; engine port TSK-632) when the `.transcript` gate is on,
/// falling back to the Swift `ClaudeLogParser` otherwise.
///
/// Scope: the projection consumers (timeline section, transcript search,
/// monitor detail). `ClaudeSessionIndex` deliberately stays Swift — it
/// streams per-line record CLASSIFICATION (`recordCwd` / `titleRecord` /
/// `userPromptText`), a different surface that migrates with the
/// transcript.list family (TSK-658).
///
/// Documented divergence (recorded on the ticket): a record with neither
/// `uuid` nor `id` gets a deterministic `line-<n>` id from the core vs the
/// Swift parser's random UUID — consumers only require Identifiable
/// stability, which the core's ids provide *better*.
public enum RustTranscriptAdapter {

    /// `ClaudeLogParser.parse` / `parseRedacted` routed per the gate.
    /// Non-UTF-8 data can't cross the String-typed wire — it falls back to
    /// the Swift parser (whose per-line JSONSerialization tolerates it).
    public static func parse(
        _ data: Data,
        redacting: Bool,
        maxEvents: Int? = nil
    ) -> [ClaudeEvent] {
        outcome(data, redacting: redacting, maxEvents: maxEvents).value
    }

    /// Same, but also reporting which engine produced the result.
    public static func outcome(
        _ data: Data,
        redacting: Bool,
        maxEvents: Int? = nil,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CoreOutcome<[ClaudeEvent]> {
        let swiftParser = maxEvents.map { ClaudeLogParser(maxEvents: $0) } ?? ClaudeLogParser()
        return RustCoreFallback.run(
            .transcript, defaults: defaults, environment: environment,
            rust: {
                guard let text = String(data: data, encoding: .utf8) else {
                    throw CoreError.badUTF8
                }
                return try mdvCoreTranscriptParse(
                    text: text, redacting: redacting, maxEvents: maxEvents
                ).map(Self.clientEvent)
            },
            swift: {
                redacting ? swiftParser.parseRedacted(data) : swiftParser.parse(data)
            }
        )
    }

    /// `ClaudeLogParser.redactedEvents(from:)` routed per the gate — same
    /// file-error contract (`.fileNotFound` / `.unreadable`), redaction
    /// ALWAYS on (this is the surfacing-consumer entry point).
    public static func redactedEvents(from url: URL) throws -> [ClaudeEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ClaudeLogError.fileNotFound
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw ClaudeLogError.unreadable }
        return parse(data, redacting: true)
    }

    private static func clientEvent(_ e: CoreTranscriptEvent) -> ClaudeEvent {
        let timestamp = e.timestampMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        let kind: ClaudeEvent.Kind
        switch e.kind {
        case .userMessage(let text):
            kind = .userMessage(text: text)
        case .assistantMessage(let text):
            kind = .assistantMessage(text: text)
        case .thinking(let text):
            kind = .thinking(text: text)
        case .toolUse(let id, let name, let input):
            kind = .toolUse(id: id, name: name, input: input)
        case .toolResult(let toolUseId, let summary):
            kind = .toolResult(toolUseId: toolUseId, summary: summary)
        }
        return ClaudeEvent(id: e.id, timestamp: timestamp, kind: kind)
    }
}
