import AppKit
import ViewerCore

/// A direct-drawing `NSView` that renders a `TerminalScreen` grid in a
/// monospaced font and forwards key events to a `TerminalModel`. NO
/// `NSScrollView` / NO `NSRulerView` are involved, so the SwiftUI
/// compositor pathology documented in LESSONS (ruler-tile reentrancy)
/// does not apply — this is a plain custom view drawing into its own
/// layer.
///
/// Rendering: each frame we paint the whole grid with Core Text glyph
/// runs, one `NSAttributedString` draw per cell-run of identical
/// attributes (coalesced left-to-right). The grid is small (≈ rows×cols
/// ≤ a few thousand cells); a full repaint per coalesced frame is cheap
/// and avoids any incremental-diff bookkeeping.
///
/// Input: the view is the first responder; `keyDown` maps the event to
/// terminal bytes via `TerminalKeyEncoder` (pure logic) and writes them
/// to the PTY. `insertText`/IME paths route plain text through the same
/// encoder.
final class TerminalNSView: NSView, SidebarKeyMonitorExempt, NSMenuItemValidation {
    /// Callback the view uses to push input bytes to the PTY. Set by the
    /// representable's coordinator. Off the SwiftUI body path.
    var onInput: ((Data) -> Void)?
    /// Called when the view's pixel size resolves a new (rows, cols) so
    /// the model + PTY can re-dimension. Debounced by equality on the
    /// model side.
    var onResize: ((_ rows: Int, _ cols: Int) -> Void)?
    /// Cycle terminal tabs (⌃Tab next / ⌃⇧Tab prev). Set by the
    /// representable; routed to `TerminalPaneStore.cycleTab`.
    var onCycleTab: ((_ forward: Bool) -> Void)?
    /// New terminal tab (⌘T while the terminal is focused).
    var onNewTab: (() -> Void)?
    /// Close the current terminal tab (⌘W while the terminal is focused).
    var onCloseTab: (() -> Void)?
    /// Persist the scrollback offset back to the per-tab model so it
    /// survives the `.id`-driven view recreation on tab switch (TSK-489).
    var onScrollOffsetChange: ((Int) -> Void)?

    /// True while dragging the scrollback scrollbar thumb (vs selecting text).
    private var isScrollbarDrag = false
    /// Hit width of the right-edge scrollbar gutter, in points.
    private let scrollbarHitWidth: CGFloat = 14

    private(set) var fontSize: CGFloat = 12 {
        didSet { rebuildFontMetrics() }
    }

    private var screen: TerminalScreen
    private var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    private var boldFont: NSFont = .monospacedSystemFont(ofSize: 12, weight: .bold)
    private var cellWidth: CGFloat = 7
    private var cellHeight: CGFloat = 15
    private var ascent: CGFloat = 12

    /// Live mouse selection over the grid (pure geometry in ViewerCore).
    /// `nil` when nothing is selected.
    private var selection: TerminalSelection?
    /// True between `mouseDown` and `mouseUp` for a plain (click+drag)
    /// gesture — distinguishes a drag-select from a focus click.
    private var isDragging = false
    /// True once a drag has moved off the anchor cell. A click that never
    /// moves clears the selection on `mouseUp` (so a focus click doesn't
    /// leave a stray 1-cell selection); word/line selects bypass this.
    private var didDrag = false

    var hasSelection: Bool { selection != nil }

    /// Scrollback viewport: lines scrolled up from the live bottom.
    /// 0 == following the live output. Driven by `scrollWheel`; reset to 0
    /// on keyboard input.
    private var scrollOffset = 0
    /// Sub-line scroll accumulator so trackpad momentum maps smoothly to
    /// whole-line steps.
    private var scrollAccum: CGFloat = 0

    /// The rows currently on screen — the live grid when at the bottom, or
    /// a window into scrollback when scrolled up.
    private var displayRows: [[TerminalCell]] {
        screen.visibleLines(scrollOffset: scrollOffset)
    }

    init(initialScreen: TerminalScreen, fontSize: CGFloat, initialScrollOffset: Int = 0) {
        self.screen = initialScreen
        // Seed from the per-tab model so a tab switch restores the prior
        // scroll position (clamped to this screen's scrollback). TSK-489.
        self.scrollOffset = min(max(0, initialScrollOffset), initialScreen.scrollback.count)
        super.init(frame: .zero)
        self.fontSize = fontSize
        wantsLayer = true
        rebuildFontMetrics()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - First responder / focus

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }
    override func resignFirstResponder() -> Bool { true }
    override var isFlipped: Bool { true }   // top-left origin matches the grid

