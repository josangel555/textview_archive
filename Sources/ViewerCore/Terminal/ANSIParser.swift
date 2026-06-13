import Foundation

/// Minimal ANSI / VT100 escape-sequence parser that drives a
/// `TerminalScreen`. PURE logic — no I/O, no AppKit. Feed it raw bytes
/// from the PTY (`feed(_:)`); it mutates the embedded `screen`.
///
/// SCOPE (dep-free v1 — see the module note in `TerminalScreen`):
///
///   HANDLED
///   ───────
///   • Printable UTF-8 text (decoded incrementally; partial multibyte
///     sequences at a chunk boundary are buffered, not corrupted).
///   • C0 controls: `\n` (LF/IND), `\r` (CR), `\b` (BS), `\t` (HT),
///     `\a` (BEL, ignored), `\v`/`\f` (treated as LF).
///   • CSI cursor moves: CUU `A`, CUD `B`, CUF `C`, CUB `D`,
///     CUP `H` / HVP `f` (row;col), CHA `G` (column), VPA `d` (row).
///   • CSI erase: ED `J` (0/1/2), EL `K` (0/1/2).
///   • CSI scroll: SU `S`, SD `T`.
///   • CSI SGR `m`: reset(0), bold(1), underline(4), inverse(7),
///     un-bold(22), un-underline(24), un-inverse(27), fg 30–37 / 90–97,
///     bg 40–47 / 100–107, default fg(39) / bg(49), 256-colour
///     (`38;5;n` / `48;5;n`), and truecolor (`38;2;r;g;b` / `48;2;…`).
///   • DEC private alternate-screen toggles `ESC[?1049h/l`, `?1047h/l`,
///     `?47h/l` → `TerminalScreen.enterAltScreen()`/`exitAltScreen()`
///     (`top`/`vim`/`less` render on a throwaway buffer; scrollback intact).
///
///   PARSED-THEN-IGNORED (consumed so they don't garble the grid, but
///   produce no screen change)
///   ──────────────────────────────────────────────────────────────────
///   • Other DEC private modes `ESC[?…h` / `ESC[?…l` (cursor visibility,
///     bracketed paste, mouse tracking, …).
///   • Other unrecognised CSI final bytes, and any unrecognised
///     intermediate.
///   • OSC sequences `ESC]…BEL` / `ESC]…ST` (window-title sets, etc.) —
///     swallowed up to the terminator.
///   • Two-byte ESC sequences we don't model (`ESC(B`, `ESC=`, `ESC>`,
///     `ESC M` reverse-index is approximated as scrollDown, …).
///
/// Anything not in the first list is a no-op on the grid; we never emit
/// the raw escape bytes as visible text.
public struct ANSIParser: Sendable {
    public private(set) var screen: TerminalScreen

    public init(rows: Int, cols: Int) {
        self.screen = TerminalScreen(rows: rows, cols: cols)
    }

    public init(screen: TerminalScreen) {
        self.screen = screen
    }

    public mutating func resize(rows: Int, cols: Int) {
        screen.resize(rows: rows, cols: cols)
    }

    // MARK: - Parser state

    private enum State: Equatable {
        case ground
        case escape          // saw ESC, awaiting the next byte
        case escapeCharset   // saw ESC ( / ) / * / + — swallow the next id byte
        case csi             // inside ESC[ … (collecting params)
        case osc             // inside ESC] … (swallow to ST/BEL)
        case oscEscape       // inside OSC and just saw ESC (await `\`)
    }

    private var state: State = .ground
    /// Raw CSI parameter/intermediate bytes between `ESC[` and the final
    /// byte. Kept as bytes; parsed lazily when the final byte arrives.
    private var csiBuffer: [UInt8] = []
    /// Pending UTF-8 continuation bytes spanning a chunk boundary.
    private var utf8Pending: [UInt8] = []

    private static let csiMaxLen = 64   // defensive bound on a runaway CSI

    // MARK: - Feed

    /// Feed a raw byte chunk from the PTY. Safe to call with arbitrary
    /// split points — multibyte UTF-8 and multi-byte escape sequences are
    /// carried across calls in `utf8Pending` / `csiBuffer`.
    public mutating func feed(_ data: [UInt8]) {
        for byte in data { feed(byte) }
    }

    public mutating func feed(_ data: Data) {
        for byte in data { feed(byte) }
    }

