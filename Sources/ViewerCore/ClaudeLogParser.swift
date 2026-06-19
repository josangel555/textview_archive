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

    /// Redacting counterpart to `events(from:)` — reads the transcript and
    /// parses it through the redaction barrier (`parseRedacted`). Surfacing
    /// consumers must use this, not `events(from:)`.
    public func redactedEvents(from url: URL) throws -> [ClaudeEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ClaudeLogError.fileNotFound
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw ClaudeLogError.unreadable }
        return parseRedacted(data)
    }

    public func parse(_ rawData: Data) -> [ClaudeEvent] {
        parseCore(rawData, redacting: false)
    }

    /// Like `parse`, but every decoded record passes through `redact(_:)`
    /// BEFORE `parseRecord` — the security barrier any *surfacing* consumer
    /// (the `--claude-monitor` view, `ClaudeTranscriptSearch`) must use so no
    /// emitted event text can carry a `signature` / `headers` value or a raw
    /// inline image blob. `parse` stays un-redacted for callers that redact
    /// separately or only count (e.g. `ClaudeSessionIndex`).
    public func parseRedacted(_ rawData: Data) -> [ClaudeEvent] {
        parseCore(rawData, redacting: true)
    }

    private func parseCore(_ rawData: Data, redacting: Bool) -> [ClaudeEvent] {
        // Re-base via `Data(_:)` so the per-line slicing and 0-based
        // `withUnsafeBytes` newline scan below behave the same whether
        // the caller hands us a freshly-loaded `Data` or a slice carved
        // out of a larger buffer. Slices keep their parent's non-zero
        // `startIndex`, which on macOS 26 makes `subdata(in:)` return
        // garbage bytes for 0-based ranges (see LESSONS.md
        // "Data.subdata(in:) after removeFirst slice-offset bug";
        // LSPFraming.decode applies the same defensive rebase).
        let data = Data(rawData)
        var events: [ClaudeEvent] = []
        // Two-pass to keep the zero-copy slicing clean: scan newline
        // offsets under `withUnsafeBytes` (raw pointer, no per-byte
        // `Data` accessor cost), then slice + JSON-decode outside the
        // closure. SCALE-9/PERF-09: the per-line `data.subdata(in:)`
        // copied every line's bytes into a fresh allocation before
        // handing it to JSONSerialization — for a 100 MB transcript
        // that's ~one full extra copy of the file split across hundreds
        // of thousands of small allocations. `data[lineStart..<i]` is a
        // copy-free slice over the already-rebased buffer; because
        // `data` is 0-based after the rebase, the slice's logical range
        // is what JSONSerialization reads (it is range-aware, unlike
        // the buggy `subdata(in:)`). Covered by
        // DataSliceOffsetDefenseTests' offset-slice cases.
        var lineRanges: [Range<Int>] = []
        let count = data.count
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var lineStart = 0
            var i = 0
            while i < count {
                if bytes[i] == 0x0A { // \n
                    let lineLen = i - lineStart
                    if lineLen > 0 && lineLen <= self.maxLineBytes {
                        lineRanges.append(lineStart..<i)
                        // S3-C / cap: stop scanning once we've collected
                        // enough candidate lines to reach maxEvents. One
                        // line can emit multiple events, so this is an
                        // over-collect that the final prefix trims — but
                        // it still bounds the scan for a pathological
                        // many-line file.
                        if lineRanges.count >= self.maxEvents {
                            return
                        }
                    }
                    lineStart = i + 1
                }
                i += 1
            }
            // Trailing line without newline.
            if lineStart < count, lineRanges.count < self.maxEvents {
                let lineLen = count - lineStart
                if lineLen > 0 && lineLen <= self.maxLineBytes {
                    lineRanges.append(lineStart..<count)
                }
            }
        }

        for range in lineRanges {
            // Zero-copy slice over the rebased (0-based) buffer.
            let slice = data[range]
            if let obj = try? JSONSerialization.jsonObject(with: slice, options: []) as? [String: Any] {
                let record = redacting ? Self.redact(obj) : obj
                events.append(contentsOf: Self.parseRecord(record))
                if events.count >= maxEvents { break }
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

    static func parseTimestamp(_ raw: Any?) -> Date? {
        if let s = raw as? String {
            if let d = isoFractional.date(from: s) { return d }
            return iso.date(from: s)
        }
        if let n = raw as? Double {
            // A non-finite seconds value (NaN/±Inf) makes Date(timeIntervalSince1970:)
            // produce a garbage/distant Date; treat it as "no timestamp".
            guard n.isFinite else { return nil }
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

    /// Cheap "does this project have at least one Claude transcript?"
    /// check used by the sidebar to decide whether to render the
    /// timeline section's chrome at all. Returns `false` for `nil` /
    /// missing dir / dir with no `.jsonl` children.
    ///
    /// Pure FileManager — no parse. Safe to call from a SwiftUI body
    /// occasionally; cache the result behind an `onChange(of: rootURL)`
    /// if it gets called on every redraw.
    static func hasTranscripts(for projectPath: URL?) -> Bool {
        guard let projectPath else { return false }
        let dir = transcriptDirectory(for: projectPath)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? []
        return urls.contains { $0.pathExtension == "jsonl" }
    }
}
