import XCTest
@testable import ViewerCore

final class FeedParserTests: XCTestCase {

    private let parser = FeedParser()

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - RSS 2.0

    func test_rss2_basic_channel_and_items() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Example RSS Feed</title>
            <link>https://example.com/</link>
            <description>A test feed</description>
            <item>
              <title>First Post</title>
              <link>https://example.com/posts/1</link>
              <guid isPermaLink="false">post-0001</guid>
              <pubDate>Mon, 16 Jun 2025 09:30:00 GMT</pubDate>
              <author>jane@example.com</author>
              <description>Hello &amp; welcome</description>
            </item>
            <item>
              <title>Second Post</title>
              <link>https://example.com/posts/2</link>
              <guid isPermaLink="false">post-0002</guid>
              <pubDate>Tue, 17 Jun 2025 12:00:00 +0000</pubDate>
              <description>Another one</description>
            </item>
          </channel>
        </rss>
        """
        guard let feed = parser.parse(data(xml)) else {
            return XCTFail("RSS2 feed failed to parse")
        }
        XCTAssertEqual(feed.title, "Example RSS Feed")
        XCTAssertEqual(feed.siteURL, "https://example.com/")
        XCTAssertEqual(feed.items.count, 2)

        let first = feed.items[0]
        XCTAssertEqual(first.id, "post-0001")
        XCTAssertEqual(first.title, "First Post")
        XCTAssertEqual(first.link, "https://example.com/posts/1")
        XCTAssertEqual(first.author, "jane@example.com")
        XCTAssertEqual(first.summaryHTML, "Hello & welcome")  // entity decoded
        XCTAssertNotNil(first.published)

        // RFC822 date precision: Mon, 16 Jun 2025 09:30:00 GMT.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute],
                                       from: first.published!)
        XCTAssertEqual(comps.year, 2025)
        XCTAssertEqual(comps.month, 6)
        XCTAssertEqual(comps.day, 16)
        XCTAssertEqual(comps.hour, 9)
        XCTAssertEqual(comps.minute, 30)

        XCTAssertEqual(feed.items[1].id, "post-0002")
        XCTAssertNotNil(feed.items[1].published)  // +0000 offset variant
    }

    func test_rss2_cdata_html_summary_preserved() {
        let xml = """
        <rss version="2.0"><channel>
          <title>CDATA Feed</title>
          <item>
            <title>Rich Post</title>
            <guid>g-1</guid>
            <description><![CDATA[<p>Bold <strong>text</strong> & raw <markup>.</p>]]></description>
          </item>
        </channel></rss>
        """
        guard let feed = parser.parse(data(xml)) else {
            return XCTFail("CDATA feed failed to parse")
        }
        XCTAssertEqual(feed.items.count, 1)
        // CDATA HTML must survive verbatim (the < > & are NOT entities).
        XCTAssertEqual(feed.items[0].summaryHTML,
                       "<p>Bold <strong>text</strong> & raw <markup>.</p>")
    }

    func test_rss2_content_encoded_preferred_over_description() {
        let xml = """
        <rss version="2.0"
             xmlns:content="http://purl.org/rss/1.0/modules/content/">
          <channel>
            <title>Content Feed</title>
            <item>
              <title>Body Post</title>
              <guid>c-1</guid>
              <description>short summary</description>
              <content:encoded><![CDATA[<p>full rich body</p>]]></content:encoded>
            </item>
          </channel>
        </rss>
        """
        guard let feed = parser.parse(data(xml)) else {
            return XCTFail("content:encoded feed failed")
        }
        XCTAssertEqual(feed.items[0].summaryHTML, "<p>full rich body</p>")
    }

    func test_rss2_missing_date_yields_nil_published() {
        let xml = """
        <rss version="2.0"><channel>
          <title>No-Date Feed</title>
          <item>
            <title>Undated Post</title>
            <guid>nd-1</guid>
            <description>no pubDate here</description>
          </item>
        </channel></rss>
        """
        guard let feed = parser.parse(data(xml)) else {
            return XCTFail("no-date feed failed")
        }
        XCTAssertEqual(feed.items.count, 1)
        XCTAssertNil(feed.items[0].published)
        XCTAssertEqual(feed.items[0].title, "Undated Post")
    }

    func test_rss2_guid_falls_back_to_link_then_title() {
        let xml = """
        <rss version="2.0"><channel>
          <title>Fallback Feed</title>
          <item>
            <title>Has Link No Guid</title>
            <link>https://example.com/x</link>
            <description>d</description>
          </item>
          <item>
            <title>Only Title</title>
            <description>d2</description>
          </item>
        </channel></rss>
        """
        guard let feed = parser.parse(data(xml)) else {
            return XCTFail("fallback feed failed")
        }
        XCTAssertEqual(feed.items[0].id, "https://example.com/x")  // link fallback
        XCTAssertEqual(feed.items[1].id, "Only Title")             // title fallback
    }

    func test_rss2_dc_creator_used_as_author() {
        let xml = """
        <rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <channel>
            <title>DC Feed</title>
            <item>
              <title>DC Post</title>
              <guid>dc-1</guid>
              <dc:creator>Alex Doe</dc:creator>
              <description>d</description>
            </item>
          </channel>
        </rss>
        """
        guard let feed = parser.parse(data(xml)) else {
            return XCTFail("dc:creator feed failed")
        }
        XCTAssertEqual(feed.items[0].author, "Alex Doe")
    }

    // MARK: - Atom

    func test_atom_basic_feed_and_entries() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Example Atom Feed</title>
          <link href="https://example.com/" rel="alternate"/>
          <link href="https://example.com/feed.atom" rel="self"/>
          <entry>
            <title>Atom Post One</title>
            <link href="https://example.com/atom/1" rel="alternate"/>
            <id>urn:uuid:1225c695-cfb8-4ebb-aaaa-80da344efa6a</id>
            <published>2025-06-16T09:30:00Z</published>
            <updated>2025-06-16T10:00:00Z</updated>
            <author><name>Jane Roe</name><email>jane@example.com</email></author>
            <summary>An Atom summary</summary>
          </entry>
        </feed>
        """
        guard let feed = parser.parse(data(xml)) else {
            return XCTFail("Atom feed failed to parse")
        }
        XCTAssertEqual(feed.title, "Example Atom Feed")
        // Self link must NOT be picked as siteURL.
        XCTAssertEqual(feed.siteURL, "https://example.com/")
        XCTAssertEqual(feed.items.count, 1)

