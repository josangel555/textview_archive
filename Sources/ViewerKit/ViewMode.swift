import Foundation

/// How a file is currently being displayed. The set of available
/// modes varies by file type; the always-on baseline is `source`
/// + `hex`, with `rendered` and `formatted` opt-in for files that
/// support them.
public enum ViewMode: String, Equatable, Sendable, CaseIterable {
    case rendered    // markdown only: WKWebView-rendered HTML
    case source      // every text file: NSTextView with syntax highlight
    case formatted   // JSON / XML / etc.: pretty-printed source
    case hex         // every file: byte grid
}

/// Computes which view modes are reachable for a given URL. Always
/// includes `.source` + `.hex`. Adds `.rendered` for markdown and
/// `.formatted` when the URL has a registered pretty-printer.
public enum ViewModeOptions {
    public static func availableModes(for url: URL?) -> [ViewMode] {
        guard let url else { return [.source, .hex] }
        var modes: [ViewMode] = [.source]
        let cat = FileTypeDetector.category(for: url)
        if cat == .markdown { modes.insert(.rendered, at: 0) }
        // Formatted is opt-in per file type. We mirror the existing
        // Formatter.SupportedFormat list (JSON / XML / plist / svg
        // etc.) but check it via a stable URL test that doesn't pull
        // ViewerCore into ViewerKit.
        if Self.supportsFormatting(url) { modes.append(.formatted) }
        modes.append(.hex)
        return modes
    }

    private static let formatterExtensions: Set<String> = [
        "json", "jsonl", "xml", "plist", "xib", "storyboard", "svg",
        "html", "htm", "xhtml"
    ]

    private static func supportsFormatting(_ url: URL) -> Bool {
        formatterExtensions.contains(url.pathExtension.lowercased())
    }
}
