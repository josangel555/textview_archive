import Foundation

/// Closed, hyper-restricted Markdown IR for the Docs-style RichText editor
/// (TSK-706, foundation slice). This is deliberately NOT a CommonMark tree: it
/// is a *constrained subset* whose vocabulary is fixed and exhaustive, so the
/// editor (and any later WYSIWYG toolbar) only ever has a small, known set of
/// constructs to render and round-trip.
///
/// ## Allowed vocabulary (and ONLY this)
///   - **Blocks:** headings H1–H3, paragraph, bullet (unordered) list, ordered
///     list, blockquote.
///   - **Inline:** plain text, bold, italic, strikethrough, inline code, link.
///
/// ## Explicitly excluded (downgraded by ``RichTextNormalizer``)
/// Tables, raw/inline HTML, indented/fenced code blocks, images, H4–H6,
/// horizontal rules, footnotes, task-list checkboxes, nested lists deeper than
/// the model allows, etc. Disallowed input is mapped to the *nearest* allowed
/// construct (often plain text) — it NEVER produces an out-of-vocabulary node.
///
/// Pure + dependency-free, mirroring `MarkdownOutline` / `MarkdownLinks`. The
/// whole pipeline (parse → normalize → serialize) is host-testable; the
/// read-only stacked render is a later slice behind a flag.

// MARK: - Inline IR

/// A single inline run. The vocabulary is closed: a parser/normalizer MUST map
/// everything into exactly one of these cases.
public indirect enum RichInline: Equatable, Sendable {
    /// Literal text. Carries no markup. The canonical leaf.
    case text(String)
    /// Strong emphasis (`**…**`). Children are themselves restricted inline.
    case bold([RichInline])
    /// Emphasis (`*…*` / `_…_`).
    case italic([RichInline])
    /// Strikethrough (`~~…~~`).
    case strike([RichInline])
    /// Inline code span (`` `…` ``). Content is opaque literal text (never
    /// re-parsed for markup).
    case code(String)
    /// A link. `text` is the restricted-inline label; `url` is the destination.
    case link(text: [RichInline], url: String)
}

// MARK: - Block IR

/// One list item: a sequence of restricted inline runs. (Block-level nesting
/// inside list items — sub-lists, paragraphs — is intentionally out of scope
/// for this restricted model; ``RichTextNormalizer`` flattens such input.)
public struct RichListItem: Equatable, Sendable {
    public var inlines: [RichInline]
    public init(_ inlines: [RichInline]) { self.inlines = inlines }
}

/// A block node. Closed vocabulary — every block in a `RichTextDocument` is one
/// of these and nothing else.
public enum RichBlock: Equatable, Sendable {
    /// Heading, `level` constrained to 1...3. The initializer clamps; the
    /// parser never emits H4+ (they're downgraded to a paragraph upstream).
    case heading(level: Int, inlines: [RichInline])
    /// A normal paragraph.
    case paragraph([RichInline])
    /// An unordered (bullet) list.
    case bulletList([RichListItem])
    /// An ordered (numbered) list. `start` is the first item's number
    /// (canonical serialization renumbers sequentially from `start`).
    case orderedList(start: Int, items: [RichListItem])
    /// A blockquote. Restricted: its content is a flat sequence of paragraphs
    /// (no nested blockquotes/lists/headings inside — those are flattened).
    case blockquote([[RichInline]])
    /// A fenced code block — opaque literal text (newlines preserved), serialized
    /// as a ```-fence. TSK-1327: a rich-paste of `<pre>`/`<pre><code>` (browser /
    /// doc copy) must survive as a real code block, not collapse into invalid
    /// inline-code-with-newlines.
    case codeBlock(String)
    /// A GFM pipe table — `header` cells + `rows` of cells (each cell is inline
    /// content). TSK-1427: a rich-paste of `<table>` (browser/spreadsheet copy)
    /// must survive as a Markdown table, not collapse all cells into one run.
    case table(header: [[RichInline]], rows: [[[RichInline]]])

    /// The allowed heading levels for this restricted model.
    public static let maxHeadingLevel = 3
}

// MARK: - Document

/// The top-level restricted document: an ordered list of allowed blocks.
public struct RichTextDocument: Equatable, Sendable {
    public var blocks: [RichBlock]
    public init(_ blocks: [RichBlock] = []) { self.blocks = blocks }

    /// Parse arbitrary Markdown text into the restricted IR. The result is
    /// ALWAYS in-vocabulary: disallowed constructs are downgraded to the
    /// nearest allowed form (see ``RichTextNormalizer``). Equivalent to
    /// `RichTextNormalizer.normalize(RichTextParser.parse(text))` but the
    /// parser already only ever emits allowed nodes, so the normalize pass is a
    /// no-op stabilizer for parser output and a real downgrade only for IR
    /// constructed by hand / from a less-restricted source.
    public static func parse(_ text: String) -> RichTextDocument {
        RichTextNormalizer.normalize(RichTextParser.parse(text))
    }

    /// Serialize back to canonical, restricted Markdown. Round-trips: for
    /// allowed-only input, `parse(serialize(parse(x))) == parse(x)`.
    public func serialized() -> String {
        RichTextSerializer.serialize(self)
    }
}
