import Foundation

/// Turns the raw terminal INPUT keystroke stream (what the user types, sent to
/// the PTY) into completed command lines, for TSK-1176's command history. A raw
/// PTY is a byte stream with no command boundaries, so this reconstructs them
/// from the input side (the lighter path — no shell-integration / OSC-133 dep):
///
///   • printable chars accumulate into the current line;
///   • Enter (CR/LF) emits the current line (trimmed; empty lines skipped) + resets;
///   • Backspace (DEL / BS) edits the line;
///   • ESC and Tab make the rest of the line UNTRACKABLE from the input side
///     (cursor moves, history-recall, tab-completion all change the line in ways
///     the keystroke stream alone can't follow) — so the whole line is DROPPED
///     until the next Enter;
///   • any other control char (Ctrl-C abort, Ctrl-U clear, …) clears the partial
///     line so a fresh retype on the same prompt is still captured.
///
/// DELIBERATELY CONSERVATIVE: it captures cleanly-typed commands and NEVER records
/// garbage (a half-edited line, an escape-sequence body, a tab-completed fragment).
/// The cost is under-capture of arrow-recalled / tab-completed commands — acceptable
/// for a history feature, and far better than recording wrong/garbled entries.
/// Pure value type → fully host-testable without a PTY.
public struct TerminalInputLineAccumulator {

    private var current = ""
    /// True while dropping the remainder of an untrackable line (after ESC/Tab),
    /// until the next Enter resets us.
    private var dropping = false

    public init() {}

    /// Feed a chunk of user input (one keystroke, or a multi-line paste). Returns
    /// the command lines COMPLETED by this chunk (usually 0 or 1; more for a paste).
    public mutating func feed(_ input: String) -> [String] {
        var completed: [String] = []
        for ch in input.unicodeScalars {
            switch ch {
            case "\r", "\n":
                if !dropping {
                    let cmd = current.trimmingCharacters(in: .whitespaces)
                    if !cmd.isEmpty { completed.append(cmd) }
                }
                current = ""
                dropping = false
            case _ where dropping:
                continue   // swallow the rest of an untrackable line
            case "\u{7f}", "\u{08}":   // DEL / Backspace
                if !current.isEmpty { current.removeLast() }
            case "\u{1b}", "\u{09}":   // ESC (arrows/edit/recall) / Tab (completion)
                current = ""
                dropping = true
            case let c where c.value < 0x20:   // other C0 control (Ctrl-C/U/…): clear the partial
                current = ""
            default:
                current.unicodeScalars.append(ch)
            }
        }
        return completed
    }
}
