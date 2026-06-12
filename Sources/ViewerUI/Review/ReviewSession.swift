import Foundation
import SwiftUI
import ViewerCore

// MARK: - ReviewSession
//
// v2 §6.1: the observable runtime the review views bind to. Wraps a `Review`
// (the SwiftUI-free ViewerCore aggregate), caches the parsed diff, owns the
// §3.1 capture pipeline + the §3.2 derived staleness map, and persists every
// mutation to a project-local `ReviewStore` via a debounced serial write
// queue (the `SessionStore` pattern) so a typing/drag storm collapses to one
// disk write.
//
// `ViewerCore` stays SwiftUI/AppKit-free — this observable lives in `ViewerUI`.

@MainActor
public final class ReviewSession: ObservableObject {

    /// The review aggregate. `private(set)` so only the typed mutators below
    /// can change it (each one bumps `updatedAt` + enqueues a save).
    @Published public private(set) var review: Review

    /// Parsed diff for the review's scope, keyed by file path (newPath, the
    /// post-change path DiffParser emits). Parsed ONCE at init / `reload()`,
    /// not per body-eval — same lesson `DiffView` encodes.
    @Published public private(set) var diffFiles: [UnifiedDiff.File] = []

    /// Derived staleness per comment id (§3.2). Recomputed on `reload()` and
    /// on demand; never stored on the model.
    @Published public private(set) var anchorStates: [String: AnchorState] = [:]

    /// The project-local store this session persists through.
    private let store: ReviewStore

    /// Git client for the repo, used for capture (blob SHAs) + diff. Optional
    /// so tests can construct a session without a live repo (capture then
    /// records `blobSha: nil` → staleness degrades to `.unknown`).
    private let git: GitClient?

    /// Clock seam so tests pin timestamps.
    private let now: @Sendable () -> Date

    public init(
        review: Review,
        store: ReviewStore,
        git: GitClient? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.review = review
        self.store = store
        self.git = git
        self.now = now
    }

    // MARK: - Lifecycle

    /// Load (or reload) the scope's diff + recompute the staleness map.
    /// Synchronous on the main actor — diff parse + a handful of `git`
    /// blob-hash calls. Callers fire this on appear / on a manual refresh.
    public func reload() {
        if let git {
            // `.commit` returns a full multi-file diff; the per-path modes
            // return a single file. Parse whatever we get and key by newPath.
            // We diff each commented file's path for the per-path scopes;
            // for `.commit` one call covers everything.
            diffFiles = parseDiffForScope(git: git)
        }
        recomputeAnchorStates()
    }

    private func parseDiffForScope(git: GitClient) -> [UnifiedDiff.File] {
        switch review.scope {
        case .commit:
            // One `git show` → all files.
            return RustDiffAdapter.parse(git.diff(scope: review.scope, path: ""))
        case .workingTree, .range, .branch:
            // Per-path modes: union the diffs of every path we have a comment
            // on (plus, if none yet, nothing — the view drives path selection
            // for fresh reviews via a separate file picker, out of scope here).
            let paths = Set(review.comments.map(\.filePath))
            var files: [UnifiedDiff.File] = []
            for path in paths.sorted() {
                files.append(contentsOf: RustDiffAdapter.parse(git.diff(scope: review.scope, path: path)))
            }
            return files
        }
    }

    /// Recompute `anchorStates` for every comment against the live blob on
    /// its anchored side. No-op staleness (`.unknown`) when there's no git.
    public func recomputeAnchorStates() {
        var map: [String: AnchorState] = [:]
        for c in review.comments {
            let live = liveBlobSha(for: c)
            map[c.id] = AnchorState.evaluate(anchor: c.anchor, liveBlobSha: live)
        }
        anchorStates = map
    }

    /// Resolve the live blob SHA for a comment's anchored side, matching the
    /// capture rule (§3.1): committed side → `rev-parse <rev>:<path>`,
    /// working-tree side → `hash-object`.
    private func liveBlobSha(for comment: ReviewComment) -> String? {
        guard let git else { return nil }
        return liveBlobSha(git: git, side: comment.anchor.side, path: comment.filePath)
    }

