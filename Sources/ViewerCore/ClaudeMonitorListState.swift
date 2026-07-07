import Foundation

/// TSK-1477 — the Claude monitor's list-state model: WHY the list is empty
/// (so the pane explains itself instead of showing a blank), and a cheap
/// refresh FINGERPRINT so the auto-refresh timer re-scans only when the
/// transcript tree actually changed (the recurring-no-op-update guard: a
/// poll tick that sees the same fingerprint must not rebuild the list and
/// churn observers). Pure over stat facts — host-tested on fixture dirs.
public enum ClaudeMonitorListState: Equatable, Sendable {
    /// Sessions found — the pane shows the list.
    case sessions(count: Int)
    /// Nothing to show, with the REASON the pane renders.
    case empty(EmptyReason)

    /// Why the list is empty — each renders a different, actionable message.
    public enum EmptyReason: Equatable, Sendable {
        /// The monitor root doesn't exist at all ("configure the path").
        case rootMissing(path: String)
        /// The root exists but has no `projects/` dir — probably not a
        /// Claude data dir ("is this the right folder?").
        case notAClaudeDir(path: String)
        /// The layout is right but there are no transcripts yet.
        case noTranscripts(path: String)
    }

    /// Classify the pane state from the root + the index's transcript scan.
    public static func classify(root: URL, transcriptCount: Int) -> ClaudeMonitorListState {
        if transcriptCount > 0 { return .sessions(count: transcriptCount) }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return .empty(.rootMissing(path: root.path))
        }
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        guard fm.fileExists(atPath: projects.path, isDirectory: &isDir), isDir.boolValue else {
            return .empty(.notAClaudeDir(path: root.path))
        }
        return .empty(.noTranscripts(path: root.path))
    }

    // MARK: - refresh fingerprint

    /// A cheap change-detection token over the transcript files: the count
    /// plus the newest content-modification date and total size. Catches
    /// adds, removals, AND appends (an append bumps the file's mtime/size
    /// even when no directory mtime moves) — while staying O(files) stats,
    /// no content reads.
    public struct Fingerprint: Equatable, Sendable {
        public let fileCount: Int
        public let newestModification: Date?
        public let totalBytes: Int
        public init(fileCount: Int, newestModification: Date?, totalBytes: Int) {
            self.fileCount = fileCount
            self.newestModification = newestModification
            self.totalBytes = totalBytes
        }
    }

    /// Fingerprint the transcript URLs (as returned by
    /// `ClaudeSessionIndex.transcriptURLs`).
    public static func fingerprint(of urls: [URL]) -> Fingerprint {
        var newest: Date?
        var bytes = 0
        for url in urls {
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey])
            if let m = values?.contentModificationDate {
                if newest.map({ m > $0 }) ?? true { newest = m }
            }
            bytes += values?.fileSize ?? 0
        }
        return Fingerprint(fileCount: urls.count, newestModification: newest, totalBytes: bytes)
    }

    /// The timer tick's decision: re-scan only when the fingerprint moved.
    public static func needsRescan(previous: Fingerprint?, current: Fingerprint) -> Bool {
        previous != current
    }
}
