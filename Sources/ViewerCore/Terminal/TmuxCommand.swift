import Foundation

/// The typed OUTBOUND half of the `tmux -CC` control-mode signal translation
/// (TSK-964 slice, the missing twin of the inbound `TmuxControlParser`).
///
/// A `TmuxCommand` is a pure, host-testable description of an action the UI
/// wants to perform (open a tab, split a pane, deliver a keystroke, …). Its
/// `controlModeString` renders the EXACT tmux command-line the controller must
/// write — with correct `-t` targeting (window `@N` vs pane `%N`), `-P -F`
/// id-capture, and send-keys / argument escaping — so the on-wire bytes match
/// what tmux expects byte-for-byte.
///
/// Integration: the rendered string is fed straight to
/// `TmuxControllerCore.encodeCommand(_:)` (or the typed convenience
/// `TmuxControllerCore.send(_:)`), which owns the trailing-`\n` framing and the
/// FIFO command-number correlation. The serializer NEVER appends the newline
/// itself and NEVER prefixes `%` — those belong to the transport layer.
///
/// PURE: no AppKit, no I/O, no `Process`. The live PTY pump (slice d) is the
/// consumer that writes the framed `Data` to tmux's stdin — out of scope here.
///
/// ## Escaping model
/// tmux's command-line parser (the same one used on a control-client's stdin)
/// performs, on UNQUOTED text and inside DOUBLE quotes: `$VAR` / `~` expansion,
/// `\e \r \n \t`, `\uXXXX`, and `\ooo` (octal) substitution; it also treats an
/// unquoted `;` as a command-SEPARATOR and an unquoted `#` as a comment. SINGLE
/// quotes suppress ALL of it. So every user-supplied string argument (window
/// name, cwd, pane title, literal send-keys text) is wrapped in single quotes,
/// with an embedded `'` rendered as the canonical `'\''` break-out. This is why
/// the raw byte path for keystrokes uses `send-keys -H <hex>` — arbitrary
/// control bytes need no quoting at all and can never be mis-parsed.
public enum TmuxCommand: Sendable, Equatable {

    // MARK: Window / tab operations

    /// Create a new window (a new tab). `-P -F '#{window_id}'` makes tmux echo
    /// the new `@id` synchronously in the reply body. `detached == true` adds
    /// `-d` so the attached client does NOT switch to it (the UI decides which
    /// tab is active); `detached == false` omits `-d` (also make it current).
    /// `name` → `-n`, `workingDirectory` → `-c` (each single-quoted).
    case newWindow(name: String? = nil, workingDirectory: String? = nil, detached: Bool = true)

    /// Close a tab. tmux replies with `%window-close @<window>`.
    case killWindow(window: TmuxWindowID)

    /// Retitle a tab. The new name is a POSITIONAL trailing arg (single-quoted).
    case renameWindow(window: TmuxWindowID, name: String)

    /// Activate a tab (the attached client's current window).
    case selectWindow(window: TmuxWindowID)

    // MARK: Pane / split operations

    /// Split a pane. `axis` picks `-h` (side-by-side, new pane to the right —
    /// tmux's "horizontal split") or `-v` (stacked, new pane below). `before`
    /// adds `-b` (new pane left/above instead). `full` adds `-f` (span the full
    /// window dimension). `size`, when set, adds `-l` (cols for `-h`, rows for
    /// `-v`; `.percent` appends `%`). `workingDirectory` → `-c`.
    /// `-P -F '#{pane_id}'` echoes the new `%id` in the reply.
    case splitWindow(
        pane: TmuxPaneID,
        axis: SplitAxis,
        size: TmuxPaneSize? = nil,
        before: Bool = false,
        full: Bool = false,
        workingDirectory: String? = nil
    )

    /// Make a pane the active pane within its window (click-to-focus).
    /// `direction`, when set, selects the pane left/right/above/below the target
    /// instead of the target itself (`-L`/`-R`/`-U`/`-D`).
    case selectPane(pane: TmuxPaneID, direction: TmuxDirection? = nil)

