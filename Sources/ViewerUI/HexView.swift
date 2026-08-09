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
    /// TSK-986: cancel-and-reschedule handle so the full-buffer hex scan is
    /// debounced instead of running synchronously on every keystroke.
    @State private var searchTask: Task<Void, Never>?

    /// Hard cap on the number of search / click match offsets we retain
    /// and paint. A pathological query (e.g. searching `00` across a 4 MB
    /// zero-filled blob) yields millions of hits; each painted match is two
    /// `addAttribute(.backgroundColor:)` ranges, so an uncapped list both
    /// balloons `@State` arrays and pins the main thread re-painting a
    /// screenful's worth of invisible highlights. 50k is far more than any
    /// human steps through and keeps the paint loop bounded.
    static let matchCap: Int = 50_000

    private var width: Int { model.hexWidth(forTabID: tabID) }

    /// HEX is editable when the file's tab is in `.hex` mode AND the
    /// ViewOnly toggle is OFF (#234). A *truncated* file (we only loaded
    /// the first 4 MB) is never editable — saving would drop the unread
    /// tail. The read-only path is byte-identical to before when this is
    /// false.
    private var isEditable: Bool {
        guard !file.isTruncated else { return false }
        let p = model.viewModePresentation
        return p.primary == .hex && p.viewOnly == false
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HexTextRepresentable(
                file: file,
                fontSize: fontSize,
                width: width,
                editable: isEditable,
                matches: matches,
                matchPatternLength: searchPattern.count,
                currentMatch: matches.isEmpty ? nil : currentMatch,
                clickOffsets: clickOffsets,
                clickPatternLength: clickPattern.count,
                onClickPattern: handleClickPattern(_:),
                onClearClickPattern: clearClickHighlight,
                onDirtyChange: { dirty, data in
                    if dirty, let data { model.stashHexBytes(data, forTabID: tabID) }
                    model.setHexDirty(dirty, forTabID: tabID)
                },
                onRequestSave: { data in _ = model.saveHexEdits(data, forTabID: tabID) },
                onControllerReady: { controller in
                    // Let a model-side save (the close-confirm "Save"
                    // branch, which runs without going through the live
                    // ⌘S handler) tell THIS controller to mark its buffer
                    // clean. Captured weakly; matched by tab id so a stale
                    // controller from another tab is ignored.
                    let boundTab = tabID
                    model.hexSavedNotifier = { [weak controller] savedTab in
                        guard savedTab == boundTab else { return }
                        controller?.markHexSaved()
                    }
                },
                // Hex hot-exit (2026-08-01): a restored/remounted tab's dirty
                // stash seeds the buffer instead of clean disk bytes.
                dirtySeed: { model.dirtyHexBytes(forTabID: tabID) }
            )
        }
        .accessibilityIdentifier("mdv.hexView")
        .onChange(of: searchQuery) { _, _ in scheduleRecompute() }
        .onChange(of: searchMode)  { _, _ in scheduleRecompute() }
        .onChange(of: file)        { _, _ in
            searchTask?.cancel()
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
            .helpInfo(title: "Previous match", description: "Jump to the previous byte match (⇧⌘G)")
            .keyboardShortcut("g", modifiers: [.command, .shift])

            Button(action: { stepMatch(by: 1) }) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(matches.isEmpty)
            .accessibilityIdentifier("mdv.hex.search.next")
            .accessibilityLabel("Next match")
            .helpInfo(title: "Next match", description: "Jump to the next byte match (⌘G)")
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

    /// TSK-986: debounce the full-buffer scan (180 ms, cancel-and-reschedule —
    /// the codebase's `searchTask` idiom) so typing in the search field no longer
    /// fires a synchronous whole-buffer scan on every keystroke; only the final
    /// pause triggers one scan.
    private func scheduleRecompute() {
        searchTask?.cancel()
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            if Task.isCancelled { return }
            recomputeMatches()
        }
    }

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
        // Routed through the `.hexSearch` gate (TSK-649 A0): the adapter
        // re-parses the query rust-side; its Swift arm is the incumbent
        // parse+find. The click-highlight below stays Swift-only by design
        // (byte-pattern entry, the adapter's documented carve-out).
        let capped = HexMatchCap.cap(
            pattern.isEmpty
                ? []
                : RustHexSearchAdapter.search(searchQuery, mode: searchMode, in: searchableData),
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
                : HexSearchEngine.find(pattern: pattern, in: searchableData),
            to: Self.matchCap).offsets
    }

    /// TSK-1423: the bytes search + click-highlight run against — the model's
    /// stashed DIRTY hex bytes when the tab has unsaved edits (the controller
    /// pushes them via `stashHexBytes` on every edit), else the on-disk
    /// `file.data`. Before this, search read `file.data` and silently ignored
    /// unsaved edits, so a just-typed byte was un-findable.
    private var searchableData: Data { model.dirtyHexBytes(forTabID: tabID) ?? file.data }

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
    let editable: Bool
    let matches: [Int]
    let matchPatternLength: Int
    let currentMatch: Int?
    let clickOffsets: [Int]
    let clickPatternLength: Int
    let onClickPattern: ([UInt8]) -> Void
    let onClearClickPattern: () -> Void
    let onDirtyChange: (Bool, Data?) -> Void
    let onRequestSave: (Data) -> Void
    let onControllerReady: (HexTextController) -> Void
    /// Hex hot-exit (2026-08-01): consulted ONCE per file-identity change —
    /// a restored session's dirty stash (or a remount's live stash) seeds
    /// the edit buffer instead of the clean disk bytes, so what the user
    /// SEES is what ⌘S will write. Nil = seed from disk as always.
    let dirtySeed: () -> Data?

    func makeNSViewController(context: Context) -> HexTextController {
        let c = HexTextController()
        c.onClickPattern = onClickPattern
        c.onClearClickPattern = onClearClickPattern
        c.onDirtyChange = onDirtyChange
        c.onRequestSave = onRequestSave
        c.dirtySeed = dirtySeed
        onControllerReady(c)
        return c
    }

    func updateNSViewController(_ controller: HexTextController, context: Context) {
        controller.onClickPattern = onClickPattern
        controller.onClearClickPattern = onClearClickPattern
        controller.onDirtyChange = onDirtyChange
        controller.onRequestSave = onRequestSave
        controller.dirtySeed = dirtySeed
        controller.apply(
            file: file,
            fontSize: fontSize,
            width: width,
            editable: editable,
            matches: matches,
            matchPatternLength: matchPatternLength,
            currentMatch: currentMatch,
            clickOffsets: clickOffsets,
            clickPatternLength: clickPatternLength
        )
    }
}

