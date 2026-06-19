import Foundation

// MARK: - ReviewQAContext
//
// TSK-318 — "Ask-the-agent about a Code Review" (CR Q&A), FOUNDATION SLICE.
//
// A pure, SwiftUI/AppKit-free context assembler. Given a `Review` + a free-text
// question + a byte budget, it builds the structured payload an agent needs to
// answer questions about the review: the review's identity, each top-level
// comment's anchored hunk text, file paths, severities, and the question.
//
// What this is NOT (deliberately deferred to a later slice):
//   • the agent transport (no networking, no MCP, no Claude Code handoff).
//   • the UI (no view, no observable). This is the model the wiring binds to.
//
// Two properties the host tests pin (the contract):
//   1. DETERMINISTIC ORDER — given the same review + question, the assembled
//      context is byte-for-byte identical. Comments are ordered by file path →
//      anchor start line → comment id (a total order; ids are ULID-unique).
//   2. SIZE-BOUNDED with PRIORITY-AWARE TRUNCATION — when the serialized
//      payload would exceed `byteBudget`, the LOWEST-PRIORITY comments are
//      dropped FIRST (blocker kept longest, praise dropped first), and the
//      payload records how many were dropped so the agent knows it's partial.

public struct ReviewQAContext: Equatable, Sendable {

    // MARK: Inputs / metadata

    /// The user's question to the agent. Free text, verbatim.
    public let question: String

    /// Review identity — enough for the agent to scope its answer without the
    /// full persistence shape (no internal blob SHAs / timestamps).
    public let reviewID: String
    public let reviewTitle: String
    public let reviewDescription: String?
    public let scopeSummary: String       // human-readable, e.g. "branch feat/x vs main"
    public let repoRoot: String

    // MARK: Assembled body

    /// Top-level comments included in the context, in deterministic order,
    /// after any budget-driven truncation. Replies are flattened onto their
    /// parent (matching the exporter contract).
    public let comments: [Item]

    /// How many top-level comments were DROPPED to fit the byte budget. 0 when
    /// the whole review fit. Non-zero ⇒ the context is partial; lowest-priority
    /// comments went first.
    public let droppedCommentCount: Int

    /// Serialized size (UTF-8 bytes) of this context's JSON payload. Always
    /// `<= byteBudget` for the budget it was built with.
    public let byteSize: Int

    // MARK: - Item

    /// One comment's worth of context, self-contained for the agent.
    public struct Item: Equatable, Sendable {
        public let commentID: String
        public let filePath: String
        public let severity: ReviewComment.Severity
        public let resolved: Bool
        public let anchor: Anchor
        public let body: String
        /// The frozen hunk: header + reconstructed diff text (pre + anchored +
        /// post lines), each prefixed with its diff marker (` `/`+`/`-`).
        public let hunkHeader: String
        public let hunkText: String

        public struct Anchor: Equatable, Sendable {
            public let side: LineAnchor.Side
            public let startLine: Int
            public let endLine: Int

            public init(side: LineAnchor.Side, startLine: Int, endLine: Int) {
                self.side = side
                self.startLine = startLine
                self.endLine = endLine
            }
        }

        public init(
            commentID: String,
            filePath: String,
            severity: ReviewComment.Severity,
            resolved: Bool,
            anchor: Anchor,
            body: String,
            hunkHeader: String,
            hunkText: String
        ) {
            self.commentID = commentID
            self.filePath = filePath
            self.severity = severity
            self.resolved = resolved
            self.anchor = anchor
            self.body = body
            self.hunkHeader = hunkHeader
            self.hunkText = hunkText
        }
    }

    // MARK: - Priority

    /// Drop order is driven by severity priority: HIGHER stays longer.
    /// Blocker > issue > suggestion > question > info > praise. Matches the
    /// "act on blockers/issues first" framing of the exporter instructions.
    /// (A larger number = higher priority = kept longer.)
    public static func priority(of severity: ReviewComment.Severity) -> Int {
        switch severity {
        case .blocker:    return 5
        case .issue:      return 4
        case .suggestion: return 3
        case .question:   return 2
        case .info:       return 1
        case .praise:     return 0
        }
    }

    // MARK: - Build

    /// Default budget — generous enough for a typical review, tight enough to
    /// keep a pathological one from blowing an agent's context window. Callers
    /// override per transport. 256 KiB.
    public static let defaultByteBudget = 256 * 1024