    // MARK: - Mouse: focus + text selection

    /// Convert a mouse event to the grid cell under the pointer (clamped
    /// to the grid).
    private func cellPoint(for event: NSEvent) -> TerminalSelection.Point {
        let p = convert(event.locationInWindow, from: nil)
        let col = cellWidth > 0 ? Int(floor(p.x / cellWidth)) : 0
        let row = cellHeight > 0 ? Int(floor(p.y / cellHeight)) : 0
        return TerminalSelection.Point(
            row: min(max(0, row), max(0, screen.rows - 1)),
            col: min(max(0, col), max(0, screen.cols - 1))
        )
    }

    /// Map a mouse event to a scroll offset via the scrollbar gutter.
    private func scrollbarOffset(for event: NSEvent) -> Int {
        let local = convert(event.locationInWindow, from: nil)
        let f = bounds.height > 0 ? Double(local.y / bounds.height) : 0
        return TerminalScrollbar.offset(forYFraction: f,
                                        rows: screen.rows, scrollback: screen.scrollback.count)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // Right-edge gutter drives the scrollbar (when there's scrollback).
        let local = convert(event.locationInWindow, from: nil)
        if screen.scrollback.count > 0, local.x >= bounds.width - scrollbarHitWidth {
            isScrollbarDrag = true
            if selection != nil { selection = nil }
            scrollOffset = scrollbarOffset(for: event)
            needsDisplay = true
            return
        }
        let p = cellPoint(for: event)
        switch event.clickCount {
        case 2:    // word (over the currently-visible rows — may be scrollback)
            selection = TerminalSelection.word(at: p, inRows: displayRows)
            isDragging = false
            didDrag = true            // keep it on mouseUp
        case 3:    // line
            selection = TerminalSelection.line(p.row, cols: screen.cols)
            isDragging = false
            didDrag = true
        default:   // begin drag-select (tentative 1-cell anchor)
            selection = TerminalSelection(anchor: p, head: p)
            isDragging = true
            didDrag = false
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if isScrollbarDrag {
            scrollOffset = scrollbarOffset(for: event)
            needsDisplay = true
            return
        }
        guard isDragging else { return }
        let p = cellPoint(for: event)
        guard var sel = selection else { return }
        if p != sel.anchor { didDrag = true }
        sel.head = p
        selection = sel
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isScrollbarDrag { isScrollbarDrag = false; return }
        // A focus click that never dragged clears any tentative selection.
        if isDragging && !didDrag { selection = nil; needsDisplay = true }
        isDragging = false
    }

    // MARK: - Public update

    /// Install a new screen snapshot + font size and redraw. Called from
    /// the representable's `updateNSView` (main actor) on a version bump.
    func update(screen: TerminalScreen, fontSize: CGFloat) {
        var changed = false
        if self.fontSize != fontSize { self.fontSize = fontSize; changed = true }
        let oldScrollback = self.screen.scrollback.count
        if self.screen != screen { self.screen = screen; changed = true }
        let newScrollback = self.screen.scrollback.count
        // While scrolled up (reading history), new shell output that pushes
        // lines into scrollback would otherwise slide the "frozen" view —
        // and drag a held selection off its content. Advance the offset by
        // the same growth so the viewport stays pinned to what the user is
        // reading (capped at the buffer; at the cap the oldest line is
        // genuinely evicted and can't be pinned).
        if scrollOffset > 0, newScrollback > oldScrollback {
            scrollOffset = min(scrollOffset + (newScrollback - oldScrollback), newScrollback)
            changed = true
            onScrollOffsetChange?(scrollOffset)
        }
        // Keep the viewport valid as scrollback shrinks (resize/reset).
        if scrollOffset > newScrollback {
            scrollOffset = newScrollback
            changed = true
            onScrollOffsetChange?(scrollOffset)
        }
        if changed { needsDisplay = true }
    }

    // MARK: - Scroll (scrollback viewport)

    override func scrollWheel(with event: NSEvent) {
        guard cellHeight > 0 else { return }
        scrollAccum += event.scrollingDeltaY
        let lines = Int((scrollAccum / cellHeight).rounded(.towardZero))
        guard lines != 0 else { return }
        scrollAccum -= CGFloat(lines) * cellHeight
        // Positive scrollingDeltaY (content pulled down) reveals older
        // lines → larger offset.
        let maxOff = screen.scrollback.count
        let newOff = min(max(0, scrollOffset + lines), maxOff)
        guard newOff != scrollOffset else { return }
        scrollOffset = newOff
        // Selection is in viewport-row space; scrolling moves content under
        // it, so drop it rather than leave a misaligned highlight.
        if selection != nil { selection = nil }
        needsDisplay = true
    }

    /// Snap the viewport back to the live bottom (called on keyboard input).
    private func snapToBottom() {
        guard scrollOffset != 0 else { return }
        scrollOffset = 0
        scrollAccum = 0
        needsDisplay = true
    }

    private func rebuildFontMetrics() {
        font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        boldFont = .monospacedSystemFont(ofSize: fontSize, weight: .bold)
        // Advance width of a representative monospace glyph.
        let probe = NSAttributedString(string: "M", attributes: [.font: font])
        cellWidth = max(1, probe.size().width)
        let lh = font.ascender - font.descender + font.leading
        cellHeight = max(1, ceil(lh))
        ascent = font.ascender
        needsDisplay = true
    }

    // MARK: - Resize → (rows, cols)

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recomputeGridDimensions()
    }

