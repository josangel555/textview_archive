import AppKit

/// `NSRulerView` subclass that paints line numbers down the left margin of a
/// non-editable `NSTextView`. Survives scrolling/resize via standard
/// NSRulerView hooks; no manual sync needed.
final class LineNumberRulerView: NSRulerView {
    private let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private let inset: CGFloat = 6

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // Background.
        NSColor.controlBackgroundColor.setFill()
        rect.fill()

        // Subtle separator.
        NSColor.separatorColor.setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        separator.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        separator.lineWidth = 0.5
        separator.stroke()

        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let nsText = textView.string as NSString
        let textLength = nsText.length
        let containerInset = textView.textContainerInset.height
        let visibleRect = textView.visibleRect

        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect, in: container
        )
        let visibleCharStart = layoutManager.characterIndexForGlyph(
            at: visibleGlyphRange.location
        )

        // Walk from start of buffer to first visible char, counting newlines.
        var lineNumber = 1
        var charIndex = 0
        while charIndex < visibleCharStart && charIndex < textLength {
            if nsText.character(at: charIndex) == 0x0A {
                lineNumber += 1
            }
            charIndex += 1
        }
        // If we landed inside a line, that whole line gets the *next* number
        // when we begin iterating; restart at the line start.
        while charIndex > 0 && nsText.character(at: charIndex - 1) != 0x0A {
            charIndex -= 1
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        while charIndex <= textLength {
            let glyphIdx = layoutManager.glyphIndexForCharacter(at: min(charIndex, max(textLength - 1, 0)))
            var effectiveRange = NSRange()
            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIdx, effectiveRange: &effectiveRange
            )
            let y = lineRect.minY + containerInset - visibleRect.minY

            if y > bounds.maxY { break }
            if y + lineRect.height >= bounds.minY {
                let label = "\(lineNumber)" as NSString
                let size = label.size(withAttributes: attrs)
                let x = ruleThickness - size.width - inset
                label.draw(at: NSPoint(x: x, y: y + 1), withAttributes: attrs)
            }

            // Advance to next line's first character.
            let lineEnd = NSMaxRange(effectiveRange)
            if lineEnd <= charIndex { break }
            charIndex = lineEnd
            lineNumber += 1
            if charIndex >= textLength { break }
        }
    }
}
