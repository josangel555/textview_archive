import Foundation

// Reader for the passive Claude Code hook monitor log (the second data source
// for the "agent monitoring" feature, alongside `ClaudeSessionIndex` which
// reads the transcripts themselves).
//
// The companion shell hook `scripts/hooks/monitor-log.sh` — registered by the
// owner in `~/.claude/settings.json` (see that script's header for the opt-in
// block) — appends one compact, privacy-conscious JSON-Lines record per Claude
// Code lifecycle event to `~/.claude/monitor/<session_id>.jsonl`. The envelope
// is FLAT and bounded — it deliberately does NOT persist the full hook payload
// (tool_input/tool_response/prompt can carry secrets); instead it keeps sizes
// and a short prompt preview. Each line looks like:
//
//   {"ts":"2026-06-04T07:15:09Z","host":"mac","pid":40231,"event":"PostToolUse",
//    "session_id":"abc","tool":"Edit","cwd":"/repo","prompt":null,"prompt_len":0,
//    "tool_input_bytes":81,"tool_succeeded":true, ...}
//
// This type turns those lines into typed `ClaudeMonitorEvent`s and offers a few
// pure aggregations (tool-call frequency, failures, per-turn latency) the UI
// layer renders. Foundation-only, strictly read-only (`O_RDONLY`), and bounded:
// a monitor file is one-per-session and append-only, but a chatty session can
// still grow it, so reads are capped at `maxBytes`.

// MARK: - Event model

/// One monitor-log record. Top-level fields come from the hook script's
/// envelope; the event-specific fields are best-effort extractions from the
/// embedded `raw` payload and are `nil` when not applicable to the event.
public struct ClaudeMonitorEvent: Equatable, Sendable, Identifiable {
    /// 0-based position within its source file — gives a stable identity and
    /// preserves emission order for turn pairing.
    public let sequence: Int
    public let timestamp: Date?
    public let host: String?
    public let pid: Int?
    /// `hook_event_name`, e.g. `PostToolUse`, `UserPromptSubmit`, `Stop`.
    public let event: String
    /// `tool_name` for the per-tool events; nil otherwise.
    public let tool: String?
    public let cwd: String?
    public let sessionId: String?

    // Event-specific (best-effort).
    public let prompt: String?           // UserPromptSubmit
    public let errorMessage: String?     // PostToolUseFailure
    public let reason: String?           // SessionEnd
    public let source: String?           // SessionStart
    public let notificationType: String? // Notification
    /// Serialized size of `tool_input` in bytes (so the UI can flag a huge
    /// Read/Write without us retaining the payload). nil when absent.
    public let toolInputBytes: Int?
    /// `tool_response.success` when the payload carried it; nil otherwise.
    public let toolSucceeded: Bool?

    public var id: Int { sequence }

    public init(
        sequence: Int,
        timestamp: Date?,
        host: String?,
        pid: Int?,
        event: String,
        tool: String?,
        cwd: String?,
        sessionId: String?,
        prompt: String? = nil,
        errorMessage: String? = nil,
        reason: String? = nil,
        source: String? = nil,
        notificationType: String? = nil,
        toolInputBytes: Int? = nil,
        toolSucceeded: Bool? = nil
    ) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.host = host
        self.pid = pid
        self.event = event
        self.tool = tool
        self.cwd = cwd
        self.sessionId = sessionId
        self.prompt = prompt
        self.errorMessage = errorMessage
        self.reason = reason
        self.source = source
        self.notificationType = notificationType
        self.toolInputBytes = toolInputBytes
        self.toolSucceeded = toolSucceeded
    }
}

// MARK: - Reader

public struct ClaudeMonitorLog: Sendable {

    /// Read cap per monitor file. A per-session log shouldn't approach this;
    /// the cap just bounds a pathological / runaway log.
    public let maxBytes: Int

    public init(maxBytes: Int = 16 * 1024 * 1024) {
        self.maxBytes = maxBytes
    }

