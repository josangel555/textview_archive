import Foundation

// MARK: - ReviewImporter

/// The round-trip half of `ReviewExporter` (design §5.4, deferred until now).
///
/// `ReviewExporter` emits a self-contained `textview.code-review` JSON work
/// order whose `instructions` ask the agent to *"Re-emit the review JSON with
/// each comment marked `resolved=true` and a `response` field containing your
/// reply."* — but nothing ever read that reply back. `ReviewImporter` closes
/// the loop: it parses the agent's re-emitted JSON and merges its `resolved`
/// flips + `response` fields back into the live `Review`.
///
/// ## Matching strategy
///
/// The wire shape carries no internal comment IDs (deliberately — §5.2: "no
/// internal IDs / timestamps / blob SHAs — noise for the LLM"). So we match an
/// inbound `ExportComment` back to a model `ReviewComment` by its **stable
/// identity**: `(filePath, anchor.side, anchor.startLine, anchor.endLine)`.
/// That tuple is exactly what the exporter groups + sorts by and is invariant
/// across the round trip. Only **top-level** comments (`parentId == nil`) are
/// matched — replies are flattened into the parent's body on export, so they
/// have no independent wire identity to match against.
///
/// ## What the merge does
///
/// For each matched comment:
/// - `resolved` is set to the inbound value (lets the agent reopen as well as
///   close — idempotent).
/// - A non-blank `response` is appended as a **threaded reply** authored by the
///   agent, *unless that exact response text already exists as a reply* (so
///   re-importing the same JSON twice doesn't duplicate replies — idempotent).
///
/// Everything else (`severity`, `body`, anchors, hunk context, scope, repo) is
/// left untouched — the export is advisory feedback, not a model rewrite.
///
/// Pure `ViewerCore` logic: no SwiftUI / AppKit, no I/O. The caller owns
/// reading the JSON off the pasteboard / a file and persisting the result.
public enum ReviewImporter {

    /// Why an import was rejected outright (vs. partially applied).
    public enum ImportError: Error, Equatable, Sendable {
        /// The bytes weren't valid JSON, or didn't decode to the wire shape.
        case malformed(String)
        /// `kind` wasn't `"textview.code-review"`.
        case wrongKind(String)
        /// `schemaVersion` is newer than this build understands — refuse rather
        /// than silently mis-merge. Mirrors `ReviewStore`'s schema-too-new guard.
        case schemaTooNew(found: Int, supported: Int)
        /// The inbound review's `id` doesn't match the target review's `id`.
        /// Guards against pasting the wrong agent reply into the wrong review.
        case reviewIDMismatch(expected: String, found: String)
    }

    /// Outcome of a successful merge — what changed, so the UI can report
    /// "applied N of M" and flag comments the agent didn't address.
    public struct ImportResult: Equatable, Sendable {
        /// The review with `resolved` flips + agent replies merged in.
        public let review: Review
        /// Top-level comments whose inbound `resolved` flipped from the model.
        public let resolvedChanged: Int
        /// Agent replies actually appended (deduped — re-imports add nothing).
        public let repliesAdded: Int
        /// Inbound comments that matched a model comment.
        public let matched: Int
        /// Inbound comments with no matching model comment (agent invented a
        /// comment, or the anchor drifted) — surfaced, never silently dropped.
        public let unmatched: Int

        public init(
            review: Review,
            resolvedChanged: Int,
            repliesAdded: Int,
            matched: Int,
            unmatched: Int
        ) {
            self.review = review
            self.resolvedChanged = resolvedChanged
            self.repliesAdded = repliesAdded
            self.matched = matched
            self.unmatched = unmatched
        }

        /// True iff the merge changed nothing (no flips, no new replies).
        public var isNoOp: Bool { resolvedChanged == 0 && repliesAdded == 0 }
    }

    /// 10 MiB cap on inbound bytes — same untrusted-input ceiling
    /// `ReviewStore` enforces (design §9: the import surface is
    /// attacker-influenced once reviews live project-local).
    public static let maxImportBytes = 10 * 1024 * 1024

