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
    /// True when `HexSearchEngine.find` returned more than `Self.matchCap`
    /// hits and we kept only the first `matchCap`. Drives the "N+ matches"
    /// label and the capped highlight paint.
    @State private var matchesCapped: Bool = false

    /// Hard cap on the number of search / click match offsets we retain
    /// and paint. A pathological query (e.g. searching `00` across a 4 MB
    /// zero-filled blob) yields millions of hits; each painted match is two
    /// `addAttribute(.backgroundColor:)` ranges, so an uncapped list both
    /// balloons `@State` arrays and pins the main thread re-painting a
    /// screenful's worth of invisible highlights. 50k is far more than any
    /// human steps through and keeps the paint loop bounded.
    static let matchCap: Int = 50_000

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
            matchesCapped = false
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
            .accessibilityLabel("Previous match")
            .help("Previous match (⇧⌘G)")
            .keyboardShortcut("g", modifiers: [.command, .shift])

            Button(action: { stepMatch(by: 1) }) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(matches.isEmpty)
            .accessibilityIdentifier("mdv.hex.search.next")
            .accessibilityLabel("Next match")
            .help("Next match (⌘G)")
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
        if matchesCapped {
            // We stepped through the first `matchCap`; signal there are more
            // than we retained rather than implying an exact total.
            return "\(currentMatch + 1) / \(matches.count)+"
        }
        return "\(currentMatch + 1) / \(matches.count)"
    }

    // MARK: Match plumbing

    private func recomputeMatches() {
        guard !searchQuery.isEmpty else {
            searchPattern = []
            matches = []
            matchesCapped = false
            currentMatch = 0
            queryIsInvalid = false
            return
        }
        guard let pattern = HexSearchEngine.parse(searchQuery, mode: searchMode) else {
            queryIsInvalid = true
            searchPattern = []
            matches = []
            matchesCapped = false
            return
        }
        queryIsInvalid = false
        searchPattern = pattern
        let capped = HexMatchCap.cap(
            pattern.isEmpty
                ? []
                : HexSearchEngine.find(pattern: pattern, in: file.data),
            to: Self.matchCap)
        matches = capped.offsets
        matchesCapped = capped.wasCapped
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
        // Click-to-highlight can match a single byte across the whole 4 MB
        // buffer; cap the offsets we retain/paint with the same bound as
        // search so the highlight loop stays O(matchCap).
        clickOffsets = HexMatchCap.cap(
            pattern.isEmpty
                ? []
                : HexSearchEngine.find(pattern: pattern, in: file.data),
            to: Self.matchCap).offsets
    }

    private func clearClickHighlight() {
        clickPattern = []
        clickOffsets = []
    }
}

// MARK: - Match-list cap (pure, host-testable)

