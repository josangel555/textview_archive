import Foundation

/// Parsed form of the `ui-type` / `ui-key` script verbs — the harness's
/// REAL-keydown interaction layer (TSK-818), the keyboard sibling of
/// `UIClickSpec`. It force-multiplies VM validation of the whole CM6/AppKit
/// key-routing bug tail (894/896/921/730/728): a test can post genuine
/// `keyDown`/`keyUp` (and modifier chords) into the spawned `dist/TextView.app`'s
/// focused field and then assert the document model received the input.
///
/// Two grammars, both producing the same `UIKeySpec` (an ordered list of
/// `KeyStroke`s — one physical key press, with its modifier set):
///
///     ui-type <literal text>          → one KeyStroke per character
///     ui-key  <chord> [<chord> ...]   → one KeyStroke per chord token
///
/// A *chord* token is `mod+mod+key` (e.g. `cmd+c`, `shift+a`, `cmd+shift+z`)
/// or a bare named/printable key (`enter`, `left`, `tab`, `a`). Modifiers:
/// `cmd`/`command`, `shift`, `ctrl`/`control`, `opt`/`option`/`alt`. The base
/// key is a single printable character OR one of the named special keys
/// (arrows, enter/return, tab, esc, delete/backspace, space, home/end, …).
///
/// ## Why the spec is the host-testable seam
/// Building the `(keyCode, modifiers, characters)` for a char/chord is PURE
/// LOGIC — no window, no event queue, no GUI session — so it is pinned by
/// host XCTest. The ACTUAL event injection (CGEvent / NSEvent posting into a
/// live focused field) needs a real WindowServer + GUI login session, so it
/// runs ONLY in the VM GUI lane (`MDV_VM_GUI_SESSION=1`), exactly like the
/// click layer's `events()` (host) vs `click()`-delivery (VM) split.
///
/// Strict grammar: any unknown modifier or unrecognised named key fails the
/// parse (returns `nil`) rather than silently degrading — a test that "types"
/// the wrong thing is the false green we kill.
public struct UIKeySpec: Equatable, Sendable {

