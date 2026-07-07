import Foundation

/// TSK-1480 — the current encoding / line-ending / indent style of a file,
/// aggregated for the footer chip ("UTF-8 · LF · Spaces:4") and the Format
/// submenus' check-marks. Pure; the view layer reads `.footerLabel` and
/// per-facet fields. Encoding is known at load; EOL + indent are cheap
/// scans over the current text.
public struct FileFormatState: Equatable, Sendable {
    public let encodingLabel: String
    public let lineEnding: LineEnding
    public let indent: IndentStyleDetector.Style

    public init(encodingLabel: String, lineEnding: LineEnding, indent: IndentStyleDetector.Style) {
        self.encodingLabel = encodingLabel
        self.lineEnding = lineEnding
        self.indent = indent
    }

    /// Compute from the live text + a known encoding label.
    public static func detect(text: String, encodingLabel: String) -> FileFormatState {
        FileFormatState(
            encodingLabel: encodingLabel,
            lineEnding: LineEndingDetector.detect(in: text),
            indent: IndentStyleDetector.detect(in: text))
    }

    /// The footer chip: dot-separated, omitting facets that are unknown
    /// (empty encoding / .none EOL / .none indent) so a blank file shows
    /// only what's real.
    public var footerLabel: String {
        var parts: [String] = []
        if !encodingLabel.isEmpty { parts.append(encodingLabel) }
        if lineEnding != .none { parts.append(lineEnding.rawValue) }
        if case .none = indent {} else { parts.append(indent.label) }
        return parts.joined(separator: " · ")
    }
}
