import Foundation

/// A back-end-agnostic handle to one version of a file. The unified version
/// viewer (TSK-1103) lists these and lets the user view a version, diff it
/// against current, or select a range for a cumulative diff — identically for
/// **Local History** snapshots and **Git** commits.
///
/// `id` is the stable token the back-end resolves a version by: a
/// `LocalHistoryStore.Version.id` (unix-millis), or a git full SHA. The rest is
/// display metadata. `Sendable` so it crosses the off-main load boundary.
public struct VersionRef: Sendable, Equatable, Identifiable {
    /// Back-end-stable id (snapshot id OR git full SHA). Resolves content/diffs.
    public let id: String
    /// Compact label for the list row (a formatted time, or a short SHA).
    public let shortLabel: String
    /// When this version was created, if known (always for both back-ends).
    public let timestamp: Date?
    /// Commit author (git only); nil for Local History.
    public let author: String?
    /// Commit subject (git only); nil for Local History.
    public let subject: String?
    /// Snapshot size in bytes (Local History only; nil for git — a commit has
    /// no single "size"). Drives the timeline's size + size-delta annotation
    /// (TSK-1462).
    public let byteSize: Int?
    public let kind: Kind

    public enum Kind: Sendable, Equatable {
        case localHistory
        case git
    }

    public init(
        id: String, shortLabel: String, timestamp: Date?,
        author: String? = nil, subject: String? = nil,
        byteSize: Int? = nil, kind: Kind
    ) {
        self.id = id
        self.shortLabel = shortLabel
        self.timestamp = timestamp
        self.author = author
        self.subject = subject
        self.byteSize = byteSize
        self.kind = kind
    }
}

/// The single seam both history back-ends conform to, so ONE viewer + view-model
/// drive both Local History and Git. SwiftUI/AppKit-free and fully synchronous
/// (the view-model calls these on a detached task) → host-testable.
///
/// All methods are best-effort and non-throwing, matching `GitClient` /
/// `LocalHistoryStore`: a failure degrades to an empty list / nil content /
/// empty diff, never a crash.
public protocol VersionSource: Sendable {
    /// File label shown in the viewer header.
    var displayName: String { get }

    /// Whether this source supports cumulative range diffs across non-adjacent
    /// versions. Local History: yes (we own both endpoints' text). Git: yes
    /// (`git diff base..tip`). Always true for the two built-in sources; the
    /// protocol carries it so a synthetic source (e.g. a 2-version conflict
    /// view) can opt out.
    var supportsRangeDiff: Bool { get }

    /// All versions, newest-first.
    func listVersions() -> [VersionRef]

    /// Full text of `version` (the "view this version" path), or nil if it
    /// can't be loaded (missing / binary / unreadable).
    func content(of version: VersionRef) -> String?

    /// Unified-diff TEXT for `version` vs the CURRENT file content — the
    /// owner's "diff between [it and] current" toggle. "" when identical or on
    /// failure.
    func diffAgainstCurrent(_ version: VersionRef) -> String

    /// Unified-diff TEXT between two versions. `to == nil` ⇒ the change
    /// introduced by `from` relative to its immediate predecessor (the "this
    /// version's own change" reading). "" on failure.
    func diff(from: VersionRef, to: VersionRef?) -> String

    /// Cumulative unified-diff TEXT across an ordered selection of versions
    /// (the net change from the oldest to the newest selected). "" for an empty
    /// / single selection or on failure.
    func cumulativeDiff(in selection: [VersionRef]) -> String
}

public extension VersionSource {
    var supportsRangeDiff: Bool { true }
}
