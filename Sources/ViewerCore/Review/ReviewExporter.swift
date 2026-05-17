import Foundation

// MARK: - ReviewExporter

/// Renders a `Review` to the on-the-wire JSON shape that gets pasted
/// into a Claude Code prompt. See §3 of CODE_REVIEW_DESIGN.md for the
/// contract. This is a **different shape** from the on-disk persistence:
///
/// - File-grouped, not flat.
/// - Each comment carries its hunk context inline (so Claude doesn't
///   need to re-run `git`).
/// - No internal IDs / timestamps / blob SHAs — noise for the LLM.
/// - Files with zero comments are dropped.
/// - Top-level `instructions` block — phrased once, not per-comment.
///
/// The DTOs live in this same file (private) so callers can't
/// accidentally take a dependency on the wire shape — they go through
/// `ReviewExporter.export(...)` and get `Data` back.
public enum ReviewExporter {

    /// Default instructions string. Editable in the export menu before
    /// emission; the design's recommended template.
    public static let defaultInstructions: String = """
    Please act on each comment in turn. For severity=blocker and \
    severity=issue, write the fix. For severity=suggestion, evaluate \
    and either apply or push back with reasoning. For severity=question, \
    answer in line. Re-emit the review JSON with each comment marked \
    resolved=true and a `response` field containing your reply.
    """

    /// Build the export DTO and encode it to pretty-printed JSON.
    /// `exportedAt` is parameterized so tests can pin it.
    public static func export(
        _ review: Review,
        instructions: String? = nil,
        exportedAt: Date = Date()
    ) throws -> Data {
        let dto = buildDTO(
            review,
            instructions: instructions ?? defaultInstructions,
            exportedAt: exportedAt
        )
        return try JSONFileStore.encoder.encode(dto)
    }

