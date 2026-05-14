import AppKit

/// Container view that lays out a line-number gutter alongside an
/// `NSScrollView`. Replaces the earlier `LineNumberRulerView` /
/// `NSScrollView.verticalRulerView` approach, which caused a macOS 14+
/// SwiftUI compositing pathology where installing the ruler made every
/// SwiftUI-hosted layer in the window stop committing contents.
/// See FINDINGS.md for the investigation.
///
/// Layout:
///
///     ┌──────────┬─────────────────────────┐
///     │  gutter  │      NSScrollView       │
///     │          │  (NSTextView document)  │
///     │  1       │                         │
///     │  2       │   text content here     │
///     │  3       │                         │
///     └──────────┴─────────────────────────┘
///
/// The gutter observes the scroll view's `NSClipView`
/// `boundsDidChangeNotification` so it redraws aligned with the visible
/// line fragments. Gutter draws via Core Graphics in `drawRect` — a
/// traditional NSView path that does NOT disturb the parent SwiftUI
/// hosting layer's compositing.
public final class GutterScrollContainerView: NSView {
    public let scrollView: NSScrollView
    let gutter: LineNumberGutterView
    // nonisolated(unsafe): NotificationCenter tokens aren't Sendable but
    // we only set this once in init and only read it once in deinit;
    // the only operation is removeObserver which is thread-safe.
    private nonisolated(unsafe) var observation: NSObjectProtocol?

    public init(scrollView: NSScrollView, textView: NSTextView) {
        self.scrollView = scrollView
        self.gutter = LineNumberGutterView(textView: textView)
        super.init(frame: .zero)
        gutter.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutter)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutter.widthAnchor.constraint(equalToConstant: GutterScrollContainerView.gutterWidth),

            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // Redraw gutter when scroll position changes.
        scrollView.contentView.postsBoundsChangedNotifications = true
        observation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.gutter.needsDisplay = true
        }
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        // Observation token can be removed safely from any thread —
        // NotificationCenter handles that. The `nonisolated` deinit
        // restriction blocks accessing main-actor properties, so capture
        // before the deinit.
        if let obs = observation {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    static let gutterWidth: CGFloat = 40
}

/// Draws line numbers next to an NSTextView's currently visible glyph
/// range. Uses TextKit 1 / NSLayoutManager queries — the same logic the
/// old NSRulerView subclass used, just hosted as a sibling NSView
/// rather than inside the NSScrollView's ruler slot.
final class LineNumberGutterView: NSView {
    weak var textView: NSTextView?
    private let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private let horizontalInset: CGFloat = 6
    private var newlineOffsets: [Int]?
    private var cachedText: String?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func invalidateLineCache() {
        newlineOffsets = nil
        cachedText = nil
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Background fill + right-edge separator.
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.setStroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        separator.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        separator.lineWidth = 0.5
        separator.stroke()

        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return }
        let text = textView.string
        if text.isEmpty { return }

        let visibleRect = textView.visibleRect
        if visibleRect.width <= 0 || visibleRect.height <= 0 { return }

        ensureCacheBuilt(text: text)

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
            // Convert text-view-local Y into gutter-local Y, accounting for
            // scroll offset (visibleRect.minY) and container inset.
            let yInTextView = lineRect.minY + containerInsetY
            let yInGutter = yInTextView - visibleRect.minY

            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attrs)
            let x = self.bounds.width - size.width - self.horizontalInset
            label.draw(at: NSPoint(x: max(x, 2), y: yInGutter + 1), withAttributes: attrs)
        }
    }

    private func ensureCacheBuilt(text: String) {
        if cachedText == text, newlineOffsets != nil { return }
        cachedText = text
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