    /// Resize a pane (divider drag). Either an absolute target size (`-x`/`-y`)
    /// or a relative nudge (`-U`/`-D`/`-L`/`-R` by an integer amount), per the
    /// `mode`. `zoom == true` adds `-Z` (zoom toggle).
    case resizePane(pane: TmuxPaneID, mode: TmuxResizeMode, zoom: Bool = false)

    /// Close one split. If it was the window's last pane, tmux destroys the
    /// window too (a `%window-close` rather than just a `%layout-change`).
    case killPane(pane: TmuxPaneID)

    // MARK: Keystroke / text delivery

    /// Deliver keystrokes / raw bytes to a pane (the keyboard input path). The
    /// `keys` payload picks the encoding:
    ///   • `.hexBytes` → `send-keys -H` with space-separated two-hex-digit
    ///     tokens — the robust path for arbitrary control bytes (ESC/CR/Ctrl…)
    ///     straight from `TerminalKeyEncoder`; tmux applies NO interpretation.
    ///   • `.literal`  → `send-keys -l '<text>'` — literal UTF-8 text, no
    ///     key-name lookup, single-quoted so `$VAR`/`~`/`\e`/spaces/`;`/`#` are
    ///     all inert.
    ///   • `.named`    → `send-keys <names…>` — each token is a tmux KEY NAME
    ///     (`C-c`, `Enter`, `NPage`, …) for the cases where you WANT the lookup.
    case sendKeys(pane: TmuxPaneID, keys: TmuxKeys)

    /// Paste the named (or top) paste buffer into a pane. `-r` keeps trailing
    /// CRs as-is; `-p` interprets bracketed-paste. Buffer name (when set) is the
    /// trailing positional arg via `-b`.
    case pasteBuffer(pane: TmuxPaneID, buffer: String? = nil, bracketed: Bool = false)

    // MARK: Geometry negotiation

    /// Tell tmux this control client's size so it re-lays-out and answers with
    /// `%layout-change`. `.client(cols,rows)` → `refresh-client -C WxH`;
    /// `.window(@id,cols,rows)` → `refresh-client -C @id:WxH` (per-window, the
    /// tmux 3.x form). Sent on every geometry change (debounced by the caller).
    case refreshClient(size: TmuxClientSize)

    // MARK: Lifecycle

    /// Detach this control client (tear down the controller; tmux keeps running).
    case detachClient

    // MARK: Topology discovery (attach / reattach session restore)

    /// Run on connect to rebuild tabs+splits from tmux (the source of truth).
    /// Output lands as literal lines in the `%begin..%end` reply body.
    case listWindows(window: TmuxWindowID? = nil)
    /// `list-panes -s` (whole session). Reply rows: one pane per line.
    case listPanesInSession
    /// One window's `#{window_visible_layout}` via `display-message -p`.
    case displayLayout(window: TmuxWindowID)
    /// Enumerate sessions.
    case listSessions

    // MARK: - Rendering