    /// Same as `export(...)` but returns a `String` for clipboard /
    /// preview use.
    public static func exportAsString(
        _ review: Review,
        instructions: String? = nil,
        exportedAt: Date = Date()
    ) throws -> String {
        let data = try export(review, instructions: instructions, exportedAt: exportedAt)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - DTO construction

    /// Internal entry point — exposed at file scope for tests.
    static func buildDTO(
        _ review: Review,
        instructions: String,
        exportedAt: Date
    ) -> ExportDTO {
        // Group comments by file path. Threaded replies (parentId != nil)
        // are flattened: the parent's body gets a "Thread:" suffix with
        // its replies, the reply itself is dropped.
        // v1 is single-author so replies are rare — but we honor the
        // contract from §3 of the design.
        let topLevel = review.comments.filter { $0.parentId == nil }
        let repliesByParent = Dictionary(
            grouping: review.comments.filter { $0.parentId != nil },
            by: { $0.parentId! }
        )

        // Sort: file path → anchor.startLine. §10 Q5 of the design.
        let sortedTopLevel = topLevel.sorted { lhs, rhs in
            if lhs.filePath != rhs.filePath { return lhs.filePath < rhs.filePath }
            return lhs.anchor.startLine < rhs.anchor.startLine
        }

        let grouped = Dictionary(grouping: sortedTopLevel, by: { $0.filePath })
        // Stable file order: sort keys lexicographically (matches the
        // within-group sort).
        let filePaths = grouped.keys.sorted()

        let files: [ExportFile] = filePaths.compactMap { path in
            guard let comments = grouped[path], !comments.isEmpty else {
                return nil  // §3: zero-comment files are omitted
            }
            let exportComments = comments.map { c in
                buildExportComment(c, replies: repliesByParent[c.id] ?? [])
            }
            return ExportFile(
                path: path,
                stats: buildFileStats(comments: comments),
                comments: exportComments
            )
        }

        let stats = buildReviewStats(review)
        let reviewDTO = ExportReview(
            id: review.id,
            title: review.title,
            description: review.description,
            state: review.state,
            scope: ExportScope(review.scope),
            repo: ExportRepo(
                root: review.repoRoot,
                baseSha: review.baseSha,
                headSha: review.headSha
            ),
            author: review.author,
            stats: stats
        )

        return ExportDTO(
            schemaVersion: Review.currentSchema,
            kind: "textview.code-review",
            exportedAt: exportedAt,
            review: reviewDTO,
            instructions: instructions,
            files: files
        )
    }

    private static func buildExportComment(
        _ c: ReviewComment,
        replies: [ReviewComment]
    ) -> ExportComment {
        let anchorRange = c.anchor.startLine...c.anchor.endLine
        let lines: [ExportContextLine] = (
            c.hunkContext.preLines
            + c.hunkContext.anchoredLines
            + c.hunkContext.postLines
        ).map { line in
            ExportContextLine(line: line, anchorRange: anchorRange, side: c.anchor.side)
        }

        // Flatten replies into a "Thread:" suffix on the body. v1 is
        // single-author so this rarely fires; future Claude-Code
        // responses arrive via re-import, not in the original export.
        let body: String
        if replies.isEmpty {
            body = c.body
        } else {
            let sortedReplies = replies.sorted { $0.createdAt < $1.createdAt }
            var s = c.body
            s += "\n\nThread:"
            for r in sortedReplies {
                s += "\n— \(r.body)"
            }
            body = s
        }

        return ExportComment(
            severity: c.severity,
            resolved: c.resolved,
            anchor: ExportAnchor(
                side: c.anchor.side,
                startLine: c.anchor.startLine,
                endLine: c.anchor.endLine
            ),
            body: body,
            context: ExportHunkContext(
                hunkHeader: c.hunkContext.hunkHeader,
                lines: lines
            )
        )
    }

    private static func buildFileStats(comments: [ReviewComment]) -> ExportFileStats {
        // Aggregate from the comments' hunk contexts. We tally lines
        // by `kind` across every line we have on hand for this file.
        // This is a coarse stat — not the *true* `+N −M` of the diff,
        // but the diff isn't in scope at export time (we could load it,
        // but persistence is the source of truth here).
        var added = 0
        var removed = 0
        for c in comments {
            for line in c.hunkContext.preLines + c.hunkContext.anchoredLines + c.hunkContext.postLines {
                switch line.kind {
                case .added:   added += 1
                case .removed: removed += 1
                case .context: break
                }
            }
        }
        return ExportFileStats(added: added, removed: removed)
    }

    private static func buildReviewStats(_ review: Review) -> ExportStats {
        // §3: comment counts here are top-level only. Replies are
        // folded into their parents in the wire output.
        let topLevel = review.comments.filter { $0.parentId == nil }
        var bySeverity: [ReviewComment.Severity: Int] = [:]
        for sev in ReviewComment.Severity.allCases { bySeverity[sev] = 0 }
        for c in topLevel { bySeverity[c.severity, default: 0] += 1 }
        let unresolved = topLevel.filter { !$0.resolved }.count
        let fileCount = Set(topLevel.map(\.filePath)).count

        return ExportStats(
            fileCount: fileCount,
            commentCount: topLevel.count,
            bySeverity: ExportSeverityBreakdown(
                blocker:    bySeverity[.blocker]    ?? 0,
                issue:      bySeverity[.issue]      ?? 0,
                suggestion: bySeverity[.suggestion] ?? 0,
                info:       bySeverity[.info]       ?? 0,
                question:   bySeverity[.question]   ?? 0,
                praise:     bySeverity[.praise]     ?? 0
            ),
            unresolved: unresolved
        )
    }
}

// MARK: - Wire DTOs
//
// These are intentionally `internal` (not `public`) — callers go
// through `ReviewExporter.export(...)`. Keeping the wire shape
// non-public means we can evolve it without breaking compile-time
// callers in the UI / app layers. Tests in the same module can
// still introspect by re-decoding the JSON.

struct ExportDTO: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let kind: String
    let exportedAt: Date
    let review: ExportReview
    let instructions: String
    let files: [ExportFile]
}

struct ExportReview: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let description: String?
    let state: ReviewState
    let scope: ExportScope
    let repo: ExportRepo
    let author: ReviewAuthor
    let stats: ExportStats
}

/// Export-flavored scope. Same content as `ReviewScope` but encoded
/// with all keys flat under the same object (matching the example in
/// §3 of the design rather than re-using the persistence Codable).
struct ExportScope: Codable, Equatable, Sendable {
    let kind: String
    let base: String?
    let sha: String?
    let from: String?
    let to: String?
    let branch: String?

    init(_ scope: ReviewScope) {
        switch scope {
        case .workingTree(let base):
            self.kind = "workingTree"
            self.base = base
            self.sha = nil; self.from = nil; self.to = nil; self.branch = nil
        case .commit(let sha):
            self.kind = "commit"
            self.sha = sha
            self.base = nil; self.from = nil; self.to = nil; self.branch = nil
        case .range(let from, let to):
            self.kind = "range"
            self.from = from; self.to = to
            self.base = nil; self.sha = nil; self.branch = nil
        case .branch(let branch, let base):
            self.kind = "branch"
            self.branch = branch; self.base = base
            self.sha = nil; self.from = nil; self.to = nil
        }
    }

