import Testing
import Foundation
@testable import ViewerCore

/// TSK-1149 — host coverage for the RSS reader display composition: items sort
/// newest-first (undated last) + carry read-state, unread counts, and per-feed
/// summaries with a fetched/not-fetched distinction.
struct FeedReaderModelTests {

    private func item(_ id: String, daysAgo: Int) -> FeedItem {
        FeedItem(id: id, title: "t-\(id)", link: nil,
                 published: Date(timeIntervalSinceReferenceDate: Double(-daysAgo) * 86_400),
                 summaryHTML: "", author: nil)
    }

    @Test func displayItems_sortNewestFirst_andAnnotateRead() {
        let feed = Feed(title: "F", siteURL: nil, items: [
            item("old", daysAgo: 10), item("new", daysAgo: 1), item("mid", daysAgo: 5),
        ])
        let read: Set<String> = ["mid"]
        let items = FeedReaderModel.displayItems(feed: feed, isRead: { read.contains($0) })
        #expect(items.map(\.item.id) == ["new", "mid", "old"], "newest-first")
        #expect(items.map(\.isRead) == [false, true, false], "mid annotated read")
        #expect(FeedReaderModel.unreadCount(items) == 2)
    }

    @Test func displayItems_undatedSortLast() {
        let feed = Feed(title: "F", siteURL: nil, items: [
            FeedItem(id: "undated", title: "u", link: nil, published: nil, summaryHTML: "", author: nil),
            item("dated", daysAgo: 3),
        ])
        let items = FeedReaderModel.displayItems(feed: feed, isRead: { _ in false })
        #expect(items.map(\.item.id) == ["dated", "undated"], "undated sorts last")
    }

    @Test func feedSummaries_unreadAndFetchedFlag() {
        let u1 = URL(string: "https://a.example/feed")!
        let u2 = URL(string: "https://b.example/feed")!  // not fetched
        let subs = [
            FeedSubscription(url: u1, title: "A", addedAt: Date(timeIntervalSinceReferenceDate: 0)),
            FeedSubscription(url: u2, title: "B", addedAt: Date(timeIntervalSinceReferenceDate: 0)),
        ]
        let feeds: [URL: Feed] = [u1: Feed(title: "A", siteURL: nil, items: [
            item("a1", daysAgo: 1), item("a2", daysAgo: 2),
        ])]
        let read: Set<String> = ["a1"]
        let summaries = FeedReaderModel.feedSummaries(
            subscriptions: subs, feeds: feeds,
            isRead: { _, itemID in read.contains(itemID) })
        #expect(summaries.count == 2)
        #expect(summaries[0].unread == 1, "A: a1 read → a2 unread (teeth)")
        #expect(summaries[0].hasFetched)
        #expect(summaries[1].unread == 0, "B not fetched → 0")
        #expect(summaries[1].hasFetched == false)
        #expect(FeedReaderModel.totalUnread(summaries) == 1)
    }
}