    /// The exact tmux command-line for this command — NO leading `%`, NO
    /// trailing newline. Feed straight to `TmuxControllerCore.encodeCommand`.
    public var controlModeString: String {
        switch self {
        case let .newWindow(name, cwd, detached):
            var argv = ["new-window"]
            if detached { argv.append("-d") }
            if let name { argv += ["-n", Self.quote(name)] }
            if let cwd { argv += ["-c", Self.quote(cwd)] }
            argv += ["-P", "-F", "'#{window_id}'"]
            return argv.joined(separator: " ")

        case let .killWindow(window):
            return "kill-window -t \(window.target)"

        case let .renameWindow(window, name):
            return "rename-window -t \(window.target) \(Self.quote(name))"

        case let .selectWindow(window):
            return "select-window -t \(window.target)"

        case let .splitWindow(pane, axis, size, before, full, cwd):
            var argv = ["split-window", axis == .horizontal ? "-h" : "-v"]
            if before { argv.append("-b") }
            if full { argv.append("-f") }
            if let size { argv += ["-l", size.argument] }
            if let cwd { argv += ["-c", Self.quote(cwd)] }
            argv += ["-t", pane.description]
            argv += ["-P", "-F", "'#{pane_id}'"]
            return argv.joined(separator: " ")

        case let .selectPane(pane, direction):
            var argv = ["select-pane"]
            if let direction { argv.append(direction.flag) }
            argv += ["-t", pane.description]
            return argv.joined(separator: " ")

        case let .resizePane(pane, mode, zoom):
            var argv = ["resize-pane"]
            if zoom { argv.append("-Z") }
            argv += ["-t", pane.description]
            argv += mode.arguments
            return argv.joined(separator: " ")

        case let .killPane(pane):
            return "kill-pane -t \(pane.description)"

        case let .sendKeys(pane, keys):
            var argv = ["send-keys"]
            argv += keys.flags
            argv += ["-t", pane.description]
            argv += keys.tokens
            return argv.joined(separator: " ")

        case let .pasteBuffer(pane, buffer, bracketed):
            var argv = ["paste-buffer"]
            if bracketed { argv.append("-p") }
            if let buffer { argv += ["-b", Self.quote(buffer)] }
            argv += ["-t", pane.description]
            return argv.joined(separator: " ")

        case let .refreshClient(size):
            return "refresh-client -C \(size.argument)"

        case .detachClient:
            return "detach-client"

        case let .listWindows(window):
            var s = "list-windows"
            if let window { s += " -t \(window.target)" }
            s += " -F '#{window_id} #{window_name} #{window_active} #{window_layout}'"
            return s

        case .listPanesInSession:
            return "list-panes -s -F '#{window_id} #{pane_id} #{pane_active} #{pane_width}x#{pane_height}'"

        case let .displayLayout(window):
            return "display-message -p -t \(window.target) '#{window_visible_layout}'"

        case .listSessions:
            return "list-sessions -F '#{session_id} #{session_name}'"
        }
    }

    // MARK: - Argument escaping

