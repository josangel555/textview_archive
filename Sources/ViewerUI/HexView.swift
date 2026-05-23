import AppKit
import SwiftUI
import ViewerCore

/// Hex + ASCII viewer for binary files.
///
/// Architecture: a SwiftUI toolbar (search + width picker) sits above
/// a single `NSTextView` inside an `NSScrollView`. The text view
/// renders the entire dump as one pre-built `NSAttributedString` so
/// TextKit can lazy-lay out only visible glyphs — preserving the
/// scroll perf the original view earned (see LESSONS.md).
///
/// Features layered on top of the original renderer:
///
/// * **Width selector** (16 / 32 / 64). Per-tab in `DocumentModel`,
///   default in `PreferencesStore.hexBytesPerRow`. Wide widths
///   side-scroll horizontally — the dump is rendered as-is and the
///   scroll view is configured `hasHorizontalScroller = true`.
///
/// * **Search** (HEX bytes / ASCII string). Local to this view's
///   state. The match list comes from `HexSearchEngine`; we overlay
///   yellow backgrounds on both the hex and ASCII columns and
///   ⌘-G / arrow-step through them.
///
/// * **Click-to-highlight**. Clicking on a byte highlights every
///   other byte with the same value. Click-and-drag picks a
///   multi-byte pattern and highlights every occurrence. Press ⎋
///   or click empty space to clear.
///
/// Performance notes: the dump is rebuilt only when (file, font, width)
/// changes. Highlights are applied via `addAttribute(.backgroundColor:)`
/// on the existing storage — O(matches), no full re-render.
struct HexView: View {
    let file: BinaryFile
    let fontSize: CGFloat
    let tabID: UUID
    @ObservedObject var model: DocumentModel

    @State private var searchQuery: String = ""
    @State private var searchMode: HexSearchMode = .hex
    @State private var searchPattern: [UInt8] = []
    @State private var matches: [Int] = []
    @State private var currentMatch: Int = 0
    @State private var queryIsInvalid: Bool = false
    @State private var clickPattern: [UInt8] = []
    @State private var clickOffsets: [Int] = []

