import XCTest
import ViewerCore
@testable import ViewerUI

/// Canned-Feeds stub for the refresh-orchestration test (no network/parse).
private struct StubFetcher: FeedFetching {
    let feeds: [URL: Feed]
    func refreshAll(_ urls: [URL]) async -> [URL: Feed] {
        feeds.filter { urls.contains($0.key) }
    }
}

/// TSK-1149 — host coverage for the feed-reader view-model's state coordination:
/// selecting a feed populates its items, ingesting a fetch updates the summaries,
/// and marking an item read decrements the unread rollup + annotates the item.
@MainActor
final class FeedReaderViewModelTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-feedreader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeStore() -> FeedSubscriptionStore {
        FeedSubscriptionStore(
            subscriptionsURL: tmp.appendingPathComponent("feeds.json"),
            readStateURL: tmp.appendingPathComponent("read.json"))
    }

    private func item(_ id: String, daysAgo: Int) -> FeedItem {
        FeedItem(id: id, title: "t-\(id)", link: nil,
                 published: Date(timeIntervalSinceReferenceDate: Double(-daysAgo) * 86_400),
                 summaryHTML: "", author: nil)
    }

    func test_selectAndIngest_populatesItemsAndSummaries() {
        let store = makeStore()
        let u = URL(string: "https://a.example/feed")!
        _ = store.subscribe(url: u, title: "A")
        let vm = FeedReaderViewModel(store: store)

        // Subscribed but not fetched → one summary, not-fetched, no items.
        XCTAssertEqual(vm.summaries.count, 1)
        XCTAssertFalse(vm.summaries[0].hasFetched)
        vm.selectFeed(u)
        XCTAssertTrue(vm.items.isEmpty, "no fetched feed yet → no items")

        vm.ingestFetched(url: u, feed: Feed(title: "A", siteURL: nil, items: [
            item("a1", daysAgo: 1), item("a2", daysAgo: 2),
        ]))
        XCTAssertTrue(vm.summaries[0].hasFetched)
        XCTAssertEqual(vm.summaries[0].unread, 2)
        XCTAssertEqual(vm.items.map(\.item.id), ["a1", "a2"], "newest-first")
        XCTAssertEqual(vm.totalUnread, 2)
    }

    func test_markRead_decrementsUnread_andAnnotatesItem() {
        let store = makeStore()
        let u = URL(string: "https://a.example/feed")!
        _ = store.subscribe(url: u, title: "A")
        let vm = FeedReaderViewModel(store: store)
        vm.ingestFetched(url: u, feed: Feed(title: "A", siteURL: nil, items: [
            item("a1", daysAgo: 1), item("a2", daysAgo: 2),
        ]))
        vm.selectFeed(u)
        XCTAssertEqual(vm.totalUnread, 2)

        vm.markRead(itemID: "a1")
        XCTAssertEqual(vm.totalUnread, 1, "a1 read → 1 unread (teeth)")
        XCTAssertEqual(vm.items.first { $0.item.id == "a1" }?.isRead, true)
        XCTAssertEqual(vm.items.first { $0.item.id == "a2" }?.isRead, false)
    }

    func test_refresh_fetchesDueFeeds_stampsTime_andSkipsFresh() async {
        let store = makeStore()
        let u = URL(string: "https://a.example/feed")!
        _ = store.subscribe(url: u, title: "A")
        let feed = Feed(title: "A", siteURL: nil, items: [item("a1", daysAgo: 1)])
        let vm = FeedReaderViewModel(store: store, fetcher: StubFetcher(feeds: [u: feed]))
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

        // Never-fetched → due → refresh fetches, ingests, and stamps the time.
        await vm.refresh(now: now)
        XCTAssertEqual(vm.lastFetched[u], now, "fetched feed stamped at now (feeds the scheduler)")
        XCTAssertTrue(vm.summaries.first?.hasFetched == true, "feed now fetched")
        XCTAssertEqual(vm.totalUnread, 1)

        // 1 min later (< refreshInterval) → not due → no refetch, stamp unchanged (teeth).
        await vm.refresh(now: now.addingTimeInterval(60))
        XCTAssertEqual(vm.lastFetched[u], now, "fresh feed not refetched (due-logic)")
    }

    // MARK: - Subscription management (addFeed / removeFeed / importOPML)

    func test_addFeed_subscribesAndAppearsInSummaries_idempotently() {
        let store = makeStore()
        let vm = FeedReaderViewModel(store: store)
        XCTAssertEqual(vm.summaries.count, 0)
        let u = URL(string: "https://a.example/feed")!
        vm.addFeed(url: u, title: "A")
        XCTAssertEqual(vm.summaries.map(\.subscription.url), [u], "added feed appears in the sidebar")
        XCTAssertEqual(vm.summaries.first?.subscription.title, "A")
        vm.addFeed(url: u, title: "A")
        XCTAssertEqual(vm.summaries.count, 1, "re-adding the same feed URL is a no-op (store dedupes)")
    }

    func test_addFeed_defaultsTitleToHost() {
        let store = makeStore()
        let vm = FeedReaderViewModel(store: store)
        vm.addFeed(url: URL(string: "https://news.example/rss")!)
        XCTAssertEqual(vm.summaries.first?.subscription.title, "news.example",
                       "title defaults to the URL host when omitted")
    }

    func test_removeFeed_unsubscribesAndClearsSelection() {
        let store = makeStore()
        let u = URL(string: "https://a.example/feed")!
        let vm = FeedReaderViewModel(store: store)
        vm.addFeed(url: u, title: "A")
        vm.selectFeed(u)
        XCTAssertEqual(vm.selectedFeedURL, u)
        vm.removeFeed(url: u)
        XCTAssertEqual(vm.summaries.count, 0, "feed removed from the sidebar")
        XCTAssertNil(vm.selectedFeedURL, "removing the selected feed clears the selection")
        XCTAssertTrue(vm.items.isEmpty)
    }

    func test_importOPML_roundTripsFromExport() {
        // Build guaranteed-valid OPML via the store's own exporter, then import it
        // into a fresh VM (avoids hand-OPML format fragility).
        let seed = makeStore()
        _ = seed.subscribe(url: URL(string: "https://a.example/feed")!, title: "A")
        _ = seed.subscribe(url: URL(string: "https://b.example/feed")!, title: "B")
        let opml = seed.exportOPML()

        let store2 = FeedSubscriptionStore(
            subscriptionsURL: tmp.appendingPathComponent("feeds2.json"),
            readStateURL: tmp.appendingPathComponent("read2.json"))
        let vm = FeedReaderViewModel(store: store2)
        let n = vm.importOPML(opml)
        XCTAssertEqual(n, 2, "imported both exported feeds")
        XCTAssertEqual(Set(vm.summaries.map(\.subscription.title)), ["A", "B"])
    }
}