    /// Single-quote a tmux string argument so NONE of tmux's substitutions
    /// (`$VAR`, `~`, `\e`, `\ooo`, `\uXXXX`), the `;` command-separator, or the
    /// `#` comment marker apply, and embedded spaces stay one argument. An
    /// embedded single quote is rendered with the canonical `'\''` break-out
    /// (close-quote, escaped-quote, re-open-quote) — robust even though tmux's
    /// own lexer would also accept a `\'`, because `'\''` works identically
    /// whether read by tmux or by an `sh -c` shell-command tail.
    public static func quote(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Window id (sigiled so it can't transpose with a pane id)

/// Stable identifier for a tmux window (a tab). Wraps tmux's `@N` window id so
/// callers don't pass a bare `Int` that could silently transpose with a pane
/// `%N` (the exact footgun `TmuxPaneID` was created to prevent). The model
/// stores window ids as bare `Int`; this type sigils them for argv.
public struct TmuxWindowID: Hashable, Comparable, Sendable, CustomStringConvertible {
    /// The numeric part of tmux's `@N` form (e.g. `@3` → 3).
    public let value: Int
    public init(_ value: Int) { self.value = value }
    /// The `@N` wire form (e.g. `@3`).
    public var description: String { "@\(value)" }
    /// The `-t` target token (identical to `description`; named for call-site
    /// clarity at the `-t` argument).
    public var target: String { description }
    public static func < (lhs: TmuxWindowID, rhs: TmuxWindowID) -> Bool {
        lhs.value < rhs.value
    }
}

// MARK: - Keystroke payload

/// How a `send-keys` payload is encoded on the wire.
public enum TmuxKeys: Sendable, Equatable {
    /// Raw bytes (`send-keys -H`) — each byte a two-hex-digit token. The robust
    /// path for arbitrary control bytes from `TerminalKeyEncoder`; tmux applies
    /// NO interpretation, so nothing needs quoting.
    case hexBytes([UInt8])
    /// Literal UTF-8 text (`send-keys -l '<text>'`) — single-quoted, no key-name
    /// lookup, no substitution.
    case literal(String)
    /// tmux key NAMES (`send-keys C-c Enter`) — each token is interpreted by
    /// tmux's key-name table. Names are emitted verbatim (callers pass valid
    /// tmux key names; they contain no shell/tmux specials).
    case named([String])

    var flags: [String] {
        switch self {
        case .hexBytes: return ["-H"]
        case .literal: return ["-l"]
        case .named: return []
        }
    }

    var tokens: [String] {
        switch self {
        case let .hexBytes(bytes):
            return bytes.map { String(format: "%02x", $0) }
        case let .literal(text):
            return [TmuxCommand.quote(text)]
        case let .named(names):
            return names
        }
    }
}

// MARK: - Pane size (for split -l)

/// A `split-window -l` size: an absolute count (cols for `-h`, rows for `-v`)
/// or a percentage of the parent.
public enum TmuxPaneSize: Sendable, Equatable {
    case cells(Int)
    case percent(Int)

    var argument: String {
        switch self {
        case let .cells(n): return "\(n)"
        case let .percent(p): return "\(p)%"
        }
    }
}

// MARK: - Resize mode

/// How a `resize-pane` changes size: an absolute target geometry or a
/// directional nudge.
public enum TmuxResizeMode: Sendable, Equatable {
    /// Absolute `-x <cols> -y <rows>`. Either dimension may be a percentage.
    case absolute(cols: TmuxResizeDimension, rows: TmuxResizeDimension)
    /// Relative nudge: shift one edge by `amount` cells/rows in `direction`.
    case relative(direction: TmuxDirection, amount: Int)

    var arguments: [String] {
        switch self {
        case let .absolute(cols, rows):
            return ["-x", cols.argument, "-y", rows.argument]
        case let .relative(direction, amount):
            return [direction.flag, "\(amount)"]
        }
    }
}

/// One dimension of an absolute resize: integer cells/rows or a percentage of
/// the window.
public enum TmuxResizeDimension: Sendable, Equatable {
    case cells(Int)
    case percent(Int)

    var argument: String {
        switch self {
        case let .cells(n): return "\(n)"
        case let .percent(p): return "\(p)%"
        }
    }
}

// MARK: - Direction

/// A tmux directional flag, used by `select-pane` (which pane to focus) and
/// relative `resize-pane` (which edge to move).
public enum TmuxDirection: Sendable, Equatable {
    case left, right, up, down

    var flag: String {
        switch self {
        case .left: return "-L"
        case .right: return "-R"
        case .up: return "-U"
        case .down: return "-D"
        }
    }
}

// MARK: - Client size (for refresh-client -C)

/// The size argument for `refresh-client -C`: the whole control client
/// (`WxH`) or a single window for this control client (`@id:WxH`, tmux 3.x).
public enum TmuxClientSize: Sendable, Equatable {
    case client(cols: Int, rows: Int)
    case window(TmuxWindowID, cols: Int, rows: Int)

    var argument: String {
        switch self {
        case let .client(cols, rows):
            return "\(cols)x\(rows)"
        case let .window(window, cols, rows):
            return "\(window.description):\(cols)x\(rows)"
        }
    }
}

// MARK: - Typed convenience on the controller core

public extension TmuxControllerCore {
    /// Render a typed `TmuxCommand` and hand its string to `encodeCommand` —
    /// the single chokepoint that owns enqueue + trailing-`\n` framing. Callers
    /// stay typed end-to-end; the raw `encodeCommand(_:)` stays for the
    /// escape-hatch / back-compat path. Returns the framed wire bytes.
    @discardableResult
    mutating func send(_ command: TmuxCommand) -> Data {
        encodeCommand(command.controlModeString)
    }
}
