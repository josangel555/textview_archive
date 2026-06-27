import Testing
import Foundation
@testable import ViewerCore

/// TSK-1149 — host coverage for the feed-reader refresh scheduler (the pure,
/// host-completable model layer; the tool-window UI is the VM render tail).
@Suite struct FeedRefreshSchedulerTests {
    let a = URL(string: "https://a.example/feed")!
    let b = URL(string: "https://b.example/feed")!
    let c = URL(string: "https://c.example/feed")!
    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func neverFetched_isDue() {
        let due = FeedRefreshScheduler.dueForRefresh(
            subscriptions: [a, b], lastFetched: [:], interval: 1800, now: now)
        #expect(due == [a, b], "never-fetched feeds are due")
    }

    @Test func freshNotDue_staleDue_orderPreserved() {
        let due = FeedRefreshScheduler.dueForRefresh(
            subscriptions: [a, b, c],
            lastFetched: [a: now.addingTimeInterval(-60),     // 1 min ago — fresh
                          b: now.addingTimeInterval(-3600),   // 1 h ago — stale
                          c: now],                            // just now — fresh
            interval: 1800, now: now)
        #expect(due == [b], "only the stale feed (>= interval) is due; input order preserved")
    }

    @Test func boundaryExactlyInterval_isDue() {
        let due = FeedRefreshScheduler.dueForRefresh(
            subscriptions: [a], lastFetched: [a: now.addingTimeInterval(-1800)],
            interval: 1800, now: now)
        #expect(due == [a], ">= interval is due (boundary inclusive)")
    }

    @Test func nonPositiveInterval_alwaysRefreshes() {
        let due = FeedRefreshScheduler.dueForRefresh(
            subscriptions: [a], lastFetched: [a: now], interval: 0, now: now)
        #expect(due == [a], "interval 0 → every feed due (always refresh)")
    }
}
