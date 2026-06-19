import Foundation

/// A single entry in a syndication feed, normalized across RSS 2.0,
/// Atom, and RDF/RSS 1.0.
public struct FeedItem: Equatable, Sendable, Identifiable {
    /// Stable dedup id: `guid` (RSS) / `atom:id` (Atom) / `rdf:about`
    /// attribute (RDF), falling back to `link` then `title` when no
    /// explicit identifier exists.
    public let id: String
    public let title: String
    /// Canonical permalink for the item, if present.
    public let link: String?
    /// Publish date, normalized from RFC822 (RSS) or ISO8601 (Atom)
    /// to a `Date`. `nil` when the item carries no parseable date.
    public let published: Date?
    /// Item body / summary as HTML (CDATA already unwrapped by the
    /// XML parser). May be empty.
    public let summaryHTML: String
    /// Author display name / email, if the feed supplied one.
    public let author: String?

    public init(id: String,
                title: String,
                link: String?,
                published: Date?,
                summaryHTML: String,
                author: String?) {
        self.id = id
        self.title = title
        self.link = link
        self.published = published
        self.summaryHTML = summaryHTML
        self.author = author
    }
}

/// A parsed syndication feed (RSS 2.0 / Atom / RDF-RSS 1.0).
public struct Feed: Equatable, Sendable {
    public let title: String
    /// The site/home URL the feed represents (channel `<link>` or the
    /// Atom `alternate` link), distinct from the feed's self URL.
    public let siteURL: String?
    public let items: [FeedItem]

    public init(title: String, siteURL: String?, items: [FeedItem]) {
        self.title = title
        self.siteURL = siteURL
        self.items = items
    }
}

/// Parses RSS 2.0, Atom, and RDF/RSS 1.0 feeds into a normalized `Feed`
/// using Foundation's `XMLParser` — no third-party dependency.
///
/// The parser is intentionally forgiving: it auto-detects the dialect
/// from the document's element structure (no need to sniff the root
/// element name up front, which differs per dialect and namespace
/// prefix), normalizes the two date conventions, and dedups items by a
/// best-available stable id. Malformed / truncated XML yields `nil`
/// rather than throwing or crashing, so a bad network fetch can't take
/// the UI down.
///
/// Resource caps protect against pathological input (a multi-GB or
/// item-bomb feed): `maxBytes` rejects oversized documents before the
/// XML scan, and `maxItems` bounds the emitted array.
public struct FeedParser: Sendable {

    /// Largest document we'll feed to `XMLParser`. Default 16 MB —
    /// generously above any real feed (most are <1 MB) while bounding a
    /// hostile payload. Oversized input returns `nil`.
    public let maxBytes: Int

    /// Hard cap on items returned from one parse. Default 5,000 — well
    /// above typical feeds (10–50 items) yet bounding an item-bomb.
    public let maxItems: Int

    public init(maxBytes: Int = 16 * 1024 * 1024, maxItems: Int = 5_000) {
        self.maxBytes = maxBytes
        self.maxItems = maxItems
    }

    /// Parse feed bytes into a normalized `Feed`. Returns `nil` when the
    /// document is oversized, malformed/truncated, or contains no
    /// recognizable feed structure.
    public func parse(_ data: Data) -> Feed? {
        guard !data.isEmpty, data.count <= maxBytes else { return nil }
        let delegate = FeedParserDelegate(maxItems: maxItems)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        // Without resolving external entities, an XXE / billion-laughs
        // payload can't pull in network resources or expand recursively.
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        // A parse abort due to a malformed body leaves `parserError`
        // set. Even on a hard XML error we still return whatever
        // well-formed items were collected before the break, IF the
        // document clearly is a feed (a channel/feed title or at least
        // one item was seen) — a truncated-but-recognizable feed is more
        // useful than nothing. A document with no feed structure at all
        // is `nil`.
        if !ok && !delegate.sawFeedStructure { return nil }
        if !delegate.sawFeedStructure { return nil }
        return delegate.makeFeed()
    }

    /// Convenience: read + parse a feed file from disk. Returns `nil` on
    /// any read error or parse failure (never throws).
    public func parse(contentsOf url: URL) -> Feed? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }
}

// MARK: - Date normalization

