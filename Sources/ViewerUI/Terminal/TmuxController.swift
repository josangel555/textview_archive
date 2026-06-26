import Foundation
import Combine
import ViewerCore

/// Slice (d) of the tmux `-CC` integration (epic TSK-964 / TSK-1023): the
/// OBSERVABLE bridge that drives the pure `TmuxControllerCore` from a byte
/// stream and republishes for SwiftUI. See `docs/TMUX_CC_DESIGN_2026-06-18.md`
/// §3 — one `tmux -CC` PTY fans out to N `TerminalScreen`s keyed by pane id.
///
/// This file is the **host-testable pump + outbound encoder**. The live
/// `tmux -CC` PTY spawn (`start`/`stop` below) and the SwiftUI nested-split
/// render (slice e, `TerminalSplitView`) are the VM-tail: the spawn touches a
/// live PTY and the render touches AppKit, so they self-skip on host and
/// validate on the UTM VM (T4/T5) per the testing rules. The `ingest(_:)` pump
/// — the correctness-bearing part — is fully host-tested (feed canned
/// control-mode bytes, assert the published topology / pane screen; no PTY).
@MainActor
public final class TmuxController: ObservableObject {

    /// Bumped whenever one or more panes' screens changed (`%output`). The view
    /// re-reads `screen(forPane:)` for the visible panes. Separate from
    /// `topologyVersion` so a pure output burst doesn't churn the tab/split tree.
    @Published public private(set) var outputVersion: Int = 0

    /// Bumped when the window/pane topology (tabs ↔ windows, splits ↔ pane tree)
    /// or session metadata changed. The view rebuilds the tab strip / split tree.
    @Published public private(set) var topologyVersion: Int = 0

    /// Set once tmux reported `%exit` — the control session has ended.
    @Published public private(set) var didExit: Bool = false

    private var core: TmuxControllerCore
    private var parser = TmuxControlParser()

    public init(rows: Int = 24, cols: Int = 80) {
        self.core = TmuxControllerCore(rows: rows, cols: cols)
    }

    /// The current session topology (windows ↔ tabs, pane tree ↔ splits). The
    /// view reads this on a `topologyVersion` change.
    public var session: TmuxSession { core.session }

    /// The latest ANSI screen snapshot for a pane (nil until it has received
    /// `%output`). The view reads this per visible pane on an `outputVersion`
    /// change.
    public func screen(forPane pane: TmuxPaneID) -> TerminalScreen? {
        core.screen(forPane: pane)
    }

    /// THE PUMP (host-testable). Feed a chunk of raw `tmux -CC` stdout bytes →
    /// parse (incremental, buffers partial lines across chunks) → apply to the
    /// core → republish on the two channels. The live path calls this from
    /// `PTYProcess.onOutput` (hopping to the main actor); tests call it directly
    /// with canned control-mode bytes — no PTY needed.
    @discardableResult
    public func ingest(_ data: Data) -> TmuxControllerCore.Effects {
        let events = parser.feed(data)
        let fx = core.ingest(events)
        if !fx.updatedPanes.isEmpty { outputVersion &+= 1 }
        if fx.topologyChanged {
            _ = core.reapClosedPanes()   // closed-window panes don't leak parsers
            topologyVersion &+= 1
        }
        if fx.didExit { didExit = true }
        return fx
    }

    /// Encode an outbound tmux command for the stdin writer + correlate its
    /// reply (FIFO). Takes a raw command string today (e.g.
    /// `"split-window -h -t %1"`); TSK-964's typed `TmuxCommand` serializer
    /// (in flight) will render these strings with correct targeting + escaping.
    public func encode(command: String) -> Data {
        core.encodeCommand(command)
    }

    // MARK: - Live spawn (VM-tail — slice d, validated on the UTM VM)
    //
    // The live integration spawns ONE `tmux -CC` via PTYProcess
    // (`TmuxControllerCore.controlModeArgv` / `locateTmux`), wires
    // `PTYProcess.onOutput` → (MainActor) `ingest(_:)`, and writes
    // `core.drainCommands()` to the PTY with write(2). It touches a live PTY,
    // so it is added + validated in the VM lane (TSK-1023), not here. The pump
    // above is the seam it drives; keeping it host-tested means a protocol or
    // demux regression fails the host gate even though the spawn is VM-only.
}