/// Caps a list of match offsets so the hex view never retains or paints
/// an unbounded number of highlights. Pure value logic, kept out of the
/// SwiftUI `View` so it's unit-testable without an `NSApplication`.
enum HexMatchCap {
    /// Returns the first `limit` offsets and whether the input exceeded the
    /// cap. `limit <= 0` is treated as "no matches retained".
    static func cap(_ offsets: [Int], to limit: Int)
        -> (offsets: [Int], wasCapped: Bool)
    {
        guard limit > 0 else { return ([], !offsets.isEmpty) }
        if offsets.count <= limit { return (offsets, false) }
        return (Array(offsets.prefix(limit)), true)
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
    /// Monotonic counter incremented on every `apply` whose
    /// (file, font, width) tuple differs from `lastDumpKey`. The
    /// background build task captures the current value and discards
    /// chunks if it changes — drops a stale dump when the user
    /// switches files / widths mid-render.
    private var buildGeneration: Int = 0
    /// True while a background chunked build is filling `textStorage`.
    /// Highlights cannot be applied yet — the storage doesn't have
    /// final character offsets — so `applyHighlights` queues the
    /// requested key in `pendingHighlightKey` and we re-run it from
    /// `finishBuild()`.
    private var isStreaming: Bool = false
    private var pendingHighlightKey: PendingHighlightKey?
    /// First row index in the streaming build for which we've already
    /// pushed a chunk. Used to know whether the placeholder is still
    /// in the storage and needs replacing.
    private var streamingHasPlaceholder: Bool = false

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
    private struct PendingHighlightKey {
        let matches: [Int]
        let matchPatternLength: Int
        let currentMatch: Int?
        let clickOffsets: [Int]
        let clickPatternLength: Int
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
        // VoiceOver otherwise announces this as an unlabeled text area.
        // `apply(...)` refines the label with the byte count / truncation.
        tv.setAccessibilityLabel("Hex dump")
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
            rowLength = HexLayout.renderedRowLength(width: width)
            textView.setAccessibilityLabel(
                Self.accessibilityLabel(for: file))
            startChunkedBuild(file: file,
                              fontSize: fontSize,
                              width: width)
            lastHighlightKey = nil // force re-apply
        }

        applyHighlights(matches: matches,
                        matchPatternLength: matchPatternLength,
                        currentMatch: currentMatch,
                        clickOffsets: clickOffsets,
                        clickPatternLength: clickPatternLength)
    }

    // MARK: Chunked build

