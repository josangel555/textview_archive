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
final class TerminalNSView: NSView, SidebarKeyMonitorExempt {
    /// Callback the view uses to push input bytes to the PTY. Set by the
    /// representable's coordinator. Off the SwiftUI body path.
    var onInput: ((Data) -> Void)?
    /// Called when the view's pixel size resolves a new (rows, cols) so
    /// the model + PTY can re-dimension. Debounced by equality on the
    /// model side.
    var onResize: ((_ rows: Int, _ cols: Int) -> Void)?

    private(set) var fontSize: CGFloat = 12 {
        didSet { rebuildFontMetrics() }
    }

    private var screen: TerminalScreen
    private var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    private var boldFont: NSFont = .monospacedSystemFont(ofSize: 12, weight: .bold)
    private var cellWidth: CGFloat = 7
    private var cellHeight: CGFloat = 15
    private var ascent: CGFloat = 12

    init(initialScreen: TerminalScreen, fontSize: CGFloat) {
        self.screen = initialScreen
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
    // Click anywhere focuses the terminal.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }
    override var isFlipped: Bool { true }   // top-left origin matches the grid

    // MARK: - Public update

    /// Install a new screen snapshot + font size and redraw. Called from
    /// the representable's `updateNSView` (main actor) on a version bump.
    func update(screen: TerminalScreen, fontSize: CGFloat) {
        var changed = false
        if self.fontSize != fontSize { self.fontSize = fontSize; changed = true }
        if self.screen != screen { self.screen = screen; changed = true }
        if changed { needsDisplay = true }
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

    private func recomputeGridDimensions() {
        guard cellWidth > 0, cellHeight > 0 else { return }
        let cols = max(1, Int(floor(bounds.width / cellWidth)))
        let rows = max(1, Int(floor(bounds.height / cellHeight)))
        onResize?(rows, cols)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSColor.textBackgroundColor
        bg.setFill()
        dirtyRect.fill()

        let defaultFg = NSColor.labelColor
        let rows = screen.rows
        let cols = screen.cols

        for r in 0..<rows {
            let rowCells = screen.cells[r]
            let y = CGFloat(r) * cellHeight
            var c = 0
            while c < cols {
                let attrs = rowCells[c].attributes
                // Coalesce a run of cells sharing the same attributes.
                var end = c + 1
                while end < cols && rowCells[end].attributes == attrs {
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

        drawCursor(defaultFg: defaultFg)
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
        guard window?.firstResponder === self else { return }
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
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .contains(.command) { return false }
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
        onInput?(Data(bytes))
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