    override func layout() {
        super.layout()
        recomputeGridDimensions()
    }

    /// Last (rows, cols) actually reported via `onResize`, to suppress
    /// duplicate / destructive resizes.
    private var lastReportedGrid: (rows: Int, cols: Int)?

    private func recomputeGridDimensions() {
        guard cellWidth > 0, cellHeight > 0 else { return }
        // CRITICAL (TSK-489 follow-up): on a tab-switch REMOUNT the view first
        // lays out at frame `.zero`, so `floor(0/cellHeight)` would be 0 →
        // `max(1, …)` = a 1×1 grid. Firing `onResize(1,1)` collapses the live
        // grid to one cell and DESTROYS the on-screen output (the reported
        // "switch away + back → results gone, prompt scrolled to the top",
        // and it wrecks alt-screen TUIs). Require at least one full cell of
        // real space before reporting a size; a zero/degenerate transient is
        // ignored, so the geometry the model already has survives the remount.
        guard bounds.width >= cellWidth, bounds.height >= cellHeight else { return }
        let cols = max(1, Int(floor(bounds.width / cellWidth)))
        let rows = max(1, Int(floor(bounds.height / cellHeight)))
        // Dedupe: an unchanged size must not churn the parser / re-SIGWINCH the
        // shell on every layout pass.
        if let last = lastReportedGrid, last == (rows, cols) { return }
        lastReportedGrid = (rows, cols)
        onResize?(rows, cols)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSColor.textBackgroundColor
        bg.setFill()
        dirtyRect.fill()

        let defaultFg = NSColor.labelColor
        let cols = screen.cols
        // Render the current viewport — the live grid at the bottom, or a
        // window into scrollback when scrolled up.
        let rows = displayRows

        for r in 0..<rows.count {
            let rowCells = rows[r]
            let rowCount = min(rowCells.count, cols)
            let y = CGFloat(r) * cellHeight
            var c = 0
            while c < rowCount {
                let attrs = rowCells[c].attributes
                // Coalesce a run of cells sharing the same attributes.
                var end = c + 1
                while end < rowCount && rowCells[end].attributes == attrs {
                    end += 1
                }
                let runText = String(rowCells[c..<end].map(\.char))
                drawRun(
                    runText,
                    attributes: attrs,
                    atColumn: c,
                    y: y,
                    defaultFg: defaultFg
                )
                c = end
            }
        }

        drawSelection()
        drawCursor(defaultFg: defaultFg)
        drawScrollbar()
    }