    /// The modifier keys held during a keystroke. Maps 1:1 to the
    /// AppKit/CoreGraphics flag families; the synth layer translates.
    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift   = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let option  = Modifiers(rawValue: 1 << 3)
    }

    /// One physical key press: a hardware-independent macOS virtual keycode
    /// (`kVK_*` from HIToolbox), the modifier set held with it, and the
    /// `characters` string AppKit would report (`""` for a pure navigation /
    /// command key, the unmodified glyph otherwise — uppercasing for a
    /// shifted letter is left to the synth layer / live field, matching how a
    /// real keyboard reports `charactersIgnoringModifiers`).
    public struct KeyStroke: Equatable, Sendable {
        public let keyCode: UInt16
        public let modifiers: Modifiers
        /// The base glyph this stroke produces with no modifiers applied
        /// (lowercase letter, digit, symbol), or `nil` for a named special
        /// key that has no inherent printable character (arrows, enter, …).
        public let baseCharacter: String?

        public init(keyCode: UInt16, modifiers: Modifiers, baseCharacter: String?) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.baseCharacter = baseCharacter
        }
    }

    public let strokes: [KeyStroke]

    public init(strokes: [KeyStroke]) { self.strokes = strokes }

    // MARK: - Parsing

    /// Parse `ui-type` / `ui-key` into an ordered stroke list, or `nil` on a
    /// malformed grammar.
    ///
    /// - `ui-type`: every character of `arg` (raw, spaces included) becomes
    ///   one stroke via `stroke(forCharacter:)`. An uppercase letter / shifted
    ///   symbol carries the `.shift` modifier automatically.
    /// - `ui-key`: `arg` is split on whitespace into chord tokens, each parsed
    ///   by `stroke(forChord:)`.
    public static func parse(verb: String, arg: String) -> UIKeySpec? {
        switch verb {
        case "ui-type":
            guard !arg.isEmpty else { return nil }
            var strokes: [KeyStroke] = []
            for ch in arg {
                guard let s = stroke(forCharacter: ch) else { return nil }
                strokes.append(s)
            }
            return UIKeySpec(strokes: strokes)
        case "ui-key":
            let tokens = arg.split(whereSeparator: { $0 == " " }).map(String.init)
            guard !tokens.isEmpty else { return nil }
            var strokes: [KeyStroke] = []
            for token in tokens {
                guard let s = stroke(forChord: token) else { return nil }
                strokes.append(s)
            }
            return UIKeySpec(strokes: strokes)
        default:
            return nil
        }
    }

    /// One literal character → one stroke. Uppercase letters and the shifted
    /// symbols carry `.shift`; the keycode is always the UNSHIFTED key (a
    /// real keyboard presses ⇧ + the base key).
    public static func stroke(forCharacter ch: Character) -> KeyStroke? {
        // Shifted symbol? Map to its base key + .shift.
        if let (base, code) = unshiftedKeyCode(for: ch) {
            let needsShift = (ch != base.first.map(Character.init))
            return KeyStroke(
                keyCode: code,
                modifiers: needsShift ? .shift : [],
                baseCharacter: base)
        }
        // Uppercase letter → base lowercase key + .shift.
        if ch.isLetter {
            let lower = Character(ch.lowercased())
            guard let code = letterKeyCode[lower] else { return nil }
            let isUpper = (ch != lower)
            return KeyStroke(
                keyCode: code,
                modifiers: isUpper ? .shift : [],
                baseCharacter: String(lower))
        }
        return nil
    }

    /// One chord token (`cmd+shift+z`, `left`, `a`) → one stroke.
    public static func stroke(forChord token: String) -> KeyStroke? {
        guard !token.isEmpty else { return nil }
        // A bare "+" (the plus key) must not be split as an empty-mod chord.
        if token == "+" { return stroke(forCharacter: "+") }

        let parts = token.split(separator: "+", omittingEmptySubsequences: false)
            .map(String.init)
        // Everything before the last part is a modifier; the last is the key.
        // (A trailing "cmd+" — empty final key — is malformed.)
        guard let keyToken = parts.last, !keyToken.isEmpty else { return nil }
        var mods: Modifiers = []
        for modToken in parts.dropLast() {
            guard let m = modifier(for: modToken.lowercased()) else { return nil }
            mods.insert(m)
        }
        // Resolve the base key: a named special key first, else a single
        // printable character.
        if let code = namedKeyCode[keyToken.lowercased()] {
            return KeyStroke(keyCode: code, modifiers: mods, baseCharacter: nil)
        }
        guard keyToken.count == 1, let ch = keyToken.first else { return nil }
        guard let base = stroke(forCharacter: ch) else { return nil }
        // Merge any explicit chord modifiers with the character's own (a
        // shifted symbol keeps its implicit .shift, e.g. `cmd+?`).
        return KeyStroke(
            keyCode: base.keyCode,
            modifiers: mods.union(base.modifiers),
            baseCharacter: base.baseCharacter)
    }

    private static func modifier(for token: String) -> Modifiers? {
        switch token {
        case "cmd", "command":         return .command
        case "shift":                  return .shift
        case "ctrl", "control":        return .control
        case "opt", "option", "alt":   return .option
        default:                       return nil
        }
    }

    // MARK: - Virtual keycode tables (kVK_*, HIToolbox/Events.h)
    //
    // Hardware-independent macOS virtual keycodes for the ANSI US layout.
    // Hardcoded (not imported from Carbon) to keep ViewerCore framework-light
    // and the table host-testable in isolation. These are the SAME constants
    // `CGEvent(keyboardEventSource:virtualKey:keyDown:)` and `NSEvent.keyCode`
    // use, so the synth layer feeds them through unchanged.

    private static let letterKeyCode: [Character: UInt16] = [
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03,
        "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25,
        "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23, "q": 0x0C, "r": 0x0F,
        "s": 0x01, "t": 0x11, "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
        "y": 0x10, "z": 0x06,
    ]

    /// Maps a printable character (digit, symbol, or its shifted variant) to
    /// `(baseGlyph, keyCode)`. The shifted variants share the base key's
    /// code; `stroke(forCharacter:)` derives the `.shift` from glyph identity.
    private static func unshiftedKeyCode(for ch: Character) -> (base: String, code: UInt16)? {
        switch ch {
        // Digits row (unshifted)
        case "1": return ("1", 0x12)
        case "2": return ("2", 0x13)
        case "3": return ("3", 0x14)
        case "4": return ("4", 0x15)
        case "5": return ("5", 0x17)
        case "6": return ("6", 0x16)
        case "7": return ("7", 0x1A)
        case "8": return ("8", 0x1C)
        case "9": return ("9", 0x19)
        case "0": return ("0", 0x1D)
        // Digits row (shifted symbols)
        case "!": return ("1", 0x12)
        case "@": return ("2", 0x13)
        case "#": return ("3", 0x14)
        case "$": return ("4", 0x15)
        case "%": return ("5", 0x17)
        case "^": return ("6", 0x16)
        case "&": return ("7", 0x1A)
        case "*": return ("8", 0x1C)
        case "(": return ("9", 0x19)
        case ")": return ("0", 0x1D)
        // Punctuation
        case " ":  return (" ", 0x31)   // space
        case "-":  return ("-", 0x1B)
        case "_":  return ("-", 0x1B)
        case "=":  return ("=", 0x18)
        case "+":  return ("=", 0x18)
        case "[":  return ("[", 0x21)
        case "{":  return ("[", 0x21)
        case "]":  return ("]", 0x1E)
        case "}":  return ("]", 0x1E)
        case "\\": return ("\\", 0x2A)
        case "|":  return ("\\", 0x2A)
        case ";":  return (";", 0x29)
        case ":":  return (";", 0x29)
        case "'":  return ("'", 0x27)
        case "\"": return ("'", 0x27)
        case ",":  return (",", 0x2B)
        case "<":  return (",", 0x2B)
        case ".":  return (".", 0x2F)
        case ">":  return (".", 0x2F)
        case "/":  return ("/", 0x2C)
        case "?":  return ("/", 0x2C)
        case "`":  return ("`", 0x32)
        case "~":  return ("`", 0x32)
        default:   return nil
        }
    }

    /// Named special keys → keycode. Lowercased lookup; multiple aliases map
    /// to the same physical key (`enter`/`return`, `del`/`delete`/`backspace`).
    private static let namedKeyCode: [String: UInt16] = [
        "return": 0x24, "enter": 0x24,
        "tab": 0x30,
        "space": 0x31,
        "delete": 0x33, "del": 0x33, "backspace": 0x33,
        "esc": 0x35, "escape": 0x35,
        "left": 0x7B, "arrow-left": 0x7B, "arrowleft": 0x7B,
        "right": 0x7C, "arrow-right": 0x7C, "arrowright": 0x7C,
        "down": 0x7D, "arrow-down": 0x7D, "arrowdown": 0x7D,
        "up": 0x7E, "arrow-up": 0x7E, "arrowup": 0x7E,
        "home": 0x73,
        "end": 0x77,
        "pageup": 0x74, "page-up": 0x74,
        "pagedown": 0x79, "page-down": 0x79,
        "forward-delete": 0x75, "fwddelete": 0x75,
    ]
}
