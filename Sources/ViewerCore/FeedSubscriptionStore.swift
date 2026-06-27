import Foundation

/// One RSS/Atom feed the user subscribes to. Identity is the feed `url`
/// (the document URL the fetcher polls), so re-subscribing to the same
/// feed is idempotent. `title` is a display label (the feed's `<title>`,
/// or a user override); `addedAt` orders the list newest-first.
///
/// Pure value type — no fetch/network state lives here. This is the
/// persistence model only; the fetcher and UI are separate slices.
public struct FeedSubscription: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Identity is the canonical feed URL string. Two subscriptions with
    /// the same `url` collide, so `subscribe` dedups on it.
    public var id: String { url.absoluteString }
    public let url: URL
    public let title: String
    public let addedAt: Date

    public init(url: URL, title: String, addedAt: Date) {
        self.url = url
        self.title = title
        self.addedAt = addedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try c.decode(URL.self, forKey: .url)
        // Title is best-effort: an entry written before titles, or one with
        // a malformed title, falls back to the URL's last path component so a
        // single bad field doesn't drop the subscription.
        self.title = (try? c.decode(String.self, forKey: .title))
            ?? url.lastPathComponent
        if let d = try? c.decode(Date.self, forKey: .addedAt) {
            self.addedAt = d
        } else {
            self.addedAt = Date()
        }
    }

    public enum CodingKeys: String, CodingKey {
        case url, title, addedAt
    }
}

/// A single fetched feed item, reduced to what the read-state model needs:
/// a stable `id` (RSS `<guid>` / Atom `<id>`, or a fetcher-derived fallback
/// such as the item link). The fetch/parse slice produces these; this model
/// only diffs ids, so nothing heavier (body, date, author) belongs here.
public struct FeedItemRef: Equatable, Hashable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
}

/// Persists RSS/Atom subscriptions and per-feed read-state to JSON on disk,
/// following the `HistoryStore` / `BookmarksStore` / `GoToPathHistoryStore`
/// pattern (single-file JSON via `JSONFileStore`, max-size guard, off-main
/// coalesced writes, Application-Support layout with NO bundle-id prefix).
///
/// TWO files under `~/Library/Application Support/MarkdownViewer/`:
///   - `feeds.json`           — `[FeedSubscription]`, newest-first.
///   - `feed-read-state.json` — feed URL → ordered list of read item ids.
///
/// Read-state is BOUNDED per feed (`maxReadIDsPerFeed`) so a long-lived
/// high-volume feed can't grow the file without limit — mirrors the
/// `history.json` `prefix(maxEntries)` trim. The most-recently-marked ids
/// are kept (front of the list); the oldest are evicted.
///
/// Thread-safety is NOT a goal — callers touch this from the main actor,
/// same contract as the sibling stores.
public final class FeedSubscriptionStore {
    public let subscriptionsURL: URL
    public let readStateURL: URL

    /// Cap on the number of subscriptions. A feed list this long is already
    /// pathological; the cap bounds the persisted file and matches the
    /// "tampered file can't balloon memory" posture of the sibling stores.
    public let maxSubscriptions: Int

    /// Cap on read-item ids retained PER FEED. The diff in `mergeFetched`
    /// only needs to remember ids it has already seen; once a feed scrolls
    /// past this many items the oldest ids age out (a re-surfaced ancient
    /// item counting as "unread" again is acceptable, and rare). Bounds the
    /// `feed-read-state.json` growth.
    public let maxReadIDsPerFeed: Int

    public let maxStoreFileBytes: Int

    private var subscriptions: [FeedSubscription] = []
    /// feed URL (canonical absoluteString) → read item ids, MOST-RECENTLY-
    /// MARKED FIRST. Order is the eviction policy: `prefix(cap)` drops the
    /// tail (oldest). A `Set` view is rebuilt for O(1) membership.
    private var readIDs: [String: [String]] = [:]
    private var readIDIndex: [String: Set<String>] = [:]

    private let clock: @Sendable () -> Date

    public init(
        subscriptionsURL: URL,
        readStateURL: URL,
        maxSubscriptions: Int = 500,
        maxReadIDsPerFeed: Int = 1000,
        maxStoreFileBytes: Int = 4 * 1024 * 1024,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.subscriptionsURL = subscriptionsURL
        self.readStateURL = readStateURL
        self.maxSubscriptions = maxSubscriptions
        self.maxReadIDsPerFeed = maxReadIDsPerFeed
        self.maxStoreFileBytes = maxStoreFileBytes
        self.clock = clock
        load()
    }

    public static func defaultSubscriptionsURL() -> URL {
        supportDir().appendingPathComponent("feeds.json", isDirectory: false)
    }

    public static func defaultReadStateURL() -> URL {
        supportDir().appendingPathComponent("feed-read-state.json", isDirectory: false)
    }

    private static func supportDir() -> URL {
        // TSK-1288: markdownViewerDir() redirects to tmp under XCTest (real dir in prod).
        return TestStateRedirect.markdownViewerDir()
    }

    // MARK: - Subscriptions

