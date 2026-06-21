import XCTest
@testable import ViewerCore

/// TSK-1150 — teeth for OPML import/export (pure parse/emit + the store round-trip).
final class OPMLTests: XCTestCase {

    func test_parse_collectsFeedOutlinesFlattened() {
        let opml = """
        <opml version="2.0"><body>
          <outline title="Folder">
            <outline type="rss" title="Blog A" xmlUrl="https://a.example/feed.xml"/>
          </outline>
          <outline type="rss" text="Blog B" xmlUrl="https://b.example/rss"/>
          <outline title="Not a feed (no xmlUrl)"/>
        </body></opml>
        """
        let feeds = OPML.parse(opml)
        XCTAssertEqual(feeds.count, 2, "two feed outlines; folder flattened, non-feed ignored")
        XCTAssertEqual(feeds[0].title, "Blog A")
        XCTAssertEqual(feeds[0].xmlURL.absoluteString, "https://a.example/feed.xml")
        XCTAssertEqual(feeds[1].title, "Blog B", "title falls back to text= when title= absent")
    }

    func test_export_thenParse_roundTrips() {
        let feeds = [
            OPMLFeed(title: "A & B <feed>", xmlURL: URL(string: "https://x.example/f?q=1&z=2")!),
            OPMLFeed(title: "Plain", xmlURL: URL(string: "https://y.example/feed")!),
        ]
        let back = OPML.parse(OPML.export(title: "Mine", feeds: feeds))
        XCTAssertEqual(back, feeds, "export→parse preserves titles (incl. escaped chars) + URLs")
    }

    func test_parse_malformed_isEmpty() {
        XCTAssertEqual(OPML.parse("not xml at all <<<"), [])
    }

    func test_store_importExportRoundTrip() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("opml-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = FeedSubscriptionStore(
            subscriptionsURL: tmp.appendingPathComponent("subs.json"),
            readStateURL: tmp.appendingPathComponent("state.json"))
        let opml = OPML.export(title: "X", feeds: [
            OPMLFeed(title: "A", xmlURL: URL(string: "https://a.example/feed")!),
            OPMLFeed(title: "B", xmlURL: URL(string: "https://b.example/feed")!),
        ])
        XCTAssertEqual(store.importOPML(opml), 2, "two new subscriptions added")
        XCTAssertEqual(store.importOPML(opml), 0, "re-import adds nothing (deduped)")
        XCTAssertEqual(OPML.parse(store.exportOPML()).count, 2, "export lists both subscriptions")
    }
}