    /// Default monitor directory the hook script writes to.
    public static func defaultMonitorDir() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/monitor", isDirectory: true)
    }

    // MARK: Parsing

    /// Parse a single JSONL line into an event. The writer emits a FLAT,
    /// privacy-conscious envelope (no nested `raw` payload — tool_input/response
    /// are reduced to sizes, the prompt to a 200-char preview), so every field
    /// is read from the top level. Returns `nil` for blank lines or lines that
    /// don't decode to a JSON object — a partially-written trailing line is
    /// simply skipped, not fatal.
    public func parseLine(_ line: Data, sequence: Int) -> ClaudeMonitorEvent? {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return nil }

        return ClaudeMonitorEvent(
            sequence: sequence,
            timestamp: Self.parseTimestamp(obj["ts"]),
            host: obj["host"] as? String,
            pid: (obj["pid"] as? NSNumber)?.intValue,
            event: (obj["event"] as? String) ?? "unknown",
            tool: obj["tool"] as? String,
            cwd: obj["cwd"] as? String,
            sessionId: obj["session_id"] as? String,
            prompt: obj["prompt"] as? String,
            errorMessage: obj["error"] as? String,
            reason: obj["reason"] as? String,
            source: obj["source"] as? String,
            notificationType: obj["notification_type"] as? String,
            toolInputBytes: (obj["tool_input_bytes"] as? NSNumber)?.intValue,
            toolSucceeded: obj["tool_succeeded"] as? Bool
        )
    }

    /// Read and parse one monitor file (read-only, capped at `maxBytes`).
    /// Throws `ClaudeLogError` on a missing/unreadable file.
    public func events(inFile url: URL) throws -> [ClaudeMonitorEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ClaudeLogError.fileNotFound
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw ClaudeLogError.unreadable }
        defer { try? handle.close() }

        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        return parse(data)
    }

    /// Parse a whole monitor blob (already in memory) into ordered events.
    /// Lines are split on `\n`; blank / undecodable lines are skipped but
    /// still advance the sequence so indices stay aligned with the file.
    public func parse(_ data: Data) -> [ClaudeMonitorEvent] {
        var out: [ClaudeMonitorEvent] = []
        var sequence = 0
        let newline: UInt8 = 0x0A
        var start = data.startIndex
        while start < data.endIndex {
            let nl = data[start...].firstIndex(of: newline) ?? data.endIndex
            let line = data[start..<nl]
            if let ev = parseLine(Data(line), sequence: sequence) {
                out.append(ev)
            }
            sequence += 1
            start = (nl == data.endIndex) ? data.endIndex : data.index(after: nl)
        }
        return out
    }

    /// Enumerate `<dir>/*.jsonl` and parse each into a `(key, events)` pair,
    /// where `key` is the filename stem (the session id). Unreadable files are
    /// skipped. Sorted by key for deterministic output.
    public func sessions(inDir dir: URL) -> [(key: String, events: [ClaudeMonitorEvent])] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [(String, [ClaudeMonitorEvent])] = []
        for child in children where child.pathExtension == "jsonl" {
            guard let events = try? events(inFile: child) else { continue }
            out.append((child.deletingPathExtension().lastPathComponent, events))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    // MARK: - Aggregations (pure)

    /// Tool-call counts across the given events, descending by count then tool
    /// name. Only events carrying a `tool` contribute.
    public static func toolFrequency(_ events: [ClaudeMonitorEvent]) -> [(tool: String, count: Int)] {
        var counts: [String: Int] = [:]
        for e in events { if let t = e.tool { counts[t, default: 0] += 1 } }
        return counts
            .map { (tool: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.tool < $1.tool }
    }

    /// Per-event-type counts, descending by count then name.
    public static func eventCounts(_ events: [ClaudeMonitorEvent]) -> [(event: String, count: Int)] {
        var counts: [String: Int] = [:]
        for e in events { counts[e.event, default: 0] += 1 }
        return counts
            .map { (event: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.event < $1.event }
    }

    /// The failure events (`PostToolUseFailure`, or any event carrying an
    /// `errorMessage`, or a tool call whose response reported `success:false`).
    public static func failures(_ events: [ClaudeMonitorEvent]) -> [ClaudeMonitorEvent] {
        events.filter {
            $0.event == "PostToolUseFailure"
                || $0.errorMessage != nil
                || $0.toolSucceeded == false
        }
    }

    /// Wall-clock latency of each completed turn, pairing every
    /// `UserPromptSubmit` with the next `Stop` in emission order. Turns missing
    /// a terminating `Stop` (e.g. the in-flight last turn) are omitted, as are
    /// pairs where either timestamp is absent.
    public static func turnLatencies(_ events: [ClaudeMonitorEvent]) -> [TimeInterval] {
        var out: [TimeInterval] = []
        var pendingStart: Date?
        for e in events {
            switch e.event {
            case "UserPromptSubmit":
                pendingStart = e.timestamp     // last prompt wins if doubled
            case "Stop":
                if let start = pendingStart, let end = e.timestamp, end >= start {
                    out.append(end.timeIntervalSince(start))
                }
                pendingStart = nil
            default:
                break
            }
        }
        return out
    }

    // MARK: - Timestamp

    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseTimestamp(_ raw: Any?) -> Date? {
        if let s = raw as? String {
            if let d = iso.date(from: s) { return d }
            return isoFractional.date(from: s)
        }
        if let n = raw as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        return nil
    }
}
