import AppKit
import SwiftUI

/// Read-only monospaced text view backed by `NSTextView`. Lines do
/// **not** wrap — long lines scroll horizontally, matching every other
/// code/source viewer on the platform. Line numbers are drawn by a
/// sibling `LineNumberGutterView` (see GutterScrollView.swift), NOT via
/// NSRulerView, because the latter triggers a macOS-14+ SwiftUI
/// compositing bug. See FINDINGS.md.
public struct TextDisplayView: NSViewRepresentable {
    public let text: String
    public let fontSize: CGFloat

    public init(text: String, fontSize: CGFloat = 13) {
        self.text = text
        self.fontSize = fontSize
    }

    public func makeNSView(context: Context) -> GutterScrollContainerView {
        // Build NSTextView with **explicit TextKit 1** stack instead of the
        // `NSTextView.scrollableTextView()` factory (which uses TextKit 2 by
        // default in macOS 14+). TextKit 2 + NSHostingView has a known
        // rendering pathology where the text storage is populated and
        // glyphs are laid out, but the layer never commits drawn contents
        // to the window server, producing a window that shows the line
        // number ruler (traditional NSRulerView drawing) and empty white
        // where the text should be. Building TextKit 1 manually bypasses it.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(containerSize: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = false   // long lines scroll, not wrap
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)

        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isRichText = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // Explicitly suppress the macOS 14+ `_NSScrollViewContentBackgroundView`
        // (an NSVisualEffectView). It's a second-order suspect for the
        // compositing pathology — and we're handling the background on
        // the text view anyway.
        scrollView.drawsBackground = false

        return GutterScrollContainerView(scrollView: scrollView, textView: textView)
    }

    public func updateNSView(_ container: GutterScrollContainerView, context: Context) {
        guard let textView = container.scrollView.documentView as? NSTextView else { return }
        let desiredFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if textView.font != desiredFont {
            textView.font = desiredFont
        }
        if textView.string != text {
            textView.string = text
            container.gutter.invalidateLineCache()
        }
    }
}