enum FeedDate {
    // ISO8601 / RFC3339 (Atom <updated>/<published>), with and without
    // fractional seconds.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // RFC822 (RSS <pubDate>). RSS dates use English month/day names and
    // a fixed format regardless of host locale, so the formatters pin
    // `en_US_POSIX` and a UTC base. Two variants: 4-digit and 2-digit
    // years (RFC822 vs RFC1123), plus optional leading weekday.
    private static let rfc822Variants: [DateFormatter] = {
        // Order matters: most specific (with weekday + 4-digit year)
        // first. `DateFormatter` is forgiving about the timezone token
        // (`zzz` accepts both `GMT`/`UTC` names and `+0000` offsets).
        let templates = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",   // RFC1123, full
            "EEE, dd MMM yyyy HH:mm zzz",       // no seconds
            "dd MMM yyyy HH:mm:ss zzz",         // no weekday
            "EEE, dd MMM yy HH:mm:ss zzz",      // 2-digit year (RFC822)
            "dd MMM yy HH:mm:ss zzz",
        ]
        return templates.map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = fmt
            return f
        }
    }()

    /// Parse a date string from any of the supported dialects. Tries
    /// ISO8601 first (Atom), then the RFC822 variants (RSS). Returns
    /// `nil` for an empty or unrecognized string.
    static func parse(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let d = isoFractional.date(from: s) { return d }
        if let d = iso.date(from: s) { return d }
        for f in rfc822Variants {
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

// MARK: - XMLParser delegate

/// Streaming delegate that walks the feed element tree and collects
/// items for all three dialects. Kept `final class` (XMLParser requires
/// a reference delegate); not `Sendable` — it lives only for the
/// duration of one synchronous `parser.parse()` call.
private final class FeedParserDelegate: NSObject, XMLParserDelegate {

    private let maxItems: Int

    /// True once we've entered any element that marks this as a feed —
    /// `channel`, `feed`, or an `item`/`entry`. Used to reject
    /// non-feed XML (a plain HTML doc, an unrelated XML file) as `nil`.
    private(set) var sawFeedStructure = false

    init(maxItems: Int) {
        self.maxItems = maxItems
        super.init()
    }

    // Feed-level accumulators.
    private var feedTitle = ""
    private var siteURL: String?
    private var sawChannelTitle = false   // RSS/RDF channel title wins over a stray item

    // Whether we are currently inside an item/entry vs the channel head.
    private var inItem = false

    // Per-item accumulators (reset on each item/entry start).
    private var itemTitle = ""
    private var itemLink: String?
    private var itemGuid: String?
    private var itemRdfAbout: String?
    private var itemDateRaw: String?
    private var itemSummary = ""
    private var itemContent = ""        // Atom <content> / RSS <content:encoded>
    private var itemAuthor: String?
    private var inAuthorBlock = false   // Atom <author><name>…</name></author>
    private var authorName: String?
    private var authorEmail: String?

    private var items: [FeedItem] = []

    // Text capture: the parser delivers character data in chunks, so we
    // accumulate into `currentText` between didStart/didEnd for the
    // element we care about.
    private var currentText = ""
    private var currentElement = ""

    // MARK: Element start

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        // We disabled namespace processing, so `elementName` is the raw
        // qualified name (e.g. `content:encoded`, `dc:date`, `atom:id`).
        let name = elementName.lowercased()
        currentElement = name
        currentText = ""

        switch name {
        case "channel", "feed":
            sawFeedStructure = true

        case "item", "entry":
            sawFeedStructure = true
            if items.count < maxItems {
                beginItem()
                // RDF/RSS 1.0 carries the item URI as rdf:about on the
                // <item> element itself.
                itemRdfAbout = attributeDict["rdf:about"]
            }

        case "link":
            // Atom <link> is attribute-driven: href + rel. RSS/RDF
            // <link> is element-text (handled in didEnd). For Atom, a
            // `rel="alternate"` (or no rel) href is the canonical link.
            if let href = attributeDict["href"] {
                let rel = attributeDict["rel"]?.lowercased()
                if inItem {
                    if rel == nil || rel == "alternate" || itemLink == nil {
                        if rel != "self" && rel != "enclosure" {
                            itemLink = href
                        }
                    }
                } else {
                    if rel == nil || rel == "alternate" || siteURL == nil {
                        if rel != "self" {
                            siteURL = href
                        }
                    }
                }
            }

        case "author":
            // Atom author block (contains <name>/<email>) vs RSS
            // plain-text <author> are disambiguated at didEnd: we mark
            // we're inside an author element here so child <name>/<email>
            // get routed, then at end pick the composed name (Atom) or
            // the element's own text (RSS) — whichever is present.
            if inItem {
                inAuthorBlock = true
                authorName = nil
                authorEmail = nil
            }

        default:
            break
        }
    }

    private func beginItem() {
        inItem = true
        itemTitle = ""
        itemLink = nil
        itemGuid = nil
        itemRdfAbout = nil
        itemDateRaw = nil
        itemSummary = ""
        itemContent = ""
        itemAuthor = nil
        inAuthorBlock = false
        authorName = nil
        authorEmail = nil
    }

    // MARK: Character data

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    // CDATA blocks (e.g. CDATA-wrapped HTML summaries) arrive here, not
    // via foundCharacters. Decode as UTF-8 and append to the same buffer.
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) {
            currentText += s
        }
    }

    // MARK: Element end

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = elementName.lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "item", "entry":
            finishItem()

        case "title":
            if inItem {
                if itemTitle.isEmpty { itemTitle = text }
            } else if !sawChannelTitle || feedTitle.isEmpty {
                // The first channel/feed-level title wins; ignore any
                // later stray titles outside an item.
                feedTitle = text
                sawChannelTitle = true
            }

        case "link":
            // Element-text <link> (RSS / RDF). Atom's attribute link was
            // already captured in didStart; only fill from text if we
            // don't yet have one.
            if !text.isEmpty {
                if inItem {
                    if itemLink == nil { itemLink = text }
                } else {
                    if siteURL == nil { siteURL = text }
                }
            }

        case "guid", "id":
            // RSS <guid> and Atom <id> both serve as the stable id.
            if inItem, itemGuid == nil, !text.isEmpty { itemGuid = text }

        case "pubdate", "published", "updated", "dc:date", "date":
            // RSS <pubDate>, Atom <published>/<updated>, RDF/Dublin Core
            // <dc:date>. Prefer the first parseable one we see; for Atom
            // <published> beats <updated> but we accept whichever exists.
            if inItem, itemDateRaw == nil, !text.isEmpty { itemDateRaw = text }

        case "description", "summary":
            // RSS <description>, Atom <summary>.
            if inItem, itemSummary.isEmpty { itemSummary = currentText }

        case "content", "content:encoded":
            // Atom <content>, RSS <content:encoded> (richer body).
            if inItem, itemContent.isEmpty { itemContent = currentText }

        case "author":
            if inItem {
                // Prefer the composed Atom <name>/<email>; if neither
                // child appeared this is an RSS plain-text <author>, so
                // fall back to the element's own text.
                let composed = composeAuthor()
                if let composed {
                    itemAuthor = composed
                } else if itemAuthor == nil, !text.isEmpty {
                    itemAuthor = text
                }
                inAuthorBlock = false
            }

        case "name":
            if inAuthorBlock, !text.isEmpty { authorName = text }

        case "email":
            if inAuthorBlock, !text.isEmpty { authorEmail = text }

        case "creator", "dc:creator":
            // Dublin Core author used by many RSS/RDF feeds.
            if inItem, itemAuthor == nil, !text.isEmpty { itemAuthor = text }

        default:
            break
        }

        currentText = ""
    }

    private func composeAuthor() -> String? {
        switch (authorName, authorEmail) {
        case let (n?, e?): return "\(n) <\(e)>"
        case let (n?, nil): return n
        case let (nil, e?): return e
        case (nil, nil): return nil
        }
    }

    private func finishItem() {
        defer { inItem = false }
        guard items.count < maxItems else { return }

        // Prefer the richer content body over the short summary, but
        // fall back to summary when content is absent.
        let body = itemContent.isEmpty ? itemSummary : itemContent

        // Dedup id: guid / atom-id > rdf:about > link > title.
        let id = firstNonEmpty(itemGuid, itemRdfAbout, itemLink, itemTitle) ?? ""
        // Skip entirely empty items (no id, title, link, or body).
        if id.isEmpty && itemTitle.isEmpty && itemLink == nil && body.isEmpty {
            return
        }

        let item = FeedItem(
            id: id,
            title: itemTitle,
            link: itemLink,
            published: itemDateRaw.flatMap(FeedDate.parse),
            summaryHTML: body,
            author: itemAuthor
        )
        items.append(item)
    }

    private func firstNonEmpty(_ candidates: String?...) -> String? {
        for c in candidates {
            if let c, !c.isEmpty { return c }
        }
        return nil
    }

    // MARK: Result

    func makeFeed() -> Feed {
        Feed(title: feedTitle, siteURL: siteURL, items: items)
    }
}
