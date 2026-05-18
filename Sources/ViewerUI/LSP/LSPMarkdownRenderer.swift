import AppKit
import Foundation

/// Render `LSPHover.contents` into an `NSAttributedString` suitable for
/// the hover popover.
///
/// Strategy: use Foundation's `AttributedString(markdown:options:)` for
/// the structured-inline subset (bold / italic / code spans / links)
/// and then layer on AppKit-specific attributes (monospaced font for
/// fenced code blocks, label color for foreground). The full CommonMark
/// surface is not parsed by Foundation — its `markdown:` initializer
/// only handles inline markup — so we do the **fenced-code-block**
/// pass ourselves first, since hover responses lean heavily on those.
///
/// Why not pull in our own markdown package? `swift-markdown` is
/// already in the dep graph (`ViewerCore`) but it's overkill for hover
/// rendering — its output is a tree we'd have to traverse and re-style
/// from scratch, ~200 lines for what Foundation does in 5. We use
/// `Markdown` for the *file viewer* because we need the full structure;
/// hover popover uses Foundation's lightweight path.
@MainActor
public enum LSPMarkdownRenderer {

    /// Render `contents` (markdown or plain text) into an attributed
    /// string ready for `NSTextView.textStorage.setAttributedString`.
    public static func attributedString(
        from contents: String, isMarkdown: Bool
    ) -> NSAttributedString {
        if !isMarkdown {
            return plain(contents)
        }
        return renderMarkdown(contents)
    }

    private static func plain(_ s: String) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        return NSAttributedString(string: s, attributes: attrs)
    }

    // MARK: - Markdown rendering

    private static func renderMarkdown(_ source: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        let codeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(
                ofSize: NSFont.systemFontSize - 1, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.textBackgroundColor.withAlphaComponent(0.6),
        ]
        // Split on fenced-code-block boundaries. A simple line-based
        // pass: collect lines, toggle code/body mode on ``` markers.
        let lines = source.components(separatedBy: "\n")
        var inCode = false
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: "\n")
            paragraph.removeAll(keepingCapacity: true)
            // Inline pass via AttributedString(markdown:). The full-
            // body block-level markdown is what we just did manually
            // (paragraphs split by blank lines); here we render inline.
            let rendered: NSAttributedString
            if let attr = try? AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                rendered = NSAttributedString(attr)
            } else {
                rendered = NSAttributedString(string: text)
            }
            // Re-apply body attrs as a baseline (the markdown attrs are
            // semantic — `.inlinePresentationIntent` etc. — and don't
            // include font/color unless we map them. AppKit's NSAttributedString
            // bridge does pick up bold/italic via `.font` so we set
            // the base font here and let the bridge override per-run).
            let mut = NSMutableAttributedString(attributedString: rendered)
            mut.addAttributes(bodyAttrs, range: NSRange(location: 0, length: mut.length))
            // The markdown parser sets `.inlinePresentationIntent` for
            // bold/italic/code; bridge that to actual font traits.
            applyInlineTraits(in: mut)
            out.append(mut)
            out.append(NSAttributedString(string: "\n", attributes: bodyAttrs))
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushParagraph()
                inCode.toggle()
                continue
            }
            if inCode {
                out.append(NSAttributedString(
                    string: line + "\n", attributes: codeAttrs))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        // Trim trailing newline for tidy popover sizing.
        while out.length > 0,
              (out.string as NSString).substring(from: out.length - 1) == "\n" {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    /// Re-apply font traits from the markdown parser's
    /// `.inlinePresentationIntent` attribute to the underlying NSFont
    /// runs. Foundation's bridge to NSAttributedString does *not*
    /// translate these to font traits automatically.
    private static func applyInlineTraits(in attr: NSMutableAttributedString) {
        let full = NSRange(location: 0, length: attr.length)
        attr.enumerateAttribute(
            .init("NSInlinePresentationIntent"),
            in: full
        ) { value, range, _ in
            // The value is an Int representing OptionSet bits of
            // `InlinePresentationIntent`. Bits we care about (from the
            // Foundation source, stable across releases):
            //   1 = .emphasized (italic)
            //   2 = .stronglyEmphasized (bold)
            //   4 = .code
            guard let raw = value as? Int else { return }
            let isItalic = (raw & 1) != 0
            let isBold   = (raw & 2) != 0
            let isCode   = (raw & 4) != 0

            let existing = attr.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
                ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            var traits: NSFontDescriptor.SymbolicTraits = []
            if isBold   { traits.insert(.bold) }
            if isItalic { traits.insert(.italic) }
            var font = existing
            if !traits.isEmpty {
                let desc = existing.fontDescriptor.withSymbolicTraits(traits)
                font = NSFont(descriptor: desc, size: existing.pointSize) ?? existing
            }
            if isCode {
                font = NSFont.monospacedSystemFont(
                    ofSize: existing.pointSize - 1, weight: .regular)
            }
            attr.addAttribute(.font, value: font, range: range)
        }
    }
}