    /// JSONEncoder with `.sortedKeys` plus our nil-skipping behavior:
    /// emit only the keys relevant to the active kind. Otherwise the
    /// export gets cluttered with `"sha": null` etc.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try c.encode(kind, forKey: .init("kind"))
        if let v = base   { try c.encode(v, forKey: .init("base")) }
        if let v = sha    { try c.encode(v, forKey: .init("sha")) }
        if let v = from   { try c.encode(v, forKey: .init("from")) }
        if let v = to     { try c.encode(v, forKey: .init("to")) }
        if let v = branch { try c.encode(v, forKey: .init("branch")) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        self.kind = try c.decode(String.self, forKey: .init("kind"))
        self.base   = try c.decodeIfPresent(String.self, forKey: .init("base"))
        self.sha    = try c.decodeIfPresent(String.self, forKey: .init("sha"))
        self.from   = try c.decodeIfPresent(String.self, forKey: .init("from"))
        self.to     = try c.decodeIfPresent(String.self, forKey: .init("to"))
        self.branch = try c.decodeIfPresent(String.self, forKey: .init("branch"))
    }
}

struct ExportRepo: Codable, Equatable, Sendable {
    let root: String
    let baseSha: String?
    let headSha: String?

    // Force `baseSha` / `headSha` to emit even when nil — the design's
    // §3 example shows them as `null` for the working-tree scope, and
    // Claude Code reads them to know whether comments are on
    // uncommitted work. Default Codable synthesis drops nil optionals.
    private enum CodingKeys: String, CodingKey { case root, baseSha, headSha }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(root, forKey: .root)
        try c.encode(baseSha, forKey: .baseSha)  // emits null if nil
        try c.encode(headSha, forKey: .headSha)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.root    = try c.decode(String.self, forKey: .root)
        self.baseSha = try c.decodeIfPresent(String.self, forKey: .baseSha)
        self.headSha = try c.decodeIfPresent(String.self, forKey: .headSha)
    }

    init(root: String, baseSha: String?, headSha: String?) {
        self.root = root
        self.baseSha = baseSha
        self.headSha = headSha
    }
}

struct ExportStats: Codable, Equatable, Sendable {
    let fileCount: Int
    let commentCount: Int
    let bySeverity: ExportSeverityBreakdown
    let unresolved: Int
}

struct ExportSeverityBreakdown: Codable, Equatable, Sendable {
    let blocker: Int
    let issue: Int
    let suggestion: Int
    let info: Int
    let question: Int
    let praise: Int
}

struct ExportFile: Codable, Equatable, Sendable {
    let path: String
    let stats: ExportFileStats
    let comments: [ExportComment]
}

struct ExportFileStats: Codable, Equatable, Sendable {
    let added: Int
    let removed: Int
}

struct ExportComment: Codable, Equatable, Sendable {
    let severity: ReviewComment.Severity
    let resolved: Bool
    let anchor: ExportAnchor
    let body: String
    let context: ExportHunkContext
}

struct ExportAnchor: Codable, Equatable, Sendable {
    let side: LineAnchor.Side
    let startLine: Int
    let endLine: Int
}

struct ExportHunkContext: Codable, Equatable, Sendable {
    let hunkHeader: String
    let lines: [ExportContextLine]
}

/// One row inside `context.lines`. Maps `DiffLine.kind` to wire
/// vocabulary, includes `anchored: true` only on lines inside the
/// anchor range. We custom-encode so `anchored: false` is omitted
/// for the non-anchored rows — matches the design example shape.
struct ExportContextLine: Codable, Equatable, Sendable {
    let kind: String       // "context" | "added" | "removed"
    let old: Int?
    let new: Int?
    let text: String
    let anchored: Bool

    init(line: DiffLine, anchorRange: ClosedRange<Int>, side: LineAnchor.Side) {
        self.kind = line.kind.rawValue
        self.old = line.oldLineNo
        self.new = line.newLineNo
        self.text = line.content
        // A line is "anchored" if its line-number on the anchored
        // side falls in the comment's range. `.context` anchors
        // match either side because the line is on both.
        let n: Int?
        switch side {
        case .old:     n = line.oldLineNo
        case .new:     n = line.newLineNo
        case .context: n = line.newLineNo ?? line.oldLineNo
        }
        self.anchored = n.map { anchorRange.contains($0) } ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        try c.encode(kind, forKey: .init("kind"))
        try c.encode(old,  forKey: .init("old"))   // nil → null, matches design example
        try c.encode(new,  forKey: .init("new"))
        try c.encode(text, forKey: .init("text"))
        if anchored {
            try c.encode(true, forKey: .init("anchored"))
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        self.kind = try c.decode(String.self, forKey: .init("kind"))
        self.old  = try c.decodeIfPresent(Int.self, forKey: .init("old"))
        self.new  = try c.decodeIfPresent(Int.self, forKey: .init("new"))
        self.text = try c.decode(String.self, forKey: .init("text"))
        self.anchored = (try? c.decodeIfPresent(Bool.self, forKey: .init("anchored"))) ?? false
    }
}

// MARK: - DynamicKey

/// String-keyed CodingKey for the custom encoders above. Stdlib has
/// no public concrete `CodingKey` impl so each module rolls its own.
private struct DynamicKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { self.stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
