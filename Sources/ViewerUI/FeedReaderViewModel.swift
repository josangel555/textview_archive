import Foundation
import Combine
import ViewerCore

/// TSK-1149 — the stateful coordinator for the feed-reader tool window. Holds the
/// subscription/read-state store plus a fetched-feed cache, derives the sidebar
/// summaries and the selected feed's item list via the pure `FeedReaderModel`,
/// and applies user actions (select a feed, mark an item read, ingest a fetch).
/// `@Published` so the (render) SwiftUI reader view binds it — the view itself is
/// the render tail; this view-model is the host-testable layer.
@MainActor
public final class FeedReaderViewModel: ObservableObject {
    /// Per-subscription sidebar rows (unread rollups + fetched/not-fetched).
    @Published public private(set) var summaries: [FeedReaderModel.FeedSummary] = []
    /// The currently selected feed, or nil.
    @Published public private(set) var selectedFeedURL: URL?
    /// The selected feed's items, newest-first + read-annotated.
    @Published public private(set) var items: [FeedReaderModel.DisplayItem] = []

    private let store: FeedSubscriptionStore
    private let fetcher: FeedFetching
    /// Fetched-feed cache (feed URL → last fetched `Feed`).
    private var feeds: [URL: Feed] = [:]
    /// When each feed was last fetched — feeds the refresh scheduler.
    public private(set) var lastFetched: [URL: Date] = [:]
    /// Refresh staleness threshold (seconds): a feed older than this is refetched.
    public var refreshInterval: TimeInterval = 1800

    public init(store: FeedSubscriptionStore, fetcher: FeedFetching = FeedFetcher()) {
        self.store = store
        self.fetcher = fetcher
        recompute()
    }

    /// Replace the cached `Feed` for `url` (after a `FeedFetcher` fetch) and
    /// recompute the summaries (and the item list if this feed is selected).
    public func ingestFetched(url: URL, feed: Feed, at fetchedAt: Date = Date()) {
        feeds[url] = feed
        lastFetched[url] = fetchedAt
        recompute()
    }

    /// Select a feed (or nil) and recompute its item list.
    public func selectFeed(_ url: URL?) {
        selectedFeedURL = url
        recomputeItems()
    }

    /// Mark `itemID` (in the selected feed) read and recompute.
    public func markRead(itemID: String) {
        guard let url = selectedFeedURL else { return }
        store.markRead(feedURL: url, itemID: itemID)
        recompute()
    }

    /// Total unread across all fetched feeds (the badge count).
    public var totalUnread: Int { FeedReaderModel.totalUnread(summaries) }

    /// Refresh the feeds DUE per FeedRefreshScheduler (never-fetched or older than
    /// `refreshInterval`), fetch them via the injected fetcher, and ingest each
    /// (stamping its fetch time). Failed feeds keep their old `lastFetched` so they
    /// retry next pass. `now` is injectable for tests.
    public func refresh(now: Date = Date()) async {
        let due = FeedRefreshScheduler.dueForRefresh(
            subscriptions: store.allSubscriptions().map(\.url),
            lastFetched: lastFetched,
            interval: refreshInterval,
            now: now)
        guard !due.isEmpty else { return }
        let fetched = await fetcher.refreshAll(due)
        for (url, feed) in fetched {
            ingestFetched(url: url, feed: feed, at: now)
        }
    }

    private func recompute() {
        summaries = FeedReaderModel.feedSummaries(
            subscriptions: store.allSubscriptions(),
            feeds: feeds,
            isRead: { [store] url, id in store.isRead(feedURL: url, itemID: id) })
        recomputeItems()
    }

    private func recomputeItems() {
        guard let url = selectedFeedURL, let feed = feeds[url] else {
            items = []
            return
        }
        items = FeedReaderModel.displayItems(
            feed: feed,
            isRead: { [store] id in store.isRead(feedURL: url, itemID: id) })
    }
}
