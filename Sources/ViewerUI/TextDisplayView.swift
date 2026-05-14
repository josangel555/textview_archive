import AppKit
import SwiftUI

/// Read-only monospaced text view backed by `NSTextView`. Wraps lines to the
/// view's visible width so source mode reads top-to-bottom without horizontal
/// scrolling. Line numbers in a `LineNumberRulerView` on the left.
public struct TextDisplayView: NSViewRepresentable {
    public let text: String
    public let fontSize: CGFloat

    public init(text: String, fontSize: CGFloat = 13) {
        self.text = text
        self.fontSize = fontSize
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        // Read-only display configuration.
        textView.isEditable = false
        textView.isRichText = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        // Critical: make the text container track the text view's width so
        // long lines wrap inside the visible viewport instead of extending
        // off-screen by 1e7 points (the default for scrollableTextView()).
        // Without these three lines the source view appears "blank" for any
        // file where the first visible line is long enough to scroll the
        // viewport past the gutter.
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.containerSize = NSSize(
                width: scrollView.contentSize.width,
                height: .greatestFiniteMagnitude
            )
        }

        textView.string = text

        // Line numbers gutter.
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let desiredFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if textView.font != desiredFont {
            textView.font = desiredFont
        }
        if textView.string != text {
            textView.string = text
            (scrollView.verticalRulerView as? LineNumberRulerView)?.invalidateLineCache()
            // Force the layout manager to compute glyphs immediately so the
            // ruler has accurate line fragments to draw against on first
            // appearance after a Rendered→Source toggle.
            if let lm = textView.layoutManager, let c = textView.textContainer {
                lm.ensureLayout(for: c)
            }
        }
    }
}
