import AppKit
import SwiftUI
import ViewerCore

/// Hex + ASCII viewer for binary files.
///
/// Implementation note: this view USED to be a LazyVStack of HexRow
/// SwiftUI views, one per row of bytes. For a 4 MB file at
/// bytesPerRow=16 that's 256k rows. Even with LazyVStack realizing
/// only visible rows, SwiftUI's diff machinery, the per-body
/// `Array(file.data[offset..<end])` slice→array conversion, and the
/// per-row `String(format:)` builds caused steady RAM growth as the
/// user scrolled or as `body` re-evaluated (which SwiftUI does
/// frequently). LESSONS.md has the longer version.
///
/// Replaced with: pre-render the entire dump once into a single
/// `NSAttributedString`, hand it to a single `NSTextView` inside an
/// `NSScrollView`. TextKit lazily lays out only visible glyphs, the
/// string is one allocation total, scroll/redraw cost is O(visible).
/// Memory stays flat.
///
/// The NSTextView is wrapped via `NSViewControllerRepresentable`
/// (not NSViewRepresentable) — same pattern + reason as
/// `TextDisplayView` (LESSONS.md compositor pathology).
struct HexView: View {
    let file: BinaryFile
    let fontSize: CGFloat

    var body: some View {
        HexTextRepresentable(file: file, fontSize: fontSize)
            .accessibilityIdentifier("mdv.hexView")
    }
}

private struct HexTextRepresentable: NSViewControllerRepresentable {
    let file: BinaryFile
    let fontSize: CGFloat

    func makeNSViewController(context: Context) -> HexTextController {
        HexTextController(file: file, fontSize: fontSize)
    }

    func updateNSViewController(_ controller: HexTextController, context: Context) {
        controller.apply(file: file, fontSize: fontSize)
    }
}

private final class HexTextController: NSViewController {
    let scrollView: NSScrollView
    let textView: NSTextView
    private var lastKey: CacheKey?

    private struct CacheKey: Equatable {
        let url: URL
        let byteCount: Int
        let fontSize: CGFloat
    }

    init(file: BinaryFile, fontSize: CGFloat) {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        self.scrollView = scroll

        let tv = (scroll.documentView as? NSTextView) ?? NSTextView()
        tv.isEditable = false
        tv.isRichText = false
        tv.isSelectable = true
        tv.allowsUndo = false
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 10, height: 8)
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        self.textView = tv

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        // Scrollview directly as the controller's view. Same pattern
        // as TextDisplayView (no intermediate container).
        self.view = scrollView
    }

    func apply(file: BinaryFile, fontSize: CGFloat) {
        let key = CacheKey(url: file.url, byteCount: file.byteCount, fontSize: fontSize)
        if key == lastKey { return }
        lastKey = key

        let attr = Self.buildDump(file: file, fontSize: fontSize)
        // setAttributedString replaces the whole storage in one shot.
        // TextKit then lazy-lays out only visible glyphs.
        textView.textStorage?.setAttributedString(attr)
        // Make sure we always start at the top when entering hex mode.
        textView.scrollToBeginningOfDocument(nil)
    }

    /// Render the hex dump as a single `NSAttributedString`. Format
    /// (matches the prior SwiftUI layout):
    ///   00000000  68 65 6c 6c 6f 20 77 6f 72 6c 64                  hello world
    ///   00000010  ...
    /// Header line up front when the binary was truncated to the cap.
    static func buildDump(file: BinaryFile, fontSize: CGFloat) -> NSAttributedString {
        let bytesPerRow = 16
        let bytes = file.data
        let byteCount = file.byteCount
        let rowCount = byteCount == 0 ? 0 : (byteCount + bytesPerRow - 1) / bytesPerRow

        // Capacity estimate per row:
        //   8 (offset) + 2 (gap) + 16*3 (hex) + 2 (gap) + 16 (ascii) + 1 (nl)
        //   ≈ 77 chars/row
        var s = String()
        s.reserveCapacity(rowCount * 77 + 80)

        if file.isTruncated {
            s += "Showing first \(byteCount) of \(file.totalByteCount) bytes\n\n"
        }

        let hexChars: [Character] = ["0","1","2","3","4","5","6","7",
                                     "8","9","a","b","c","d","e","f"]

        var rowStart = 0
        while rowStart < byteCount {
            // Offset (8 hex digits).
            var off = rowStart
            var offBuf = [Character](repeating: "0", count: 8)
            for i in stride(from: 7, through: 0, by: -1) {
                offBuf[i] = hexChars[off & 0xF]
                off >>= 4
            }
            s += String(offBuf)
            s += "  "

            let rowEnd = min(rowStart + bytesPerRow, byteCount)
            // Hex column.
            for i in 0..<bytesPerRow {
                let pos = rowStart + i
                if pos < rowEnd {
                    let b = bytes[pos]
                    s.append(hexChars[Int(b >> 4)])
                    s.append(hexChars[Int(b & 0xF)])
                } else {
                    s += "  "
                }
                if i != bytesPerRow - 1 { s.append(" ") }
            }
            s += "  "
            // ASCII column.
            for pos in rowStart..<rowEnd {
                let b = bytes[pos]
                if (32...126).contains(b) {
                    s.append(Character(UnicodeScalar(b)))
                } else {
                    s.append(".")
                }
            }
            s.append("\n")
            rowStart += bytesPerRow
        }

        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        return NSAttributedString(string: s, attributes: attrs)
    }
}
