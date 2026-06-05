import Foundation

// First slice of the read-only "agent monitoring" index over `~/.claude`.
//
// `ClaudeSessionIndex` enumerates top-level session transcripts under
// `<root>/projects/*/*.jsonl` and produces one `ClaudeSessionSummary` per
// file. Everything here is Foundation-only (no AppKit/SwiftUI) and strictly
// read-only: files are opened `O_RDONLY` and streamed line-by-line so a
// 100 MB / 29k-line transcript never lands in memory whole.
//
// Reference schema: docs/research/autorun-2026-06-04/claude-dir.md.

// MARK: - Summary model

/// One transcript file, summarized for a session list. The `key` is the
/// FILENAME STEM — the canonical session key — which deliberately may differ
/// from the in-record `sessionId` (they diverge on resume/fork; multiple
/// files can share one in-record `sessionId`).
public struct ClaudeSessionSummary: Equatable, Sendable, Identifiable, Codable {
    /// Filename stem (canonical session key). Stable across record drift.
    public let key: String
    /// Absolute file path of the transcript.
    public let path: String
    /// Grouping key: the (lossy) project-dir name the file lives under.
    public let projectDirName: String
    /// Real working directory read from inside the records (un-mangled).
    public let cwd: String?
    /// Resolved title: last `custom-title` → last `ai-title` → first user
    /// prompt text → `nil`.
    public let title: String?
    /// In-record logical session id (diagnostic only; may differ from `key`).
    public let recordSessionId: String?
    /// First record timestamp encountered (file order).
    public let firstTimestamp: Date?
    /// Last record timestamp encountered (file order).
    public let lastTimestamp: Date?
    /// Count of conversation-message records (`user`/`assistant`).
    public let messageCount: Int
    /// Count of surfaced events (text/thinking/tool_use/tool_result) — i.e.
    /// what `ClaudeLogParser` would emit, after redaction.
    public let eventCount: Int
    /// Total decodable JSONL records (any `type`).
    public let recordCount: Int

    public var id: String { key }

    public init(
        key: String,
        path: String,
        projectDirName: String,
        cwd: String?,
        title: String?,
        recordSessionId: String?,
        firstTimestamp: Date?,
        lastTimestamp: Date?,
        messageCount: Int,
        eventCount: Int,
        recordCount: Int
    ) {
        self.key = key
        self.path = path
        self.projectDirName = projectDirName
        self.cwd = cwd
        self.title = title
        self.recordSessionId = recordSessionId
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.messageCount = messageCount
        self.eventCount = eventCount
        self.recordCount = recordCount
    }
}

// MARK: - Index

public struct ClaudeSessionIndex: Sendable {

    /// Largest single JSONL line we'll attempt to JSON-decode. Lines longer
    /// than this have their byte offset recorded (so the line index stays
    /// complete) but are NOT decoded — they contribute to neither counts nor
    /// title/timestamp resolution. Mirrors `ClaudeLogParser.maxLineBytes`.
    public let maxLineBytes: Int

    /// Read buffer size for the streaming scan. The whole file is consumed in
    /// chunks of this size; only the buffer plus at most one in-flight line
    /// (≤ `maxLineBytes`) are resident at once.
    public let readChunkBytes: Int

    /// Hard cap on records scanned per file, guarding a pathological
    /// many-line file. Real transcripts are < 30k lines.
    public let maxRecords: Int

    /// Upper bound on the characters retained for any resolved title
    /// candidate (first user prompt, custom-title, ai-title). A first prompt
    /// can be arbitrarily large (up to `maxLineBytes`); the summary is a
    /// one-line list field, so capping at capture keeps a multi-MB prompt from
    /// being held in (and serialized into) the index. Generous relative to the
    /// 80-char event `summary` discipline because a title is the whole label.
    public static let maxTitleChars = 200

    public init(
        maxLineBytes: Int = 4 * 1024 * 1024,
        readChunkBytes: Int = 256 * 1024,
        maxRecords: Int = 1_000_000
    ) {
        self.maxLineBytes = maxLineBytes
        self.readChunkBytes = readChunkBytes
        self.maxRecords = maxRecords
    }

