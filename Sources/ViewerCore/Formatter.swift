import Foundation

/// Pretty-printing for structured text formats.
///
/// Supported: JSON, XML. Future: YAML, TOML, CSS, JS (would need
/// third-party parsers; deliberately not pulling them in yet).
///
/// Each format degrades gracefully — if parsing fails, the original
/// content is returned (so a malformed JSON file doesn't become empty).
public enum Formatter {

    public enum SupportedFormat: String, CaseIterable, Sendable {
        case json
        case xml

        /// Detect a supported format from a URL's path extension.
        public static func detect(_ url: URL) -> SupportedFormat? {
            switch url.pathExtension.lowercased() {
            case "json", "jsonl":
                return .json
            case "xml", "plist", "xib", "storyboard", "html", "htm", "xhtml", "svg":
                // XMLDocument handles these as XML; HTML strictness is
                // looser via the .documentTidyHTML option (we pass that).
                return .xml
            default:
                return nil
            }
        }
    }

    /// Pretty-print `content` as `format`. Returns the original string
    /// unchanged on parse failure — callers should validate by comparing
    /// length / content if they need a hard "did it format" signal.
    public static func prettyPrint(_ content: String, as format: SupportedFormat) -> String {
        switch format {
        case .json: return prettyPrintJSON(content)
        case .xml:  return prettyPrintXML(content)
        }
    }

    /// Convenience: detect format from URL and pretty-print, or return
    /// the original if the file extension isn't formattable.
    public static func prettyPrintIfFormattable(
        _ content: String,
        url: URL
    ) -> (formatted: String, didFormat: Bool) {
        guard let format = SupportedFormat.detect(url) else {
            return (content, false)
        }
        let out = prettyPrint(content, as: format)
        return (out, out != content)
    }

    // MARK: - JSON

    private static func prettyPrintJSON(_ content: String) -> String {
        guard let data = content.data(using: .utf8) else { return content }
        guard let obj = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) else { return content }
        // .sortedKeys makes pretty-printed output deterministic (great
        // for diffing). Skip if it'd reorder a meaningful key sequence
        // — but most JSON files are configuration, where sorted is fine.
        guard let pretty = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return content }
        return String(data: pretty, encoding: .utf8) ?? content
    }

    // MARK: - XML

    private static func prettyPrintXML(_ content: String) -> String {
        guard let data = content.data(using: .utf8) else { return content }
        var options: XMLNode.Options = []
        // Permissive parsing so a near-XML HTML document doesn't fail.
        options.insert(.documentTidyHTML)
        options.insert(.documentTidyXML)
        let doc: XMLDocument
        do {
            doc = try XMLDocument(data: data, options: options)
        } catch {
            return content
        }
        return doc.xmlString(options: [.nodePrettyPrint])
    }
}