    /// Kick off a background build of the dump. The first chunk (plan
    /// header, or a small placeholder for empty files) goes in
    /// synchronously so the text view never flashes empty content.
    /// Subsequent chunks are computed on a detached task and appended
    /// on the main actor — each appended via `replaceCharacters`
    /// wrapped in `beginEditing` / `endEditing` to coalesce TextKit
    /// layout invalidation into one pass per chunk.
    private func startChunkedBuild(file: BinaryFile,
                                   fontSize: CGFloat,
                                   width: Int) {
        buildGeneration &+= 1
        let generation = buildGeneration
        let font = NSFont.monospacedSystemFont(ofSize: fontSize,
                                               weight: .regular)
        let placeholder: NSAttributedString = {
            let s = "Building hex dump…\n"
            return NSAttributedString(string: s, attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }()

        guard let storage = textView.textStorage else { return }
        // Show the placeholder immediately so the user sees a hint
        // before the first body chunk lands.
        storage.beginEditing()
        storage.setAttributedString(placeholder)
        storage.endEditing()
        textView.scrollToBeginningOfDocument(nil)

        // Empty body — nothing more to do, but make sure the storage
        // is empty so character indices line up with the layout math.
        let plan = HexDumpBuilder.plan(byteCount: file.byteCount,
                                       totalByteCount: file.totalByteCount,
                                       isTruncated: file.isTruncated,
                                       width: width)
        if plan.rowCount == 0 && plan.headerCharCount == 0 {
            storage.beginEditing()
            storage.setAttributedString(NSAttributedString())
            storage.endEditing()
            headerCharCount = 0
            isStreaming = false
            streamingHasPlaceholder = false
            return
        }

        isStreaming = true
        streamingHasPlaceholder = true
        headerCharCount = plan.headerCharCount

        // Detached task: build each chunk's plain `String` on a
        // background thread (pure work over the immutable
        // `BinaryFile`), then hop to the main actor to wrap it into
        // an `NSAttributedString` and push it into `textStorage`.
        //
        // We pass `String` (Sendable) across the hop rather than
        // `NSAttributedString` / `[NSAttributedString.Key: Any]`
        // (neither is Sendable). The wrap happens main-actor-side
        // where it's also captured by storage — no cross-actor
        // reference to mutable Cocoa state.
        //
        // The builder's chunked callback is synchronous so we
        // serialize render-then-push — one chunk in flight at a
        // time (natural backpressure; storage append never falls
        // behind the producer).
        let captureFontSize = fontSize
        Task.detached(priority: .userInitiated) { [weak self] in
            HexDumpBuilder.build(file: file,
                                 width: width) { _, chunk in
                // `DispatchQueue.main.sync` lets the synchronous
                // builder callback wait for the main-actor append
                // before producing the next chunk. Safe here because
                // this task is detached (no parent main-actor frame
                // to deadlock).
                let keepGoing: Bool = DispatchQueue.main.sync {
                    guard let self else { return false }
                    let f = NSFont.monospacedSystemFont(
                        ofSize: captureFontSize, weight: .regular)
                    let chunkAttr = NSAttributedString(
                        string: chunk,
                        attributes: [
                            .font: f,
                            .foregroundColor: NSColor.labelColor,
                        ])
                    return self.appendChunk(chunkAttr,
                                            generation: generation)
                }
                return keepGoing
            }
            await MainActor.run {
                self?.finishBuild(generation: generation)
            }
        }
    }

    /// Append a chunk to the text storage on the main actor. Returns
    /// `false` if the build is stale (user changed file/width) so the
    /// background task can stop producing further chunks.
    @MainActor
    private func appendChunk(_ chunk: NSAttributedString,
                             generation: Int) -> Bool {
        guard generation == buildGeneration else { return false }
        guard let storage = textView.textStorage else { return false }
        storage.beginEditing()
        if streamingHasPlaceholder {
            // First real chunk — replace the placeholder wholesale.
            storage.setAttributedString(chunk)
            streamingHasPlaceholder = false
        } else {
            let end = NSRange(location: storage.length, length: 0)
            storage.replaceCharacters(in: end, with: chunk)
        }
        storage.endEditing()
        return true
    }

    /// Wrap up after the final chunk. Re-applies any highlights that
    /// were requested mid-stream against the now-final character
    /// offsets.
    @MainActor
    private func finishBuild(generation: Int) {
        guard generation == buildGeneration else { return }
        isStreaming = false
        streamingHasPlaceholder = false
        if let pending = pendingHighlightKey {
            pendingHighlightKey = nil
            applyHighlights(matches: pending.matches,
                            matchPatternLength: pending.matchPatternLength,
                            currentMatch: pending.currentMatch,
                            clickOffsets: pending.clickOffsets,
                            clickPatternLength: pending.clickPatternLength)
        }
    }

    private func applyHighlights(matches: [Int],
                                 matchPatternLength: Int,
                                 currentMatch: Int?,
                                 clickOffsets: [Int],
                                 clickPatternLength: Int) {
        if isStreaming {
            // Storage doesn't have its final character offsets yet —
            // any addAttribute call now would target stale ranges. Hold
            // the request and reapply from `finishBuild()`.
            pendingHighlightKey = PendingHighlightKey(
                matches: matches,
                matchPatternLength: matchPatternLength,
                currentMatch: currentMatch,
                clickOffsets: clickOffsets,
                clickPatternLength: clickPatternLength)
            return
        }
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

    static func accessibilityLabel(for file: BinaryFile) -> String {
        HexAccessibility.dumpLabel(byteCount: file.byteCount,
                                   totalByteCount: file.totalByteCount,
                                   isTruncated: file.isTruncated)
    }

    // MARK: Rendering — see HexDumpBuilder in ViewerCore for the
    // chunked text-build implementation.
}

// MARK: - Accessibility label formatting (pure, host-testable)

/// VoiceOver label formatting for the hex dump text area. Pure value logic,
/// kept out of the `private` controller so it's unit-testable without an
/// `NSApplication`.
enum HexAccessibility {
    /// Label for the dump text area. Makes the truncated case explicit
    /// ("showing first N of M bytes") so a non-sighted user gets the same
    /// "this is a partial view" cue the on-screen banner gives a sighted one.
    static func dumpLabel(byteCount: Int,
                          totalByteCount: Int,
                          isTruncated: Bool) -> String {
        if isTruncated {
            return "Hex dump, showing first \(byteCount) "
                + "of \(totalByteCount) bytes"
        }
        return "Hex dump, \(byteCount) bytes"
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
