import SwiftUI

/// TSK-679 follow-up (owner wishlist, L861): the vim mode chip should color
/// NORMAL / INSERT / VISUAL distinctly instead of one flat accent color. CM6's
/// raw mode string varies ("NORMAL", "INSERT", "VISUAL", "VISUAL LINE",
/// "VISUAL BLOCK", "REPLACE", …); this classifier is the HOST-TESTABLE half —
/// the chip's actual `Color` is the render tail (review/VM).
public enum VimModeKind: Equatable, Sendable {
    case normal, insert, visual, replace, other

    /// Classify a raw CM6 vim-mode string, case- and spacing-insensitively.
    /// Prefix-matches so "VISUAL LINE"/"VISUAL BLOCK" both map to `.visual`.
    public static func from(_ raw: String) -> VimModeKind {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.isEmpty { return .other }
        if s.hasPrefix("INSERT")  { return .insert }
        if s.hasPrefix("VISUAL")  { return .visual }
        if s.hasPrefix("REPLACE") { return .replace }
        if s.hasPrefix("NORMAL")  { return .normal }
        return .other
    }

    /// Per-mode chip color (render side — host tests cover `from`, not pixels).
    public var color: Color {
        switch self {
        case .normal:  return .accentColor
        case .insert:  return .green
        case .visual:  return .orange
        case .replace: return .red
        case .other:   return .secondary
        }
    }
}