    /// Right-edge scrollback thumb (overlay style — only when there's
    /// history to scroll). Geometry from the pure `TerminalScrollbar`.
    private func drawScrollbar() {
        guard let t = TerminalScrollbar.thumb(rows: screen.rows,
                                              scrollback: screen.scrollback.count,
                                              offset: scrollOffset) else { return }
        let trackH = bounds.height
        let thumbW: CGFloat = 6
        let thumbH = max(18, min(CGFloat(t.height) * trackH, trackH))
        let travel = max(0, trackH - thumbH)
        let y = CGFloat(t.position) * travel
        let x = bounds.width - thumbW - 2
        let highlighted = isScrollbarDrag || scrollOffset > 0
        NSColor.secondaryLabelColor
            .withAlphaComponent(highlighted ? 0.55 : 0.30)
            .setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: thumbW, height: thumbH),
                     xRadius: thumbW / 2, yRadius: thumbW / 2).fill()
    }

    /// Translucent highlight over the selected cell spans (drawn after the
    /// glyphs so the text shows through). Per-row span comes from the pure
    /// `TerminalSelection.columnRange`.
    private func drawSelection() {
        guard let selection else { return }
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45).setFill()
        for r in 0..<screen.rows {
            guard let range = selection.columnRange(forRow: r, cols: screen.cols) else { continue }
            let x = CGFloat(range.lowerBound) * cellWidth
            let w = CGFloat(range.count) * cellWidth
            NSRect(x: x, y: CGFloat(r) * cellHeight, width: w, height: cellHeight).fill()
        }
    }

    private func drawRun(
        _ text: String,
        attributes: CellAttributes,
        atColumn col: Int,
        y: CGFloat,
        defaultFg: NSColor
    ) {
        let x = CGFloat(col) * cellWidth
        let runWidth = CGFloat(text.count) * cellWidth

        // Background fill (only when non-default — saves a fill per blank run).
        if let bgColor = TerminalPalette.nsColor(attributes.effectiveBg) {
            bgColor.setFill()
            NSRect(x: x, y: y, width: runWidth, height: cellHeight).fill()
        }

        // Skip drawing glyphs for an all-space run (common — trailing blanks).
        if text.allSatisfy({ $0 == " " }) && !attributes.underline { return }

        let fg = TerminalPalette.nsColor(attributes.effectiveFg) ?? defaultFg
        var glyphAttrs: [NSAttributedString.Key: Any] = [
            .font: attributes.bold ? boldFont : font,
            .foregroundColor: fg,
        ]
        if attributes.underline {
            glyphAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        let attr = NSAttributedString(string: text, attributes: glyphAttrs)
        attr.draw(at: NSPoint(x: x, y: y))
    }

    private func drawCursor(defaultFg: NSColor) {
        // No cursor while scrolled into history (it belongs to the live grid).
        guard scrollOffset == 0, window?.firstResponder === self else { return }
        let cur = screen.cursor
        guard cur.row < screen.rows, cur.col < screen.cols else { return }
        let x = CGFloat(cur.col) * cellWidth
        let y = CGFloat(cur.row) * cellHeight
        NSColor.controlAccentColor.withAlphaComponent(0.55).setFill()
        NSRect(x: x, y: y, width: cellWidth, height: cellHeight).fill()
    }

    // MARK: - Key input

    /// Return / keypad-Enter are routed by AppKit through the key-equivalent
    /// (window default-button) machinery BEFORE `keyDown`. SwiftUI installs a
    /// window default button whenever a `.keyboardShortcut(.defaultAction)` /
    /// `.return` button exists anywhere in the chrome, so pressing Return fires
    /// THAT button and the event never reaches our `keyDown` — the shell never
    /// sees a CR. Symptom: typing echoes fine (letters aren't key-equivalents,
    /// so they hit `keyDown` directly) but Enter does nothing. While the
    /// terminal is the focused view, claim Return here and route it through the
    /// normal `keyDown` path so it reaches the PTY. ⌘-chords are left alone so
    /// real menu shortcuts (⌘C/⌘V/⌘W/…) still resolve.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌃Tab / ⌃⇧Tab → cycle terminal tabs. Focus-scoped (only while the
        // terminal owns first responder), so it doesn't collide with the
        // document-tab shortcuts (⌘⇧[ / ⌘⇧] / ⌃1–9). keyCode 48 = Tab.
        if event.keyCode == 48, flags.contains(.control), !flags.contains(.command) {
            onCycleTab?(!flags.contains(.shift))
            return true
        }
        // Bare ⌘T / ⌘W act on terminal tabs while the terminal is focused
        // (shadowing the document-tab New/Close only when typing here).
        // Other ⌘-chords (⌘C/⌘V/⌘A, ⌘⇧T, …) fall through to the menu.
        if flags == .command, let ch = event.charactersIgnoringModifiers {
            if ch == "t" { onNewTab?(); return true }
            if ch == "w" { onCloseTab?(); return true }
        }
        if flags.contains(.command) { return false }
        switch event.keyCode {
        case 36, 76:   // Return, keypad Enter
            keyDown(with: event)
            return true
        default:
            return false
        }
    }

    override func keyDown(with event: NSEvent) {
        if let special = Self.specialKey(for: event) {
            send(TerminalKeyEncoder.bytes(for: special))
            return
        }
        let control = event.modifierFlags.contains(.control)
        let option = event.modifierFlags.contains(.option)
        // `characters` honours the keyboard layout; `charactersIgnoringModifiers`
        // gives us the base letter for Ctrl-chords (so Ctrl-C is 'c' not '\u{03}').
        let text: String
        if control {
            text = event.charactersIgnoringModifiers ?? ""
        } else {
            text = event.characters ?? ""
        }
        guard !text.isEmpty else { return }
        send(TerminalKeyEncoder.bytes(forText: text, control: control, option: option))
    }

    /// Paste / IME committed text path.
    override func insertText(_ insertString: Any) {
        if let s = insertString as? String {
            send(Array(s.utf8))
        } else if let a = insertString as? NSAttributedString {
            send(Array(a.string.utf8))
        }
    }

    private func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        // Typing / pasting jumps back to the live prompt.
        snapToBottom()
        onInput?(Data(bytes))
    }

    // MARK: - Copy / Paste / Select All (Edit menu + ⌘C/⌘V/⌘A + context menu)
    //
    // The app's Edit menu wires `copy:`/`paste:`/`selectAll:` to the first
    // responder with a nil target (main.swift), so implementing these
    // selectors here makes ⌘C/⌘V/⌘A work automatically while the terminal
    // is focused — no `performKeyEquivalent` hijacking needed. `validate-
    // MenuItem` drives their enabled state. Ctrl-C (SIGINT) is unaffected:
    // that's the `.control` chord handled in `keyDown`.

    @objc func copy(_ sender: Any?) {
        guard let text = selection?.selectedText(fromRows: displayRows, cols: screen.cols),
              !text.isEmpty else { return }
        Pasteboard.copy(text)
    }

    @objc func paste(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else { return }
        // Send raw bytes. We don't advertise bracketed-paste (mode 2004 is
        // parse-and-ignored), so a raw write is correct for the shell.
        send(Array(s.utf8))
    }

    @objc override func selectAll(_ sender: Any?) {
        // Snap to the live grid first so "Select All" copies the on-screen
        // buffer rather than whatever scrollback window happens to show.
        snapToBottom()
        selection = TerminalSelection.all(rows: screen.rows, cols: screen.cols)
        needsDisplay = true
    }

    @objc func clearSelection(_ sender: Any?) {
        guard selection != nil else { return }
        selection = nil
        needsDisplay = true
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return hasSelection
        case #selector(paste(_:)):
            return NSPasteboard.general.string(forType: .string) != nil
        case #selector(clearSelection(_:)):
            return hasSelection
        case #selector(selectAll(_:)):
            return true
        default:
            return true
        }
    }

    /// Right-click context menu: Copy / Paste / Select All / Clear.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = hasSelection
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        pasteItem.target = self
        pasteItem.isEnabled = NSPasteboard.general.string(forType: .string) != nil
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        selectAllItem.target = self
        let clearItem = NSMenuItem(title: "Clear Selection", action: #selector(clearSelection(_:)), keyEquivalent: "")
        clearItem.target = self
        clearItem.isEnabled = hasSelection
        menu.addItem(copyItem)
        menu.addItem(pasteItem)
        menu.addItem(.separator())
        menu.addItem(selectAllItem)
        menu.addItem(clearItem)
        return menu
    }

    /// Map an `NSEvent` to a `SpecialKey`, or nil for ordinary text.
    /// Extracts only the `keyCode` (Sendable primitive) — no `NSEvent`
    /// escapes this method (LESSONS: NSEvent isn't Sendable on Swift 6.0).
    private static func specialKey(for event: NSEvent) -> TerminalKeyEncoder.SpecialKey? {
        switch event.keyCode {
        case 36, 76:  return .enter          // Return, keypad Enter
        case 51:      return .backspace      // Delete (backspace)
        case 117:     return .deleteForward  // Forward-Delete
        case 48:      return .tab
        case 53:      return .escape
        case 126:     return .up
        case 125:     return .down
        case 124:     return .right
        case 123:     return .left
        case 115:     return .home
        case 119:     return .end
        case 116:     return .pageUp
        case 121:     return .pageDown
        default:      return nil
        }
    }
}
