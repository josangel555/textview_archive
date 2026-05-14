import Foundation

public struct ClaudeEvent: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case userMessage(text: String)
        case assistantMessage(text: String)
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
public struct ClaudeLogParser: Sendable {
    public init() {}

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
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(text)
    }

    public func parse(_ text: String) -> [ClaudeEvent] {
        var events: [ClaudeEvent] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            guard let data = line.data(using: .utf8) else { continue }
            guard let any = try? JSONSerialization.jsonObject(with: data, options: []),
                  let obj = any as? [String: Any] else { continue }
            events.append(contentsOf: Self.parseRecord(obj))
        }
        return events
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

    private static func parseTimestamp(_ raw: Any?) -> Date? {
        if let s = raw as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = formatter.date(from: s) { return d }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: s)
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
            if let s = v as? String { result[k] = s }
            else if let n = v as? Int { result[k] = String(n) }
            else if let b = v as? Bool { result[k] = String(b) }
            else { result[k] = "\(v)" }
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
