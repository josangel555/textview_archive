import Foundation

/// One feed entry parsed from / emitted to an OPML subscription list.
public struct OPMLFeed: Equatable, Sendable {
    public let title: String
    public let xmlURL: URL
    public init(title: String, xmlURL: URL) {
        self.title = title
        self.xmlURL = xmlURL
    }
}

/// TSK-1150 — OPML (the standard feed-subscription interchange format) import +
/// export. Pure + dependency-free (Foundation `XMLParser` to read, string build
/// to write), so the whole round-trip is host-testable. Folder nesting is
/// flattened on import — only `<outline>` elements carrying an `xmlUrl` (the feed
/// entries) are collected; non-feed grouping outlines are ignored.
public enum OPML {

    // MARK: Import

    public static func parse(_ xml: String) -> [OPMLFeed] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        let collector = OutlineCollector()
        parser.delegate = collector
        parser.parse()
        return collector.feeds
    }

    private final class OutlineCollector: NSObject, XMLParserDelegate {
        var feeds: [OPMLFeed] = []
        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            guard elementName == "outline" else { return }
            // xmlUrl is the conventional key; tolerate case variants.
            let urlString = attributeDict["xmlUrl"] ?? attributeDict["xmlURL"]
                ?? attributeDict["xmlurl"]
            guard let urlString, let url = URL(string: urlString) else { return }
            let title = attributeDict["title"] ?? attributeDict["text"] ?? url.absoluteString
            feeds.append(OPMLFeed(title: title, xmlURL: url))
        }
    }

    // MARK: Export

    /// Emit an OPML 2.0 document listing `feeds` under `title`.
    public static func export(title: String, feeds: [OPMLFeed]) -> String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<opml version="2.0">"#,
            "  <head><title>\(escape(title))</title></head>",
            "  <body>",
        ]
        for f in feeds {
            let t = escape(f.title)
            lines.append(
                #"    <outline type="rss" text="\#(t)" title="\#(t)" xmlUrl="\#(escape(f.xmlURL.absoluteString))"/>"#)
        }
        lines.append("  </body>")
        lines.append("</opml>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// XML attribute/text escaping for the five predefined entities.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
