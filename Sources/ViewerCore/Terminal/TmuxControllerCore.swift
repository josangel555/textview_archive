import Foundation

/// The PURE host-logic core of the tmux control-mode (`tmux -CC`) controller
/// (TSK-1018, re-landed from the dropped wave slice 45946cdd and reconciled
/// onto the canonical landed model — `TmuxSession` / `TerminalPaneTree` /
/// `TmuxControlParser` / `ANSIParser`).
///
/// `TmuxControllerCore` is everything the live controller does EXCEPT the
/// injected edges (PTY spawn + SwiftUI render). It:
///
///   • ingests decoded `ControlModeEvent`s (NOT a live PTY),
///   • drives the `TmuxSession` window/pane topology,
///   • DEMUXES `%output` bytes into per-pane `ANSIParser`s it allocates
///     lazily (reusing the EXISTING terminal model — one `ANSIParser` ⇒
///     `TerminalScreen` snapshot per pane, keyed by `TmuxPaneID`),
///   • correlates `%begin … %end/%error <cmdNum>` reply frames back to the
///     commands we wrote on stdin via a FIFO,
///   • resolves the active-pane INPUT TARGET (delegating to
///     `TerminalPaneTree.keyRoutingTarget` / `TmuxSession`),
///   • and EMITS render-intent (`Effects`: which panes changed, whether
///     topology changed, resolved replies, exit) for a view to consume.
///
/// No PTY, no AppKit, no dispatch — so the demux + correlation + routing
/// seams are host-testable by injecting a fake `[ControlModeEvent]` stream
/// (the exact "inject events, assert the right pane parser got the right
/// bytes" pin TSK-1018 calls for).
///
/// THE INJECTED EDGES ARE OUT OF SCOPE (VM-tail, separate follow-up): the
/// `tmux -CC` `Process`/PTY spawn + the stdout pump, and the SwiftUI
/// `TerminalSplitView` render. The live wrapper owns one of these cores
/// behind its off-main parse queue, mirroring `TerminalParserBox`'s snapshot
/// discipline: feed runs on the queue; the view pulls a pane's snapshot under
/// a lock.
public struct TmuxControllerCore: Sendable {
    /// The window/pane topology model (the canonical landed `TmuxSession`).
    public private(set) var session = TmuxSession()

    /// Per-pane ANSI parser, allocated lazily on first `%output`. Keyed by
    /// `TmuxPaneID` (never a bare int — same discipline as the rest of the
    /// model). The view reads `screen(forPane:)` for the snapshot.
    private var paneParsers: [TmuxPaneID: ANSIParser] = [:]

    /// Default grid for a freshly-allocated pane parser (the live wrapper
    /// resizes per-pane once it maps tmux's layout to pixel geometry).
    private let defaultRows: Int
    private let defaultCols: Int

    /// Correlation FIFO. The tag is the command STRING we sent — popped when
    /// the matching reply frame closes, so the FIFO number and the bytes on
    /// the wire can never drift apart. Public read access for tests.
    public private(set) var commandQueue = TmuxCommandQueue<String>()

    /// Buffer accumulating the literal lines of the reply frame currently
    /// open (between `%begin` and its `%end`/`%error`). `nil` when not inside
    /// a frame. The landed `TmuxControlParser` splits a reply into discrete
    /// `.beginReply` / `.replyLine` / `.endReply` / `.errorReply` events; this
    /// core re-assembles them into one correlated reply.
    private var openReply: (cmdNum: Int, lines: [String])?

    public init(rows: Int = 24, cols: Int = 80) {
        self.defaultRows = max(1, rows)
        self.defaultCols = max(1, cols)
    }

    // MARK: - Outbound commands

    /// Record a command being written to tmux's stdin. Returns the wire form
    /// the wrapper should actually `write` (the command + a trailing newline)
    /// — the wrapper never hand-rolls the framing, so the FIFO number and the
    /// bytes on the wire can never drift apart. The assigned command number is
    /// `commandQueue.nextCommandNumber - 1` after this call.
    @discardableResult
    public mutating func encodeCommand(_ command: String) -> Data {
        commandQueue.enqueue(command)
        return Data((command + "\n").utf8)
    }

    /// Drop all in-flight commands (detach/teardown), returning the command
    /// strings in FIFO order so the wrapper can fail any awaiting callers.
    @discardableResult
    public mutating func drainCommands() -> [String] {
        commandQueue.drain()
    }

    // MARK: - Inbound events

    /// What ingesting a batch of events produced, so the wrapper can drive UI
    /// work (bump only panes that changed; rebuild tabs on topology).
    public struct Effects: Sendable, Equatable {
        /// Pane ids whose ANSI screen changed (got `%output`). The wrapper
        /// bumps these (throttled, per visible pane).
        public var updatedPanes: Set<TmuxPaneID> = []
        /// True if the window/pane topology (or session metadata) changed —
        /// the wrapper republishes the tab strip / split layout.
        public var topologyChanged = false
        /// Resolved command replies, in resolution order.
        public var replies: [Reply] = []
        /// True if `%exit` was seen.
        public var didExit = false

