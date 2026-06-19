import Foundation

/// A single typed event emitted by `TmuxControlParser` from one line of the
/// tmux **control mode** (`tmux -CC`) protocol stream.
///
/// Reply framing (`%begin`/`%end`/`%error`) is correlated by *command
/// number*; notifications (`%output`, `%window-*`, `%layout-change`, …) are
/// asynchronous. Any `%…` line we don't model becomes `.unknown` so a tmux
/// version we don't fully understand can NEVER desync the stream.
///
/// See `docs/TMUX_CC_DESIGN_2026-06-18.md` §1 for the wire format.
public enum ControlModeEvent: Equatable, Sendable {
    /// `%begin <ts> <cmdNum> <flags>` — start of a synchronous reply frame.
    case beginReply(cmdNum: Int)
    /// A literal output line *inside* a `%begin`…`%end`/`%error` frame.
    case replyLine(String)
    /// `%end <ts> <cmdNum> <flags>` — successful end of a reply frame.
    case endReply(cmdNum: Int)
    /// `%error <ts> <cmdNum> <flags>` — failed end of a reply frame.
    case errorReply(cmdNum: Int)
    /// `%output %<pane> <octal-escaped-bytes>` — pane output. `bytes` is
    /// already UN-escaped (octal `\NNN` / `\\` resolved).
    case output(paneId: Int, bytes: [UInt8])
    /// `%window-add @<win>` — a new tmux window appeared.
    case windowAdd(Int)
    /// `%window-close @<win>` — a tmux window was closed.
    case windowClose(Int)
    /// `%window-renamed @<win> <name>` — a window was retitled.
    case windowRenamed(Int, String)
    /// `%layout-change @<win> <layout> [<visible-layout>] [<flags>]` — the
    /// pane layout of a window changed. `layout` is the first (raw) layout
    /// string; later fields are not modelled here.
    case layoutChange(window: Int, layout: String)
    /// `%session-changed $<sess> <name>` — the attached session changed.
    case sessionChanged(Int, String)
    /// `%client-session-changed <client> $<sess> <name>` — our client's
    /// session changed.
    case clientSessionChanged
    /// `%sessions-changed` — the session list changed (re-`list-sessions`).
    case sessionsChanged
    /// `%pane-mode-changed %<pane>` — a pane entered/left a tmux mode.
    case paneModeChanged(Int)
    /// `%window-pane-changed @<win> %<pane>` — active pane in a window changed.
    case windowPaneChanged(window: Int, pane: Int)
    /// `%exit [<reason>]` — tmux is detaching/exiting; tear down.
    case exit(reason: String?)
    /// Any other `%…` notification — kept typed so the stream never desyncs
    /// on an unmodeled tmux version. `name` excludes the leading `%`.
    case unknown(name: String, args: [String])
}

/// Incremental parser for the tmux control-mode (`tmux -CC`) protocol.
///
/// PURE logic — no I/O, no AppKit. Feed it raw `Data`/`[UInt8]` chunks from
/// the `tmux -CC` PTY via `feed(_:)`; it returns the `[ControlModeEvent]`
/// completed by that chunk. A partial trailing line (no terminating `\n`
/// yet) is BUFFERED across calls — exactly like `ANSIParser` buffers a
/// partial UTF-8 sequence — so arbitrary byte split-points are safe.
///
/// The protocol is line-oriented: tmux terminates every control line with a
/// LF (it CR/LF-pairs, so a trailing `\r` is stripped). Crucially, `%output`
/// payload bytes that are control/non-printable are *octal-escaped*
/// (`\NNN`), so a real `\n` (0x0A) byte never appears mid-line — splitting
/// the stream on raw `\n` is therefore lossless even for binary pane output.
public struct TmuxControlParser: Sendable {
    /// Bytes of a line seen so far with no terminating `\n` yet.
    private var pending: [UInt8] = []

    /// True while we are between a `%begin` and its `%end`/`%error`; lines in
    /// this window are reply output, not notifications.
    private var inReplyFrame = false

    public init() {}

    // MARK: - Feed