    private var width: Int { model.hexWidth(forTabID: tabID) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HexTextRepresentable(
                file: file,
                fontSize: fontSize,
                width: width,
                matches: matches,
                matchPatternLength: searchPattern.count,
                currentMatch: matches.isEmpty ? nil : currentMatch,
                clickOffsets: clickOffsets,
                clickPatternLength: clickPattern.count,
                onClickPattern: handleClickPattern(_:),
                onClearClickPattern: clearClickHighlight
            )
        }
        .accessibilityIdentifier("mdv.hexView")
        .onChange(of: searchQuery) { _, _ in recomputeMatches() }
        .onChange(of: searchMode)  { _, _ in recomputeMatches() }
        .onChange(of: file)        { _, _ in
            searchQuery = ""
            searchPattern = []
            matches = []
            currentMatch = 0
            queryIsInvalid = false
            clickPattern = []
            clickOffsets = []
        }
    }

    // MARK: Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $searchMode) {
                Text("Hex").tag(HexSearchMode.hex)
                Text("ASCII").tag(HexSearchMode.ascii)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier("mdv.hex.search.mode")

            TextField(searchMode == .hex
                      ? "de ad be ef"
                      : "search bytes…",
                      text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: 320)
                .onSubmit { stepMatch(by: 1) }
                .accessibilityIdentifier("mdv.hex.search.field")
                .background(
                    queryIsInvalid
                        ? Color.red.opacity(0.15)
                        : Color.clear
                )

            Text(matchCountLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 80, alignment: .leading)
                .accessibilityIdentifier("mdv.hex.search.count")

            Button(action: { stepMatch(by: -1) }) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(matches.isEmpty)
            .accessibilityIdentifier("mdv.hex.search.prev")
            .keyboardShortcut("g", modifiers: [.command, .shift])

            Button(action: { stepMatch(by: 1) }) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(matches.isEmpty)
            .accessibilityIdentifier("mdv.hex.search.next")
            .keyboardShortcut("g", modifiers: [.command])

            Spacer()

            Picker("Width", selection: Binding<Int>(
                get: { width },
                set: { model.setHexWidth($0, forTabID: tabID) }
            )) {
                ForEach(HexLayout.allowedWidths, id: \.self) { w in
                    Text("\(w)").tag(w)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityIdentifier("mdv.hex.widthPicker")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var matchCountLabel: String {
        if queryIsInvalid { return "invalid" }
        if matches.isEmpty { return searchQuery.isEmpty ? "" : "0 matches" }
        return "\(currentMatch + 1) / \(matches.count)"
    }

    // MARK: Match plumbing

    private func recomputeMatches() {
        guard !searchQuery.isEmpty else {
            searchPattern = []
            matches = []
            currentMatch = 0
            queryIsInvalid = false
            return
        }
        guard let pattern = HexSearchEngine.parse(searchQuery, mode: searchMode) else {
            queryIsInvalid = true
            searchPattern = []
            matches = []
            return
        }
        queryIsInvalid = false
        searchPattern = pattern
        matches = pattern.isEmpty
            ? []
            : HexSearchEngine.find(pattern: pattern, in: file.data)
        currentMatch = 0
    }

    private func stepMatch(by delta: Int) {
        guard !matches.isEmpty else { return }
        let count = matches.count
        currentMatch = (currentMatch + delta + count) % count
    }

    // MARK: Click-pattern wiring

    private func handleClickPattern(_ pattern: [UInt8]) {
        clickPattern = pattern
        clickOffsets = pattern.isEmpty
            ? []
            : HexSearchEngine.find(pattern: pattern, in: file.data)
    }

    private func clearClickHighlight() {
        clickPattern = []
        clickOffsets = []
    }
}

// MARK: - NSViewControllerRepresentable bridge

private struct HexTextRepresentable: NSViewControllerRepresentable {
    let file: BinaryFile
    let fontSize: CGFloat
    let width: Int
    let matches: [Int]
    let matchPatternLength: Int
    let currentMatch: Int?
    let clickOffsets: [Int]
    let clickPatternLength: Int
    let onClickPattern: ([UInt8]) -> Void
    let onClearClickPattern: () -> Void

    func makeNSViewController(context: Context) -> HexTextController {
        let c = HexTextController()
        c.onClickPattern = onClickPattern
        c.onClearClickPattern = onClearClickPattern
        return c
    }

    func updateNSViewController(_ controller: HexTextController, context: Context) {
        controller.onClickPattern = onClickPattern
        controller.onClearClickPattern = onClearClickPattern
        controller.apply(
            file: file,
            fontSize: fontSize,
            width: width,
            matches: matches,
            matchPatternLength: matchPatternLength,
            currentMatch: currentMatch,
            clickOffsets: clickOffsets,
            clickPatternLength: clickPatternLength
        )
    }
}

// MARK: - NSViewController

private final class HexTextController: NSViewController {
    let scrollView: NSScrollView
    let textView: HexNSTextView
    /// Latest file bytes so the mouse handler can derive the
    /// click-pattern without re-parsing the rendered text.
    fileprivate var fileData: Data = Data()

    private var lastDumpKey: DumpKey?
    private var lastHighlightKey: HighlightKey?
    private var rowLength: Int = 0
    private var headerCharCount: Int = 0
    private var currentWidth: Int = HexLayout.defaultWidth
    private var byteCount: Int = 0

    var onClickPattern: (([UInt8]) -> Void)?
    var onClearClickPattern: (() -> Void)?

    private struct DumpKey: Equatable {
        let url: URL
        let byteCount: Int
        let fontSize: CGFloat
        let width: Int
    }
    private struct HighlightKey: Equatable {
        let matches: [Int]
        let matchPatternLength: Int
        let currentMatch: Int?
        let clickOffsets: [Int]
        let clickPatternLength: Int
        let width: Int
    }

    init() {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        self.scrollView = scroll

        let oldTV = scroll.documentView as? NSTextView
        let tv = HexNSTextView(frame: oldTV?.frame ?? .zero,
                               textContainer: oldTV?.textContainer)
        tv.autoresizingMask = oldTV?.autoresizingMask ?? []
        tv.minSize = oldTV?.minSize ?? .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
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
        scroll.documentView = tv
        self.textView = tv

        super.init(nibName: nil, bundle: nil)
        tv.controller = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() { self.view = scrollView }

    func apply(file: BinaryFile,
               fontSize: CGFloat,
               width: Int,
               matches: [Int],
               matchPatternLength: Int,
               currentMatch: Int?,
               clickOffsets: [Int],
               clickPatternLength: Int) {
        let dumpKey = DumpKey(url: file.url,
                              byteCount: file.byteCount,
                              fontSize: fontSize,
                              width: width)
        if dumpKey != lastDumpKey {
            lastDumpKey = dumpKey
            currentWidth = width
            byteCount = file.byteCount
            fileData = file.data

            let result = Self.buildDump(file: file,
                                        fontSize: fontSize,
                                        width: width)
            textView.textStorage?.setAttributedString(result.attr)
            headerCharCount = result.headerCharCount
            rowLength = HexLayout.renderedRowLength(width: width)
            textView.scrollToBeginningOfDocument(nil)
            lastHighlightKey = nil // force re-apply
        }

        applyHighlights(matches: matches,
                        matchPatternLength: matchPatternLength,
                        currentMatch: currentMatch,
                        clickOffsets: clickOffsets,
                        clickPatternLength: clickPatternLength)
    }

    private func applyHighlights(matches: [Int],
                                 matchPatternLength: Int,
                                 currentMatch: Int?,
                                 clickOffsets: [Int],
                                 clickPatternLength: Int) {
        let key = HighlightKey(matches: matches,
                               matchPatternLength: matchPatternLength,
                               currentMatch: currentMatch,
                               clickOffsets: clickOffsets,
                               clickPatternLength: clickPatternLength,
                               width: currentWidth)
        if key == lastHighlightKey { return }
        lastHighlightKey = key

        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        let full = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.backgroundColor, range: full)

        // Click-highlight first; search-match wins ties by painting last.
        if !clickOffsets.isEmpty, clickPatternLength > 0 {
            let color = NSColor.systemTeal.withAlphaComponent(0.30)
            for off in clickOffsets {
                paint(offset: off, length: clickPatternLength,
                      color: color, in: storage)
            }
        }

        if !matches.isEmpty, matchPatternLength > 0 {
            let base = NSColor.systemYellow.withAlphaComponent(0.45)
            let active = NSColor.systemOrange.withAlphaComponent(0.60)
            for (i, off) in matches.enumerated() {
                let c = (i == currentMatch) ? active : base
                paint(offset: off, length: matchPatternLength,
                      color: c, in: storage)
            }
        }

        storage.endEditing()

        if let idx = currentMatch, matches.indices.contains(idx) {
            scrollByteIntoView(offset: matches[idx])
        }
    }

    private func paint(offset: Int, length: Int,
                       color: NSColor, in storage: NSTextStorage) {
        guard length > 0 else { return }
        let last = min(offset + length - 1, byteCount - 1)
        guard offset <= last else { return }
        for b in offset...last {
            let row = HexLayout.row(forOffset: b, width: currentWidth)
            let col = HexLayout.column(forOffset: b, width: currentWidth)
            let rowStart = headerCharCount + row * rowLength
            let hex = NSRange(
                location: rowStart + HexLayout.hexCharOffset(inRowColumn: col),
                length: 2)
            let ascii = NSRange(
                location: rowStart + HexLayout.asciiCharOffset(
                    inRowColumn: col, width: currentWidth),
                length: 1)
            if NSMaxRange(hex) <= storage.length {
                storage.addAttribute(.backgroundColor, value: color, range: hex)
            }
            if NSMaxRange(ascii) <= storage.length {
                storage.addAttribute(.backgroundColor, value: color, range: ascii)
            }
        }
    }

    private func scrollByteIntoView(offset: Int) {
        let row = HexLayout.row(forOffset: offset, width: currentWidth)
        let col = HexLayout.column(forOffset: offset, width: currentWidth)
        let rowStart = headerCharCount + row * rowLength
        let charIdx = rowStart + HexLayout.hexCharOffset(inRowColumn: col)
        textView.scrollRangeToVisible(NSRange(location: charIdx, length: 2))
    }

    // MARK: Click-pattern derivation

    func charIndexToByteOffset(_ idx: Int) -> Int? {
        guard rowLength > 0 else { return nil }
        if idx < headerCharCount { return nil }
        let rel = idx - headerCharCount
        let row = rel / rowLength
        let inRow = rel % rowLength
        let hexStart = HexLayout.hexCharOffset(inRowColumn: 0)
        let hexEnd = hexStart + currentWidth * 3 - 1
        let asciiStart = HexLayout.asciiCharOffset(inRowColumn: 0,
                                                   width: currentWidth)
        let asciiEnd = asciiStart + currentWidth
        var col: Int? = nil
        if inRow >= hexStart, inRow < hexEnd {
            col = (inRow - hexStart) / 3
        } else if inRow >= asciiStart, inRow < asciiEnd {
            col = inRow - asciiStart
        }
        guard let c = col else { return nil }
        let off = row * currentWidth + c
        return off < byteCount ? off : nil
    }

    func reportClickPattern(range: Range<Int>) {
        let clamped = max(0, range.lowerBound)..<min(fileData.count, range.upperBound)
        guard clamped.lowerBound < clamped.upperBound else {
            onClearClickPattern?()
            return
        }
        let bytes = Array(fileData[clamped])
        onClickPattern?(bytes)
    }

    func reportClickClear() {
        onClearClickPattern?()
    }

    // MARK: Rendering

    struct DumpResult {
        let attr: NSAttributedString
        let headerCharCount: Int
    }

    static func buildDump(file: BinaryFile,
                          fontSize: CGFloat,
                          width: Int) -> DumpResult {
        let bytesPerRow = width
        let bytes = file.data
        let byteCount = file.byteCount
        let rowCount = HexLayout.rowCount(byteCount: byteCount, width: bytesPerRow)
        let perRowChars = HexLayout.renderedRowLength(width: bytesPerRow)

        var s = String()
        s.reserveCapacity(rowCount * perRowChars + 80)
        var headerCharCount = 0
        if file.isTruncated {
            let header = "Showing first \(byteCount) of \(file.totalByteCount) bytes\n\n"
            s += header
            headerCharCount = header.count
        }

        let hexChars: [Character] = ["0","1","2","3","4","5","6","7",
                                     "8","9","a","b","c","d","e","f"]

        var rowStart = 0
        while rowStart < byteCount {
            var off = rowStart
            var offBuf = [Character](repeating: "0", count: 8)
            for i in stride(from: 7, through: 0, by: -1) {
                offBuf[i] = hexChars[off & 0xF]
                off >>= 4
            }
            s += String(offBuf)
            s += "  "

            let rowEnd = min(rowStart + bytesPerRow, byteCount)
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
            // Pad short final row so every row has the same character
            // length — lets us address bytes by
            // `(row * rowLength + col)` without tracking per-row
            // variable lengths.
            for i in 0..<bytesPerRow {
                let pos = rowStart + i
                if pos < rowEnd {
                    let b = bytes[pos]
                    if (32...126).contains(b) {
                        s.append(Character(UnicodeScalar(b)))
                    } else {
                        s.append(".")
                    }
                } else {
                    s.append(" ")
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
        return DumpResult(
            attr: NSAttributedString(string: s, attributes: attrs),
            headerCharCount: headerCharCount
        )
    }
}

// MARK: - NSTextView subclass for click-to-highlight

private final class HexNSTextView: NSTextView {
    weak var controller: HexTextController?
    private var dragStartOffset: Int?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let idx = characterIndex(forPoint: pt)
        if let idx, let off = controller?.charIndexToByteOffset(idx) {
            dragStartOffset = off
        } else {
            dragStartOffset = nil
            controller?.reportClickClear()
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { super.mouseUp(with: event) }
        guard let start = dragStartOffset else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let idx = characterIndex(forPoint: pt)
        let endOff = idx.flatMap { controller?.charIndexToByteOffset($0) } ?? start
        let lo = min(start, endOff)
        let hi = max(start, endOff) + 1
        controller?.reportClickPattern(range: lo..<hi)
        dragStartOffset = nil
    }

    private func characterIndex(forPoint pt: NSPoint) -> Int? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        let local = NSPoint(x: pt.x - textContainerOrigin.x,
                            y: pt.y - textContainerOrigin.y)
        var frac: CGFloat = 0
        let glyphIdx = lm.glyphIndex(for: local, in: tc,
                                     fractionOfDistanceThroughGlyph: &frac)
        if glyphIdx >= lm.numberOfGlyphs { return nil }
        return lm.characterIndexForGlyph(at: glyphIdx)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // escape
            controller?.reportClickClear()
            return
        }
        super.keyDown(with: event)
    }
}