    private mutating func feed(_ byte: UInt8) {
        switch state {
        case .ground:
            groundByte(byte)
        case .escape:
            escapeByte(byte)
        case .escapeCharset:
            // Swallow the single charset-designator byte (e.g. 'B', '0').
            state = .ground
        case .csi:
            csiByte(byte)
        case .osc:
            oscByte(byte)
        case .oscEscape:
            // ESC inside OSC: `\` (0x5C) closes (ST); anything else
            // we treat as the OSC having ended + reprocess in ground.
            if byte == 0x5C {
                state = .ground
            } else {
                state = .ground
                feed(byte)
            }
        }
    }

    // MARK: - Ground state

    private mutating func groundByte(_ byte: UInt8) {
        switch byte {
        case 0x1B:                       // ESC
            flushUTF8()
            state = .escape
        case 0x0A, 0x0B, 0x0C:           // LF, VT, FF → line feed
            flushUTF8()
            screen.lineFeed()
        case 0x0D:                       // CR
            flushUTF8()
            screen.carriageReturn()
        case 0x08:                       // BS
            flushUTF8()
            screen.backspace()
        case 0x09:                       // HT
            flushUTF8()
            screen.tab()
        case 0x07:                       // BEL — ignore
            flushUTF8()
        case 0x00...0x06, 0x0E...0x1A, 0x1C...0x1F:
            // Other C0 controls we don't model — drop silently.
            flushUTF8()
        default:
            // Printable byte — accumulate for UTF-8 decode.
            appendUTF8(byte)
        }
    }

    // MARK: - UTF-8 incremental decode

    /// Number of bytes a UTF-8 sequence with this lead byte spans, or
    /// nil if `byte` is a continuation / invalid lead.
    private func utf8Length(lead byte: UInt8) -> Int? {
        if byte & 0x80 == 0 { return 1 }            // 0xxxxxxx
        if byte & 0xE0 == 0xC0 { return 2 }         // 110xxxxx
        if byte & 0xF0 == 0xE0 { return 3 }         // 1110xxxx
        if byte & 0xF8 == 0xF0 { return 4 }         // 11110xxx
        return nil
    }

    private mutating func appendUTF8(_ byte: UInt8) {
        if utf8Pending.isEmpty {
            guard let len = utf8Length(lead: byte) else {
                // Stray continuation byte / invalid lead — emit U+FFFD so
                // we never silently drop a column, then carry on.
                screen.write("\u{FFFD}")
                return
            }
            if len == 1 {
                writeScalarByte(byte)
            } else {
                utf8Pending = [byte]
            }
        } else {
            // Continuation expected.
            if byte & 0xC0 == 0x80 {
                utf8Pending.append(byte)
                if let len = utf8Length(lead: utf8Pending[0]),
                   utf8Pending.count == len {
                    flushUTF8()
                }
            } else {
                // Malformed: the prior partial is invalid; emit U+FFFD
                // for it and restart decode with this byte.
                screen.write("\u{FFFD}")
                utf8Pending.removeAll(keepingCapacity: true)
                appendUTF8(byte)
            }
        }
    }

    /// Decode + write any complete pending UTF-8 sequence. Called before
    /// every control byte so a pending multibyte run can't straddle an
    /// escape.
    private mutating func flushUTF8() {
        guard !utf8Pending.isEmpty else { return }
        let bytes = utf8Pending
        utf8Pending.removeAll(keepingCapacity: true)
        if let str = String(bytes: bytes, encoding: .utf8) {
            for ch in str { screen.write(ch) }
        } else {
            screen.write("\u{FFFD}")
        }
    }

    private mutating func writeScalarByte(_ byte: UInt8) {
        screen.write(Character(UnicodeScalar(byte)))
    }

    // MARK: - Escape state

    private mutating func escapeByte(_ byte: UInt8) {
        switch byte {
        case 0x5B:                       // '[' → CSI
            csiBuffer.removeAll(keepingCapacity: true)
            state = .csi
        case 0x5D:                       // ']' → OSC
            state = .osc
        case 0x4D:                       // ESC M — reverse index (RI)
            screen.scrollDown(1)
            state = .ground
        case 0x37, 0x38:                 // ESC 7 / ESC 8 — save/restore
            // cursor; not modelled. Drop.
            state = .ground
        case 0x28, 0x29, 0x2A, 0x2B:     // ESC ( ) * + — charset select.
            // The NEXT byte is the charset designator (e.g. 'B' = ASCII,
            // '0' = DEC line-drawing). Swallow it via a dedicated state so
            // it never prints as a stray glyph.
            state = .escapeCharset
        default:
            // ESC =, ESC >, ESC c (RIS), and anything else: drop.
            state = .ground
        }
    }

