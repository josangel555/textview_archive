import Foundation

// MARK: - ReviewComment

/// A single comment anchored to a specific line range in a specific file.
/// Threads (replies) are flat: a top-level comment has `parentId == nil`,
/// replies point at the parent.
public struct ReviewComment: Codable, Equatable, Sendable, Identifiable {
    public let id: String                 // ULID-shaped
    public let parentId: String?          // nil for top-level

    /// Path relative to repoRoot, forward-slash, no leading "./".
    /// Matches what `DiffParser` produces.
    public let filePath: String

    /// Anchor — see anchor model below.
    public let anchor: LineAnchor

    public var severity: Severity
    public var body: String               // markdown

    public let createdAt: Date
    public var updatedAt: Date

    public var resolved: Bool

    /// Capture of the diff hunk this comment was placed in. Frozen at
    /// comment-creation; never re-derived. Used by the exporter so
    /// Claude Code has the surrounding context even if the file
    /// changes underneath us.
    public let hunkContext: HunkContext

    public enum Severity: String, Codable, Sendable, CaseIterable {
        case info        // FYI / nit / style preference
        case suggestion  // "consider doing X instead"
        case issue       // bug, correctness problem
        case blocker     // must-fix-before-merge
        case praise      // explicit positive callout
        case question    // I don't understand — please explain
    }

    public init(
        id: String,
        parentId: String? = nil,
        filePath: String,
        anchor: LineAnchor,
        severity: Severity,
        body: String,
        createdAt: Date,
        updatedAt: Date,
        resolved: Bool = false,
        hunkContext: HunkContext
    ) {
        self.id = id
        self.parentId = parentId
        self.filePath = filePath
        self.anchor = anchor
        self.severity = severity
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resolved = resolved
        self.hunkContext = hunkContext
    }
}

// MARK: - LineAnchor

/// Anchors a comment to one or more lines on the **new** or **old** side
/// of the diff. Comments on context lines anchor to both sides.
public struct LineAnchor: Codable, Equatable, Sendable {

    /// Which side of the diff the user clicked on.
    public enum Side: String, Codable, Sendable, CaseIterable {
        case old        // the "-" side — pre-change file content
        case new        // the "+" side — post-change file content
        case context    // a " " line — present on both sides
    }
    public let side: Side

    /// Line number on the anchored side. For multi-line selections,
    /// this is the start line; `endLine` is set.
    /// Line numbers are 1-based; match what DiffParser emits.
    public let startLine: Int
    public let endLine: Int                // == startLine for single-line

    /// SHA of the file's blob on the anchored side, at review creation.
    /// Lets us detect a stale anchor on reload.
    public let blobSha: String?

    public init(side: Side, startLine: Int, endLine: Int, blobSha: String? = nil) {
        // Caller invariants — `endLine >= startLine`, lines 1-based.
        // We don't precondition-trap here (would crash on corrupt disk
        // input); callers and tests assert.
        self.side = side
        self.startLine = startLine
        self.endLine = endLine
        self.blobSha = blobSha
    }
}

// MARK: - HunkContext

/// 3 lines before + the anchored line(s) + 3 lines after, frozen.
/// Embedded in every comment so the export is self-contained — the
/// receiver (Claude Code) can read context without re-running git.
///
/// Pre/post counts can be smaller than 3 when the anchor is near a
/// hunk boundary; the exporter contract says "up to 3, clipped to
/// the hunk".
public struct HunkContext: Codable, Equatable, Sendable {
    public let hunkHeader: String          // "@@ -10,5 +12,7 @@ func foo()"
    public let preLines: [DiffLine]        // up to 3 lines before
    public let anchoredLines: [DiffLine]   // the actual commented line(s)
    public let postLines: [DiffLine]       // up to 3 lines after

    public init(
        hunkHeader: String,
        preLines: [DiffLine],
        anchoredLines: [DiffLine],
        postLines: [DiffLine]
    ) {
        self.hunkHeader = hunkHeader
        self.preLines = preLines
        self.anchoredLines = anchoredLines
        self.postLines = postLines
    }
}

// MARK: - DiffLine

public struct DiffLine: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case context, added, removed
    }
    public let kind: Kind
    public let oldLineNo: Int?
    public let newLineNo: Int?
    public let content: String

    public init(kind: Kind, oldLineNo: Int?, newLineNo: Int?, content: String) {
        self.kind = kind
        self.oldLineNo = oldLineNo
        self.newLineNo = newLineNo
        self.content = content
    }
}