    /// Feed a raw chunk; returns the events completed by it. A partial
    /// trailing line is retained for the next call.
    public mutating func feed(_ data: [UInt8]) -> [ControlModeEvent] {
        var events: [ControlModeEvent] = []
        for byte in data {
            if byte == 0x0A {                       // LF terminates a line
                var line = pending
                pending.removeAll(keepingCapacity: true)
                if line.last == 0x0D { line.removeLast() }   // strip CR of CR/LF
                if let event = parseLine(line) {
                    events.append(event)
                }
            } else {
                pending.append(byte)
            }
        }
        return events
    }

    public mutating func feed(_ data: Data) -> [ControlModeEvent] {
        feed([UInt8](data))
    }

    // MARK: - Line parsing

    /// Parse one complete (LF-stripped) line into an event, or `nil` if the
    /// line produces none (e.g. an empty reply line we choose to keep would
    /// still emit `.replyLine("")`, so `nil` is rare — only a truly empty
    /// out-of-frame line).
    private mutating func parseLine(_ line: [UInt8]) -> ControlModeEvent? {
        // Inside a reply frame, every line is literal command output UNTIL we
        // see the closing %end/%error. %begin/%end/%error are the only control
        // lines that bookend a frame.
        if inReplyFrame {
            if line.first == 0x25 {                 // '%' — possible frame end
                let (name, args) = splitNotification(line)
                if name == "end" {
                    inReplyFrame = false
                    return .endReply(cmdNum: cmdNum(from: args))
                }
                if name == "error" {
                    inReplyFrame = false
                    return .errorReply(cmdNum: cmdNum(from: args))
                }
                // A %-prefixed line that is NOT the frame terminator is still
                // literal reply output (tmux never nests notifications inside a
                // reply frame; e.g. `list-keys` rows can begin with '%').
            }
            return .replyLine(decodeUTF8(line))
        }

        // Not in a frame. Only `%…` lines are control protocol; anything else
        // is ignored (the protocol emits nothing outside %-lines once attached).
        guard line.first == 0x25 else {             // '%'
            return nil
        }

        let (name, args) = splitNotification(line)
        switch name {
        case "begin":
            inReplyFrame = true
            return .beginReply(cmdNum: cmdNum(from: args))
        case "end":
            // %end with no matching %begin — treat defensively as a frame end.
            return .endReply(cmdNum: cmdNum(from: args))
        case "error":
            return .errorReply(cmdNum: cmdNum(from: args))

        case "output":
            return parseOutput(line)

        case "window-add":
            guard let win = sigilInt(args.first) else { return .unknown(name: name, args: args) }
            return .windowAdd(win)
        case "window-close", "unlinked-window-close":
            guard let win = sigilInt(args.first) else { return .unknown(name: name, args: args) }
            return .windowClose(win)
        case "window-renamed", "unlinked-window-renamed":
            guard args.count >= 2, let win = sigilInt(args[0]) else {
                return .unknown(name: name, args: args)
            }
            return .windowRenamed(win, args[1...].joined(separator: " "))
        case "layout-change":
            guard args.count >= 2, let win = sigilInt(args[0]) else {
                return .unknown(name: name, args: args)
            }
            return .layoutChange(window: win, layout: args[1])
        case "session-changed":
            guard args.count >= 2, let sess = sigilInt(args[0]) else {
                return .unknown(name: name, args: args)
            }
            return .sessionChanged(sess, args[1...].joined(separator: " "))
        case "client-session-changed":
            return .clientSessionChanged
        case "sessions-changed":
            return .sessionsChanged
        case "pane-mode-changed":
            guard let pane = sigilInt(args.first) else { return .unknown(name: name, args: args) }
            return .paneModeChanged(pane)
        case "window-pane-changed":
            guard args.count >= 2, let win = sigilInt(args[0]), let pane = sigilInt(args[1]) else {
                return .unknown(name: name, args: args)
            }
            return .windowPaneChanged(window: win, pane: pane)
        case "exit":
            return .exit(reason: args.isEmpty ? nil : args.joined(separator: " "))

        default:
            return .unknown(name: name, args: args)
        }
    }

