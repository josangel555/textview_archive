import Foundation

/// One highlighted span. `range` is an NSRange into the source string
/// using UTF-16 offsets (AppKit/SwiftUI's text model). `Sendable` so it
/// crosses the off-main-engine → main-actor publish boundary cleanly.
public struct HighlightRun: Sendable, Equatable {
    public let range: NSRange
    public let kind: TokenKind

    public init(range: NSRange, kind: TokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// Semantic categories the engine emits. Themes map these to colors.
/// Deliberately small + language-neutral — "this is a keyword" rather
/// than "this is an `if`" — so a theme doesn't need per-language tables.
public enum TokenKind: String, Sendable, CaseIterable, Codable {
    case keyword
    case string
    case comment
    case number
    case type
    case function
    case variable
    case attribute
    case `operator`
    case punctuation
    case builtin
    case regex
    case escape
    case heading
    case link
    case emphasis
    case strong
    case tag
    case tagAttribute
    case constant
}

/// Soft cap: skip highlighting any file larger than this. Above this
/// size the query phase + attribute application start dominating
/// frame budget — the coloring hurts more than it helps. Plain text
/// still renders. Was 2 MB; lowered to 512 KB after 1-MB JSON files
/// were observed to crawl in source mode (the full pipeline cost
/// per render: paintOver canvas alloc + N×addAttribute + layout).
public let highlightMaxBytes: Int = 512 * 1024
