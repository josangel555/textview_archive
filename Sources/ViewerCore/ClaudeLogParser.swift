import Foundation

public struct ClaudeEvent: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case userMessage(text: String)
        case assistantMessage(text: String)
        case thinking(text: String)
        case toolUse(id: String, name: String, input: [String: String])
        case toolResult(toolUseId: String, summary: String)
    }

    public let id: String
    public let timestamp: Date?
    public let kind: Kind

    public init(id: String, timestamp: Date?, kind: Kind) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
    }

    public var summary: String {
        switch kind {
        case .userMessage(let text):
            return Self.truncate(text, max: 80)
        case .assistantMessage(let text):
            return Self.truncate(text, max: 80)
        case .thinking(let text):
            return "thinking: " + Self.truncate(text, max: 80)
        case .toolUse(_, let name, let input):
            let target = input["file_path"]
                ?? input["path"]
                ?? input["command"]
                ?? input.values.first
                ?? ""
            return name + (target.isEmpty ? "" : "  \(Self.truncate(target, max: 60))")
        case .toolResult(_, let summary):
            return Self.truncate(summary, max: 80)
        }
    }

    private static func truncate(_ s: String, max: Int) -> String {
        let single = s.replacingOccurrences(of: "\n", with: " ")
        if single.count <= max { return single }
        return String(single.prefix(max - 1)) + "…"
    }
}

public enum ClaudeLogError: Error, Equatable {
    case fileNotFound
    case unreadable
}

/// Parses Claude Code's JSONL transcripts into structured events. The
/// transcript format is loose-y goose-y; the parser is intentionally
/// forgiving — unknown record shapes are skipped, not fatal.
///
/// Resource caps (S6/S7) protect against pathological input: real
/// transcripts can exceed 100 MB; a malicious one could be unbounded.
public struct ClaudeLogParser: Sendable {

    /// Largest single JSONL line we'll try to parse. Lines longer than
    /// this are skipped rather than feeding `JSONSerialization` a
    /// gigabyte buffer that may OOM. Default 4 MB.
    public let maxLineBytes: Int

    /// Cap on total events returned from one parse. Hard ceiling so the
    /// caller can't accidentally materialize an unbounded array. Default
    /// 200,000 (real transcripts are <10k events).
    public let maxEvents: Int

    public init(maxLineBytes: Int = 4 * 1024 * 1024,
                maxEvents: Int = 200_000) {
        self.maxLineBytes = maxLineBytes
        self.maxEvents = maxEvents
    }

