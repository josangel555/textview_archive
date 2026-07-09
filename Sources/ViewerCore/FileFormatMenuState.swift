import Foundation

/// TSK-1480 — pure resolution of the Convert submenus' current-value markers so
/// the user isn't converting blind. `menuNeedsUpdate` computes the active file's
/// encoding / line-ending / indent, calls `resolve`, and applies the result to
/// the NSMenuItems (check-marks on the encoding + EOL value-pickers; a "Current:"
/// header on the direction-based Indent submenu). Pure + host-tested; the AppKit
/// application is thin glue.
public enum FileFormatMenuState {

    public struct Resolution: Equatable, Sendable {
        /// Index into the Convert Encoding choices to check (nil = current
        /// encoding isn't one of the offered choices → nothing checked).
        public let checkedEncodingIndex: Int?
        /// Index into the Convert Line Endings choices to check.
        public let checkedLineEndingIndex: Int?
        /// Disabled header for the Convert Indentation submenu (it offers
        /// directions, not values, so a check-mark can't express "current").
        public let indentHeader: String

        public init(checkedEncodingIndex: Int?, checkedLineEndingIndex: Int?, indentHeader: String) {
            self.checkedEncodingIndex = checkedEncodingIndex
            self.checkedLineEndingIndex = checkedLineEndingIndex
            self.indentHeader = indentHeader
        }
    }

    /// Resolve the markers for the active file's detected format against the
    /// menus' offered choices.
    public static func resolve(
        encoding: String.Encoding,
        lineEnding: LineEnding,
        indent: IndentStyleDetector.Style,
        encodingChoices: [String.Encoding],
        lineEndingChoices: [LineEnding]
    ) -> Resolution {
        Resolution(
            checkedEncodingIndex: encodingChoices.firstIndex(of: encoding),
            // A file with no line endings yet (single line / empty) has no
            // current convention to mark.
            checkedLineEndingIndex: lineEnding == .none
                ? nil : lineEndingChoices.firstIndex(of: lineEnding),
            indentHeader: indentHeaderLabel(indent))
    }

    /// "Current: Spaces (4)" / "Current: Tabs" / "Current: —" for the Indent
    /// submenu header. Never empty (the header row is always shown so the user
    /// sees what the file IS even when it's indeterminate).
    public static func indentHeaderLabel(_ indent: IndentStyleDetector.Style) -> String {
        if case .none = indent { return "Current: —" }
        return "Current: \(indent.label)"
    }
}
