import Foundation

/// TSK-1148 — the network seam for feeds: download a feed URL's bytes. Abstracted
/// behind a protocol so the fetch layer is host-testable with a stub (no network).
public protocol FeedTransport: Sendable {
    func data(from url: URL) async throws -> Data
}

/// Production transport over `URLSession`.
public struct URLSessionFeedTransport: FeedTransport {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func data(from url: URL) async throws -> Data {
        try await session.data(from: url).0
    }
}

/// TSK-1148 — the feed fetch layer: download a subscription's bytes (via the
/// injected `FeedTransport`) and parse them into a `Feed` (via `FeedParser`).
/// Pure orchestration over two injectable pieces, so the whole thing is
/// host-testable without a network. The periodic refresh *scheduler* (a timer
/// driving `refreshAll`) is a thin follow-on; this is the fetch core.
public struct FeedFetcher: Sendable {
    private let transport: FeedTransport
    private let parser: FeedParser

    public init(transport: FeedTransport = URLSessionFeedTransport(),
                parser: FeedParser = FeedParser()) {
        self.transport = transport
        self.parser = parser
    }

    /// Fetch + parse a single feed. Returns nil on a transport error or
    /// unparseable bytes (callers keep the last good copy).
    public func fetch(_ url: URL) async -> Feed? {
        guard let data = try? await transport.data(from: url) else { return nil }
        return parser.parse(data)
    }

    /// Refresh many feeds concurrently; the result maps each URL that parsed to
    /// its `Feed` (failed/unparseable URLs are omitted).
    public func refreshAll(_ urls: [URL]) async -> [URL: Feed] {
        await withTaskGroup(of: (URL, Feed?).self) { group in
            for url in urls {
                group.addTask { (url, await self.fetch(url)) }
            }
            var out: [URL: Feed] = [:]
            for await (url, feed) in group where feed != nil {
                out[url] = feed
            }
            return out
        }
    }
}
