import Foundation

/// A uniform (title, description) pair for an interactive UI element.
///
/// Replaces ad-hoc single-string `.help(...)` tooltips with a two-part
/// model: a short `title` (what the native macOS tooltip bubble and the
/// accessibility label show) plus a longer `description` (surfaced in the
/// status bar's hover-description slot and the accessibility hint).
///
/// Foundation-only, `Sendable`, `Equatable` — the value can be compared so
/// a hover sink can dedupe equal values and avoid republishing on every
/// pointer move (REPUB-1 discipline).
public struct HelpInfo: Equatable, Sendable {
    public let title: String
    public let description: String

    public init(title: String, description: String) {
        self.title = title
        self.description = description
    }
}
