import AppKit
import SwiftUI

/// Read-only monospaced text view backed by `NSTextView`. This is the
/// foundation for the future plaintext, code, and (with attribute spans)
/// syntax-highlit viewers.
public struct TextDisplayView: NSViewRepresentable {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder

        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isRichText = false
            textView.isSelectable = true
            textView.allowsUndo = false
            textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            textView.textContainerInset = NSSize(width: 10, height: 10)
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.string = text

            // Line numbers gutter.
            let ruler = LineNumberRulerView(textView: textView)
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        }
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            scrollView.verticalRulerView?.needsDisplay = true
        }
    }
}
