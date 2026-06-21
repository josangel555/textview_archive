import XCTest
@testable import ViewerCore

/// TSK-1148 — teeth for the feed fetch layer (transport + parse), exercised with
/// a stub transport so it's fully host-testable without a network.
final class FeedFetcherTests: XCTestCase {

    private struct StubTransport: FeedTransport {
        let map: [URL: Data]
        func data(from url: URL) async throws -> Data {
            guard let d = map[url] else { throw URLError(.fileDoesNotExist) }
            return d
        }
    }

    private static let rss = """
    <?xml version="1.0"?>
    <rss version="2.0"><channel>
      <title>My Feed</title>
      <link>https://example.com</link>
      <item><title>First</title><link>https://example.com/1</link></item>
      <item><title>Second</title><link>https://example.com/2</link></item>
    </channel></rss>
    """

    func test_fetch_downloadsAndParses() async {
        let url = URL(string: "https://example.com/feed.xml")!
        let fetcher = FeedFetcher(transport: StubTransport(map: [url: Data(Self.rss.utf8)]))
        let feed = await fetcher.fetch(url)
        XCTAssertEqual(feed?.title, "My Feed")
        XCTAssertEqual(feed?.items.count, 2)
    }

    func test_fetch_transportError_returnsNil() async {
        let fetcher = FeedFetcher(transport: StubTransport(map: [:]))
        let feed = await fetcher.fetch(URL(string: "https://missing.example/x.xml")!)
        XCTAssertNil(feed, "a transport error yields nil, not a crash")
    }

    func test_refreshAll_fetchesEachParseable() async {
        let a = URL(string: "https://example.com/a.xml")!
        let b = URL(string: "https://example.com/b.xml")!
        let bad = URL(string: "https://example.com/missing.xml")!
        let fetcher = FeedFetcher(transport: StubTransport(map: [
            a: Data(Self.rss.utf8), b: Data(Self.rss.utf8),
        ]))
        let result = await fetcher.refreshAll([a, b, bad])
        XCTAssertEqual(Set(result.keys), [a, b], "parsed URLs returned; the failing one omitted")
        XCTAssertEqual(result[a]?.items.count, 2)
    }
}
