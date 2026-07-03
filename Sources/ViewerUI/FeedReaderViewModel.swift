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

    /// TSK-1436: where refresh failures surface. Defaults to the app-wide
    /// center; tests inject a private one and assert the error toast.
    private let toasts: ToastCenter

    public init(store: FeedSubscriptionStore, fetcher: FeedFetching = FeedFetcher(),
                toasts: ToastCenter = .shared) {
        self.store = store
        self.fetcher = fetcher
        self.toasts = toasts
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
        // TSK-1436: failures used to vanish (`refreshAll` omits feeds that
        // didn't fetch/parse; they'd silently retry next pass). Surface them —
        // the user asked for a refresh and deserves the reason it's stale.
        let failed = due.filter { fetched[$0] == nil }
        if !failed.isEmpty {
            let names = failed
                .map { $0.host ?? $0.absoluteString }
                .sorted()
                .joined(separator: ", ")
            toasts.postError(
                failed.count == 1
                    ? "Couldn't refresh feed"
                    : "Couldn't refresh \(failed.count) feeds",
                reason: names)
        }
    }

    /// Subscribe to `url` (title defaults to the host) and recompute the sidebar.
    /// Idempotent — the store dedupes by URL, so re-adding is a no-op.
    public func addFeed(url: URL, title: String? = nil) {
        _ = store.subscribe(url: url, title: title ?? url.host ?? url.absoluteString)
        recompute()
    }

    /// Unsubscribe from `url`; clears the selection if it was the selected feed.
    public func removeFeed(url: URL) {
        store.unsubscribe(from: url)
        if selectedFeedURL == url {
            selectedFeedURL = nil
        }
        recompute()
    }

    /// Import OPML subscriptions into the store; returns the number added, then
    /// recomputes the sidebar.
    @discardableResult
    public func importOPML(_ xml: String) -> Int {
        let n = store.importOPML(xml)
        recompute()
        return n
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
