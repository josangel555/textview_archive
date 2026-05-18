import AppKit
import SwiftUI

/// Static palette of `Color(nsColor:)` wrappers around AppKit's
/// dynamic system colors. `Color(nsColor:)` itself does not cache —
/// every call snapshots the dynamic color into a fresh wrapper.
/// In a per-cell / per-row builder (CSV table, SQLite results,
/// gutter Canvas, tab bar, sidebar rows) those allocations multiply
/// across redraws.
///
/// All callers should reach for `Palette.X` instead of constructing
/// a new `Color(nsColor: .X)`. The values stay dynamic because
/// `NSColor.controlBackgroundColor` etc. ARE dynamic at draw time;
/// SwiftUI re-resolves them on appearance changes.
enum Palette {
    static let windowBackground   = Color(nsColor: .windowBackgroundColor)
    static let controlBackground  = Color(nsColor: .controlBackgroundColor)
    static let separator          = Color(nsColor: .separatorColor)
    static let textBackground     = Color(nsColor: .textBackgroundColor)
    static let underPageBackground = Color(nsColor: .underPageBackgroundColor)
    static let selectedContentBackground = Color(nsColor: .selectedContentBackgroundColor)
    static let labelColor         = Color(nsColor: .labelColor)
    static let secondaryLabel     = Color(nsColor: .secondaryLabelColor)
    static let tertiaryLabel      = Color(nsColor: .tertiaryLabelColor)
}
