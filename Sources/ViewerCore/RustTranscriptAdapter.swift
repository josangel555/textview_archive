import Foundation
import RustCore

/// Claude-transcript EVENT PROJECTION over the rust-core engine (port
/// TSK-632).
///
/// STAGE-B (TSK-649, 2026-07-07): the Swift twin (`ClaudeLogParser`'s
/// projection) is DELETED — rust is the only engine, routed via
/// `RustCoreFallback.runRustOnly`. Non-UTF-8 bytes are decoded LOSSILY
/// before the String-typed wire (replacement chars inside string content;
/// structurally-corrupt lines are skipped by the fuzz-hardened core parser)
/// — equivalent-or-better tolerance than the deleted per-line Swift path. A
/// bridge fault degrades to `[]` with an observable log.
///
/// Scope: the projection consumers (timeline section, transcript search,
/// monitor detail). `ClaudeSessionIndex` stays on the Swift record-
/// CLASSIFICATION statics (`ClaudeLogParser+SystemRecords`), a different
/// surface that migrates with the transcript.list family (TSK-658).
public enum RustTranscriptAdapter {

    /// Project a JSONL transcript into events (redaction per `redacting`).
    public static func parse(
        _ data: Data,
        redacting: Bool,
        maxEvents: Int? = nil
    ) -> [ClaudeEvent] {
        outcome(data, redacting: redacting, maxEvents: maxEvents).value
    }

    /// Same, but also reporting the result's provenance.
    public static func outcome(
        _ data: Data,
        redacting: Bool,
        maxEvents: Int? = nil
    ) -> CoreOutcome<[ClaudeEvent]> {
        RustCoreFallback.runRustOnly(
            .transcript,
            rust: {
                try mdvCoreTranscriptParse(
                    text: String(decoding: data, as: UTF8.self),
                    redacting: redacting,
                    maxEvents: maxEvents
                ).map(Self.clientEvent)
            },
            degraded: []
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