// MARK: - NSViewController

// Internal (not private) so HexFixedGridFrameTests can pin the fixed-grid
// configuration headlessly — the perf contract TSK-267 depends on.
final class HexTextController: NSViewController {
    let scrollView: NSScrollView
    let textView: HexNSTextView
    /// Latest file bytes so the mouse handler can derive the
    /// click-pattern without re-parsing the rendered text.
    fileprivate var fileData: Data = Data()
    /// Hex hot-exit (2026-08-01): stash consult for the identity-change
    /// seed — see `HexTextRepresentable.dirtySeed`.
    fileprivate var dirtySeed: (() -> Data?)?

    private var lastDumpKey: DumpKey?
    private var lastHighlightFingerprint: HighlightFingerprint?
    /// The `matches` array that produced the currently-painted highlights,
    /// and which entry in it is painted as the active (orange) match.
    /// Retained so the "only currentMatch changed" fast path knows which
    /// previously-active range to revert to base-yellow without a full
    /// re-paint (audit S2). `nil` ⇒ no full paint has run since the last
    /// dump rebuild, so the fast path is not eligible.
    private var lastPaintedMatches: [Int]?
    private var lastActiveMatchIndex: Int?
    /// Pattern lengths + click set that produced the painted highlights,
    /// so the next full paint can clear EXACTLY the painted ranges via
    /// `HexHighlightPlan` instead of an O(document) `removeAttribute`
    /// over the whole storage (TSK-267 step 2).
    private var lastPaintedMatchPatternLength: Int = 0
    private var lastPaintedClickOffsets: [Int]?
    private var lastPaintedClickPatternLength: Int = 0
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
    /// Open `HexView.chunkedBuild` signpost interval, ended in
    /// `finishBuild` (or when a newer build supersedes this one).
    private var buildSignpostToken: PerfSignpost.Token?
    /// First row index in the streaming build for which we've already
    /// pushed a chunk. Used to know whether the placeholder is still
    /// in the storage and needs replacing.
    private var streamingHasPlaceholder: Bool = false

    var onClickPattern: (([UInt8]) -> Void)?
    var onClearClickPattern: (() -> Void)?
    /// Mirror the edit buffer's dirty state up to the model (TabBar dot +
    /// close-confirm gate). Carries the current bytes when dirty so the
    /// model can stash them for a close-confirm save. Called on every
    /// transition, deduped by `lastReportedDirty`.
    var onDirtyChange: ((Bool, Data?) -> Void)?
    /// Request a binary write-back of the edited bytes (⌘S). The model
    /// owns the write path (`DocumentModel.saveHexEdits`) so it can run
    /// the symlink-refusal NSAlert + refresh the loaded `BinaryFile`.
    var onRequestSave: ((Data) -> Void)?

    // MARK: Edit state (#234)

    /// True when the byte grid is editable (ViewOnly off, non-truncated).
    /// `false` ⇒ the original read-only path, untouched.
    private var editable: Bool = false
    /// The dirty byte buffer over the loaded bytes. Seeded on the first
    /// `apply` for a given file; preserved across non-file `apply` calls
    /// (highlight / width changes keep edits) and reset when the file
    /// identity changes. `nil` until the file is known.
    private var editBuffer: HexEditBuffer?
    /// Last dirty value pushed via `onDirtyChange`, to dedupe.
    private var lastReportedDirty: Bool = false
    /// Where the edit caret sits, for nibble-granular hex typing and
    /// arrow/tab navigation. `nil` ⇒ no edit caret placed yet.
    private enum EditCaret: Equatable {
        case hex(byte: Int, nibble: Int)
        case ascii(byte: Int)
    }
    private var editCaret: EditCaret?

    private struct DumpKey: Equatable {
        let url: URL
        let byteCount: Int
        let fontSize: CGFloat
        let width: Int
    }
    /// Cheap O(1) fingerprint of a highlight request, replacing a full
    /// element-by-element `[Int]` compare of the (up to 50k) `matches` /
    /// `clickOffsets` arrays on every no-op `updateNSViewController`
    /// (audit S3). `count + first + last` is a near-collision-free proxy
    /// for "the match set changed" given the offsets are produced by the
    /// same deterministic search over an immutable buffer; an actual
    /// repaint never depends on this for correctness (the painter reads
    /// the real arrays), only the dedupe short-circuit does.
    ///
    /// `matchesExceptActiveMatch` is the same fingerprint with
    /// `currentMatch` zeroed out, used to detect the common "only the
    /// active match index moved" case (⌘G / arrow step) so we can take
    /// the O(2) repaint fast path instead of a full re-paint (audit S2).
    /// Internal (not private) as the TSK-141 test seam: the O(1)
    /// summary-equality semantics (equal when count/first/last/pattern/
    /// width match even if MIDDLE offsets differ) are the audited
    /// contract — `HexHighlightFingerprintTests` fails if equality
    /// reverts to an O(matches) full-array compare.
    struct HighlightFingerprint: Equatable {
        let matchCount: Int
        let matchFirst: Int?
        let matchLast: Int?
        let matchPatternLength: Int
        let currentMatch: Int?
        let clickCount: Int
        let clickFirst: Int?
        let clickLast: Int?
        let clickPatternLength: Int
        let width: Int

        init(matches: [Int],
             matchPatternLength: Int,
             currentMatch: Int?,
             clickOffsets: [Int],
             clickPatternLength: Int,
             width: Int) {
            self.matchCount = matches.count
            self.matchFirst = matches.first
            self.matchLast = matches.last
            self.matchPatternLength = matchPatternLength
            self.currentMatch = currentMatch
            self.clickCount = clickOffsets.count
            self.clickFirst = clickOffsets.first
            self.clickLast = clickOffsets.last
            self.clickPatternLength = clickPatternLength
            self.width = width
        }