    private func liveBlobSha(git: GitClient, side: LineAnchor.Side, path: String) -> String? {
        // The "live" content depends on the scope's head:
        //   • working-tree (headSha == nil): the new/context side is the
        //     working-tree file (hash-object); the old side is the base rev.
        //   • committed scopes: both sides resolve via rev-parse against the
        //     frozen base/head SHAs.
        switch side {
        case .new, .context:
            if let head = review.headSha {
                return git.blobSha(rev: head, path: path)
            }
            return git.blobShaForWorktree(path: path)
        case .old:
            if let base = review.baseSha {
                return git.blobSha(rev: base, path: path)
            }
            return git.blobShaForWorktree(path: path)
        }
    }

    // MARK: - Capture (§3.1)

    /// Build a frozen `LineAnchor` + `HunkContext` for a new comment from a
    /// parsed hunk + the selected side/range. Returns `nil` if the anchor
    /// doesn't intersect the hunk (caller bug) so we never store bogus
    /// context. The `blobSha` is resolved here at creation and frozen.
    public func capture(
        file: UnifiedDiff.File,
        hunk: UnifiedDiff.Hunk,
        side: LineAnchor.Side,
        range: ClosedRange<Int>
    ) -> (anchor: LineAnchor, context: HunkContext)? {
        guard let context = HunkContextCapture.capture(hunk: hunk, side: side, range: range) else {
            return nil
        }
        let blob: String?
        if let git {
            blob = liveBlobSha(git: git, side: side, path: file.newPath)
        } else {
            blob = nil
        }
        let anchor = LineAnchor(
            side: side, startLine: range.lowerBound, endLine: range.upperBound, blobSha: blob
        )
        return (anchor, context)
    }

    // MARK: - Mutations
    //
    // Each mutator: applies a pure transform to `review`, bumps `updatedAt`,
    // auto-promotes draft→inReview on first comment, and enqueues a debounced
    // save. State transitions go through `ReviewState.canTransition`.

    /// Add a top-level comment. Returns the created comment's id.
    @discardableResult
    public func addComment(
        filePath: String,
        anchor: LineAnchor,
        severity: ReviewComment.Severity,
        body: String,
        hunkContext: HunkContext
    ) -> String {
        let ts = now()
        // TSK-523: a comment left on a commit-scoped review is anchored to
        // that commit — stamp it so `CommitDiffAnchor` can partition and
        // staleness-bridge commit-diff comments. File-scoped reviews keep nil.
        let commitSha: String?
        if case .commit(let sha) = review.scope { commitSha = sha } else { commitSha = nil }
        let comment = ReviewComment(
            id: ReviewID.generate(now: ts),
            filePath: filePath,
            commitSha: commitSha,
            anchor: anchor,
            severity: severity,
            body: body,
            createdAt: ts,
            updatedAt: ts,
            hunkContext: hunkContext
        )
        var r = review
        r.comments.append(comment)
        // First comment auto-promotes draft → inReview.
        if r.state == .draft, r.state.canTransition(to: .inReview) {
            r.state = .inReview
        }
        r.updatedAt = ts
        apply(r)
        anchorStates[comment.id] = AnchorState.evaluate(
            anchor: anchor, liveBlobSha: liveBlobSha(for: comment)
        )
        return comment.id
    }

    /// Add a reply to an existing comment (thread).
    @discardableResult
    public func addReply(
        to parentId: String,
        severity: ReviewComment.Severity = .info,
        body: String
    ) -> String? {
        guard let parent = review.comments.first(where: { $0.id == parentId }) else { return nil }
        let ts = now()
        let reply = ReviewComment(
            id: ReviewID.generate(now: ts),
            parentId: parentId,
            filePath: parent.filePath,
            anchor: parent.anchor,
            severity: severity,
            body: body,
            createdAt: ts,
            updatedAt: ts,
            hunkContext: parent.hunkContext
        )
        var r = review
        r.comments.append(reply)
        r.updatedAt = ts
        apply(r)
        return reply.id
    }

    /// Edit a comment's body and/or severity. No-op if id not found.
    public func updateComment(
        id: String,
        body: String? = nil,
        severity: ReviewComment.Severity? = nil
    ) {
        guard let idx = review.comments.firstIndex(where: { $0.id == id }) else { return }
        var r = review
        if let body { r.comments[idx].body = body }
        if let severity { r.comments[idx].severity = severity }
        r.comments[idx].updatedAt = now()
        r.updatedAt = now()
        apply(r)
    }

    /// Mark a comment resolved / reopened.
    public func setResolved(id: String, _ resolved: Bool) {
        guard let idx = review.comments.firstIndex(where: { $0.id == id }) else { return }
        guard review.comments[idx].resolved != resolved else { return }
        var r = review
        r.comments[idx].resolved = resolved
        r.comments[idx].updatedAt = now()
        r.updatedAt = now()
        apply(r)
    }

