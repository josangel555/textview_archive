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

/// STAGE-B DELETED TWIN (TSK-649, 2026-07-07): the Swift JSONL→event
/// PROJECTION that lived here was deleted — the engine is rust-core's
/// `transcript.rs` (TSK-632 port; caps, tolerance and redaction pinned
/// there), and every projection consumer routes through
/// `RustTranscriptAdapter`. What remains on this type:
///   - the `ClaudeEvent`/`ClaudeLogError` contract types (above);
///   - the record-CLASSIFICATION + redaction statics used by
///     `ClaudeSessionIndex` (`ClaudeLogParser+SystemRecords.swift`) — a
///     DIFFERENT surface that migrates with the transcript.list family
///     (TSK-658);
///   - the transcript-directory conveniences (below).
public struct ClaudeLogParser: Sendable {
    public init() {}
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