    /// `%output %<pane> <octal-escaped-bytes>` — the payload is the REMAINDER
    /// of the line after the pane token, kept as raw bytes (it may contain any
    /// byte once unescaped) and octal-unescaped here. Parsing the payload from
    /// the raw byte line (not a re-encoded String) avoids any lossy UTF-8
    /// round-trip of binary pane output.
    private func parseOutput(_ line: [UInt8]) -> ControlModeEvent {
        // line == "%output %<pane> <payload>"; split off the first two
        // space-delimited tokens, the rest (verbatim) is the payload.
        // tok0 = "%output", tok1 = "%<pane>", payload = bytes after the 2nd space.
        var i = 0
        let n = line.count
        // skip "%output"
        while i < n && line[i] != 0x20 { i += 1 }   // to first space
        guard i < n else { return .unknown(name: "output", args: []) }
        i += 1                                       // past first space
        let paneStart = i
        while i < n && line[i] != 0x20 { i += 1 }    // to second space
        let paneToken = Array(line[paneStart..<i])
        guard let pane = sigilInt(decodeASCII(paneToken)) else {
            return .unknown(name: "output", args: [decodeUTF8(paneToken)])
        }
        // payload is everything after the second space (which may be empty).
        let payloadStart = (i < n) ? i + 1 : n
        let payload = Array(line[payloadStart..<n])
        return .output(paneId: pane, bytes: Self.unescapeOctal(payload))
    }

    // MARK: - Octal unescape (the single most test-critical transform)

    /// Resolve tmux's `%output` escaping back to raw bytes:
    ///   • `\NNN` (backslash + EXACTLY three octal digits 0–7) → that byte.
    ///   • `\\` → a single backslash byte.
    ///   • every other byte → itself, verbatim.
    /// A trailing/malformed escape (`\` at end, or `\` not followed by three
    /// octal digits or another `\`) is emitted literally so we never drop
    /// data. PURE + static so it can be unit-tested in isolation.
    public static func unescapeOctal(_ escaped: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(escaped.count)
        var i = 0
        let n = escaped.count
        while i < n {
            let b = escaped[i]
            if b != 0x5C {                           // not '\' → literal
                out.append(b)
                i += 1
                continue
            }
            // b == '\'
            if i + 1 < n && escaped[i + 1] == 0x5C { // "\\" → '\'
                out.append(0x5C)
                i += 2
                continue
            }
            // "\NNN" — need exactly three octal digits.
            if i + 3 < n,
               let d0 = octalDigit(escaped[i + 1]),
               let d1 = octalDigit(escaped[i + 2]),
               let d2 = octalDigit(escaped[i + 3]) {
                let value = d0 * 64 + d1 * 8 + d2     // 0..511; clamp to a byte
                out.append(UInt8(value & 0xFF))
                i += 4
                continue
            }
            // Malformed escape — emit the backslash literally and continue.
            out.append(0x5C)
            i += 1
        }
        return out
    }

    /// Value 0–7 of an ASCII octal digit byte, or nil.
    private static func octalDigit(_ b: UInt8) -> Int? {
        (0x30...0x37).contains(b) ? Int(b - 0x30) : nil
    }

    // MARK: - Helpers

    /// Split a `%name arg arg …` line into the bare name (no `%`) and its
    /// space-separated args. The payload of `%output` is handled separately
    /// (it must NOT be space-tokenised), so this is for the framing/notif
    /// lines whose args are whitespace-delimited tokens.
    private func splitNotification(_ line: [UInt8]) -> (name: String, args: [String]) {
        let str = decodeUTF8(line)
        // Drop the leading '%'.
        let body = str.hasPrefix("%") ? String(str.dropFirst()) : str
        let tokens = body.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = tokens.first else { return ("", []) }
        return (first, Array(tokens.dropFirst()))
    }

    /// Strip a tmux sigil (`%` pane, `@` window, `$` session) and parse the
    /// remaining digits to an Int. `%3` → 3, `@7` → 7, `$1` → 1, `5` → 5.
    private func sigilInt(_ token: String?) -> Int? {
        guard var t = token, !t.isEmpty else { return nil }
        if let first = t.first, first == "%" || first == "@" || first == "$" {
            t = String(t.dropFirst())
        }
        return Int(t)
    }

    /// command-number is the SECOND token of `%begin <ts> <cmdNum> <flags>`.
    private func cmdNum(from args: [String]) -> Int {
        // args == [<ts>, <cmdNum>, <flags>?]; the command number is args[1].
        guard args.count >= 2, let n = Int(args[1]) else { return -1 }
        return n
    }

    private func decodeUTF8(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    private func decodeASCII(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
