import Foundation

/// One entry point for "extract displayable text from a supported rich/office
/// document" — dispatches by extension to the format readers landed this
/// session (docx/rtf/ods). The viewer routing (TSK-1036) calls THIS rather than
/// switching over the individual readers; keeps the render-integration thin.
public enum MultiFormatReader {

    /// Extensions this reader can turn into displayable text.
    public static let supportedExtensions: Set<String> = ["docx", "rtf", "ods"]

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Extracted plain text, or nil if the extension isn't supported or the
    /// file can't be read/parsed.
    public static func extractedText(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "docx":
            return (try? DocxTextExtractor.load(url))?.joined(separator: "\n")
        case "ods":
            // Tab-separate cells, newline-separate rows (grid → text preview).
            return (try? ODSContentParser.load(url))?
                .map { $0.joined(separator: "\t") }
                .joined(separator: "\n")
        case "rtf":
            guard let data = try? Data(contentsOf: url) else { return nil }
            // RTF is ASCII control words + escapes; fall back to Latin-1 for raw
            // high bytes if it isn't valid UTF-8.
            guard let raw = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1) else { return nil }
            return RtfTextExtractor.plainText(raw)
        default:
            return nil
        }
    }
}