    /// Delete a comment AND its replies (a thread is deleted as a unit).
    public func delete(id: String) {
        guard review.comments.contains(where: { $0.id == id }) else { return }
        var r = review
        r.comments.removeAll { $0.id == id || $0.parentId == id }
        r.updatedAt = now()
        apply(r)
        anchorStates[id] = nil
    }

    /// Transition the review's lifecycle state. Returns `false` (no-op) if
    /// the transition is illegal per `ReviewState.canTransition` — never
    /// crashes on a bad ask.
    @discardableResult
    public func setState(_ next: ReviewState) -> Bool {
        guard review.state.canTransition(to: next) else { return false }
        guard review.state != next else { return true }   // idempotent, no write
        var r = review
        r.state = next
        r.updatedAt = now()
        apply(r)
        return true
    }

    /// Append an export record (called by the export flow) and transition to
    /// `.sent` when allowed. Returns the appended record.
    @discardableResult
    public func recordExport(
        target: ReviewExportRecord.Target,
        destination: String?
    ) -> ReviewExportRecord {
        let ts = now()
        let record = ReviewExportRecord(
            target: target,
            at: ts,
            destination: destination,
            commentCount: review.comments.filter { $0.parentId == nil }.count
        )
        var r = review
        r.exports.append(record)
        if r.state.canTransition(to: .sent) { r.state = .sent }
        r.updatedAt = ts
        apply(r)
        return record
    }

    // MARK: - Apply + debounced persistence

    /// Swap in a new review value (publishing the change) and enqueue a
    /// debounced save. The single funnel for every mutation above.
    private func apply(_ newReview: Review) {
        review = newReview
        enqueueSave(newReview)
    }

    /// Block until any pending debounced save has flushed to disk. For
    /// `applicationWillTerminate` and for tests that assert post-write state.
    public func flush() {
        Self.flushSync(store: store, id: review.id)
    }

    // MARK: - Debounced write queue (SessionStore pattern, scoped to reviews)

    private func enqueueSave(_ review: Review) {
        Self.enqueue(review, store: store)
    }

    private static let writeQueue = DispatchQueue(
        label: "com.markdownviewer.ReviewSession.writes",
        qos: .utility
    )
    nonisolated(unsafe) private static var pending: [String: (store: ReviewStore, review: Review)] = [:]
    // `nonisolated(unsafe)` (matching `pending`): the lock guards the off-main
    // `writeQueue` closures, so it must be reachable from a Sendable context.
    // NSLock is itself thread-safe; the stricter VM toolchain (Swift 6.1.2)
    // otherwise rejects referencing a main-actor static from those closures
    // (TSK-401 default-isolation skew vs the host).
    nonisolated(unsafe) private static let coalesceLock = NSLock()

    /// Coalesce by review id: a burst of edits to the same review collapses
    /// to one disk write (newer value wins). Ordering is preserved by the
    /// serial queue.
    private static func enqueue(_ review: Review, store: ReviewStore) {
        coalesceLock.lock()
        let key = review.id
        let alreadyPending = pending[key] != nil
        pending[key] = (store, review)
        coalesceLock.unlock()
        guard !alreadyPending else { return }
        writeQueue.async {
            coalesceLock.lock()
            let snapshot = pending.removeValue(forKey: key)
            coalesceLock.unlock()
            guard let snapshot else { return }
            _ = snapshot.store.save(snapshot.review)
        }
    }

    /// Drain the queue for a specific review id (flush its pending write).
    ///
    /// The drain + final write MUST run *inside* the serial queue, not before
    /// `writeQueue.sync { }`. If flush wrote the latest value on the caller's
    /// thread first and only then barrier-synced, an already-queued async
    /// block carrying a STALE value could execute after flush's write and
    /// clobber it (the "v0 wins over v50" race). Running the drain as the
    /// queue's own (necessarily last, since the queue is serial) block makes
    /// the newest value the final write, deterministically.
    private static func flushSync(store: ReviewStore, id: String) {
        writeQueue.sync {
            coalesceLock.lock()
            let snapshot = pending.removeValue(forKey: id)
            coalesceLock.unlock()
            if let snapshot {
                _ = snapshot.store.save(snapshot.review)
            }
        }
    }
}