    /// Assemble the Q&A context for `review` + `question`, bounded to
    /// `byteBudget` UTF-8 bytes of serialized payload.
    ///
    /// Algorithm:
    ///   1. Flatten replies onto their parents; map each top-level comment to
    ///      an `Item` (file path, severity, anchor, body, frozen hunk text).
    ///   2. Order deterministically: file path → start line → comment id.
    ///   3. If the full payload exceeds the budget, drop comments LOWEST-
    ///      PRIORITY first (severity asc, then REVERSE display order as the
    ///      tie-break, so a drop is reproducible) until it fits — but the
    ///      RETAINED comments stay in display order. Record the drop count.
    ///
    /// The budget governs the comment body; the fixed metadata (question,
    /// review identity) is always included. If even the metadata-only payload
    /// exceeds the budget, all comments are dropped (count == total) — we never
    /// silently truncate the question itself.
    public static func build(
        review: Review,
        question: String,
        byteBudget: Int = defaultByteBudget
    ) -> ReviewQAContext {
        // (1) Flatten replies → parent bodies (exporter contract).
        let topLevel = review.comments.filter { $0.parentId == nil }
        let repliesByParent = Dictionary(
            grouping: review.comments.filter { $0.parentId != nil },
            by: { $0.parentId! }
        )

        // (2) Deterministic display order: file path → start line → id.
        let ordered = topLevel.sorted(by: Self.displayOrder)
        let allItems = ordered.map { c in
            makeItem(c, replies: repliesByParent[c.id] ?? [])
        }

        // (3) Truncate to budget, lowest-priority first.
        let (kept, dropped) = truncate(
            allItems,
            comments: ordered,
            question: question,
            review: review,
            byteBudget: byteBudget
        )

        let size = serializedSize(
            review: review, question: question, items: kept, dropped: dropped
        )

        return ReviewQAContext(
            question: question,
            reviewID: review.id,
            reviewTitle: review.title,
            reviewDescription: review.description,
            scopeSummary: scopeSummary(review.scope),
            repoRoot: review.repoRoot,
            comments: kept,
            droppedCommentCount: dropped,
            byteSize: size
        )
    }

    // MARK: - Ordering

    /// Total order over top-level comments: file path → start line → id.
    /// `id` (ULID, unique) makes this a TOTAL order — never relies on the
    /// input array's incidental order, so the result is reproducible.
    static func displayOrder(_ lhs: ReviewComment, _ rhs: ReviewComment) -> Bool {
        if lhs.filePath != rhs.filePath { return lhs.filePath < rhs.filePath }
        if lhs.anchor.startLine != rhs.anchor.startLine {
            return lhs.anchor.startLine < rhs.anchor.startLine
        }
        return lhs.id < rhs.id
    }

    // MARK: - Item construction

    private static func makeItem(_ c: ReviewComment, replies: [ReviewComment]) -> Item {
        let body: String
        if replies.isEmpty {
            body = c.body
        } else {
            let sorted = replies.sorted { $0.createdAt < $1.createdAt }
            var s = c.body + "\n\nThread:"
            for r in sorted { s += "\n— \(r.body)" }
            body = s
        }
        return Item(
            commentID: c.id,
            filePath: c.filePath,
            severity: c.severity,
            resolved: c.resolved,
            anchor: Item.Anchor(
                side: c.anchor.side,
                startLine: c.anchor.startLine,
                endLine: c.anchor.endLine
            ),
            body: body,
            hunkHeader: c.hunkContext.hunkHeader,
            hunkText: hunkText(c.hunkContext)
        )
    }

    /// Render the frozen hunk to a single diff-marker-prefixed string:
    /// pre + anchored + post lines, in order. Empty when the hunk has no lines.
    static func hunkText(_ ctx: HunkContext) -> String {
        let lines = ctx.preLines + ctx.anchoredLines + ctx.postLines
        return lines.map { line -> String in
            let marker: String
            switch line.kind {
            case .context: marker = " "
            case .added:   marker = "+"
            case .removed: marker = "-"
            }
            return marker + line.content
        }.joined(separator: "\n")
    }

    // MARK: - Truncation

    /// Returns the kept items (in display order) + the count dropped.
    private static func truncate(
        _ items: [Item],
        comments ordered: [ReviewComment],
        question: String,
        review: Review,
        byteBudget: Int
    ) -> (kept: [Item], dropped: Int) {
        // Fast path: the whole thing fits.
        let fullSize = serializedSize(
            review: review, question: question, items: items, dropped: 0
        )
        if fullSize <= byteBudget { return (items, 0) }

        // We need to shed comments. Build a drop ORDER: lowest priority first;
        // tie-break by REVERSE display order (the visually-last lowest-priority
        // comment goes first) so the drop is deterministic and stable.
        // Pair each item with its display index so we can restore order.
        let indexed = Array(items.enumerated())   // (displayIndex, item)
        let dropOrder = indexed.sorted { a, b in
            let pa = priority(of: a.element.severity)
            let pb = priority(of: b.element.severity)
            if pa != pb { return pa < pb }            // lower priority dropped first
            return a.offset > b.offset                // then later-in-display first
        }

        // Greedily drop from the front of `dropOrder` until the remaining set
        // fits the budget (or nothing is left).
        var droppedIndices = Set<Int>()
        for entry in dropOrder {
            let remaining = indexed
                .filter { !droppedIndices.contains($0.offset) }
                .map(\.element)
            let size = serializedSize(
                review: review,
                question: question,
                items: remaining,
                dropped: droppedIndices.count
            )
            if size <= byteBudget { break }
            droppedIndices.insert(entry.offset)
        }

        let kept = indexed
            .filter { !droppedIndices.contains($0.offset) }
            .map(\.element)
        return (kept, droppedIndices.count)
    }