        public init() {}
    }

    /// A correlated tmux command reply: the command string we sent, the reply
    /// body lines, and whether tmux closed the frame with `%end` (success) or
    /// `%error` (failure).
    public struct Reply: Sendable, Equatable {
        public let command: String
        public let lines: [String]
        public let succeeded: Bool
        public init(command: String, lines: [String], succeeded: Bool) {
            self.command = command
            self.lines = lines
            self.succeeded = succeeded
        }
    }

    /// Ingest a batch of decoded events. Returns the aggregate effects.
    @discardableResult
    public mutating func ingest(_ events: [ControlModeEvent]) -> Effects {
        var fx = Effects()
        for event in events {
            switch event {
            case let .output(paneId, bytes):
                let id = TmuxPaneID(paneId)
                feedPane(id, bytes: bytes)
                fx.updatedPanes.insert(id)

            case let .beginReply(cmdNum):
                // Open a new reply frame (any half-open one is abandoned — the
                // parser only opens a frame after closing the prior one).
                openReply = (cmdNum: cmdNum, lines: [])

            case let .replyLine(line):
                openReply?.lines.append(line)

            case let .endReply(cmdNum):
                if let reply = resolveReply(cmdNum: cmdNum, succeeded: true) {
                    fx.replies.append(reply)
                }

            case let .errorReply(cmdNum):
                if let reply = resolveReply(cmdNum: cmdNum, succeeded: false) {
                    fx.replies.append(reply)
                }

            case .exit:
                fx.didExit = true
                if session.apply(event) { fx.topologyChanged = true }

            default:
                // Topology / metadata events fold into the session model.
                // `%output` and reply framing are handled above; everything
                // else (`.windowAdd/.windowClose/.windowRenamed/.layoutChange/
                // .windowPaneChanged/.sessionChanged`, and inert notifications)
                // is delegated to `TmuxSession.apply`.
                if session.apply(event) { fx.topologyChanged = true }
            }
        }
        return fx
    }

    /// Close the open reply frame for `cmdNum` and correlate it to the command
    /// we sent. Returns the resolved `Reply`, or `nil` for a spurious frame
    /// (no open frame, a number mismatch, or an unknown command number).
    private mutating func resolveReply(cmdNum: Int, succeeded: Bool) -> Reply? {
        defer { openReply = nil }
        // The lines we accumulated for this frame (if any were opened).
        let lines = (openReply?.cmdNum == cmdNum) ? (openReply?.lines ?? []) : []
        guard let command = commandQueue.resolve(cmdNum) else { return nil }
        return Reply(command: command, lines: lines, succeeded: succeeded)
    }

    // MARK: - Per-pane snapshots (the demux target)

    /// Feed un-escaped pane bytes into that pane's parser (lazily allocated).
    private mutating func feedPane(_ pane: TmuxPaneID, bytes: [UInt8]) {
        if paneParsers[pane] == nil {
            paneParsers[pane] = ANSIParser(rows: defaultRows, cols: defaultCols)
        }
        paneParsers[pane]?.feed(bytes)
    }

    /// The current screen snapshot for a pane, or `nil` if no output has been
    /// routed to it yet. The view reads this once per frame (per the throttle).
    public func screen(forPane pane: TmuxPaneID) -> TerminalScreen? {
        paneParsers[pane]?.screen
    }

    /// Pane ids that have an allocated parser (received output).
    public var activePanes: Set<TmuxPaneID> { Set(paneParsers.keys) }

    /// Resize a pane's grid (the wrapper calls this when tmux's layout maps to
    /// new pixel geometry). No-op for an unknown pane.
    public mutating func resizePane(_ pane: TmuxPaneID, rows: Int, cols: Int) {
        paneParsers[pane]?.resize(rows: max(1, rows), cols: max(1, cols))
    }

    /// Drop a pane's parser (its window/pane closed) to reclaim memory.
    public mutating func dropPane(_ pane: TmuxPaneID) {
        paneParsers[pane] = nil
    }

    /// Reap the parsers of every pane no longer present in the current
    /// session topology (panes whose windows closed). Returns the reaped ids.
    /// The wrapper calls this after a topology change so closed-pane buffers
    /// don't leak. A pane that is still receiving output but not yet in a
    /// window layout is kept (tmux can report `%output` before the layout).
    @discardableResult
    public mutating func reapClosedPanes() -> Set<TmuxPaneID> {
        let live = Set(session.allPaneIDs)
        let toReap = activePanes.subtracting(live)
        for id in toReap { paneParsers[id] = nil }
        return toReap
    }

