import Foundation

// MARK: - ReviewSummary

/// Cheap projection over a Review for list rendering — `_index.json`
/// caches an array of these so the index tab doesn't have to read
/// every review file at boot.
public struct ReviewSummary: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let state: ReviewState
    public let updatedAt: Date
    public let commentCount: Int
    public let unresolvedCount: Int

    public init(
        id: String,
        title: String,
        state: ReviewState,
        updatedAt: Date,
        commentCount: Int,
        unresolvedCount: Int
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.updatedAt = updatedAt
        self.commentCount = commentCount
        self.unresolvedCount = unresolvedCount
    }

    /// Build a summary from a full Review.
    public init(_ review: Review) {
        self.id = review.id
        self.title = review.title
        self.state = review.state
        self.updatedAt = review.updatedAt
        self.commentCount = review.comments.count
        self.unresolvedCount = review.comments.filter { !$0.resolved }.count
    }
}

// MARK: - ReviewStore

/// Reads + writes `Review` JSON files under
/// `~/Library/Application Support/MarkdownViewer/Reviews/`.
///
/// One file per review, named `<id>.json`. `_index.json` (leading
/// underscore reserves the namespace) caches list metadata. Mirrors
/// `SessionStore`'s shape.
///
/// The class is `Sendable` — no mutable state, just the directory
/// URL. All I/O goes through `JSONFileStore` which is itself
/// stateless and atomic.
public final class ReviewStore: Sendable {

    /// Per-review file size ceiling. A review with thousands of
    /// comments + 5K-line contexts could in theory bloat; anything
    /// bigger than this is corruption, not a legitimate review.
    public static let maxReviewFileSize: Int = 10 * 1024 * 1024  // 10 MiB

    public let directory: URL

    public static func defaultDirectory() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("MarkdownViewer/Reviews")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public init(directory: URL = ReviewStore.defaultDirectory()) {
        self.directory = directory
    }

    // MARK: - CRUD

    /// Persist `review` to `<id>.json`. Bumps no fields — callers are
    /// responsible for stamping `updatedAt` before calling save.
    /// Best-effort; failures (disk full, permission denied) are
    /// swallowed (atomic write means no partial state on failure).
    @discardableResult
    public func save(_ review: Review) -> Bool {
        let url = fileURL(for: review.id)
        let ok = JSONFileStore.write(review, to: url)
        if ok {
            // Index is best-effort and easily regenerated. Don't fail
            // the save if the index rebuild trips.
            rebuildIndex()
        }
        return ok
    }

    /// Load a single review by id. Returns nil on:
    /// - missing file
    /// - file larger than `maxReviewFileSize` (corruption guard)
    /// - decode failure
    /// - `schemaVersion > currentSchema` (newer-version refusal)
    public func load(id: String) -> Review? {
        let url = fileURL(for: id)
        guard let review = JSONFileStore.read(
            Review.self, from: url, maxSize: Self.maxReviewFileSize
        ) else { return nil }
        // Forward-compat: a file saved by a future version of the app
        // must not be read in by an older version (could silently drop
        // fields on the next save). Refuse the load — surface as `nil`,
        // matching `JSONFileStore.read`'s never-throws contract.
        guard review.schemaVersion <= Review.currentSchema else { return nil }
        return review
    }

    /// Remove a review's JSON file from disk. Best-effort.
    public func delete(id: String) {
        let url = fileURL(for: id)
        try? FileManager.default.removeItem(at: url)
        rebuildIndex()
    }

    /// List all reviews on disk, sorted by `updatedAt` descending
    /// (newest first).
    ///
    /// Uses `_index.json` when present and consistent with the
    /// on-disk file set; otherwise scans the directory and reads
    /// each review file in full. The scan path is the source of
    /// truth — the index is just a cache.
    public func list() -> [ReviewSummary] {
        let onDiskIDs = Set(reviewFileIDs())

        if let cached = loadIndex(),
           Set(cached.map(\.id)) == onDiskIDs {
            return cached.sorted { $0.updatedAt > $1.updatedAt }
        }

        // Cache miss or stale — rebuild by reading each file.
        var summaries: [ReviewSummary] = []
        summaries.reserveCapacity(onDiskIDs.count)
        for id in onDiskIDs {
            if let r = load(id: id) {
                summaries.append(ReviewSummary(r))
            }
        }
        summaries.sort { $0.updatedAt > $1.updatedAt }
        // Write back the rebuilt index for next time.
        _ = JSONFileStore.write(summaries, to: indexURL)
        return summaries
    }

    /// Force-rebuild `_index.json` by scanning every review file.
    /// Public so callers can drop and rebuild after out-of-band
    /// edits (e.g., the user deleted a file in Finder).
    public func rebuildIndex() {
        var summaries: [ReviewSummary] = []
        for id in reviewFileIDs() {
            if let r = load(id: id) {
                summaries.append(ReviewSummary(r))
            }
        }
        summaries.sort { $0.updatedAt > $1.updatedAt }
        _ = JSONFileStore.write(summaries, to: indexURL)
    }

    // MARK: - Private

    private var indexURL: URL {
        directory.appendingPathComponent("_index.json")
    }

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    /// Enumerate review IDs (filenames sans `.json`) on disk,
    /// skipping the index and any underscore-prefixed reserved
    /// files.
    private func reviewFileIDs() -> [String] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return urls.compactMap { url -> String? in
            guard url.pathExtension == "json" else { return nil }
            let base = url.deletingPathExtension().lastPathComponent
            if base.hasPrefix("_") { return nil }
            return base
        }
    }

    private func loadIndex() -> [ReviewSummary]? {
        JSONFileStore.read([ReviewSummary].self, from: indexURL)
    }
}
