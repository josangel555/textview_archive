import Foundation

/// App-wide sensitive-activity audit log (TSK-636) — the owner's "I want to
/// see what the app touched": file interactions, core-engine calls,
/// subprocess spawns, (v2: WebView egress, pasteboard).
///
/// Design:
///   • Append-only JSONL at `~/Library/Application Support/MarkdownViewer/
///     audit.jsonl` (the established non-bundle-id state dir). One event per
///     line — the VIEWER for v1 is the app itself: open the file in
///     TextView (a dedicated panel is the live-gated v2).
///   • Size-rotated: at 5 MB the file moves to `audit.1.jsonl` (one
///     generation kept) and a fresh file starts. Audit ≠ archive.
///   • Thread-safe, crash-tolerant (append + flush per event; a torn tail
///     line is exactly what the tolerant JSONL parsers handle).
///   • Default ON, cheap when disabled (`MarkdownViewer.auditLog.enabled`
///     defaults key; an explicit `false` short-circuits before any IO).
///   • NEVER logs file CONTENTS — paths, methods, outcomes, byte counts.
public final class AuditLog: @unchecked Sendable {

    public enum Kind: String, Sendable {
        case fileOpen = "file.open"
        case fileSave = "file.save"
        case coreCall = "core.call"
        case processSpawn = "process.spawn"
        case webNavigation = "web.navigation"
        case pasteboard = "pasteboard"
    }

    public static let shared = AuditLog()

    /// Defaults key for the kill switch (explicit `false` disables).
    public static let enabledKey = "MarkdownViewer.auditLog.enabled"
    static let maxBytes: UInt64 = 5 * 1024 * 1024

    private let lock = NSLock()
    private var handle: FileHandle?
    private var bytesWritten: UInt64 = 0
    private let directory: URL
    private let defaults: UserDefaults

    /// Production singleton uses the standard state dir; tests inject.
    public init(
        directory: URL? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first.map { $0.appendingPathComponent("MarkdownViewer", isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        self.defaults = defaults
    }

    deinit { try? handle?.close() }

    public var logURL: URL { directory.appendingPathComponent("audit.jsonl") }
    public var rotatedURL: URL { directory.appendingPathComponent("audit.1.jsonl") }

    private var enabled: Bool {
        // Default ON: only an explicit false disables.
        if defaults.object(forKey: Self.enabledKey) != nil {
            return defaults.bool(forKey: Self.enabledKey)
        }
        return true
    }

    /// Record one event. Drops silently when disabled or on IO failure —
    /// the audit log must never take the app down or block a hot path on
    /// retry loops (it appends + flushes, nothing more).
    public func record(
        _ kind: Kind,
        action: String,
        target: String,
        meta: [String: String] = [:]
    ) {
        guard enabled else { return }
        var obj: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "kind": kind.rawValue,
            "action": action,
            "target": target,
        ]
        if !meta.isEmpty { obj["meta"] = meta }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        let bytes = Data(line.utf8)

        lock.lock()
        defer { lock.unlock() }
        ensureHandleLocked()
        guard let handle else { return }
        do {
            try handle.write(contentsOf: bytes)
            bytesWritten += UInt64(bytes.count)
            if bytesWritten >= Self.maxBytes {
                rotateLocked()
            }
        } catch {
            // A failed write poisons nothing; drop and retry on next event.
            self.handle = nil
        }
    }

    /// Test/diagnostic hook: flush + forget the handle so the file can be
    /// read or the directory torn down.
    public func closeForTesting() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }

    private func ensureHandleLocked() {
        guard handle == nil else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: logURL) else { return }
        bytesWritten = (try? h.seekToEnd()) ?? 0
        handle = h
    }

    private func rotateLocked() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: logURL, to: rotatedURL)
        bytesWritten = 0
        // Next record() lazily reopens a fresh file.
    }
}
