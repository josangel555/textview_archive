import Foundation

/// File-based **bidirectional checkpoint channel** for walkthroughs.
///
/// The walkthrough drop-transport (`WalkthroughDropTransport`) is the
/// *inbound* path: an agent drops a script and the engine runs it. The
/// missing half — and the gap TSK-378 names — is the *outbound* path:
/// when a step is an `awaitUser` checkpoint, the engine has to (a) tell
/// a listening agent "I'm waiting for the user, here's the prompt" and
/// (b) hand back whatever the user replied. The MCP server is strict
/// request/response and drops notifications, so the durable, transport-
/// agnostic channel is the filesystem: a polling agent reads these
/// files. This is exactly what `WALKTHROUGH_DESIGN_v2.md` §4.1
/// ("Bidirectional channel for checkpoints (v1, file-based)") specifies.
///
/// Two artifacts per checkpoint, written into the same `directory`:
///
///   - `<walkthroughId>.<stepId>.checkpoint.json` — written when the
///     engine reaches an `awaitUser` step. Mirrors the prompt the user
///     sees so an agent that wasn't the one to author the script can
///     still understand what's being asked.
///   - `<walkthroughId>.<stepId>.reply.json` — written when the user
///     answers (a pill click or free-form text). Per design §4.1 this
///     reply is **always** persisted regardless of whether anyone is
///     listening, so an agent polling the directory always sees it.
///
/// Both writes are atomic (`Data.write(options: .atomic)`), so a poller
/// never reads a torn JSON. Filenames are sanitized so a hostile
/// `walkthroughId` / `stepId` (these can originate in an untrusted
/// dropped script) cannot escape `directory` via `/` or `..` — the
/// store is a *fence*, not just a path joiner.
///
/// Pure logic + `FileManager`: no AppKit, no SwiftUI, fully host-
/// testable. The engine/UI layer calls `writeCheckpoint` / `writeReply`;
/// nothing here knows about `DocumentModel` or the player strip.
public struct WalkthroughCheckpointStore: Sendable {

