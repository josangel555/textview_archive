import Foundation

/// TSK-1149 — pure refresh-scheduling for the feed reader: given the subscribed
/// feeds, when each was last fetched, and a refresh interval, decide which feeds
/// are DUE for a refresh `now`. Pure (interval + now injected) so it is
/// host-testable and deterministic — the tool-window UI (the VM render session)
/// drives it on a timer + manual refresh; this is the host-completable model
/// layer of the otherwise render/WKWebView feature.
public enum FeedRefreshScheduler {
    /// Feeds due for refresh, in the input order (stable): a feed is due if it
    /// has never been fetched, or its last fetch was at least `interval` seconds
    /// ago (boundary inclusive). A non-positive `interval` treats every feed as
    /// due (always refresh).
    public static func dueForRefresh(
        subscriptions: [URL],
        lastFetched: [URL: Date],
        interval: TimeInterval,
        now: Date
    ) -> [URL] {
        subscriptions.filter { url in
            guard let last = lastFetched[url] else { return true } // never fetched → due
            return now.timeIntervalSince(last) >= interval
        }
    }
}
