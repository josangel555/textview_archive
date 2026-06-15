import XCTest
@testable import ViewerCore

/// TSK-909 — the lazy "Reviews" submenu's model: reviews scoped to a commit.
final class ReviewsForCommitTests: XCTestCase {

    private func tempStore() -> ReviewStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-reviews-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ReviewStore(directory: dir)
    }

    private func save(_ store: ReviewStore, id: String, title: String, scope: ReviewScope) {
        let now = Date()
        _ = store.save(Review(
            id: id, createdAt: now, updatedAt: now, title: title,
            scope: scope, repoRoot: "/x", baseSha: nil, headSha: nil,
            author: ReviewAuthor(name: "t", email: "t@t")))
    }

    func test_returnsOnlyMatchingCommitScopedReviews() {
        let store = tempStore()
        save(store, id: "r1", title: "Review of abc", scope: .commit(sha: "abc"))
        save(store, id: "r2", title: "Review of def", scope: .commit(sha: "def"))
        save(store, id: "r3", title: "Working tree", scope: .workingTree(base: "HEAD"))
        save(store, id: "r4", title: "A range", scope: .range(from: "a", to: "b"))

        XCTAssertEqual(store.reviews(forCommit: "abc").map(\.id), ["r1"])
        XCTAssertEqual(store.reviews(forCommit: "def").map(\.id), ["r2"])
        XCTAssertTrue(store.reviews(forCommit: "zzz").isEmpty,
            "a commit with no review yields an empty list")
    }

    func test_multipleReviewsOnTheSameCommit() {
        let store = tempStore()
        save(store, id: "r1", title: "First pass", scope: .commit(sha: "abc"))
        save(store, id: "r2", title: "Second pass", scope: .commit(sha: "abc"))
        XCTAssertEqual(Set(store.reviews(forCommit: "abc").map(\.id)), ["r1", "r2"])
    }

    func test_emptyStore_isEmpty() {
        XCTAssertTrue(tempStore().reviews(forCommit: "abc").isEmpty)
    }
}
