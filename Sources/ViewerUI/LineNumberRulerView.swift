import AppKit

/// `NSRulerView` subclass that paints line numbers down the left margin of a
/// non-editable `NSTextView`. Survives scrolling/resize via standard
/// NSRulerView hooks; no manual sync needed.
///
/// ⚠️ INTENTIONALLY RETAINED — DO NOT DELETE (TSK-477). This looks like dead
/// legacy: the editable CodeMirror 6 editor draws its own gutter, and other
/// gutter work (#102) replaced line numbers elsewhere. But this view is STILL
/// the live line-number renderer for the read-only **Source** lens —
/// `TextDisplayView`'s `NSScrollView + NSTextView` triple attaches it (see
/// `TextDisplayView.swift:416`). A prior pass already tried to drop it (batch
/// #64) before that dependency was understood; removing it silently strips the
/// Source view's gutter. If you think it's unused, grep `LineNumberRulerView`
/// across `Sources/` first.
///
/// P4: a flat array of newline character offsets is built once when the
/// view's text changes (see `invalidateLineCache()` called from
/// `TextDisplayView.updateNSView`). Drawing then binary-searches it
/// to find the first visible line in O(log N) instead of walking the
/// buffer from offset 0 every draw (O(N) per draw → catastrophic when
/// scrolled to the end of a 100k-line log).
public final class LineNumberRulerView: NSRulerView {
    private let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private let inset: CGFloat = 6

    /// UTF-16 indices of every `\n` byte in the current text, ascending.
    /// `nil` until `ensureCacheBuilt` runs. Cleared by `invalidateLineCache`.
    private var newlineOffsets: [Int]?

    public init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    public required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Called by `TextDisplayView` whenever the bound text changes so we
    /// rebuild the offset table on the next draw.
    public func invalidateLineCache() {
        newlineOffsets = nil
        needsDisplay = true
    }

    public override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        rect.fill()

        NSColor.separatorColor.setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        separator.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        separator.lineWidth = 0.5
        separator.stroke()

        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        ensureCacheBuilt(text: textView.string)

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

        var lineNumber = self.lineNumber(forCharIndex: visibleCharStart)
        var charIndex = lineStart(forLine: lineNumber)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        while charIndex <= textLength {
            let glyphIdx = layoutManager.glyphIndexForCharacter(
                at: min(charIndex, max(textLength - 1, 0))
            )
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

            let lineEnd = NSMaxRange(effectiveRange)
            if lineEnd <= charIndex { break }
            charIndex = lineEnd
            lineNumber += 1
            if charIndex >= textLength { break }
        }
    }

    // MARK: - Cache + binary search

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

    /// 1-based line number for a UTF-16 character index. Computed by binary-
    /// searching the cached `\n` offsets: the line number equals
    /// "count of newlines strictly before charIndex" + 1.
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

    /// Character index where line N (1-based) starts.
    private func lineStart(forLine n: Int) -> Int {
        guard let offsets = newlineOffsets else { return 0 }
        if n <= 1 { return 0 }
        let idx = n - 2  // line N starts immediately after the (N-1)th newline
        if idx < offsets.count { return offsets[idx] + 1 }
        return 0
    }
}
