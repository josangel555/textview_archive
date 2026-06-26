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
        /// Commands whose reply was SKIPPED — tmux replied for a LATER command
        /// while these earlier ones were still in flight, so their replies are
        /// lost. Surfaced (in FIFO order) so the wrapper can fail any awaiting
        /// caller rather than strand it forever. (Was silently dropped before
        /// TSK-1018 hardening.)
        public var droppedCommands: [String] = []
        /// Protocol anomalies the core tolerated but a healthy stream never
        /// produces: a `%begin`/`%end` (or `%error`) cmdNum mismatch, an
        /// orphan frame terminator, a re-opened frame, etc. Surfaced so the
        /// wrapper can log/telemetry them instead of the loss being invisible.
        public var anomalies: [Anomaly] = []
        /// True if `%exit` was seen.
        public var didExit = false

        public init() {}
    }

    /// A tolerated-but-noteworthy protocol deviation. The core never crashes or
    /// desyncs on these; it records them so the loss/skew isn't invisible.
    public enum Anomaly: Sendable, Equatable {
        /// A reply frame opened with `%begin <openCmdNum>` but closed with
        /// `%end`/`%error <closeCmdNum>` for a DIFFERENT command — the
        /// accumulated body could not be trusted against the close. `recovered`
        /// carries the body lines that were accumulated for the open frame (so
        /// they aren't merely discarded). `succeeded` mirrors the close kind.
        case replyFrameCmdNumMismatch(openCmdNum: Int, closeCmdNum: Int, body: [String], succeeded: Bool)
        /// A frame terminator (`%end`/`%error <cmdNum>`) arrived with no open
        /// `%begin` frame. Any body intended for it is unknowable.
        case orphanFrameClose(cmdNum: Int, succeeded: Bool)
        /// A `%begin <newCmdNum>` arrived while a frame for `<abandonedCmdNum>`
        /// was still open; the prior frame's accumulated `body` was abandoned.
        case reopenedFrame(abandonedCmdNum: Int, newCmdNum: Int, body: [String])
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
                // Open a new reply frame. The parser only opens a frame after
                // closing the prior one, so a still-open frame here means the
                // batch was hand-built or spanned a parser boundary — abandon
                // the half-open frame but SURFACE it (its body is lost).
                if let stale = openReply {
                    fx.anomalies.append(.reopenedFrame(
                        abandonedCmdNum: stale.cmdNum, newCmdNum: cmdNum, body: stale.lines))
                }
                openReply = (cmdNum: cmdNum, lines: [])

            case let .replyLine(line):
                openReply?.lines.append(line)

            case let .endReply(cmdNum):
                if let reply = resolveReply(cmdNum: cmdNum, succeeded: true, fx: &fx) {
                    fx.replies.append(reply)
                }

            case let .errorReply(cmdNum):
                if let reply = resolveReply(cmdNum: cmdNum, succeeded: false, fx: &fx) {
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
    /// (an unknown command number). Surfaces, via `fx`:
    ///   • `droppedCommands` — earlier in-flight commands skipped by this
    ///     out-of-order resolution (so their callers can be failed, not
    ///     stranded);
    ///   • `.replyFrameCmdNumMismatch` — when `%begin` opened a frame for a
    ///     DIFFERENT command than this close (the accumulated body can't be
    ///     trusted against the close, but is carried in the anomaly rather than
    ///     vanishing);
    ///   • `.orphanFrameClose` — when no `%begin` ever opened a frame for this
    ///     close (a body may have been intended; it's unknowable).
    private mutating func resolveReply(cmdNum: Int, succeeded: Bool, fx: inout Effects) -> Reply? {
        let open = openReply
        defer { openReply = nil }

        // Correlate against the FIFO; capture any commands skipped ahead of it.
        let resolution = commandQueue.resolveReporting(cmdNum)
        fx.droppedCommands.append(contentsOf: resolution.dropped)
        guard let command = resolution.matched else {
            // Number isn't in flight — a spurious / already-popped reply. Still
            // surface a mismatched open frame so its body isn't silently lost.
            if let open, open.cmdNum != cmdNum {
                fx.anomalies.append(.replyFrameCmdNumMismatch(
                    openCmdNum: open.cmdNum, closeCmdNum: cmdNum,
                    body: open.lines, succeeded: succeeded))
            }
            return nil
        }

        // The lines belong to this reply ONLY when the open frame's cmdNum
        // matches the close. A mismatch (or no open frame) is surfaced so the
        // accumulated body — and the skew — isn't invisible.
        if let open, open.cmdNum == cmdNum {
            return Reply(command: command, lines: open.lines, succeeded: succeeded)
        }
        if let open {
            // Frame opened for a different command than it closed for.
            fx.anomalies.append(.replyFrameCmdNumMismatch(
                openCmdNum: open.cmdNum, closeCmdNum: cmdNum,
                body: open.lines, succeeded: succeeded))
        } else {
            // No %begin ever opened this frame.
            fx.anomalies.append(.orphanFrameClose(cmdNum: cmdNum, succeeded: succeeded))
        }
        return Reply(command: command, lines: [], succeeded: succeeded)
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
    ///
    /// NOTE: this convenience drops the SKIPPED earlier entries SILENTLY. When a
    /// caller needs to fail those abandoned commands (the common case — a
    /// `list-panes` whose reply was lost ahead of a later command's reply),
    /// use `resolveReporting(_:)` which returns the dropped tags too.
    @discardableResult
    public mutating func resolve(_ number: Int) -> Tag? {
        resolveReporting(number).matched
    }

    /// Like `resolve(_:)` but ALSO returns the tags of any earlier in-flight
    /// commands that were skipped (abandoned) by this out-of-order resolution,
    /// in FIFO order — so the caller can fail their awaiting callers rather than
    /// stranding them forever. `matched` is the tag for `number` (or `nil` if it
    /// wasn't in flight); `dropped` is the earlier entries popped ahead of it
    /// (empty when `number` was the head of the queue or wasn't found).
    public mutating func resolveReporting(_ number: Int) -> (matched: Tag?, dropped: [Tag]) {
        guard let idx = pending.firstIndex(where: { $0.number == number }) else {
            return (nil, [])
        }
        let dropped = pending[0..<idx].map { $0.tag }
        let tag = pending[idx].tag
        pending.removeFirst(idx + 1)
        return (tag, dropped)
    }

    /// Drop all in-flight entries (teardown / detach), returning their tags in
    /// FIFO order so the caller can fail them.
    public mutating func drain() -> [Tag] {
        let tags = pending.map { $0.tag }
        pending.removeAll()
        return tags
    }
}