    /// Merge an agent's re-emitted review JSON back into `review`.
    ///
    /// - Parameters:
    ///   - data: the inbound JSON (agent's reply).
    ///   - review: the live review to merge into (not mutated; a new copy is
    ///     returned in the result).
    ///   - now: timestamp for any appended reply + the review's `updatedAt`
    ///     bump (parameterized for deterministic tests).
    ///   - replyIDFactory: ID generator for appended replies (parameterized
    ///     for deterministic tests; defaults to `ReviewID.generate`).
    /// - Returns: an `ImportResult` describing the merge.
    /// - Throws: `ImportError` if the payload is rejected outright.
    public static func merge(
        _ data: Data,
        into review: Review,
        now: Date = Date(),
        replyIDFactory: () -> String = { ReviewID.generate() }
    ) throws -> ImportResult {
        guard data.count <= maxImportBytes else {
            throw ImportError.malformed("payload exceeds \(maxImportBytes)-byte cap")
        }

        let dto: ImportDTO
        do {
            dto = try JSONFileStore.decoder.decode(ImportDTO.self, from: data)
        } catch {
            throw ImportError.malformed(String(describing: error))
        }

        guard dto.kind == "textview.code-review" else {
            throw ImportError.wrongKind(dto.kind)
        }
        guard dto.schemaVersion <= Review.currentSchema else {
            throw ImportError.schemaTooNew(found: dto.schemaVersion, supported: Review.currentSchema)
        }
        guard dto.review.id == review.id else {
            throw ImportError.reviewIDMismatch(expected: review.id, found: dto.review.id)
        }

        // Flatten the file-grouped wire shape to one keyed lookup. The agent
        // *should* echo every comment, but a partial reply is fine — we only
        // touch comments it actually mentions.
        var inbound: [CommentKey: ImportComment] = [:]
        for file in dto.files {
            for c in file.comments {
                inbound[CommentKey(filePath: file.path, anchor: c.anchor)] = c
            }
        }

        let agentAuthor = "\(review.author.name) ⟲ agent"

        var newComments: [ReviewComment] = []
        newComments.reserveCapacity(review.comments.count)

        var resolvedChanged = 0
        var repliesAdded = 0
        var matchedKeys = Set<CommentKey>()

        // Existing replies, grouped by parent, so we can dedupe agent responses.
        let repliesByParent = Dictionary(
            grouping: review.comments.filter { $0.parentId != nil },
            by: { $0.parentId! }
        )

        for comment in review.comments {
            // Only top-level comments carry wire identity; replies pass through.
            guard comment.parentId == nil else {
                newComments.append(comment)
                continue
            }

            let key = CommentKey(filePath: comment.filePath, anchor: comment.anchor)
            guard let incoming = inbound[key] else {
                newComments.append(comment)  // agent didn't mention this one
                continue
            }
            matchedKeys.insert(key)

            var updated = comment
            if updated.resolved != incoming.resolved {
                updated.resolved = incoming.resolved
                updated.updatedAt = now
                resolvedChanged += 1
            }
            newComments.append(updated)

            // Append the agent's response as a threaded reply, deduped on text.
            let responseText = incoming.response?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let responseText, !responseText.isEmpty {
                let existing = repliesByParent[comment.id] ?? []
                let alreadyPresent = existing.contains { $0.body == responseText }
                if !alreadyPresent {
                    let reply = ReviewComment(
                        id: replyIDFactory(),
                        parentId: comment.id,
                        filePath: comment.filePath,
                        commitSha: comment.commitSha,
                        anchor: comment.anchor,
                        severity: .info,
                        body: responseText,
                        createdAt: now,
                        updatedAt: now,
                        resolved: false,
                        hunkContext: comment.hunkContext
                    )
                    newComments.append(reply)
                    repliesAdded += 1
                }
            }
        }
        _ = agentAuthor  // reserved for a future author-tagged reply field

        let unmatched = inbound.keys.filter { !matchedKeys.contains($0) }.count

        var merged = review
        merged.comments = newComments
        if resolvedChanged > 0 || repliesAdded > 0 {
            merged.updatedAt = now
        }

        return ImportResult(
            review: merged,
            resolvedChanged: resolvedChanged,
            repliesAdded: repliesAdded,
            matched: matchedKeys.count,
            unmatched: unmatched
        )
    }

    /// Convenience overload taking a `String` (clipboard contents).
    public static func merge(
        _ string: String,
        into review: Review,
        now: Date = Date(),
        replyIDFactory: () -> String = { ReviewID.generate() }
    ) throws -> ImportResult {
        try merge(Data(string.utf8), into: review, now: now, replyIDFactory: replyIDFactory)
    }
}

// MARK: - Match key

/// Stable round-trip identity for a comment: file + anchor. This is exactly
/// the tuple the exporter groups + sorts by, so it survives the export → agent
/// → import journey even though internal IDs don't cross the wire.
private struct CommentKey: Hashable {
    let filePath: String
    let side: LineAnchor.Side
    let startLine: Int
    let endLine: Int

    init(filePath: String, anchor: LineAnchor) {
        self.filePath = filePath
        self.side = anchor.side
        self.startLine = anchor.startLine
        self.endLine = anchor.endLine
    }

    init(filePath: String, anchor: ImportAnchor) {
        self.filePath = filePath
        self.side = anchor.side
        self.startLine = anchor.startLine
        self.endLine = anchor.endLine
    }
}

// MARK: - Inbound wire DTOs
//
// A LENIENT mirror of `ReviewExporter`'s `ExportDTO` family. We deliberately
// decode our own structs rather than reuse `ExportDTO` so the import path can:
//   - accept the extra `response` field the agent adds (Export* doesn't carry it),
//   - tolerate missing fields the agent might drop (everything but the match key
//     + resolved is ignored on the way in),
//   - never couple the import contract to the exact wire-encode quirks
//     (custom nil-skipping encoders) of the export DTOs.
// Only the fields the merge needs are modeled; unknown keys are ignored by
// JSONDecoder.

private struct ImportDTO: Decodable {
    let kind: String
    let schemaVersion: Int
    let review: ImportReviewRef
    let files: [ImportFile]
}

private struct ImportReviewRef: Decodable {
    let id: String
}

private struct ImportFile: Decodable {
    let path: String
    let comments: [ImportComment]
}

private struct ImportComment: Decodable {
    let anchor: ImportAnchor
    let resolved: Bool
    /// The agent's reply, per `ReviewExporter.defaultInstructions`. Optional —
    /// a comment with no response just contributes a `resolved` flip.
    let response: String?
}

private struct ImportAnchor: Decodable {
    let side: LineAnchor.Side
    let startLine: Int
    let endLine: Int
}
