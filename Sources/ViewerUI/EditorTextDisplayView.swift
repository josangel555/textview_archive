import AppKit
import SwiftUI

/// Editable plain-text view. Minimal-on-purpose PoC sibling to the
/// read-only `TextDisplayView`. Wraps an `NSTextView` inside an
/// `NSScrollView`, monospace font, no syntax highlighting, no fancy
/// gutter. Routes every keystroke back to the owner via
/// `onTextChange` so the model can flip the tab's dirty flag.
///
/// Hosted via `NSViewControllerRepresentable` — same compositor-
/// stability reason as `TextDisplayView` (see that file's header for
/// the WindowServer-commit bug). Plain `NSViewRepresentable` causes
/// sibling SwiftUI views to stop rendering when an `NSScrollView` is
/// mounted as a direct child.
public struct EditorTextDisplayView: NSViewControllerRepresentable {
    public let text: String
    public let fontSize: CGFloat
    public let onTextChange: (String) -> Void

    public init(
        text: String,
        fontSize: CGFloat = 13,
        onTextChange: @escaping (String) -> Void
    ) {
        self.text = text
        self.fontSize = fontSize
        self.onTextChange = onTextChange
    }

    public func makeNSViewController(context: Context) -> EditorTextController {
        let vc = EditorTextController(initialText: text, fontSize: fontSize)
        vc.onTextChange = onTextChange
        return vc
    }

    public func updateNSViewController(_ vc: EditorTextController, context: Context) {
        vc.onTextChange = onTextChange
        vc.apply(text: text, fontSize: fontSize)
    }
}

/// AppKit-side controller for `EditorTextDisplayView`. Owns the
/// `NSScrollView` + `NSTextView` lifecycle and is the
/// `NSTextViewDelegate` that bridges typing back to SwiftUI.
public final class EditorTextController: NSViewController, NSTextViewDelegate {
    fileprivate var textView: NSTextView!
    fileprivate var scrollView: NSScrollView!
    fileprivate var currentText: String
    fileprivate var currentFontSize: CGFloat
    /// Set by `updateNSViewController` on every body re-eval. Captured
    /// by reference rather than by value so each `textDidChange:` uses
    /// the latest closure (SwiftUI rebuilds the closure each pass when
    /// it captures state).
    var onTextChange: ((String) -> Void)?

    init(initialText: String, fontSize: CGFloat) {
        self.currentText = initialText
        self.currentFontSize = fontSize
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    public override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true

        let contentSize = scroll.contentSize
        // Match the read-only source view's "fill the scroll width,
        // grow vertically with content" sizing. Without these flags
        // the text view would size to its intrinsic and the scroll
        // view would scroll horizontally even with word-wrap on.
        let tv = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        tv.minSize = NSSize(width: 0, height: contentSize.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(
            width: contentSize.width, height: CGFloat.greatestFiniteMagnitude
        )
        tv.textContainer?.widthTracksTextView = true

        // Editing config — the whole point of this view.
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.font = NSFont.monospacedSystemFont(ofSize: currentFontSize, weight: .regular)
        tv.string = currentText
        tv.delegate = self
        // Use the built-in find bar so ⌘F works in editor mode just
        // like it does in source mode.
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        // Accessibility identifier for VM UI tests.
        tv.setAccessibilityIdentifier("mdv.editor.textView")

        scroll.documentView = tv
        scroll.setAccessibilityIdentifier("mdv.editor.scrollView")

        self.scrollView = scroll
        self.textView = tv
        self.view = scroll
    }

    /// Push a new value from SwiftUI. Skips when the visible text
    /// already matches — common when the user is the one driving
    /// changes (we just sent them through `textDidChange:`).
    func apply(text: String, fontSize: CGFloat) {
        if currentFontSize != fontSize {
            currentFontSize = fontSize
            textView.font = NSFont.monospacedSystemFont(
                ofSize: fontSize, weight: .regular
            )
        }
        if textView.string != text {
            // External update (load completion, conflict-resolve
            // reload). Replace contents while preserving caret as
            // best we can — `setString:` resets to (0,0), which is
            // fine for the load-completion case and acceptable for
            // discard-and-reload.
            textView.string = text
            currentText = text
        }
    }

    // MARK: NSTextViewDelegate

    public func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        currentText = tv.string
        onTextChange?(currentText)
    }
}