    // MARK: Enumeration

    /// Enumerate `<root>/projects/*/*.jsonl` TOP-LEVEL ONLY. Skips the sibling
    /// `<uuid>/` sidecar dirs (and thus any nested `subagents/` transcripts).
    /// Returns absolute file URLs, sorted by path for deterministic output.
    public func transcriptURLs(root: URL) -> [URL] {
        let fm = FileManager.default
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projects,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var out: [URL] = []
        for projectDir in projectDirs {
            // Only descend into directories (skip stray top-level files).
            let isDir = (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            // contentsOfDirectory is NON-recursive — so the `<uuid>/` sidecar
            // dirs (and their `subagents/`) are never traversed; we only pick
            // the `.jsonl` files sitting directly in the project dir.
            guard let children = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children where child.pathExtension == "jsonl" {
                let isFile = (try? child.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
                if isFile { out.append(child) }
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Build summaries for every top-level transcript under `root`.
    public func summaries(root: URL) -> [ClaudeSessionSummary] {
        return transcriptURLs(root: root).compactMap { try? summary(for: $0) }
    }

    // MARK: Per-file summary (streaming)

    /// Stream a single transcript file and build its summary. Throws
    /// `ClaudeLogError` on missing/unreadable file. Never slurps the file.
    public func summary(for url: URL) throws -> ClaudeSessionSummary {
        let scan = try scanFile(url)
        let key = url.deletingPathExtension().lastPathComponent
        let projectDirName = url.deletingLastPathComponent().lastPathComponent

        // Title precedence: last custom-title > last ai-title > first prompt.
        let title = scan.lastCustomTitle ?? scan.lastAITitle ?? scan.firstUserPrompt

        return ClaudeSessionSummary(
            key: key,
            path: url.path,
            projectDirName: projectDirName,
            cwd: scan.cwd,
            title: title,
            recordSessionId: scan.recordSessionId,
            firstTimestamp: scan.firstTimestamp,
            lastTimestamp: scan.lastTimestamp,
            messageCount: scan.messageCount,
            eventCount: scan.eventCount,
            recordCount: scan.recordCount
        )
    }

    /// Per-line byte-offset index for a file (array of line *start* offsets).
    /// Enables lazy random-access for a future detail view: line `n` begins at
    /// `offsets[n]` and ends at `offsets[n+1]-1` (minus the `\n`), or EOF for
    /// the last line. Computed by the same streaming scan, so it is cheap and
    /// never slurps. Oversized lines ARE included (their offset is real); the
    /// caller decides whether to decode them.
    public func lineOffsets(for url: URL) throws -> [Int] {
        return try scanFile(url).lineOffsets
    }

    /// Lazily read a single line by index using a previously-built offset
    /// table, opening the file read-only and seeking directly to the line.
    /// Returns the raw line bytes (without the trailing `\n`), capped at
    /// `maxLineBytes`. Returns `nil` for out-of-range indices.
    ///
    /// This is the random-access primitive a detail view uses to decode just
    /// the visible lines instead of re-streaming the whole file.
    public func line(at index: Int, offsets: [Int], in url: URL) throws -> Data? {
        guard index >= 0, index < offsets.count else { return nil }
        let start = offsets[index]
        let end: Int
        if index + 1 < offsets.count {
            // Next line's start, minus the newline byte between them.
            end = offsets[index + 1] - 1
        } else {
            end = try fileSize(url)
        }
        let length = max(0, min(end - start, maxLineBytes))
        guard length > 0 else { return Data() }

        let handle = try openReadOnly(url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start))
        return try handle.read(upToCount: length)
    }

    // MARK: - Streaming scan

    private struct Scan {
        var lineOffsets: [Int] = []
        var firstTimestamp: Date?
        var lastTimestamp: Date?
        var cwd: String?
        var recordSessionId: String?
        var lastCustomTitle: String?
        var lastAITitle: String?
        var firstUserPrompt: String?
        var messageCount = 0
        var eventCount = 0
        var recordCount = 0
    }

    /// Core streaming pass: reads the file in fixed-size chunks, splits on
    /// `\n`, decodes each line (within the size cap), and folds per-line state
    /// into a `Scan`. Memory is bounded by `readChunkBytes` + one pending line.
    private func scanFile(_ url: URL) throws -> Scan {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ClaudeLogError.fileNotFound
        }
        let handle = try openReadOnly(url)
        defer { try? handle.close() }

        var scan = Scan()
        // Bytes of the current (not-yet-terminated) line.
        var pending = Data()
        // Absolute byte offset where the current line started.
        var lineStartOffset = 0
        // Absolute byte offset of the next byte to be consumed.
        var cursor = 0
        // Once a line exceeds the cap we keep counting bytes to find its end
        // but stop accumulating them (so memory stays bounded) and skip decode.
        var pendingOverflowed = false

        let newline: UInt8 = 0x0A

        while true {
            guard let chunk = try handle.read(upToCount: readChunkBytes), !chunk.isEmpty else {
                break
            }
            // Iterate the chunk by absolute index; copy slices between
            // newlines into `pending`. `chunk` is a fresh Data per read, so
            // its indices are 0-based.
            var searchStart = chunk.startIndex
            while let nlIndex = chunk[searchStart...].firstIndex(of: newline) {
                // Segment [searchStart, nlIndex) completes the current line.
                let segment = chunk[searchStart..<nlIndex]
                appendToPending(&pending, segment, overflowed: &pendingOverflowed)
                finalizeLine(
                    pending: pending,
                    overflowed: pendingOverflowed,
                    startOffset: lineStartOffset,
                    into: &scan
                )
                // Bound on PHYSICAL lines, not just decoded records: a file
                // of millions of blank/oversized (non-decoded) lines must not
                // grow the offset table without limit, so guard on the table
                // length (which gets one entry per physical line) as well.
                if scan.recordCount >= maxRecords || scan.lineOffsets.count >= maxRecords {
                    return scan
                }
                // Reset for the next line. `+1` skips the newline byte.
                let consumed = chunk.distance(from: searchStart, to: nlIndex) + 1
                lineStartOffset = cursor + chunk.distance(from: chunk.startIndex, to: searchStart) + consumed
                pending.removeAll(keepingCapacity: true)
                pendingOverflowed = false
                searchStart = chunk.index(after: nlIndex)
            }
            // Tail of the chunk (no newline) joins the pending line.
            if searchStart < chunk.endIndex {
                appendToPending(&pending, chunk[searchStart...], overflowed: &pendingOverflowed)
            }
            cursor += chunk.count
        }

        // Trailing line without a final newline. A file ending in `\n`
        // leaves `pending` empty (the last newline already finalized its
        // line), so this only fires for genuine no-final-newline content —
        // and never invents a spurious empty trailing line.
        if !pending.isEmpty {
            finalizeLine(
                pending: pending,
                overflowed: pendingOverflowed,
                startOffset: lineStartOffset,
                into: &scan
            )
        }

        return scan
    }

    /// Append `segment` into `pending` unless doing so would exceed the line
    /// cap; once over the cap, record the offset only and drop the bytes.
    private func appendToPending(_ pending: inout Data, _ segment: Data, overflowed: inout Bool) {
        if overflowed { return }
        if pending.count + segment.count > maxLineBytes {
            // Cap reached: mark overflow and stop accumulating. We keep
            // whatever was already buffered (it's ≤ cap) but won't decode it.
            overflowed = true
            return
        }
        pending.append(segment)
    }

    /// Record a completed line's offset and, if within the cap, decode it and
    /// fold its contribution into the scan.
    private func finalizeLine(
        pending: Data,
        overflowed: Bool,
        startOffset: Int,
        into scan: inout Scan
    ) {
        // Empty line (blank or `\n\n`): record offset, nothing to decode.
        scan.lineOffsets.append(startOffset)
        if overflowed || pending.isEmpty { return }
        guard let obj = try? JSONSerialization.jsonObject(with: pending, options: []) as? [String: Any] else {
            return
        }
        fold(record: obj, into: &scan)
    }

    /// Fold one decoded record into the accumulating scan state. Title and
    /// metadata follow last-wins; timestamps track first/last in file order.
    private func fold(record obj: [String: Any], into scan: inout Scan) {
        scan.recordCount += 1

        // Timestamps (first/last in file order).
        if let ts = Self.timestamp(obj) {
            if scan.firstTimestamp == nil { scan.firstTimestamp = ts }
            scan.lastTimestamp = ts
        }

        // Real cwd (first non-empty wins; they're consistent within a file).
        if scan.cwd == nil, let cwd = ClaudeLogParser.recordCwd(obj) {
            scan.cwd = cwd
        }
        if scan.recordSessionId == nil, let sid = ClaudeLogParser.recordSessionId(obj) {
            scan.recordSessionId = sid
        }

        // Title sidecar records (last-wins). Capped at capture so an oversized
        // title doesn't ride along in the summary / on-disk index.
        if let (isCustom, title) = ClaudeLogParser.titleRecord(obj) {
            if isCustom { scan.lastCustomTitle = Self.cappedTitle(title) }
            else { scan.lastAITitle = Self.cappedTitle(title) }
        }

        // First user prompt (fallback title), only the first one. Capped at
        // capture: a first prompt can be up to `maxLineBytes`.
        if scan.firstUserPrompt == nil, let prompt = ClaudeLogParser.userPromptText(obj) {
            scan.firstUserPrompt = Self.cappedTitle(prompt)
        }

        // Message vs event counts. Count blocks directly: only `.count` is
        // consumed, so building (and redacting) a throwaway event array is pure
        // waste. Redaction never adds/removes blocks, so the count is identical
        // to `parseRecord(redact(obj)).count` and no secret is ever surfaced
        // (nothing is serialized here — only the integer count).
        let type = ClaudeLogParser.recordType(obj)
        if type == "user" || type == "assistant" {
            scan.messageCount += 1
        }
        scan.eventCount += Self.eventCount(of: obj)
    }

    /// Trim a title candidate to `maxTitleChars`. Returns the input unchanged
    /// when already within the cap (the common case) to avoid an allocation.
    private static func cappedTitle(_ s: String) -> String {
        s.count <= maxTitleChars ? s : String(s.prefix(maxTitleChars))
    }

    /// Number of events `ClaudeLogParser.parseRecord` would emit for `obj`,
    /// computed WITHOUT materializing the event array (or a redacted copy).
    /// Must stay in lockstep with `parseRecord`'s block-emission rules.
    private static func eventCount(of obj: [String: Any]) -> Int {
        guard let message = obj["message"] as? [String: Any] else { return 0 }
        let type = obj["type"] as? String ?? ""
        let role = message["role"] as? String ?? type

        // Plain-string content: one event iff the role is user/assistant.
        if message["content"] is String {
            return (role == "user" || role == "assistant") ? 1 : 0
        }

        // Block-array content: one event per surfaced block kind.
        guard let blocks = message["content"] as? [[String: Any]] else { return 0 }
        var count = 0
        for block in blocks {
            switch block["type"] as? String {
            case "text", "thinking", "tool_use", "tool_result":
                count += 1
            default:
                continue
            }
        }
        return count
    }

    // MARK: Timestamp (mirrors ClaudeLogParser's private parser)

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

    private static func timestamp(_ obj: [String: Any]) -> Date? {
        let raw = obj["timestamp"]
        if let s = raw as? String {
            if let d = isoFractional.date(from: s) { return d }
            return iso.date(from: s)
        }
        if let n = raw as? Double {
            return Date(timeIntervalSince1970: n)
        }
        return nil
    }

    // MARK: Read-only file primitives

    /// Open `url` strictly read-only. Foundation's `FileHandle(forReadingFrom:)`
    /// opens `O_RDONLY`, so the index can never mutate the user's transcripts.
    private func openReadOnly(_ url: URL) throws -> FileHandle {
        do {
            return try FileHandle(forReadingFrom: url)
        } catch {
            throw ClaudeLogError.unreadable
        }
    }

    private func fileSize(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? Int) ?? 0
    }
}