    // MARK: - Serialization (size + payload)

    /// The serialized JSON representation. Deterministic (sorted keys) — used
    /// both for the size budget and as the actual payload a transport sends.
    public func serialized() -> Data {
        let dto = Self.dto(
            question: question,
            reviewID: reviewID,
            reviewTitle: reviewTitle,
            reviewDescription: reviewDescription,
            scopeSummary: scopeSummary,
            repoRoot: repoRoot,
            items: comments,
            dropped: droppedCommentCount
        )
        // Force-try is safe: the DTO is a finite tree of String/Int/Bool — it
        // cannot fail to encode. A throw here would be a programmer error.
        return (try? Self.encoder.encode(dto)) ?? Data()
    }

    /// String form of `serialized()`, for clipboard / preview / a prompt body.
    public func serializedString() -> String {
        String(decoding: serialized(), as: UTF8.self)
    }

    /// Byte size of the payload for a given (items, dropped) selection, without
    /// constructing a full `ReviewQAContext`. Drives the budget loop.
    private static func serializedSize(
        review: Review,
        question: String,
        items: [Item],
        dropped: Int
    ) -> Int {
        let dto = dto(
            question: question,
            reviewID: review.id,
            reviewTitle: review.title,
            reviewDescription: review.description,
            scopeSummary: scopeSummary(review.scope),
            repoRoot: review.repoRoot,
            items: items,
            dropped: dropped
        )
        return ((try? encoder.encode(dto)) ?? Data()).count
    }

    private static func dto(
        question: String,
        reviewID: String,
        reviewTitle: String,
        reviewDescription: String?,
        scopeSummary: String,
        repoRoot: String,
        items: [Item],
        dropped: Int
    ) -> QADTO {
        QADTO(
            kind: "textview.review-qa",
            schemaVersion: Review.currentSchema,
            question: question,
            review: QAReviewDTO(
                id: reviewID,
                title: reviewTitle,
                description: reviewDescription,
                scope: scopeSummary,
                repoRoot: repoRoot
            ),
            comments: items.map { i in
                QACommentDTO(
                    id: i.commentID,
                    file: i.filePath,
                    severity: i.severity.rawValue,
                    resolved: i.resolved,
                    side: i.anchor.side.rawValue,
                    startLine: i.anchor.startLine,
                    endLine: i.anchor.endLine,
                    body: i.body,
                    hunkHeader: i.hunkHeader,
                    hunk: i.hunkText
                )
            },
            droppedCommentCount: dropped
        )
    }

    /// Deterministic encoder: sorted keys + ISO-8601 (no dates here, but keep
    /// it consistent with the rest of the persistence layer).
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    // MARK: - Scope summary

    /// Human-readable, agent-friendly one-liner for the review scope.
    static func scopeSummary(_ scope: ReviewScope) -> String {
        switch scope {
        case .workingTree(let base):    return "working tree vs \(base)"
        case .commit(let sha):          return "commit \(sha)"
        case .range(let from, let to):  return "range \(from)..\(to)"
        case .branch(let branch, let base): return "branch \(branch) vs \(base)"
        }
    }

    // MARK: - Designated init (kept internal-friendly; public for callers/tests)

    public init(
        question: String,
        reviewID: String,
        reviewTitle: String,
        reviewDescription: String?,
        scopeSummary: String,
        repoRoot: String,
        comments: [Item],
        droppedCommentCount: Int,
        byteSize: Int
    ) {
        self.question = question
        self.reviewID = reviewID
        self.reviewTitle = reviewTitle
        self.reviewDescription = reviewDescription
        self.scopeSummary = scopeSummary
        self.repoRoot = repoRoot
        self.comments = comments
        self.droppedCommentCount = droppedCommentCount
        self.byteSize = byteSize
    }
}

// MARK: - Wire DTOs (private to the serialization path)
//
// Intentionally non-public — callers build a `ReviewQAContext` and serialize
// through it, so the wire shape can evolve without breaking compile-time deps.

private struct QADTO: Codable {
    let kind: String
    let schemaVersion: Int
    let question: String
    let review: QAReviewDTO
    let comments: [QACommentDTO]
    let droppedCommentCount: Int
}

private struct QAReviewDTO: Codable {
    let id: String
    let title: String
    let description: String?
    let scope: String
    let repoRoot: String
}

private struct QACommentDTO: Codable {
    let id: String
    let file: String
    let severity: String
    let resolved: Bool
    let side: String
    let startLine: Int
    let endLine: Int
    let body: String
    let hunkHeader: String
    let hunk: String
}