    public func events(from url: URL) throws -> [ClaudeEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ClaudeLogError.fileNotFound
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw ClaudeLogError.unreadable }
        return parse(data)
    }

    public func parse(_ data: Data) -> [ClaudeEvent] {
        var events: [ClaudeEvent] = []
        var lineStart = 0
        let count = data.count
        var i = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            while i < count {
                if bytes[i] == 0x0A { // \n
                    let lineLen = i - lineStart
                    if lineLen > 0 && lineLen <= self.maxLineBytes {
                        let slice = data.subdata(in: lineStart..<i)
                        if let obj = try? JSONSerialization.jsonObject(with: slice, options: []) as? [String: Any] {
                            events.append(contentsOf: Self.parseRecord(obj))
                        }
                    }
                    lineStart = i + 1
                    if events.count >= self.maxEvents { return }
                }
                i += 1
            }
            // Trailing line without newline
            if lineStart < count {
                let lineLen = count - lineStart
                if lineLen > 0 && lineLen <= self.maxLineBytes {
                    let slice = data.subdata(in: lineStart..<count)
                    if let obj = try? JSONSerialization.jsonObject(with: slice, options: []) as? [String: Any] {
                        events.append(contentsOf: Self.parseRecord(obj))
                    }
                }
            }
        }
        if events.count > maxEvents {
            events = Array(events.prefix(maxEvents))
        }
        return events
    }

    public func parse(_ text: String) -> [ClaudeEvent] {
        guard let data = text.data(using: .utf8) else { return [] }
        return parse(data)
    }

    static func parseRecord(_ obj: [String: Any]) -> [ClaudeEvent] {
        let id = (obj["uuid"] as? String)
            ?? (obj["id"] as? String)
            ?? UUID().uuidString
        let timestamp = parseTimestamp(obj["timestamp"])
        let type = obj["type"] as? String ?? ""
        guard let message = obj["message"] as? [String: Any] else {
            return []
        }
        let role = message["role"] as? String ?? type

        // content may be a string or an array of blocks.
        if let contentString = message["content"] as? String {
            if role == "user" {
                return [.init(id: id, timestamp: timestamp, kind: .userMessage(text: contentString))]
            }
            if role == "assistant" {
                return [.init(id: id, timestamp: timestamp, kind: .assistantMessage(text: contentString))]
            }
            return []
        }

        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        var out: [ClaudeEvent] = []
        for block in blocks {
            let blockType = block["type"] as? String ?? ""
            switch blockType {
            case "text":
                let text = block["text"] as? String ?? ""
                if role == "user" {
                    out.append(.init(id: id, timestamp: timestamp, kind: .userMessage(text: text)))
                } else {
                    out.append(.init(id: id, timestamp: timestamp, kind: .assistantMessage(text: text)))
                }
            case "thinking":
                // CRIT-7: real transcripts include `thinking` blocks from the
                // assistant. Previously these were silently dropped. Both
                // `thinking` and `text` fields are observed in the wild for
                // the payload — accept either.
                let text = (block["thinking"] as? String) ?? (block["text"] as? String) ?? ""
                out.append(.init(id: id, timestamp: timestamp, kind: .thinking(text: text)))
            case "tool_use":
                let toolId = block["id"] as? String ?? id
                let name = block["name"] as? String ?? "tool"
                let input = stringifyInput(block["input"])
                out.append(.init(id: toolId, timestamp: timestamp, kind: .toolUse(
                    id: toolId, name: name, input: input
                )))
            case "tool_result":
                let toolUseId = block["tool_use_id"] as? String ?? ""
                let summary = summarizeToolResult(block["content"])
                out.append(.init(id: id, timestamp: timestamp, kind: .toolResult(
                    toolUseId: toolUseId, summary: summary
                )))
            default:
                continue
            }
        }
        return out
    }

    /// Shared formatters — were allocated once per log line previously.
    /// A 200K-line Claude session parsed = 200K formatter allocations,
    /// each ~few KB of internal CFLocale / format strings.
    /// `nonisolated(unsafe)`: ISO8601DateFormatter is documented
    /// thread-safe for read-only use; Swift 6's checker can't tell.
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
            if let d = isoFractional.date(from: s) { return d }
            return iso.date(from: s)
        }
        if let n = raw as? Double {
            return Date(timeIntervalSince1970: n)
        }
        return nil
    }

    private static func stringifyInput(_ raw: Any?) -> [String: String] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (k, v) in dict {
            if let s = v as? String {
                result[k] = s
            } else if let n = v as? Int {
                result[k] = String(n)
            } else if let b = v as? Bool {
                result[k] = String(b)
            } else if JSONSerialization.isValidJSONObject(v),
                      let data = try? JSONSerialization.data(withJSONObject: v, options: []),
                      let s = String(data: data, encoding: .utf8) {
                // Nested arrays/objects: emit a compact JSON repr so the
                // value doesn't show up as Swift's debug description.
                result[k] = s
            } else {
                result[k] = "\(v)"
            }
        }
        return result
    }

    private static func summarizeToolResult(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        if let arr = raw as? [[String: Any]] {
            // Each block may have {"type":"text","text":"..."}
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }
}

// MARK: Convenience

public extension ClaudeLogParser {
    /// Returns the path to the per-project transcript directory under
    /// `~/.claude/projects/<encoded-path>/`. Claude encodes the absolute path
    /// by replacing slashes with hyphens.
    static func transcriptDirectory(for projectPath: URL) -> URL {
        let encoded = projectPath
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
            .replacingOccurrences(of: "/", with: "-")
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
    }
}