    // MARK: - CSI state

    private mutating func csiByte(_ byte: UInt8) {
        // Final byte is in 0x40...0x7E. Parameter / intermediate bytes
        // (digits, ';', '?', '<', etc.) are 0x20...0x3F.
        if (0x40...0x7E).contains(byte) {
            let final = byte
            let params = csiBuffer
            csiBuffer.removeAll(keepingCapacity: true)
            state = .ground
            dispatchCSI(final: final, raw: params)
        } else {
            if csiBuffer.count < Self.csiMaxLen {
                csiBuffer.append(byte)
            }
            // If it overflows the bound, we keep waiting for a final byte
            // but stop accumulating — a runaway sequence can't blow memory.
        }
    }

    private mutating func dispatchCSI(final: UInt8, raw: [UInt8]) {
        // DEC private sequences start with '?' (0x3F). We ACT on the
        // alternate-screen toggles (1049/1047/47) and parse-and-ignore the
        // rest (cursor show/hide, bracketed paste, mouse modes).
        if raw.first == 0x3F {
            handlePrivateMode(raw: raw, final: final)
            return
        }

        let params = parseParams(raw)
        let ch = Character(UnicodeScalar(final))

        switch ch {
        case "A": screen.cursorUp(param(params, 0, default: 1))
        case "B": screen.cursorDown(param(params, 0, default: 1))
        case "C": screen.cursorForward(param(params, 0, default: 1))
        case "D": screen.cursorBackward(param(params, 0, default: 1))
        case "E":                                   // CNL — next line, col 0
            screen.cursorDown(param(params, 0, default: 1))
            screen.carriageReturn()
        case "F":                                   // CPL — prev line, col 0
            screen.cursorUp(param(params, 0, default: 1))
            screen.carriageReturn()
        case "G":                                   // CHA — absolute column
            screen.moveCursorCol(param(params, 0, default: 1) - 1)
        case "d":                                   // VPA — absolute row
            screen.moveCursorRow(param(params, 0, default: 1) - 1)
        case "H", "f":                              // CUP / HVP — row;col
            let row = param(params, 0, default: 1) - 1
            let col = param(params, 1, default: 1) - 1
            screen.moveCursor(row: row, col: col)
        case "J":                                   // ED — erase display
            switch param(params, 0, default: 0) {
            case 0: screen.eraseScreenFromCursor()
            case 1: screen.eraseScreenToCursor()
            case 2, 3: screen.eraseScreen()
            default: break
            }
        case "K":                                   // EL — erase line
            switch param(params, 0, default: 0) {
            case 0: screen.eraseLineFromCursor()
            case 1: screen.eraseLineToCursor()
            case 2: screen.eraseLine()
            default: break
            }
        case "S": screen.scrollUp(param(params, 0, default: 1))
        case "T": screen.scrollDown(param(params, 0, default: 1))
        // In-line edits (TSK-740) — line editors / full-screen apps mutate the
        // grid in place; previously parse-and-ignored, so deletions lingered.
        // In-line edits (TSK-740) — line editors / full-screen apps mutate the
        // grid in place; previously parse-and-ignored, so deletions lingered.
        case "P": screen.deleteChars(param(params, 0, default: 1))   // DCH
        case "@": screen.insertChars(param(params, 0, default: 1))   // ICH
        case "X": screen.eraseChars(param(params, 0, default: 1))    // ECH
        case "L": screen.insertLines(param(params, 0, default: 1))   // IL
        case "M": screen.deleteLines(param(params, 0, default: 1))   // DL
        case "r":                                   // DECSTBM — scroll region
            // 1-based inclusive in the sequence → 0-based for the screen.
            screen.setScrollRegion(
                top: param(params, 0, default: 1) - 1,
                bottom: param(params, 1, default: screen.rows) - 1)
        case "m": applySGR(params)
        default:
            // Unrecognised final byte (cursor-save/restore/DECSTBM/etc.) —
            // parse-and-ignore so it never garbles the grid.
            break
        }
    }

    /// DEC private modes (`ESC[?…h` set / `ESC[?…l` reset). We act on the
    /// alternate-screen toggles (1049 / 1047 / 47) so full-screen apps
    /// (`top`/`vim`/`less`) render on a throwaway buffer and never churn the
    /// user's scrollback (the `top` "constant scroll" report). Every other
    /// private mode (cursor visibility, bracketed paste, mouse tracking) is
    /// still parse-and-ignored.
    private mutating func handlePrivateMode(raw: [UInt8], final: UInt8) {
        guard final == 0x68 || final == 0x6C else { return }   // 'h' set / 'l' reset
        let enable = (final == 0x68)
        for case let mode? in parseParams(raw) {
            switch mode {
            case 47, 1047, 1049:
                if enable { screen.enterAltScreen() } else { screen.exitAltScreen() }
            default:
                break
            }
        }
    }