        /// True when only `currentMatch` differs (everything that affects
        /// which ranges exist / how they're laid out is identical).
        func differsOnlyByActiveMatch(from other: HighlightFingerprint) -> Bool {
            currentMatch != other.currentMatch
                && matchCount == other.matchCount
                && matchFirst == other.matchFirst
                && matchLast == other.matchLast
                && matchPatternLength == other.matchPatternLength
                && clickCount == other.clickCount
                && clickFirst == other.clickFirst
                && clickLast == other.clickLast
                && clickPatternLength == other.clickPatternLength
                && width == other.width
        }
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
        // Tandem selection (owner 2026-08-09): mirror a hex-side selection
        // onto the ascii chars and vice versa. Notification-based — no
        // delegate slot consumed.
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: tv, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.mirrorSelectionChanged() }
        }
    }

    nonisolated(unsafe) private var selectionObserver: NSObjectProtocol?

    deinit {
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() { self.view = scrollView }

    func apply(file: BinaryFile,
               fontSize: CGFloat,
               width: Int,
               editable: Bool,
               matches: [Int],
               matchPatternLength: Int,
               currentMatch: Int?,
               clickOffsets: [Int],
               clickPatternLength: Int) {
        let dumpKey = DumpKey(url: file.url,
                              byteCount: file.byteCount,
                              fontSize: fontSize,
                              width: width)
        // File-identity change resets the edit buffer (new bytes ⇒ new
        // baseline). Keyed on URL + byteCount only — a width / font change
        // keeps the same file's edits (it re-renders, not reloads).
        let fileIdentity = HexFileIdentity(url: file.url, byteCount: file.byteCount)
        if fileIdentity != lastFileIdentity {
            lastFileIdentity = fileIdentity
            // Seed the buffer. Hex hot-exit (2026-08-01): a restored
            // session's dirty stash (or a remount's live stash) wins over
            // the clean disk bytes — what the user SEES is what ⌘S writes;
            // previously a remount silently showed disk bytes under a
            // dirty badge. If a dirty buffer for a DIFFERENT file was
            // live, its dirt is dropped here — the close/switch confirm
            // gate runs before we ever get a new file.
            if let restored = dirtySeed?() {
                editBuffer = HexEditBuffer(data: restored)
                editCaret = nil
                lastCaretPaintedByte = nil
                lastMirrorPaint = nil
                reportDirty(true)
            } else {
                editBuffer = HexEditBuffer(data: file.data)
                editCaret = nil
                lastCaretPaintedByte = nil
                lastMirrorPaint = nil
                reportDirty(false)
            }
        }

        if dumpKey != lastDumpKey {
            lastDumpKey = dumpKey
            currentWidth = width
            byteCount = file.byteCount
            // Render the EDITED bytes when we have a buffer (so a width
            // change after edits redraws the edited values, not the
            // originals); fall back to the file's bytes pre-seed.
            fileData = editBuffer?.data ?? file.data
            rowLength = HexLayout.renderedRowLength(width: width)
            textView.setAccessibilityLabel(
                Self.accessibilityLabel(for: file))
            startChunkedBuild(file: BinaryFile(url: file.url,
                                               data: fileData,
                                               totalByteCount: file.totalByteCount,
                                               isTruncated: file.isTruncated),
                              fontSize: fontSize,
                              width: width)
            // Force a full re-apply against the freshly-built storage; the
            // fast path can't run until a full paint re-establishes the
            // painted-match bookkeeping.
            lastHighlightFingerprint = nil
            lastPaintedMatches = nil
            lastActiveMatchIndex = nil
            lastPaintedMatchPatternLength = 0
            lastPaintedClickOffsets = nil
            lastPaintedClickPatternLength = 0
        }

        // Toggle editability. The byte grid stays SELECTABLE either way
        // (so click-to-highlight + copy keep working read-only); only the
        // typing path is gated. `isEditable` on the NSTextView would route
        // keystrokes through TextKit's own insert/delete — we DON'T want
        // that (it'd insert, not overwrite, and desync the byte buffer),
        // so we keep `textView.isEditable = false` and intercept keyDown
        // ourselves. This flag just arms that interception.
        self.editable = editable
        textView.isEditingArmed = editable

        applyHighlights(matches: matches,
                        matchPatternLength: matchPatternLength,
                        currentMatch: currentMatch,
                        clickOffsets: clickOffsets,
                        clickPatternLength: clickPatternLength)
    }

    private struct HexFileIdentity: Equatable {
        let url: URL
        let byteCount: Int
    }
    private var lastFileIdentity: HexFileIdentity?

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

        // Empty body — make sure the storage is empty so character
        // indices line up with the layout math.
        let plan = HexDumpBuilder.plan(byteCount: file.byteCount,
                                       totalByteCount: file.totalByteCount,
                                       isTruncated: file.isTruncated,
                                       width: width)
        // Fix the document frame ARITHMETICALLY before any content lands
        // (TSK-267 step 4). With a self-sizing text view TK2 must lay out
        // the entire document to answer height queries (measured: 2.12s
        // CA-commit stall on a 1MB dump via textContainerOrigin →
        // ensureLayoutForRange over ~65k rows). The grid is uniform, so
        // the exact size is rows×lineHeight / cols×charAdvance — set it
        // and turn self-sizing off; TK2 then lays out viewport-only.
        applyFixedGridFrame(plan: plan, fontSize: fontSize)
        if plan.rowCount == 0 && plan.headerCharCount == 0 {
            storage.beginEditing()
            storage.setAttributedString(NSAttributedString())
            storage.endEditing()
            headerCharCount = 0
            isStreaming = false
            streamingHasPlaceholder = false
            return
        }

        // Small-file fast path (TSK-267 step 3): below the threshold the
        // dump string builds in single-digit ms, so render it in ONE
        // synchronous shot — no placeholder flash, no detached task, no
        // per-chunk main.sync round-trips. Kills the fixed per-open
        // overhead that dominated small files (#218: 6 KB ≈ 1 s).
        if HexRenderPlan.useSyncBuild(renderedByteCount: file.byteCount) {
            PerfSignpost.withInterval(.render, "HexView.syncBuild") {
                // Routed through the `.hex` gate (TSK-649 A0). The windowed
                // chunk build below stays Swift until the Phase-1 windowed
                // snapshot lands (the adapter only has the full-dump API).
                let text = RustHexAdapter.buildAll(file: file, width: width)
                storage.beginEditing()
                storage.setAttributedString(NSAttributedString(
                    string: text,
                    attributes: [
                        .font: font,
                        .foregroundColor: NSColor.labelColor,
                    ]))
                storage.endEditing()
            }
            textView.scrollToBeginningOfDocument(nil)
            headerCharCount = plan.headerCharCount
            isStreaming = false
            streamingHasPlaceholder = false
            // Same post-build fixups finishBuild() does for the async path.
            if editable, let buf = editBuffer, buf.isDirty {
                for idx in buf.dirtyByteIndices { repaintByte(idx, in: buf) }
                syncSelectionToCaret()
            }
            return
        }

        // Show the placeholder immediately so the user sees a hint
        // before the first body chunk lands.
        storage.beginEditing()
        storage.setAttributedString(placeholder)
        storage.endEditing()
        textView.scrollToBeginningOfDocument(nil)

        buildSignpostToken.map(PerfSignpost.end)
        buildSignpostToken = PerfSignpost.begin(.render, "HexView.chunkedBuild")
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
        // `nonisolated(unsafe) let` capture: the background producer only ever
        // touches the view on the main actor (the `main.sync` / `MainActor.run`
        // hops below), so opting this one immutable capture out of Sendable
        // checking is safe — it's what lets the stricter VM toolchain (Swift
        // 6.1.2) accept the detached task without "sending 'self'" (TSK-401
        // skew vs host). Strong (not weak) so the `let` is sendable-suppressible;
        // the `generation == buildGeneration` guard in append/finish already
        // makes a stale build (tab closed / width changed) a no-op, so retaining
        // the view until the build drains is bounded and correct.
        nonisolated(unsafe) let strongSelf = self
        Task.detached(priority: .userInitiated) {
            HexDumpBuilder.build(file: file,
                                 width: width) { _, chunk in
                // `DispatchQueue.main.sync` lets the synchronous
                // builder callback wait for the main-actor append
                // before producing the next chunk. Safe here because
                // this task is detached (no parent main-actor frame
                // to deadlock).
                // `main.sync` runs this on the main thread; `assumeIsolated`
                // tells the compiler so the main-actor `self`/`appendChunk` are
                // reachable WITHOUT "sending" the non-Sendable view across the
                // hop — the stricter VM toolchain (Swift 6.1.2) otherwise
                // rejects it (TSK-401 default-isolation skew vs host).
                let keepGoing: Bool = DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        let f = NSFont.monospacedSystemFont(
                            ofSize: captureFontSize, weight: .regular)
                        let chunkAttr = NSAttributedString(
                            string: chunk,
                            attributes: [
                                .font: f,
                                .foregroundColor: NSColor.labelColor,
                            ])
                        return strongSelf.appendChunk(chunkAttr,
                                                      generation: generation)
                    }
                }
                return keepGoing
            }
            await MainActor.run {
                strongSelf.finishBuild(generation: generation)
            }
        }
    }

    /// Pin the text view's frame to the grid's ARITHMETIC size and turn
    /// self-sizing off (TSK-267 step 4). Self-sizing is what forced TK2
    /// to lay out the whole document (textContainerOrigin →
    /// ensureLayoutForRange over every row — the measured 2.12s CA-commit
    /// stall on 1MB). Line height + char advance come from a one-shot TK2
    /// measurement (`HexGridMetrics`) so the arithmetic can't drift from
    /// the engine; `HexGridGeometryTK2Tests` pins the equality headlessly.
    private func applyFixedGridFrame(plan: HexDumpBuilder.Plan,
                                     fontSize: CGFloat) {
        let m = HexGridMetrics.measure(fontSize: fontSize)
        let lines = HexGridGeometry.lineCount(
            newlineCount: HexGridGeometry.newlineCount(
                rowCount: plan.rowCount,
                hasHeader: plan.headerCharCount > 0))
        let inset = textView.textContainerInset
        let pad = textView.textContainer?.lineFragmentPadding ?? 0
        let textH = HexGridGeometry.textHeight(lineCount: lines,
                                               lineHeight: m.lineHeight)
        let textW = HexGridGeometry.textWidth(perRowChars: plan.perRowChars,
                                              charAdvance: m.charAdvance)
            + Double(pad) * 2
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = []
        // NOTE: the container stays INFINITE. Bounding it was tried
        // (30fdc32) and measured WORSE — a finite container defeats TK2's
        // lazy layout for content inside the bounds (debug chunked build
        // 267ms → 4.5s). The remaining usage-derived cost lives in
        // `textContainerOrigin`, which HexNSTextView overrides instead.
        textView.setFrameSize(NSSize(
            width: ceil(textW + Double(inset.width) * 2),
            height: ceil(textH + Double(inset.height) * 2)))
        textView.usesFixedGridOrigin = true
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
        buildSignpostToken.map(PerfSignpost.end)
        buildSignpostToken = nil
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
        // Re-apply "modified byte" tints after a fresh build (e.g. a
        // width change with pending edits rebuilds the whole dump and
        // would otherwise lose the tints on changed bytes).
        if editable, let buf = editBuffer, buf.isDirty {
            for idx in buf.dirtyByteIndices { repaintByte(idx, in: buf) }
            syncSelectionToCaret()
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
        let key = HighlightFingerprint(matches: matches,
                                       matchPatternLength: matchPatternLength,
                                       currentMatch: currentMatch,
                                       clickOffsets: clickOffsets,
                                       clickPatternLength: clickPatternLength,
                                       width: currentWidth)
        if key == lastHighlightFingerprint { return }

        // Fast path: only the active match index moved (⌘G / arrow step).
        // The match set, click set, pattern lengths and width are all
        // unchanged, so the only visual delta is which single match is
        // orange (active) vs yellow (base). Repaint just the two affected
        // ranges (old-active → base, new-active → orange) instead of an
        // O(matches) removeAttribute + full re-paint (audit S2).
        if let prev = lastHighlightFingerprint,
           key.differsOnlyByActiveMatch(from: prev),
           let painted = lastPaintedMatches,
           matchPatternLength > 0 {
            stepActiveMatch(in: painted,
                            patternLength: matchPatternLength,
                            from: lastActiveMatchIndex,
                            to: currentMatch)
            lastHighlightFingerprint = key
            lastActiveMatchIndex = currentMatch
            if let idx = currentMatch, matches.indices.contains(idx) {
                scrollByteIntoView(offset: matches[idx])
            }
            return
        }

        lastHighlightFingerprint = key

        guard let storage = textView.textStorage else { return }
        PerfSignpost.withInterval(.highlight, "HexView.fullPaint") {
        storage.beginEditing()
        // Clear EXACTLY the ranges the previous paint touched (TSK-267
        // step 2) — a whole-storage removeAttribute is an O(document)
        // attribute walk on every search edit, the dominant per-keystroke
        // cost on a multi-MB dump. The planner shares HexLayout's offset
        // math with `paint(...)` below, so clear and paint cannot drift.
        clearPaintedHighlights(in: storage)
        // The scoped clear can wipe the orange "modified byte" tint where
        // a highlight overlapped an edited byte — restore tints before the
        // new paint so search highlights still win ties (paint-last).
        if editable, let buf = editBuffer, buf.isDirty {
            for idx in buf.dirtyByteIndices { repaintByte(idx, in: buf) }
        }

        // Click-highlight first; search-match wins ties by painting last.
        if !clickOffsets.isEmpty, clickPatternLength > 0 {
            let color = NSColor.systemTeal.withAlphaComponent(0.30)
            for off in clickOffsets {
                paint(offset: off, length: clickPatternLength,
                      color: color, in: storage)
            }
        }

        if !matches.isEmpty, matchPatternLength > 0 {
            for (i, off) in matches.enumerated() {
                paint(offset: off, length: matchPatternLength,
                      color: Self.matchColor(active: i == currentMatch),
                      in: storage)
            }
        }

        storage.endEditing()
        }

        // Record what we painted so the next step can take the fast path
        // and the next full paint can clear only these ranges.
        lastPaintedMatches = (matchPatternLength > 0) ? matches : nil
        lastPaintedMatchPatternLength = matchPatternLength
        lastPaintedClickOffsets = (clickPatternLength > 0) ? clickOffsets : nil
        lastPaintedClickPatternLength = clickPatternLength
        lastActiveMatchIndex = currentMatch

        if let idx = currentMatch, matches.indices.contains(idx) {
            scrollByteIntoView(offset: matches[idx])
        }
    }

    /// Search-match tint colors. Factored so the full paint and the
    /// `stepActiveMatch` fast path can never drift on which color marks
    /// the active vs base match.
    private static func matchColor(active: Bool) -> NSColor {
        active
            ? NSColor.systemOrange.withAlphaComponent(0.60)
            : NSColor.systemYellow.withAlphaComponent(0.45)
    }

    /// Repaint only the previously-active match back to base-yellow and
    /// the newly-active match to orange. Used by the `applyHighlights`
    /// fast path when only `currentMatch` changed (audit S2). `painted`
    /// is the match-offset array that produced the current highlights;
    /// both indices are bounds-checked against it.
    private func stepActiveMatch(in painted: [Int],
                                 patternLength: Int,
                                 from oldIndex: Int?,
                                 to newIndex: Int?) {
        guard patternLength > 0, let storage = textView.textStorage else { return }
        storage.beginEditing()
        if let old = oldIndex, painted.indices.contains(old) {
            paint(offset: painted[old], length: patternLength,
                  color: Self.matchColor(active: false), in: storage)
        }
        if let new = newIndex, painted.indices.contains(new) {
            paint(offset: painted[new], length: patternLength,
                  color: Self.matchColor(active: true), in: storage)
        }
        storage.endEditing()
    }

    /// Remove `.backgroundColor` from exactly the ranges the previous full
    /// paint touched (search matches + click occurrences). No-op right
    /// after a dump rebuild (nothing painted yet) — which also means the
    /// FIRST paint after a rebuild no longer walks the whole document.
    private func clearPaintedHighlights(in storage: NSTextStorage) {
        var ranges: [NSRange] = []
        if let painted = lastPaintedMatches, lastPaintedMatchPatternLength > 0 {
            ranges += HexHighlightPlan.clearRanges(
                offsets: painted,
                patternLength: lastPaintedMatchPatternLength,
                width: currentWidth,
                headerCharCount: headerCharCount,
                byteCount: byteCount)
        }
        if let clicks = lastPaintedClickOffsets, lastPaintedClickPatternLength > 0 {
            ranges += HexHighlightPlan.clearRanges(
                offsets: clicks,
                patternLength: lastPaintedClickPatternLength,
                width: currentWidth,
                headerCharCount: headerCharCount,
                byteCount: byteCount)
        }
        for r in ranges where NSMaxRange(r) <= storage.length {
            storage.removeAttribute(.backgroundColor, range: r)
        }
    }

    private func paint(offset: Int, length: Int,
                       color: NSColor, in storage: NSTextStorage) {
        guard length > 0 else { return }
        paintSide(offset: offset, length: length, side: .hex,
                  color: color, in: storage)
        paintSide(offset: offset, length: length, side: .ascii,
                  color: color, in: storage)
    }

    /// Which column family of the dump a range lives in — the two-digit hex
    /// cells or the 1-char ascii gutter. Caret + tandem paints are per-side.
    enum DumpSide { case hex, ascii }

    /// Per-side variant of `paint` — `nil` color removes the background.
    private func paintSide(offset: Int, length: Int, side: DumpSide,
                           color: NSColor?, in storage: NSTextStorage) {
        guard length > 0, byteCount > 0 else { return }
        let last = min(offset + length - 1, byteCount - 1)
        guard offset <= last else { return }
        for b in max(0, offset)...last {
            let row = HexLayout.row(forOffset: b, width: currentWidth)
            let col = HexLayout.column(forOffset: b, width: currentWidth)
            let rowStart = headerCharCount + row * rowLength
            let range: NSRange
            switch side {
            case .hex:
                range = NSRange(
                    location: rowStart + HexLayout.hexCharOffset(inRowColumn: col),
                    length: 2)
            case .ascii:
                range = NSRange(
                    location: rowStart + HexLayout.asciiCharOffset(
                        inRowColumn: col, width: currentWidth),
                    length: 1)
            }
            guard NSMaxRange(range) <= storage.length else { continue }
            if let color {
                storage.addAttribute(.backgroundColor, value: color, range: range)
            } else {
                storage.removeAttribute(.backgroundColor, range: range)
            }
        }
    }

    // MARK: Caret cell + tandem selection paints (owner 2026-08-09)

    /// The byte whose caret cells are currently painted, so a caret move
    /// clears exactly one byte's tint. (A zero-length selection draws NO
    /// insertion beam in a non-editable NSTextView — the edit caret was
    /// invisible; the painted cell is the visible caret.)
    private var lastCaretPaintedByte: Int?

    /// The mirror paint from the last selection change: byte span + the
    /// side it was painted on (the OPPOSITE of the selected side).
    private var lastMirrorPaint: (offset: Int, length: Int, side: DumpSide)?

    func repaintCaretCells() {
        guard let storage = textView.textStorage else { return }
        if let prev = lastCaretPaintedByte {
            paintSide(offset: prev, length: 1, side: .hex, color: nil, in: storage)
            paintSide(offset: prev, length: 1, side: .ascii, color: nil, in: storage)
            lastCaretPaintedByte = nil
        }
        guard let caret = editCaret else { return }
        let byte: Int
        let active: DumpSide
        switch caret {
        case .hex(let b, _): byte = b; active = .hex
        case .ascii(let b):  byte = b; active = .ascii
        }
        paintSide(offset: byte, length: 1, side: active,
                  color: NSColor.controlAccentColor.withAlphaComponent(0.55),
                  in: storage)
        paintSide(offset: byte, length: 1, side: active == .hex ? .ascii : .hex,
                  color: NSColor.controlAccentColor.withAlphaComponent(0.28),
                  in: storage)
        lastCaretPaintedByte = byte
    }

    /// View-mode tandem highlight: selecting in the hex columns tints the
    /// corresponding ascii chars, and vice versa — the selection itself is
    /// native, only the OTHER side is painted. Span capped so a select-all
    /// on a huge dump stays O(cap).
    func mirrorSelectionChanged() {
        guard let storage = textView.textStorage else { return }
        if let m = lastMirrorPaint {
            paintSide(offset: m.offset, length: m.length, side: m.side,
                      color: nil, in: storage)
            lastMirrorPaint = nil
        }
        let sel = textView.selectedRange()
        guard sel.length > 1 else { return }
        // Probe the selection's first hittable char for the selected side.
        var selectedSide: DumpSide?
        for idx in sel.location..<min(sel.location + 8, NSMaxRange(sel)) {
            if let hit = HexCaretMap.hit(charIndex: idx, width: currentWidth,
                                         byteCount: byteCount,
                                         headerCharCount: headerCharCount) {
                if case .hex = hit { selectedSide = .hex } else { selectedSide = .ascii }
                break
            }
        }
        guard let selectedSide else { return }
        // Byte span: scan the endpoints inward past gutter/gap chars.
        var first: Int?
        for idx in sel.location..<min(sel.location + 8, NSMaxRange(sel)) {
            if let b = charIndexToByteOffset(idx) { first = b; break }
        }
        var last: Int?
        for idx in stride(from: NSMaxRange(sel) - 1,
                          through: max(sel.location, NSMaxRange(sel) - 8), by: -1) {
            if let b = charIndexToByteOffset(idx) { last = b; break }
        }
        guard let lo = first, let hi = last, hi >= lo else { return }
        let length = min(hi - lo + 1, 4096)
        let mirror: DumpSide = selectedSide == .hex ? .ascii : .hex
        paintSide(offset: lo, length: length, side: mirror,
                  color: NSColor.controlAccentColor.withAlphaComponent(0.28),
                  in: storage)
        lastMirrorPaint = (lo, length, mirror)
    }

    private func scrollByteIntoView(offset: Int) {
        let row = HexLayout.row(forOffset: offset, width: currentWidth)
        let col = HexLayout.column(forOffset: offset, width: currentWidth)
        let rowStart = headerCharCount + row * rowLength
        let charIdx = rowStart + HexLayout.hexCharOffset(inRowColumn: col)
        textView.scrollRangeToVisible(NSRange(location: charIdx, length: 2))
    }

    // MARK: - Editing (#234)

    private static let hexDigits: [Character] = Array("0123456789abcdef")

    /// Push the dirty state up to the model. When dirty we ALWAYS fire (to
    /// refresh the model's stashed bytes for a close-confirm save, since a
    /// second edit keeps `isDirty == true` but changes the bytes); when
    /// clean we fire only on the dirty→clean transition. The model dedups
    /// the actual `Tab.isDirty` write itself.
    private func reportDirty(_ dirty: Bool) {
        if dirty {
            lastReportedDirty = true
            onDirtyChange?(true, editBuffer?.data)
        } else if lastReportedDirty {
            lastReportedDirty = false
            onDirtyChange?(false, nil)
        }
    }

    /// Place the edit caret from a click character index. Returns true if
    /// the click landed on an editable hex/ascii cell.
    @discardableResult
    func placeEditCaret(fromCharIndex idx: Int) -> Bool {
        guard editable, !isStreaming else { return false }
        guard let hit = HexCaretMap.hit(charIndex: idx,
                                        width: currentWidth,
                                        byteCount: byteCount,
                                        headerCharCount: headerCharCount)
        else { return false }
        switch hit {
        case .hex(let b, let n): editCaret = .hex(byte: b, nibble: n)
        case .ascii(let b):      editCaret = .ascii(byte: b)
        }
        syncSelectionToCaret()
        return true
    }

    /// Handle a single typed character in edit mode. Returns true if it
    /// was consumed (so `keyDown` doesn't fall through to TextKit).
    fileprivate func handleEditCharacter(_ scalar: Unicode.Scalar) -> Bool {
        guard editable, !isStreaming, byteCount > 0,
              var buf = editBuffer, let caret = editCaret else { return false }
        switch caret {
        case .hex(let byte, let nibble):
            guard let v = HexNibble.value(of: scalar) else { return false }
            let changed = buf.setNibble(byte: byte, nibble: nibble, value: v)
            editBuffer = buf
            if changed { repaintByte(byte, in: buf) }
            // Advance one nibble regardless (typing flows left→right even
            // when re-typing the same value).
            if let next = HexCaretMap.advanceHex(byte: byte, nibble: nibble,
                                                 by: 1, byteCount: byteCount) {
                editCaret = .hex(byte: next.byte, nibble: next.nibble)
            }
            reportDirty(buf.isDirty)
            syncSelectionToCaret()
            return true
        case .ascii(let byte):
            guard HexNibble.isPrintableASCII(scalar) else { return false }
            let changed = buf.setByte(byte: byte, value: UInt8(scalar.value))
            editBuffer = buf
            if changed { repaintByte(byte, in: buf) }
            if let next = HexCaretMap.advanceAscii(byte: byte, by: 1,
                                                   byteCount: byteCount) {
                editCaret = .ascii(byte: next)
            }
            reportDirty(buf.isDirty)
            syncSelectionToCaret()
            return true
        }
    }

    /// Move the edit caret by one cell (arrow / tab). `delta` is in
    /// nibbles for a hex caret, bytes for an ascii caret. Returns true if
    /// consumed.
    fileprivate func moveEditCaret(by delta: Int) -> Bool {
        guard editable, !isStreaming, byteCount > 0,
              let caret = editCaret else { return false }
        switch caret {
        case .hex(let b, let n):
            guard let next = HexCaretMap.advanceHex(byte: b, nibble: n,
                                                    by: delta, byteCount: byteCount)
            else { return false }
            editCaret = .hex(byte: next.byte, nibble: next.nibble)
        case .ascii(let b):
            let step = delta == 0 ? 0 : (delta > 0 ? 1 : -1)
            guard let next = HexCaretMap.advanceAscii(byte: b, by: step,
                                                      byteCount: byteCount)
            else { return false }
            editCaret = .ascii(byte: next)
        }
        syncSelectionToCaret()
        return true
    }

    /// Undo / redo a byte edit. Repaints the affected byte and moves the
    /// caret there. Returns true if anything happened.
    @discardableResult
    fileprivate func undoEdit() -> Bool {
        guard editable, var buf = editBuffer, let idx = buf.undo() else { return false }
        editBuffer = buf
        repaintByte(idx, in: buf)
        editCaret = .hex(byte: idx, nibble: 0)
        reportDirty(buf.isDirty)
        syncSelectionToCaret()
        return true
    }

    @discardableResult
    fileprivate func redoEdit() -> Bool {
        guard editable, var buf = editBuffer, let idx = buf.redo() else { return false }
        editBuffer = buf
        repaintByte(idx, in: buf)
        editCaret = .hex(byte: idx, nibble: 0)
        reportDirty(buf.isDirty)
        syncSelectionToCaret()
        return true
    }

    /// Write the edited bytes back to disk via the model's save path.
    /// No-op when clean.
    fileprivate func requestSave() {
        guard editable, let buf = editBuffer, buf.isDirty else { return }
        onRequestSave?(buf.data)
    }

    /// Whether the buffer is currently dirty — used by the controller's
    /// save validation.
    var isHexDirty: Bool { editBuffer?.isDirty ?? false }

    /// Mark the buffer clean after a successful save (caller: model). Keeps
    /// the edited bytes as the new baseline; clears the dirty dot and the
    /// "modified" tints (those bytes are now saved, not pending).
    func markHexSaved() {
        guard var buf = editBuffer else { return }
        let wasModified = buf.dirtyByteIndices
        buf.markSaved()
        editBuffer = buf
        // Repaint formerly-modified bytes so their orange tint clears now
        // that original == edited.
        for idx in wasModified { repaintByte(idx, in: buf) }
        reportDirty(false)
    }

    /// Re-render the two hex digits + the ASCII glyph for `byte` in place,
    /// preserving the monospace attributes. O(1) — addresses the exact
    /// ranges the highlight painter uses, so it stays in lock-step with
    /// the dump layout. A modified byte is tinted so the user sees what
    /// they've changed.
    private func repaintByte(_ byte: Int, in buf: HexEditBuffer) {
        guard let storage = textView.textStorage,
              byte >= 0, byte < byteCount,
              let value = buf.byte(at: byte) else { return }
        let row = HexLayout.row(forOffset: byte, width: currentWidth)
        let col = HexLayout.column(forOffset: byte, width: currentWidth)
        let rowStart = headerCharCount + row * rowLength
        let hexLoc = rowStart + HexLayout.hexCharOffset(inRowColumn: col)
        let asciiLoc = rowStart + HexLayout.asciiCharOffset(inRowColumn: col,
                                                            width: currentWidth)
        let hexRange = NSRange(location: hexLoc, length: 2)
        let asciiRange = NSRange(location: asciiLoc, length: 1)
        guard NSMaxRange(hexRange) <= storage.length,
              NSMaxRange(asciiRange) <= storage.length else { return }

        let hexStr = String([Self.hexDigits[Int(value >> 4)],
                             Self.hexDigits[Int(value & 0x0F)]])
        let asciiChar: Character = (32...126).contains(value)
            ? Character(UnicodeScalar(value)) : "."
        let modified = buf.byte(at: byte) != buf.original(at: byte)
        let tint: NSColor? = modified
            ? NSColor.systemOrange.withAlphaComponent(0.28) : nil

        storage.beginEditing()
        replaceGlyphs(hexStr, at: hexRange, tint: tint, in: storage)
        replaceGlyphs(String(asciiChar), at: asciiRange, tint: tint, in: storage)
        storage.endEditing()
        fileData = buf.data
    }

    /// Replace `range` with `text` keeping the existing font; optionally
    /// paint a background tint (for modified bytes).
    private func replaceGlyphs(_ text: String, at range: NSRange,
                               tint: NSColor?, in storage: NSTextStorage) {
        let font = (storage.length > range.location
            ? storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            : nil) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        if let tint { attrs[.backgroundColor] = tint }
        storage.replaceCharacters(in: range,
                                  with: NSAttributedString(string: text, attributes: attrs))
    }

    /// Reflect the edit caret onto the NSTextView's selection so the
    /// blinking insertion point is visible at the edit cell.
    private func syncSelectionToCaret() {
        guard let caret = editCaret else { return }
        let loc: Int
        switch caret {
        case .hex(let b, let n):
            loc = HexCaretMap.hexCharIndex(byte: b, nibble: n,
                                           width: currentWidth,
                                           headerCharCount: headerCharCount)
        case .ascii(let b):
            loc = HexCaretMap.asciiCharIndex(byte: b,
                                             width: currentWidth,
                                             headerCharCount: headerCharCount)
        }
        guard loc <= (textView.textStorage?.length ?? 0) else { return }
        textView.setSelectedRange(NSRange(location: loc, length: 0))
        textView.scrollRangeToVisible(NSRange(location: loc, length: 0))
        repaintCaretCells()
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

// MARK: - TK2 grid metrics (TSK-267 step 4)

/// Measures TextKit 2's EXACT per-line height and monospace character
/// advance for a font by laying out tiny samples with the same engine
/// `NSTextView` uses (`NSTextLayoutManager` + `NSTextContentStorage`).
/// Measuring — rather than deriving from `NSFont` metrics — guarantees
/// the arithmetic frame in `HexGridGeometry` cannot drift from what the
/// live view actually typesets. Cached per font size; each measurement
/// lays out ≤2 short lines (microseconds).
enum HexGridMetrics {
    struct Metrics {
        let lineHeight: Double
        let charAdvance: Double
    }

    @MainActor
    private static var cache: [CGFloat: Metrics] = [:]

    @MainActor
    static func measure(fontSize: CGFloat) -> Metrics {
        if let hit = cache[fontSize] { return hit }
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // Two samples one line apart: their usage-height delta is the
        // engine's true line stride (immune to any constant baseline /
        // first-line padding).
        let h1 = usage(of: "0000000000\n", font: font)
        let h2 = usage(of: "0000000000\n0000000000\n", font: font)
        let m = Metrics(
            lineHeight: h2.height - h1.height,
            charAdvance: h1.width / 10.0)
        cache[fontSize] = m
        return m
    }

    @MainActor
    private static func usage(of sample: String, font: NSFont) -> CGSize {
        let content = NSTextContentStorage()
        let layout = NSTextLayoutManager()
        content.addTextLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.textContainer = container
        content.attributedString = NSAttributedString(
            string: sample, attributes: [.font: font])
        layout.ensureLayout(for: layout.documentRange)
        let b = layout.usageBoundsForTextContainer
        return CGSize(width: b.width, height: b.height)
    }
}

// MARK: - NSTextView subclass for click-to-highlight

final class HexNSTextView: NSTextView {
    weak var controller: HexTextController?
    private var dragStartOffset: Int?
    /// Set by the controller when ViewOnly is off (#234). Arms keystroke
    /// interception for overwrite editing + click-to-place-caret. When
    /// false, every path below is byte-identical to the read-only viewer.
    var isEditingArmed: Bool = false
    /// Armed by `applyFixedGridFrame` (TSK-267): the grid is top-left
    /// aligned in a frame the controller sizes arithmetically, so the
    /// container origin is exactly the inset. The DEFAULT implementation
    /// derives the origin from usage bounds — a full TK2 layout of every
    /// row (measured: ~1.5s of ensureLayoutForRange on a 1MB dump,
    /// re-triggered from layoutViewport and renewGState).
    var usesFixedGridOrigin: Bool = false

    override var textContainerOrigin: NSPoint {
        guard usesFixedGridOrigin else { return super.textContainerOrigin }
        return NSPoint(x: textContainerInset.width,
                       y: textContainerInset.height)
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let idx = characterIndex(forPoint: pt)
        // Edit mode: a click places the edit caret on the cell. We still
        // call super so the system insertion point / selection draws.
        if isEditingArmed, let idx, controller?.placeEditCaret(fromCharIndex: idx) == true {
            super.mouseDown(with: event)
            return
        }
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
        // In edit mode the click-pattern highlight is suppressed (a click
        // is "place caret", not "highlight all equal bytes").
        if isEditingArmed { dragStartOffset = nil; return }
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
        if isEditingArmed, handleEditKeyDown(event) { return }
        super.keyDown(with: event)
    }

    /// Edit-mode key routing. Returns true if the event was consumed.
    /// Handles ⌘S (save), ⌘Z / ⇧⌘Z (undo/redo), arrows + tab (navigation),
    /// and printable hex/ascii characters (overwrite). Anything else falls
    /// through to the system (selection, copy, scroll).
    private func handleEditKeyDown(_ event: NSEvent) -> Bool {
        guard let controller else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if mods.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "s":
                controller.requestSave()
                return true
            case "z":
                if mods.contains(.shift) { return controller.redoEdit() }
                return controller.undoEdit()
            default:
                return false  // ⌘C / ⌘A / etc. → system
            }
        }

        // Bare navigation keys.
        switch event.keyCode {
        case 123: return controller.moveEditCaret(by: -1) // ←
        case 124: return controller.moveEditCaret(by: 1)  // →
        case 48:  // tab — step a whole byte (2 nibbles) forward, or back
            return controller.moveEditCaret(by: mods.contains(.shift) ? -2 : 2)
        default:
            break
        }

        // Printable character → overwrite. One scalar at a time; ignore
        // multi-scalar / control input.
        guard let chars = event.characters, chars.unicodeScalars.count == 1,
              let scalar = chars.unicodeScalars.first else { return false }
        return controller.handleEditCharacter(scalar)
    }
}
