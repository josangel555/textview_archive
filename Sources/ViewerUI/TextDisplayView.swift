import AppKit
import SwiftUI

/// Read-only monospaced text view backed by `NSTextView`, hosted by an
/// `NSScrollView` from the standard `NSTextView.scrollableTextView()`
/// factory. Lines do **not** wrap — long lines scroll horizontally,
/// matching every other code/source viewer on the platform. Line numbers
/// in a `LineNumberRulerView` on the left.
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
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
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
        textView.string = text

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
        }
    }
}
