import Foundation

/// TSK-1149 (RSS reader) — the pure display composition between the built feed
/// engine (FeedParser/FeedFetcher) + read-state store (FeedSubscriptionStore)
/// and the (render/VM) reader view. Annotates fetched items with read-state,
/// orders them newest-first, and rolls up per-feed unread counts. Read-state is
/// injected as a closure so this stays a pure, host-testable value computation
/// (the live caller passes `store.isRead`); the SwiftUI reader pane is the
/// render slice that binds to these.
public enum FeedReaderModel {

    /// One row in the item pane: a fetched item + whether it's been read.
    public struct DisplayItem: Equatable, Sendable, Identifiable {
        public let item: FeedItem
        public let isRead: Bool
        public var id: String { item.id }
        public init(item: FeedItem, isRead: Bool) {
            self.item = item
            self.isRead = isRead
        }
    }

    /// A feed's items, newest-first (undated items sort last), each annotated
    /// read/unread via `isRead(itemID)`.
    public static func displayItems(feed: Feed, isRead: (String) -> Bool) -> [DisplayItem] {
        feed.items
            .sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
            .map { DisplayItem(item: $0, isRead: isRead($0.id)) }
    }

    /// Unread count among already-composed display items.
    public static func unreadCount(_ items: [DisplayItem]) -> Int {
        items.lazy.filter { !$0.isRead }.count
    }

    /// One row in the feed (sidebar) list: a subscription + its unread rollup.
    public struct FeedSummary: Equatable, Sendable, Identifiable {
        public let subscription: FeedSubscription
        public let unread: Int
        /// False when the feed hasn't been fetched yet (unread is 0, not known).
        public let hasFetched: Bool
        public var id: String { subscription.id }
        public init(subscription: FeedSubscription, unread: Int, hasFetched: Bool) {
            self.subscription = subscription
            self.unread = unread
            self.hasFetched = hasFetched
        }
    }

    /// Per-subscription summaries for the feed list — unread counts derived from
    /// the fetched-feed cache (a not-yet-fetched subscription reports unread 0 +
    /// `hasFetched == false` so the view can show "—" rather than a false 0).
    public static func feedSummaries(
        subscriptions: [FeedSubscription],
        feeds: [URL: Feed],
        isRead: (URL, String) -> Bool
    ) -> [FeedSummary] {
        subscriptions.map { sub in
            guard let feed = feeds[sub.url] else {
                return FeedSummary(subscription: sub, unread: 0, hasFetched: false)
            }
            let unread = feed.items.filter { !isRead(sub.url, $0.id) }.count
            return FeedSummary(subscription: sub, unread: unread, hasFetched: true)
        }
    }

    /// Total unread across all fetched feeds (the badge count).
    public static func totalUnread(_ summaries: [FeedSummary]) -> Int {
        summaries.reduce(0) { $0 + $1.unread }
    }
}