    /// Newest-first list of subscriptions. Caller treats this as read-only.
    public func allSubscriptions() -> [FeedSubscription] { subscriptions }

    public var subscriptionCount: Int { subscriptions.count }

    public func isSubscribed(to url: URL) -> Bool {
        let key = Self.key(url)
        return subscriptions.contains { Self.key($0.url) == key }
    }

    /// Subscribe to `url`. Idempotent on the feed URL: re-subscribing to an
    /// existing feed UPDATES its title (a re-fetch may carry a fresher
    /// `<title>`) and leaves it in place rather than duplicating. Returns
    /// the new or existing subscription.
    @discardableResult
    public func subscribe(url: URL, title: String) -> FeedSubscription {
        let key = Self.key(url)
        if let idx = subscriptions.firstIndex(where: { Self.key($0.url) == key }) {
            let existing = subscriptions[idx]
            // Refresh the title if it changed; preserve addedAt + position.
            if existing.title != title {
                let updated = FeedSubscription(
                    url: existing.url, title: title, addedAt: existing.addedAt
                )
                subscriptions[idx] = updated
                saveSubscriptions()
                return updated
            }
            return existing
        }
        let sub = FeedSubscription(url: url, title: title, addedAt: clock())
        subscriptions.insert(sub, at: 0)
        if subscriptions.count > maxSubscriptions {
            subscriptions = Array(subscriptions.prefix(maxSubscriptions))
        }
        saveSubscriptions()
        return sub
    }

    /// TSK-1150 — import an OPML subscription list: subscribe to each feed it
    /// lists (existing subscriptions are refreshed, not duplicated). Returns the
    /// number of NEW subscriptions added.
    @discardableResult
    public func importOPML(_ xml: String) -> Int {
        var added = 0
        for feed in OPML.parse(xml) {
            if !isSubscribed(to: feed.xmlURL) { added += 1 }
            _ = subscribe(url: feed.xmlURL, title: feed.title)
        }
        return added
    }

    /// TSK-1150 — export the current subscriptions as an OPML 2.0 document.
    public func exportOPML(title: String = "Subscriptions") -> String {
        OPML.export(title: title,
                    feeds: allSubscriptions().map { OPMLFeed(title: $0.title, xmlURL: $0.url) })
    }

    /// Unsubscribe from `url`. Also drops the feed's read-state so an
    /// unsubscribe is a clean wipe (a later re-subscribe starts fresh).
    /// No-op if not subscribed.
    public func unsubscribe(from url: URL) {
        let key = Self.key(url)
        let before = subscriptions.count
        subscriptions.removeAll { Self.key($0.url) == key }
        guard subscriptions.count != before else { return }
        saveSubscriptions()
        if readIDs.removeValue(forKey: key) != nil {
            readIDIndex.removeValue(forKey: key)
            saveReadState()
        }
    }

    // MARK: - Read state

    /// Mark a single item read for a feed. Idempotent — re-marking a known
    /// id moves it back to the front (most-recent) without growing the list.
    /// Trims to `maxReadIDsPerFeed`, evicting the oldest.
    public func markRead(feedURL: URL, itemID: String) {
        let key = Self.key(feedURL)
        var ids = readIDs[key] ?? []
        var index = readIDIndex[key] ?? []
        if index.contains(itemID) {
            // Move to front (refresh recency) so it isn't the next evicted.
            ids.removeAll { $0 == itemID }
        }
        ids.insert(itemID, at: 0)
        index.insert(itemID)
        if ids.count > maxReadIDsPerFeed {
            let evicted = ids[maxReadIDsPerFeed...]
            for e in evicted { index.remove(e) }
            ids = Array(ids.prefix(maxReadIDsPerFeed))
        }
        readIDs[key] = ids
        readIDIndex[key] = index
        saveReadState()
    }

    public func isRead(feedURL: URL, itemID: String) -> Bool {
        readIDIndex[Self.key(feedURL)]?.contains(itemID) ?? false
    }

    /// Number of read item ids currently retained for a feed (post-trim).
    public func readCount(feedURL: URL) -> Int {
        readIDs[Self.key(feedURL)]?.count ?? 0
    }

    // MARK: - Merge

    /// Result of folding a freshly-fetched feed into the read-state model.
    public struct MergeResult: Equatable, Sendable {
        /// Item ids present in the fetch that are NOT yet marked read.
        public let unreadIDs: [String]
        /// Item ids in the fetch never seen before (neither read nor
        /// previously merged) — the "new since last fetch" set.
        public let newIDs: [String]
        /// Convenience: `unreadIDs.count`.
        public var unreadCount: Int { unreadIDs.count }

        public init(unreadIDs: [String], newIDs: [String]) {
            self.unreadIDs = unreadIDs
            self.newIDs = newIDs
        }
    }

