import Foundation

/// Translates logical key presses into the byte sequences a Unix shell /
/// PTY expects. PURE logic (no AppKit `NSEvent`): the view extracts the
/// primitives (`keyCode`-equivalent special key + the typed characters +
/// modifier flags) and calls in here, so the mapping is host-testable.
///
/// SCOPE: the common interactive-shell keys — Return, Backspace, Tab,
/// Escape, the four arrows, Home/End/PageUp/PageDown/Delete-forward, and
/// Ctrl-letter chords (Ctrl-C/D/Z/L/A/E/U/K/W and friends). Function keys
/// and the full xterm modifier-encoding matrix are out of scope for v1.
public enum TerminalKeyEncoder {
    /// A special (non-text) key the view can recognise without depending
    /// on a literal character.
    public enum SpecialKey: Sendable, Equatable {
        case enter
        case backspace
        case tab
        case escape
        case up, down, right, left
        case home, end, pageUp, pageDown
        case deleteForward
    }

    /// Bytes for a special key. Arrows/Home/End emit the "application
    /// cursor keys OFF" (normal) CSI forms — the safe default most shells
    /// expect at the prompt.
    public static func bytes(for key: SpecialKey) -> [UInt8] {
        switch key {
        case .enter:        return [0x0D]                       // CR
        case .backspace:    return [0x7F]                       // DEL (zsh/bash expect 0x7F)
        case .tab:          return [0x09]
        case .escape:       return [0x1B]
        case .up:           return csi("A")
        case .down:         return csi("B")
        case .right:        return csi("C")
        case .left:         return csi("D")
        case .home:         return csi("H")
        case .end:          return csi("F")
        case .pageUp:       return [0x1B, 0x5B, 0x35, 0x7E]     // ESC[5~
        case .pageDown:     return [0x1B, 0x5B, 0x36, 0x7E]     // ESC[6~
        case .deleteForward:return [0x1B, 0x5B, 0x33, 0x7E]     // ESC[3~
        }
    }

    /// Bytes for typed text under modifier flags. `control` maps an ASCII
    /// letter (or a small set of symbols) to its C0 control code (Ctrl-A →
    /// 0x01, … Ctrl-Z → 0x1A, Ctrl-[ → ESC, Ctrl-\ → 0x1C, etc.).
    /// `option` (Meta/Alt) prefixes each byte with ESC (the common
    /// "Esc-prefixed Meta" convention). With no modifiers the raw UTF-8
    /// of the text is returned.
    public static func bytes(
        forText text: String,
        control: Bool,
        option: Bool
    ) -> [UInt8] {
        if control {
            if let ctrl = controlCode(for: text) {
                return [ctrl]
            }
            // Unknown control chord — emit nothing rather than a stray char.
            return []
        }
        var out = Array(text.utf8)
        if option {
            // Esc-prefix every byte (Meta). For a single-char press this
            // is the canonical Alt-<key> form.
            out = out.flatMap { [0x1B, $0] }
        }
        return out
    }

    // MARK: - Helpers

    private static func csi(_ final: Character) -> [UInt8] {
        [0x1B, 0x5B, final.asciiValue ?? 0]
    }

    /// Map a single typed character to its Ctrl- control code, or nil if
    /// there's no standard mapping.
    static func controlCode(for text: String) -> UInt8? {
        guard let scalar = text.unicodeScalars.first,
              text.unicodeScalars.count == 1 else { return nil }
        let v = scalar.value
        // Ctrl-A..Ctrl-Z (case-insensitive) → 0x01..0x1A
        if let a = scalar.properties.lowercaseMapping.unicodeScalars.first?.value,
           (97...122).contains(a) {
            return UInt8(a - 96)
        }
        // Direct symbol chords.
        switch v {
        case 0x40: return 0x00           // Ctrl-@ → NUL
        case 0x5B: return 0x1B           // Ctrl-[ → ESC
        case 0x5C: return 0x1C           // Ctrl-\ → FS
        case 0x5D: return 0x1D           // Ctrl-] → GS
        case 0x5E: return 0x1E           // Ctrl-^ → RS
        case 0x5F: return 0x1F           // Ctrl-_ → US
        case 0x20: return 0x00           // Ctrl-Space → NUL
        default:   return nil
        }
    }
}