        let e = feed.items[0]
        XCTAssertEqual(e.id, "urn:uuid:1225c695-cfb8-4ebb-aaaa-80da344efa6a")
        XCTAssertEqual(e.title, "Atom Post One")
        XCTAssertEqual(e.link, "https://example.com/atom/1")
        XCTAssertEqual(e.author, "Jane Roe <jane@example.com>")
        XCTAssertEqual(e.summaryHTML, "An Atom summary")
        XCTAssertNotNil(e.published)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute],
                                   from: e.published!)
        XCTAssertEqual(c.year, 2025)
        XCTAssertEqual(c.month, 6)
        XCTAssertEqual(c.day, 16)
        XCTAssertEqual(c.hour, 9)
        XCTAssertEqual(c.minute, 30)  // <published> beats <updated>
    }

    func test_atom_fractional_seconds_date() {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Frac Feed</title>
          <entry>
            <title>Frac</title>
            <id>frac-1</id>
            <updated>2025-06-16T09:30:00.123Z</updated>
            <content type="html">&lt;p&gt;hi&lt;/p&gt;</content>
          </entry>
        </feed>
        """
        guard let feed = parser.parse(data(xml)) else {
            return XCTFail("fractional date feed failed")
        }
        XCTAssertNotNil(feed.items[0].published)
        // Atom escaped HTML content decodes the entities.
        XCTAssertEqual(feed.items[0].summaryHTML, "<p>hi</p>")
    }

    func test_atom_content_preferred_over_summary() {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>F</title>
          <entry>
            <title>T</title>
            <id>x</id>
            <summary>short</summary>
            <content type="html"><![CDATA[<div>long content</div>]]></content>
          </entry>
        </feed>
        """
        guard let feed = parser.parse(data(xml)) else {
            return XCTFail("atom content feed failed")
        }
        XCTAssertEqual(feed.items[0].summaryHTML, "<div>long content</div>")
    }

    // MARK: - RDF / RSS 1.0

    func test_rdf_rss1_feed_and_items() {
        let xml = """
        <?xml version="1.0"?>
        <rdf:RDF
          xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
          xmlns="http://purl.org/rss/1.0/"
          xmlns:dc="http://purl.org/dc/elements/1.1/">
          <channel rdf:about="https://example.com/feed.rdf">
            <title>RDF Example</title>
            <link>https://example.com/</link>
          </channel>
          <item rdf:about="https://example.com/rdf/1">
            <title>RDF Item One</title>
            <link>https://example.com/rdf/1</link>
            <dc:date>2025-06-16T09:30:00+00:00</dc:date>
            <dc:creator>RDF Author</dc:creator>
            <description>RDF description</description>
          </item>
        </rdf:RDF>
        """
        guard let feed = parser.parse(data(xml)) else {
            return XCTFail("RDF feed failed to parse")
        }
        XCTAssertEqual(feed.title, "RDF Example")
        XCTAssertEqual(feed.siteURL, "https://example.com/")
        XCTAssertEqual(feed.items.count, 1)

        let i = feed.items[0]
        // rdf:about on <item> is the stable id when no guid present.
        XCTAssertEqual(i.id, "https://example.com/rdf/1")
        XCTAssertEqual(i.title, "RDF Item One")
        XCTAssertEqual(i.link, "https://example.com/rdf/1")
        XCTAssertEqual(i.author, "RDF Author")
        XCTAssertEqual(i.summaryHTML, "RDF description")
        XCTAssertNotNil(i.published)  // dc:date ISO8601 with offset
    }

    // MARK: - Malformed / robustness

    func test_truncated_xml_does_not_crash() {
        // Cut off mid-element. Should return nil or a partial feed,
        // never crash.
        let xml = """
        <rss version="2.0"><channel>
          <title>Truncated</title>
          <item>
            <title>Half an it
        """
        // Either nil or a best-effort partial is acceptable; the
        // contract is "no crash, no throw".
        _ = parser.parse(data(xml))
    }

    func test_non_feed_xml_returns_nil() {
        let xml = """
        <?xml version="1.0"?>
        <html><body><h1>Not a feed</h1></body></html>
        """
        XCTAssertNil(parser.parse(data(xml)))
    }

    func test_garbage_bytes_return_nil() {
        XCTAssertNil(parser.parse(Data([0xFF, 0x00, 0x13, 0x37, 0x42])))
    }

    func test_empty_data_returns_nil() {
        XCTAssertNil(parser.parse(Data()))
    }

    func test_oversized_data_returns_nil() {
        let small = FeedParser(maxBytes: 16, maxItems: 100)
        let xml = "<rss version=\"2.0\"><channel><title>Big</title></channel></rss>"
        XCTAssertNil(small.parse(data(xml)))  // exceeds 16-byte cap
    }

    func test_item_cap_bounds_output() {
        var body = "<rss version=\"2.0\"><channel><title>Capped</title>"
        for n in 0..<10 {
            body += "<item><title>P\(n)</title><guid>g\(n)</guid><description>d</description></item>"
        }
        body += "</channel></rss>"
        let capped = FeedParser(maxBytes: 1 << 20, maxItems: 3)
        guard let feed = capped.parse(data(body)) else {
            return XCTFail("capped feed failed")
        }
        XCTAssertEqual(feed.items.count, 3)
    }

    func test_plain_text_returns_nil() {
        XCTAssertNil(parser.parse(data("just some plain text, not xml at all")))
    }

    // MARK: - FeedDate unit coverage

    func test_feeddate_parses_rfc822_and_iso() {
        XCTAssertNotNil(FeedDate.parse("Mon, 16 Jun 2025 09:30:00 GMT"))
        XCTAssertNotNil(FeedDate.parse("Mon, 16 Jun 2025 09:30:00 +0000"))
        XCTAssertNotNil(FeedDate.parse("16 Jun 2025 09:30:00 GMT"))       // no weekday
        XCTAssertNotNil(FeedDate.parse("2025-06-16T09:30:00Z"))          // ISO8601
        XCTAssertNotNil(FeedDate.parse("2025-06-16T09:30:00.500Z"))      // fractional
        XCTAssertNotNil(FeedDate.parse("2025-06-16T09:30:00+02:00"))     // ISO offset
    }

    func test_feeddate_rejects_garbage_and_empty() {
        XCTAssertNil(FeedDate.parse(""))
        XCTAssertNil(FeedDate.parse("   "))
        XCTAssertNil(FeedDate.parse("not a date"))
        XCTAssertNil(FeedDate.parse("2025/06/16"))
    }
}