    /// Diff a freshly-fetched feed's items against known read-state and
    /// report what's unread / new, WITHOUT mutating the read set (marking
    /// read is an explicit user action via `markRead`).
    ///
    /// `unreadIDs` are fetched items not in the read set (in fetch order).
    /// `newIDs` are fetched items the store has never tracked as seen — used
    /// to compute a "N new items" badge. To make re-merging the SAME feed
    /// stable (no phantom "new" on every poll), the store records every
    /// merged id in a per-feed SEEN ledger (separate from read). Items in
    /// the ledger but not the read set are unread-but-not-new.
    ///
    /// Idempotent: merging the identical item set twice yields the same
    /// `unreadCount` and an empty `newIDs` on the second call.
    @discardableResult
    public func mergeFetched(feedURL: URL, items: [FeedItemRef]) -> MergeResult {
        let key = Self.key(feedURL)
        let readSet = readIDIndex[key] ?? []
        var seen = seenIDIndex[key] ?? []

        var unread: [String] = []
        var fresh: [String] = []
        for item in items {
            let isReadAlready = readSet.contains(item.id)
            if !isReadAlready { unread.append(item.id) }
            if !seen.contains(item.id) && !isReadAlready {
                fresh.append(item.id)
            }
        }

        // Update the seen ledger with every id in this fetch (bounded the
        // same way as read-state). Newest fetch ids go to the front.
        if !items.isEmpty {
            var ledger = seenIDs[key] ?? []
            for item in items.reversed() where !seen.contains(item.id) {
                ledger.insert(item.id, at: 0)
                seen.insert(item.id)
            }
            if ledger.count > maxReadIDsPerFeed {
                ledger = Array(ledger.prefix(maxReadIDsPerFeed))
                seen = Set(ledger)
            }
            seenIDs[key] = ledger
            seenIDIndex[key] = seen
            saveReadState()
        }

        return MergeResult(unreadIDs: unread, newIDs: fresh)
    }

    /// Unread count for a feed given its current fetched item set, derived
    /// from the read set only (no mutation). Equivalent to
    /// `mergeFetched` minus the ledger side-effect.
    public func unreadCount(feedURL: URL, items: [FeedItemRef]) -> Int {
        let readSet = readIDIndex[Self.key(feedURL)] ?? []
        return items.reduce(into: 0) { acc, item in
            if !readSet.contains(item.id) { acc += 1 }
        }
    }

    // MARK: - Seen ledger (backing `newIDs`)

    /// feed key → ordered seen-but-not-necessarily-read ledger. Persisted
    /// alongside read-state so "new since last fetch" survives a relaunch.
    private var seenIDs: [String: [String]] = [:]
    private var seenIDIndex: [String: Set<String>] = [:]

    // MARK: - Maintenance

    /// Wipe every subscription and all read-state. Recoverable only from
    /// an external backup — same posture as `clear()` on the sibling stores.
    public func clear() {
        subscriptions.removeAll()
        readIDs.removeAll()
        readIDIndex.removeAll()
        seenIDs.removeAll()
        seenIDIndex.removeAll()
        saveSubscriptions()
        saveReadState()
    }

    // MARK: - Persistence

    /// On-disk shape for the read-state file: a dict of feed key → its read
    /// ids and seen ledger. A struct (not a bare dict) so the two lists stay
    /// associated and the format can grow fields without a migration.
    private struct ReadStateFile: Codable, Sendable {
        var read: [String: [String]]
        var seen: [String: [String]]
    }

    private func load() {
        if let subs = JSONFileStore.readLenientArray(
            FeedSubscription.self, from: subscriptionsURL, maxSize: maxStoreFileBytes
        ) {
            subscriptions = Array(
                subs.sorted(by: { $0.addedAt > $1.addedAt }).prefix(maxSubscriptions)
            )
        }
        if let state = JSONFileStore.read(
            ReadStateFile.self, from: readStateURL, maxSize: maxStoreFileBytes
        ) {
            // Cap each feed's lists on load too — a tampered file could carry
            // more ids than the runtime cap.
            for (feed, ids) in state.read {
                let capped = Array(ids.prefix(maxReadIDsPerFeed))
                readIDs[feed] = capped
                readIDIndex[feed] = Set(capped)
            }
            for (feed, ids) in state.seen {
                let capped = Array(ids.prefix(maxReadIDsPerFeed))
                seenIDs[feed] = capped
                seenIDIndex[feed] = Set(capped)
            }
        }
    }

    private func saveSubscriptions() {
        JSONFileStore.enqueueWrite(subscriptions, to: subscriptionsURL)
    }

    private func saveReadState() {
        let snapshot = ReadStateFile(read: readIDs, seen: seenIDs)
        JSONFileStore.enqueueWrite(snapshot, to: readStateURL)
    }

    /// Block until every pending JSON-store write has landed (writes are
    /// async/coalesced via `JSONFileStore.enqueueWrite`). For terminate-
    /// drain and persistence-roundtrip tests.
    public func flush() {
        JSONFileStore.flushSync()
    }

    /// Canonical feed-URL key. RSS/Atom feeds are http(s) URLs; normalize on
    /// the absolute string (case-preserving — feed paths can be
    /// case-sensitive) so the same feed maps to one entry across the stores.
    private static func key(_ url: URL) -> String { url.absoluteString }
}