    // MARK: - SGR

    private mutating func applySGR(_ params: [Int?]) {
        // `ESC[m` with no params == reset.
        if params.isEmpty {
            screen.pen.reset()
            return
        }
        var i = 0
        while i < params.count {
            let p = params[i] ?? 0
            switch p {
            case 0:  screen.pen.reset()
            case 1:  screen.pen.bold = true
            case 4:  screen.pen.underline = true
            case 7:  screen.pen.inverse = true
            case 22: screen.pen.bold = false
            case 24: screen.pen.underline = false
            case 27: screen.pen.inverse = false
            case 30...37:
                screen.pen.fg = TerminalColor.fromSGR(p, base: 30, bright: false) ?? .default
            case 39:
                screen.pen.fg = .default
            case 40...47:
                screen.pen.bg = TerminalColor.fromSGR(p, base: 40, bright: false) ?? .default
            case 49:
                screen.pen.bg = .default
            case 90...97:
                screen.pen.fg = TerminalColor.fromSGR(p, base: 90, bright: true) ?? .default
            case 100...107:
                screen.pen.bg = TerminalColor.fromSGR(p, base: 100, bright: true) ?? .default
            case 38, 48:
                // Extended colour: `38;5;n` (256-index) or `38;2;r;g;b`
                // (truecolor), and the `48;…` background forms. Consume the
                // param run AND apply the colour. A short/malformed run
                // consumes what it can and leaves the pen unchanged.
                let isForeground = (p == 38)
                if i + 1 < params.count {
                    let mode = params[i + 1] ?? 0
                    if mode == 5, i + 2 < params.count {
                        let raw = max(0, params[i + 2] ?? 0)
                        let color = TerminalColor.indexed(UInt8(clamping: raw))
                        if isForeground { screen.pen.fg = color } else { screen.pen.bg = color }
                        i += 2                       // consume `5;n`
                    } else if mode == 2, i + 4 < params.count {
                        let r = UInt8(clamping: max(0, params[i + 2] ?? 0))
                        let g = UInt8(clamping: max(0, params[i + 3] ?? 0))
                        let b = UInt8(clamping: max(0, params[i + 4] ?? 0))
                        if isForeground { screen.pen.fg = .rgb(r, g, b) } else { screen.pen.bg = .rgb(r, g, b) }
                        i += 4                       // consume `2;r;g;b`
                    } else {
                        i += 1
                    }
                }
            default:
                break                                // ignore (2,3,5,8,9,…)
            }
            i += 1
        }
    }

    // MARK: - OSC state (swallow to terminator)

    private mutating func oscByte(_ byte: UInt8) {
        switch byte {
        case 0x07:                       // BEL terminates OSC
            state = .ground
        case 0x1B:                       // ESC — maybe start of ST (ESC \)
            state = .oscEscape
        default:
            break                        // swallow OSC payload
        }
    }

    // MARK: - Param parsing helpers

    /// Split a CSI parameter byte run on ';' into integer params. An
    /// empty field (e.g. `ESC[;5H`) decodes to `nil` so the caller can
    /// apply its own default. A leading private-marker byte ('?', '>',
    /// '<', '=') is stripped before splitting.
    private func parseParams(_ raw: [UInt8]) -> [Int?] {
        var bytes = raw
        if let first = bytes.first,
           first == 0x3F || first == 0x3E || first == 0x3C || first == 0x3D {
            bytes.removeFirst()
        }
        if bytes.isEmpty { return [] }
        // Drop trailing intermediate bytes (space..'/') that aren't params.
        let paramBytes = bytes.prefix { (0x30...0x3B).contains($0) }
        let str = String(decoding: paramBytes, as: UTF8.self)
        if str.isEmpty { return [] }
        return str.split(separator: ";", omittingEmptySubsequences: false).map {
            $0.isEmpty ? nil : Int($0)
        }
    }

    private func param(_ params: [Int?], _ index: Int, default def: Int) -> Int {
        guard params.indices.contains(index), let v = params[index], v != 0 else {
            // VT semantics: an omitted OR zero positional param means the
            // default for cursor moves (a `0` count behaves as `1`).
            return def
        }
        return v
    }
}
