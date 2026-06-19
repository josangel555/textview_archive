import XCTest
@testable import ViewerCore

final class FeedSubscriptionStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var subsURL: URL!
    private var stateURL: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FeedSubscriptionStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        subsURL = tmpDir.appendingPathComponent("feeds.json")
        stateURL = tmpDir.appendingPathComponent("feed-read-state.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(start: Date) { self.current = start }
        func tick() -> Date {
            lock.lock(); defer { lock.unlock() }
            let value = current
            current = current.addingTimeInterval(1)
            return value
        }
    }

    private func makeStore(
        now: Date = Date(timeIntervalSince1970: 1_700_000_000),
        maxSubscriptions: Int = 500,
        maxReadIDsPerFeed: Int = 1000
    ) -> FeedSubscriptionStore {
        // Writes are async/coalesced; drain any pending write from a prior
        // store before this new one loads from disk (roundtrip determinism).
        JSONFileStore.flushSync()
        let clock = TestClock(start: now)
        return FeedSubscriptionStore(
            subscriptionsURL: subsURL,
            readStateURL: stateURL,
            maxSubscriptions: maxSubscriptions,
            maxReadIDsPerFeed: maxReadIDsPerFeed,
            clock: { clock.tick() }
        )
    }

    private func feed(_ s: String) -> URL { URL(string: s)! }
    private func items(_ ids: [String]) -> [FeedItemRef] { ids.map { FeedItemRef(id: $0) } }

    // MARK: - Subscribe / unsubscribe

    func test_subscribe_addsAndIsNewestFirst() {
        let store = makeStore()
        store.subscribe(url: feed("https://a.example/feed.xml"), title: "A")
        store.subscribe(url: feed("https://b.example/feed.xml"), title: "B")
        XCTAssertEqual(store.subscriptionCount, 2)
        XCTAssertEqual(store.allSubscriptions().map { $0.title }, ["B", "A"])
    }

    func test_subscribe_isIdempotentOnURL() {
        let store = makeStore()
        let url = feed("https://a.example/feed.xml")
        store.subscribe(url: url, title: "A")
        store.subscribe(url: url, title: "A")
        XCTAssertEqual(store.subscriptionCount, 1, "re-subscribing the same URL must not duplicate")
        XCTAssertTrue(store.isSubscribed(to: url))
    }

    func test_subscribe_reSubscribeRefreshesTitleInPlace() {
        let store = makeStore()
        let url = feed("https://a.example/feed.xml")
        // Z is subscribed FIRST → ends up behind `url` (newest-first).
        store.subscribe(url: feed("https://z.example/feed.xml"), title: "Z")
        let first = store.subscribe(url: url, title: "Old Title")
        let updated = store.subscribe(url: url, title: "New Title")
        XCTAssertEqual(store.subscriptionCount, 2)
        XCTAssertEqual(updated.title, "New Title")
        XCTAssertEqual(updated.addedAt, first.addedAt, "addedAt must be preserved on refresh")
        // Position preserved (refresh does NOT bump to front): url stays ahead of Z.
        XCTAssertEqual(store.allSubscriptions().map { $0.title }, ["New Title", "Z"])
    }

    func test_unsubscribe_removes() {
        let store = makeStore()
        let url = feed("https://a.example/feed.xml")
        store.subscribe(url: url, title: "A")
        store.unsubscribe(from: url)
        XCTAssertEqual(store.subscriptionCount, 0)
        XCTAssertFalse(store.isSubscribed(to: url))
    }

    func test_unsubscribe_missingIsNoop() {
        let store = makeStore()
        store.subscribe(url: feed("https://a.example/feed.xml"), title: "A")
        store.unsubscribe(from: feed("https://never.example/feed.xml"))
        XCTAssertEqual(store.subscriptionCount, 1)
    }

    func test_unsubscribe_dropsReadState() {
        let store = makeStore()
        let url = feed("https://a.example/feed.xml")
        store.subscribe(url: url, title: "A")
        store.markRead(feedURL: url, itemID: "i1")
        XCTAssertEqual(store.readCount(feedURL: url), 1)
        store.unsubscribe(from: url)
        XCTAssertEqual(store.readCount(feedURL: url), 0, "unsubscribe wipes the feed's read-state")
    }

    func test_subscriptionCap_dropsOldest() {
        let store = makeStore(maxSubscriptions: 3)
        for i in 0..<5 {
            store.subscribe(url: feed("https://f\(i).example/feed.xml"), title: "F\(i)")
        }
        XCTAssertEqual(store.subscriptionCount, 3)
        XCTAssertEqual(store.allSubscriptions().map { $0.title }, ["F4", "F3", "F2"])
    }

    // MARK: - Read state

    func test_markRead_isRead() {
        let store = makeStore()
        let url = feed("https://a.example/feed.xml")
        XCTAssertFalse(store.isRead(feedURL: url, itemID: "i1"))
        store.markRead(feedURL: url, itemID: "i1")
        XCTAssertTrue(store.isRead(feedURL: url, itemID: "i1"))
        XCTAssertFalse(store.isRead(feedURL: url, itemID: "i2"))
    }

    func test_markRead_isIdempotent() {
        let store = makeStore()
        let url = feed("https://a.example/feed.xml")
        store.markRead(feedURL: url, itemID: "i1")
        store.markRead(feedURL: url, itemID: "i1")
        XCTAssertEqual(store.readCount(feedURL: url), 1, "re-marking the same id must not grow the set")
    }

    func test_readState_perFeedIsolation() {
        let store = makeStore()
        let a = feed("https://a.example/feed.xml")
        let b = feed("https://b.example/feed.xml")
        store.markRead(feedURL: a, itemID: "shared")
        XCTAssertTrue(store.isRead(feedURL: a, itemID: "shared"))
        XCTAssertFalse(store.isRead(feedURL: b, itemID: "shared"),
                       "read-state must not leak across feeds")
    }

    func test_readState_capTrimsOldest() {
        let store = makeStore(maxReadIDsPerFeed: 3)
        let url = feed("https://a.example/feed.xml")
        for i in 0..<5 { store.markRead(feedURL: url, itemID: "i\(i)") }
        XCTAssertEqual(store.readCount(feedURL: url), 3, "read-state must be capped")
        // Most-recently-marked are kept; oldest (i0, i1) evicted.
        XCTAssertTrue(store.isRead(feedURL: url, itemID: "i4"))
        XCTAssertTrue(store.isRead(feedURL: url, itemID: "i3"))
        XCTAssertTrue(store.isRead(feedURL: url, itemID: "i2"))
        XCTAssertFalse(store.isRead(feedURL: url, itemID: "i1"))
        XCTAssertFalse(store.isRead(feedURL: url, itemID: "i0"))
    }

    // MARK: - Merge / unread count

    func test_merge_unreadCountIsAllItemsWhenNothingRead() {
        let store = makeStore()
        let url = feed("https://a.example/feed.xml")
        let result = store.mergeFetched(feedURL: url, items: items(["i1", "i2", "i3"]))
        XCTAssertEqual(result.unreadCount, 3)
        XCTAssertEqual(Set(result.newIDs), ["i1", "i2", "i3"])
    }

    func test_merge_unreadCountDropsAfterMarkRead() {
        let store = makeStore()
        let url = feed("https://a.example/feed.xml")
        store.markRead(feedURL: url, itemID: "i2")
        let result = store.mergeFetched(feedURL: url, items: items(["i1", "i2", "i3"]))
        XCTAssertEqual(result.unreadCount, 2, "the read item must not count as unread")
        XCTAssertEqual(result.unreadIDs, ["i1", "i3"])
        XCTAssertFalse(result.newIDs.contains("i2"), "an already-read item is not 'new'")
    }

    func test_merge_dedupOnReMergeOfSameFeed_unreadCountStable() {
        let store = makeStore()
        let url = feed("https://a.example/feed.xml")
        let fetch = items(["i1", "i2", "i3"])
        let first = store.mergeFetched(feedURL: url, items: fetch)
        let second = store.mergeFetched(feedURL: url, items: fetch)
        XCTAssertEqual(first.unreadCount, 3)
        XCTAssertEqual(second.unreadCount, 3,
                       "re-merging the identical fetch keeps unread count stable (dedup)")
        XCTAssertEqual(first.newIDs.count, 3)
        XCTAssertTrue(second.newIDs.isEmpty,
                      "no items are 'new' on a re-merge of the same set")
    }

    func test_merge_onlyTrulyNewItemsAreNew() {
        let store = makeStore()
        let url = feed("https://a.example/feed.xml")
        store.mergeFetched(feedURL: url, items: items(["i1", "i2"]))
        let second = store.mergeFetched(feedURL: url, items: items(["i1", "i2", "i3", "i4"]))
        XCTAssertEqual(Set(second.newIDs), ["i3", "i4"],
                       "only items unseen by a prior merge are 'new'")
        XCTAssertEqual(second.unreadCount, 4, "none were marked read, so all 4 are unread")
    }

    func test_unreadCount_helperMatchesMergeWithoutMutating() {
        let store = makeStore()
        let url = feed("https://a.example/feed.xml")
        store.markRead(feedURL: url, itemID: "i1")
        let fetch = items(["i1", "i2", "i3"])
        XCTAssertEqual(store.unreadCount(feedURL: url, items: fetch), 2)
        // Calling it must not have created a seen ledger → first merge still
        // reports the unread ones as new.
        let result = store.mergeFetched(feedURL: url, items: fetch)
        XCTAssertEqual(Set(result.newIDs), ["i2", "i3"])
    }

    // MARK: - Persistence

    func test_persistence_subscriptionsRoundTrip() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        do {
            let store = makeStore(now: now)
            store.subscribe(url: feed("https://a.example/feed.xml"), title: "A")
            store.subscribe(url: feed("https://b.example/feed.xml"), title: "B")
        }
        let reopened = makeStore(now: now)
        XCTAssertEqual(reopened.subscriptionCount, 2)
        XCTAssertEqual(reopened.allSubscriptions().map { $0.title }, ["B", "A"])
    }

    func test_persistence_readStateRoundTrip() {
        let url = feed("https://a.example/feed.xml")
        do {
            let store = makeStore()
            store.subscribe(url: url, title: "A")
            store.markRead(feedURL: url, itemID: "i1")
            store.markRead(feedURL: url, itemID: "i2")
        }
        let reopened = makeStore()
        XCTAssertTrue(reopened.isRead(feedURL: url, itemID: "i1"))
        XCTAssertTrue(reopened.isRead(feedURL: url, itemID: "i2"))
        XCTAssertFalse(reopened.isRead(feedURL: url, itemID: "i3"))
    }

    func test_persistence_seenLedgerSurvivesRelaunch_noPhantomNew() {
        let url = feed("https://a.example/feed.xml")
        do {
            let store = makeStore()
            store.subscribe(url: url, title: "A")
            store.mergeFetched(feedURL: url, items: items(["i1", "i2", "i3"]))
        }
        let reopened = makeStore()
        let result = reopened.mergeFetched(feedURL: url, items: items(["i1", "i2", "i3"]))
        XCTAssertTrue(result.newIDs.isEmpty,
                      "the seen ledger must persist so a re-fetch after relaunch reports no new items")
        XCTAssertEqual(result.unreadCount, 3, "still unread (never marked read)")
    }

    func test_persistence_capAppliedOnLoad() {
        let url = feed("https://a.example/feed.xml")
        do {
            let store = makeStore(maxReadIDsPerFeed: 1000)
            for i in 0..<20 { store.markRead(feedURL: url, itemID: "i\(i)") }
        }
        let tight = makeStore(maxReadIDsPerFeed: 5)
        XCTAssertEqual(tight.readCount(feedURL: url), 5, "load must re-apply the (tighter) cap")
    }

    func test_corruptSubscriptionsFile_returnsEmptyAndUsable() throws {
        try Data("not json".utf8).write(to: subsURL)
        let store = makeStore()
        XCTAssertEqual(store.subscriptionCount, 0)
        store.subscribe(url: feed("https://a.example/feed.xml"), title: "A")
        XCTAssertEqual(store.subscriptionCount, 1)
    }

    func test_corruptReadStateFile_returnsEmptyAndUsable() throws {
        try Data("{ broken".utf8).write(to: stateURL)
        let store = makeStore()
        let url = feed("https://a.example/feed.xml")
        XCTAssertFalse(store.isRead(feedURL: url, itemID: "i1"))
        store.markRead(feedURL: url, itemID: "i1")
        XCTAssertTrue(store.isRead(feedURL: url, itemID: "i1"))
    }

    func test_oneMalformedSubscription_doesNotDiscardTheRest() throws {
        let json = """
        [
          {"url":"https://a.example/feed.xml","title":"A","addedAt":"2026-05-14T00:00:00Z"},
          {"title":"broken — no url","addedAt":"2026-05-14T00:00:00Z"},
          {"url":"https://b.example/feed.xml","title":"B","addedAt":"2026-05-13T00:00:00Z"}
        ]
        """
        try json.write(to: subsURL, atomically: true, encoding: .utf8)
        let store = makeStore()
        XCTAssertEqual(store.subscriptionCount, 2,
                       "the bad element is dropped, the two valid ones kept (lenient decode)")
        XCTAssertEqual(Set(store.allSubscriptions().map { $0.title }), ["A", "B"])
    }

    func test_clear_wipesEverything() {
        let store = makeStore()
        let url = feed("https://a.example/feed.xml")
        store.subscribe(url: url, title: "A")
        store.markRead(feedURL: url, itemID: "i1")
        store.mergeFetched(feedURL: url, items: items(["i1", "i2"]))
        store.clear()
        XCTAssertEqual(store.subscriptionCount, 0)
        XCTAssertEqual(store.readCount(feedURL: url), 0)
        // After clear the seen ledger is gone too → items count as new again.
        let result = store.mergeFetched(feedURL: url, items: items(["i1", "i2"]))
        XCTAssertEqual(result.newIDs.count, 2)
    }

    func test_oversizedStoreFile_isIgnoredOnLoad() throws {
        // A structurally-valid but huge subscriptions array; the size gate
        // must refuse it before decode.
        let entry = """
        {"url":"https://x.example/\(String(repeating: "p", count: 2000))","title":"x","addedAt":"2026-05-14T00:00:00Z"}
        """
        let arrayJSON = "[" + Array(repeating: entry, count: 100).joined(separator: ",") + "]"
        try arrayJSON.write(to: subsURL, atomically: true, encoding: .utf8)
        let store = FeedSubscriptionStore(
            subscriptionsURL: subsURL,
            readStateURL: stateURL,
            maxStoreFileBytes: 5_000,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        XCTAssertEqual(store.subscriptionCount, 0, "oversized file is skipped, not decoded")
    }
}