    // MARK: - Active-pane input target

    /// The pane a keystroke should be delivered to for window `windowId`,
    /// given that window's tmux-reported active pane. Delegates to the
    /// canonical `TerminalPaneTree.keyRoutingTarget` so a closed/stale active
    /// pane never strands input (falls back to the window's first pane). `nil`
    /// when the window is unknown or has no layout yet.
    public func inputTarget(inWindow windowId: Int) -> TmuxPaneID? {
        guard let window = session.window(id: windowId), let layout = window.layout else {
            return nil
        }
        return TerminalPaneTree.keyRoutingTarget(for: layout, requestedActive: window.activePaneID)
    }

    /// The input target for the session's ACTIVE window (the one the tab strip
    /// has selected). `nil` when there is no active window / layout.
    public var activeInputTarget: TmuxPaneID? {
        guard let id = session.activeWindowId else { return nil }
        return inputTarget(inWindow: id)
    }

    // MARK: - tmux discovery + argv (pure, host-testable)

    /// Locate the `tmux` executable. Honours an explicit override (tests / the
    /// wrapper's own discovery), then `PATH`, then common fixed locations.
    /// Returns `nil` when tmux can't be found — the caller takes the graceful-
    /// fallback path (show a message + offer a plain shell). Pure: `fileExists`
    /// + `environment` are injected so it is host-testable without a real tmux.
    public static func locateTmux(
        override: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let override, fileExists(override) { return override }
        if let path = environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = "\(dir)/tmux"
                if fileExists(candidate) { return candidate }
            }
        }
        for candidate in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux",
                          "/opt/local/bin/tmux", "/usr/bin/tmux"] {
            if fileExists(candidate) { return candidate }
        }
        return nil
    }

    /// The argv for spawning a control-mode attach. `sessionName` (when set)
    /// attaches to / creates that named session, so a reattach lands on the
    /// SAME session (detach/reattach persistence). Factored out (not inlined
    /// in a spawn call) so it is host-testable without spawning tmux. The
    /// first element is the executable; the rest are arguments.
    public static func controlModeArgv(tmuxPath: String, sessionName: String? = nil) -> [String] {
        var argv = [tmuxPath, "-CC", "new-session", "-A"]
        if let sessionName, !sessionName.isEmpty {
            argv += ["-s", sessionName]
        }
        return argv
    }
}

// MARK: - Command-number correlation FIFO

/// Correlates the replies tmux sends (`%begin … %end/%error <num>`) back to
/// the commands we wrote on stdin (TSK-1018, restored from 45946cdd). tmux
/// assigns each command a monotonically increasing number and echoes it in
/// the reply markers; we write commands in order, so a FIFO of (number, tag)
/// pairs pops in lock-step with the replies.
///
/// PURE + host-testable: the controller appends a tag when it writes a command
/// (`enqueue`) and pops it when the matching reply lands (`resolve`). Kept
/// separate from `TmuxSession` because it's transport correlation, not
/// topology — the controller core owns both.
public struct TmuxCommandQueue<Tag: Sendable>: Sendable {
    /// One in-flight command: its assigned number + caller tag.
    private struct Pending: Sendable {
        let number: Int
        let tag: Tag
    }
    private var pending: [Pending] = []
    /// The next command number to hand out. tmux numbers commands starting at
    /// 0 for the first command on a control client; we mirror that so a test
    /// can assert correlation without a live tmux.
    private var nextNumber = 0

    public init() {}

    public var inFlightCount: Int { pending.count }
    public var nextCommandNumber: Int { nextNumber }

    /// Register a command being written. Returns the command number tmux will
    /// echo in the reply (monotonic). Append-only FIFO.
    @discardableResult
    public mutating func enqueue(_ tag: Tag) -> Int {
        let number = nextNumber
        nextNumber += 1
        pending.append(Pending(number: number, tag: tag))
        return number
    }

    /// Resolve the reply for command `number`. Pops everything up to AND
    /// including the matched entry (tmux replies strictly in send order, so a
    /// reply for `number` means any earlier still-pending command's reply was
    /// missed — drop them rather than desync). Returns the matched tag, or
    /// `nil` if `number` isn't in flight (a spurious / already-popped reply).
    public mutating func resolve(_ number: Int) -> Tag? {
        guard let idx = pending.firstIndex(where: { $0.number == number }) else {
            return nil
        }
        let tag = pending[idx].tag
        pending.removeFirst(idx + 1)
        return tag
    }

    /// Drop all in-flight entries (teardown / detach), returning their tags in
    /// FIFO order so the caller can fail them.
    public mutating func drain() -> [Tag] {
        let tags = pending.map { $0.tag }
        pending.removeAll()
        return tags
    }
}
