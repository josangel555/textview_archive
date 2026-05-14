import AppKit

/// `NSRulerView` subclass that paints line numbers down the left margin of a
/// non-editable `NSTextView`. Defensive about empty / partially-laid-out
/// state — never throws or crashes, just draws nothing if the layout
/// manager can't answer.
final class LineNumberRulerView: NSRulerView {
    private let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private let horizontalInset: CGFloat = 6
    private var newlineOffsets: [Int]?

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func invalidateLineCache() {
        newlineOffsets = nil
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // Background fill clipped to the dirty rect.
        NSColor.controlBackgroundColor.setFill()
        rect.fill()

        // Right-edge separator.
        NSColor.separatorColor.setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        separator.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        separator.lineWidth = 0.5
        separator.stroke()

        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return }

        let nsText = textView.string as NSString
        if nsText.length == 0 { return }

        let visibleRect = textView.visibleRect
        if visibleRect.width <= 0 || visibleRect.height <= 0 { return }

        ensureCacheBuilt(text: textView.string)

        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect, in: textContainer
        )
        if glyphRange.length == 0 { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let containerInsetY = textView.textContainerInset.height

        layoutManager.enumerateLineFragments(
            forGlyphRange: glyphRange
        ) { [self] lineRect, _, _, lineGlyphRange, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: lineGlyphRange.location)
            let number = self.lineNumber(forCharIndex: charIndex)
            let yInTextView = lineRect.minY + containerInsetY
            let yInRuler = yInTextView - visibleRect.minY

            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attrs)
            let x = self.ruleThickness - size.width - self.horizontalInset
            label.draw(at: NSPoint(x: max(x, 2), y: yInRuler + 1), withAttributes: attrs)
        }
    }

    // MARK: - Newline-offset cache + binary search

    private func ensureCacheBuilt(text: String) {
        guard newlineOffsets == nil else { return }
        let ns = text as NSString
        var offsets: [Int] = []
        offsets.reserveCapacity(max(ns.length / 50, 16))
        var i = 0
        while i < ns.length {
            if ns.character(at: i) == 0x0A {
                offsets.append(i)
            }
            i += 1
        }
        newlineOffsets = offsets
    }

    private func lineNumber(forCharIndex charIndex: Int) -> Int {
        guard let offsets = newlineOffsets, !offsets.isEmpty else { return 1 }
        var lo = 0
        var hi = offsets.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if offsets[mid] < charIndex { lo = mid + 1 } else { hi = mid }
        }
        return lo + 1
    }
}
