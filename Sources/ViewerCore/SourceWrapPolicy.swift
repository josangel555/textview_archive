import Foundation

/// Decides when the read-only source `NSTextView` must soft-wrap regardless of
/// the user's wrap preference (TSK-361).
///
/// A single pathologically long line — a Jupyter `.ipynb` with a base64 image
/// blob, a minified JS/CSS bundle, a one-line JSON dump — makes `NSTextView`'s
/// HORIZONTAL layout superlinear in line width and hangs the main thread for
/// seconds when the file opens (the owner had to force-kill the app). Soft-wrap
/// bounds layout to the viewport width, so forcing it on for such files keeps
/// the open responsive while still showing the content (no lockout).
///
/// Pure — host-testable; the view layer (`SourceTextController.apply`) calls
/// `effectiveWrap` and configures the text container from the result.
public enum SourceWrapPolicy {

    /// A line at least this many characters long forces wrap. Set high enough
    /// that ordinary code (even long minified-ish lines) is unaffected, but
    /// below the length where `NSTextView` horizontal layout starts to stall.
    public static let forceWrapLineLength = 100_000

    /// True if `text` contains any line `threshold` characters or longer.
    /// Early-exits at the first over-long line (O(1) for the pathological case),
    /// otherwise a single linear scan. Counts Unicode scalars and resets at any
    /// line break (`\n` or `\r`, so CRLF and classic-Mac CR both split lines).
    public static func hasLongLine(_ text: String, threshold: Int = forceWrapLineLength) -> Bool {
        guard threshold > 0 else { return false }
        var lineLength = 0
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" {
                lineLength = 0
            } else {
                lineLength += 1
                if lineLength >= threshold { return true }
            }
        }
        return false
    }

    /// Effective soft-wrap: the user's preference OR a hang-prone long line
    /// (the latter overrides the preference for safety).
    public static func effectiveWrap(
        userWrap: Bool, text: String, threshold: Int = forceWrapLineLength
    ) -> Bool {
        userWrap || hasLongLine(text, threshold: threshold)
    }
}