    /// Directory the checkpoint + reply artifacts live in. The store
    /// creates it on demand (owner-only, `0o700`) on the first write —
    /// these files can carry developer-machine paths, so restrict them
    /// even on a shared-user host (same posture as the drop dir).
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    /// Default checkpoint directory, a sibling of the drop inbox:
    /// `~/Library/Application Support/com.markdownviewer.MarkdownViewer/Walkthroughs/checkpoints/`.
    public static func defaultDirectory() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("com.markdownviewer.MarkdownViewer", isDirectory: true)
            .appendingPathComponent("Walkthroughs", isDirectory: true)
            .appendingPathComponent("checkpoints", isDirectory: true)
    }

    // MARK: - Errors

    public enum Error: Swift.Error, Equatable, Sendable {
        /// `walkthroughId` or `stepId` sanitized to an empty string —
        /// the filename would have no stable stem, so we refuse rather
        /// than write to an ambiguous path.
        case emptyIdentifier
        /// Could not create `directory`. Carries the underlying message.
        case directoryCreateFailed(String)
        /// The atomic write failed. Carries the underlying message.
        case writeFailed(String)
    }

    // MARK: - Public API

    /// Persist the prompt for an `awaitUser` checkpoint. Idempotent in
    /// effect: re-writing the same checkpoint overwrites the prior file
    /// (atomic), so a `previous` → re-enter of the same step is safe.
    ///
    /// `at` is injectable so tests can pin `writtenAt` deterministically.
    @discardableResult
    public func writeCheckpoint(
        walkthroughId: String,
        stepId: String,
        payload: AwaitUserPayload,
        at date: Date = Date()
    ) throws -> URL {
        let record = CheckpointRecord(
            walkthroughId: walkthroughId,
            stepId: stepId,
            prompt: payload.prompt,
            placeholder: payload.placeholder,
            pills: payload.pills,
            writtenAt: date
        )
        return try write(
            record,
            walkthroughId: walkthroughId,
            stepId: stepId,
            suffix: "checkpoint"
        )
    }

    /// Persist a user reply to a checkpoint. Always writes, even with no
    /// listener (design §4.1) — the file IS the channel. Re-writing the
    /// same `(walkthroughId, stepId)` overwrites the prior reply.
    @discardableResult
    public func writeReply(
        walkthroughId: String,
        stepId: String,
        answer: CheckpointAnswer,
        at date: Date = Date()
    ) throws -> URL {
        let record = ReplyRecord(
            walkthroughId: walkthroughId,
            stepId: stepId,
            answer: answer,
            writtenAt: date
        )
        return try write(
            record,
            walkthroughId: walkthroughId,
            stepId: stepId,
            suffix: "reply"
        )
    }

    /// Read back a previously-written reply, if present. Returns nil
    /// when no reply file exists or it fails to decode (a torn/foreign
    /// file is treated as "no reply" rather than surfacing a parse
    /// error — a poller only cares whether a usable reply is there).
    public func readReply(
        walkthroughId: String,
        stepId: String
    ) -> ReplyRecord? {
        guard let url = try? fileURL(
            walkthroughId: walkthroughId, stepId: stepId, suffix: "reply"
        ) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder().decode(ReplyRecord.self, from: data)
    }

    /// TSK-1211 — the step at which to RESUME `script`: the step immediately
    /// after the last one that has a recorded reply (history-resume). Returns nil
    /// when no progress is recorded, so the caller starts from the top. Pure over
    /// the on-disk reply records — no engine state.
    public func resumeStepID(for script: WalkthroughScript) -> String? {
        var lastReplied = -1
        for (i, step) in script.steps.enumerated()
        where readReply(walkthroughId: script.id, stepId: step.id) != nil {
            lastReplied = i
        }
        guard lastReplied >= 0 else { return nil }
        let next = Swift.min(lastReplied + 1, script.steps.count - 1)
        return script.steps[next].id
    }

    /// Read back a previously-written checkpoint prompt, if present.
    public func readCheckpoint(
        walkthroughId: String,
        stepId: String
    ) -> CheckpointRecord? {
        guard let url = try? fileURL(
            walkthroughId: walkthroughId, stepId: stepId, suffix: "checkpoint"
        ) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder().decode(CheckpointRecord.self, from: data)
    }

    // MARK: - Private

    private func write<T: Encodable>(
        _ record: T,
        walkthroughId: String,
        stepId: String,
        suffix: String
    ) throws -> URL {
        let url = try fileURL(
            walkthroughId: walkthroughId, stepId: stepId, suffix: suffix
        )
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw Error.directoryCreateFailed(error.localizedDescription)
        }
        let data: Data
        do {
            data = try Self.encoder().encode(record)
        } catch {
            throw Error.writeFailed(error.localizedDescription)
        }
        do {
            // `.atomic` = write to a temp + rename, so a poller never
            // sees a half-written JSON.
            try data.write(to: url, options: [.atomic])
        } catch {
            throw Error.writeFailed(error.localizedDescription)
        }
        return url
    }

    /// Build the artifact URL, sanitizing both identifiers so a hostile
    /// `walkthroughId` / `stepId` cannot escape `directory`. The
    /// identifiers can come from an untrusted dropped script, so this
    /// is a security fence, not cosmetics.
    private func fileURL(
        walkthroughId: String,
        stepId: String,
        suffix: String
    ) throws -> URL {
        let safeId = Self.sanitize(walkthroughId)
        let safeStep = Self.sanitize(stepId)
        guard !safeId.isEmpty, !safeStep.isEmpty else {
            throw Error.emptyIdentifier
        }
        let name = "\(safeId).\(safeStep).\(suffix).json"
        return directory.appendingPathComponent(name, isDirectory: false)
    }

    /// Reduce an identifier to a filename-safe stem: keep alphanumerics,
    /// `-`, `_`, and `.`; collapse everything else (including path
    /// separators) to `_`; then strip leading dots so the result can
    /// never be `.`, `..`, or a hidden-file traversal. Idempotent.
    static func sanitize(_ raw: String) -> String {
        let allowed: Set<Character> = Set(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
        )
        var out = String(raw.map { allowed.contains($0) ? $0 : "_" })
        // Strip leading dots so `..`, `.`, `.hidden` can't appear as the
        // stem (after this, the joined filename always has our suffix +
        // ".json", so it can't BE `.` / `..`, but defense in depth).
        while out.hasPrefix(".") { out.removeFirst() }
        return out
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - On-disk records

/// The checkpoint prompt an agent reads from
/// `<walkthroughId>.<stepId>.checkpoint.json`. Mirrors `AwaitUserPayload`
/// plus routing identifiers and a timestamp.
public struct CheckpointRecord: Codable, Sendable, Equatable {
    public let walkthroughId: String
    public let stepId: String
    public let prompt: String
    public let placeholder: String?
    public let pills: [String]?
    public let writtenAt: Date

    public init(
        walkthroughId: String,
        stepId: String,
        prompt: String,
        placeholder: String? = nil,
        pills: [String]? = nil,
        writtenAt: Date
    ) {
        self.walkthroughId = walkthroughId
        self.stepId = stepId
        self.prompt = prompt
        self.placeholder = placeholder
        self.pills = pills
        self.writtenAt = writtenAt
    }
}

/// The user's reply an agent reads from
/// `<walkthroughId>.<stepId>.reply.json`.
public struct ReplyRecord: Codable, Sendable, Equatable {
    public let walkthroughId: String
    public let stepId: String
    public let answer: CheckpointAnswer
    public let writtenAt: Date

    public init(
        walkthroughId: String,
        stepId: String,
        answer: CheckpointAnswer,
        writtenAt: Date
    ) {
        self.walkthroughId = walkthroughId
        self.stepId = stepId
        self.answer = answer
        self.writtenAt = writtenAt
    }
}

/// What the user picked at an `awaitUser` checkpoint: a suggested pill
/// (`option`) or typed-in text (`freeForm`). Tagged on `kind` so the
/// wire form is self-describing and an unknown future kind rejects
/// cleanly rather than silently best-effort decoding.
///
/// Named to match `WALKTHROUGH_DESIGN_v2.md` §4.3 (`CheckpointAnswer`),
/// the type the planned `walkthrough.reply(...)` MCP tool and the
/// engine's `reply(stepId:answer:)` will carry.
public enum CheckpointAnswer: Codable, Sendable, Equatable {
    /// The user clicked one of the suggested `pills`. Carries the pill
    /// text (the index isn't stable across `appendSteps`, the text is
    /// what the author wrote and what the agent reasons about).
    case option(String)
    /// The user typed a free-form reply.
    case freeForm(String)

    enum CodingKeys: String, CodingKey { case kind, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let value = try c.decode(String.self, forKey: .value)
        switch kind {
        case "option":   self = .option(value)
        case "freeForm": self = .freeForm(value)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "Unknown checkpoint answer kind: \(kind)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .option(let v):
            try c.encode("option", forKey: .kind)
            try c.encode(v, forKey: .value)
        case .freeForm(let v):
            try c.encode("freeForm", forKey: .kind)
            try c.encode(v, forKey: .value)
        }
    }

    /// The reply text regardless of kind — convenience for the agent
    /// that just wants "what did the user say".
    public var text: String {
        switch self {
        case .option(let v), .freeForm(let v): return v
        }
    }
}
