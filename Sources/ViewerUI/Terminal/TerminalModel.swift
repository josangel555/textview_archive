import Foundation
import Combine
import ViewerCore

/// Off-main owner of the ANSI parser + the latest screen snapshot. ALL
/// parser mutation is confined to `queue` (a serial dispatch queue), so
/// the chatty decode of PTY output never touches the main actor. The
/// snapshot read by the view is guarded by `snapshotLock`.
///
/// This is a `final class` marked `@unchecked Sendable`: every access to
/// `parser` happens on `queue`; `latestSnapshot` is guarded by the lock.
/// Keeping it OUT of `@MainActor` is what lets `TerminalModel` stay a
/// clean `@MainActor ObservableObject` (its `@Published` UI state) while
/// the heavy parse runs in the background — the Swift 6 concurrency split
/// the LESSONS notes demand (don't decode bytes on the main actor).
private final class TerminalParserBox: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.markdownviewer.terminal.parse")
    private var parser: ANSIParser
    private let snapshotLock = NSLock()
    private var latestSnapshot: TerminalScreen

    /// Whether the owning tab is currently the visible/selected one. Read
    /// from the PTY's background queue (nonisolated) to decide whether an
    /// output chunk is worth a main-actor UI bump, so a backgrounded tab's
    /// chatty shell stops churning `Task { @MainActor }` hops that no
    /// mounted view observes. Guarded by its own lock (independent of the
    /// snapshot lock — different access cadence).
    private let foregroundLock = NSLock()
    private var _foreground = true

    init(rows: Int, cols: Int) {
        self.parser = ANSIParser(rows: rows, cols: cols)
        self.latestSnapshot = TerminalScreen(rows: rows, cols: cols)
    }

    var snapshot: TerminalScreen {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        return latestSnapshot
    }

    var isForeground: Bool {
        foregroundLock.lock(); defer { foregroundLock.unlock() }
        return _foreground
    }

    func setForeground(_ on: Bool) {
        foregroundLock.lock(); _foreground = on; foregroundLock.unlock()
    }

    /// Decode a chunk + republish a snapshot. Runs on `queue`.
    func feed(_ data: Data) {
        queue.async { [self] in
            parser.feed(data)
            publishLocked()
        }
    }

    func resize(rows: Int, cols: Int) {
        queue.async { [self] in
            parser.resize(rows: rows, cols: cols)
            publishLocked()
        }
    }

    func reset(rows: Int, cols: Int) {
        queue.async { [self] in
            parser = ANSIParser(rows: rows, cols: cols)
            publishLocked()
        }
    }

    private func publishLocked() {
        let snap = parser.screen
        snapshotLock.lock()
        latestSnapshot = snap
        snapshotLock.unlock()
    }
}

/// Bridges a live `PTYProcess` to the pure `ANSIParser` / `TerminalScreen`
/// model and publishes throttled snapshots for the SwiftUI/AppKit view.
///
/// OBSERVATION + THROTTLE DISCIPLINE (load-bearing — LESSONS "don't
/// republish per output byte"): PTY output arrives on the PTY's
/// background queue and is DECODED off-main in `TerminalParserBox`. We
/// then hop to the main actor and bump `version` AT MOST once per
/// ~16 ms (`coalesceInterval`) — coalescing a burst of reads into a
/// single re-render. The view observes `version` and pulls a fresh
/// `screenSnapshot`. `objectWillChange` therefore fires on a frame clock,
/// not a byte clock.
///
/// This object is observed DIRECTLY by the terminal view — it does NOT
/// forward into `DocumentModel` (same narrow pattern as
/// `PanelLayoutStore` / `FindCoordinator`).
@MainActor
public final class TerminalModel: ObservableObject {
    /// Monotonic frame counter. Bumped (throttled) whenever the screen
    /// buffer changed. The view re-bodies on the change and reads
    /// `screenSnapshot`.
    @Published public private(set) var version: Int = 0

    /// True once the shell has exited (EOF on the PTY).
    @Published public private(set) var hasExited: Bool = false

    /// Current grid dimensions, driven by the view's pixel size.
    public private(set) var rows: Int
    public private(set) var cols: Int

    /// Scrollback viewport offset (lines scrolled up from the live bottom;
    /// 0 == following live output). Held HERE, per tab, not on the NSView —
    /// `TerminalPaneView` re-creates the `TerminalNSView` on every tab
    /// switch (`.id(selectedTabID)`), so a view-local offset would reset to
    /// 0 each switch. Persisting it on the model maintains the user's scroll
    /// position across tab switches (TSK-489). Not `@Published`: it's
    /// view-render state seeded on mount + written back on scroll, not
    /// something the SwiftUI body re-renders on.
    public var scrollOffset: Int = 0

    private let pty = PTYProcess()
    private let box: TerminalParserBox
    /// Leading-edge throttle: first output after an idle gap paints
    /// immediately; subsequent output within a frame is coalesced.
    private var throttle = FrameThrottle()
    private static let coalesceInterval: TimeInterval = 1.0 / 60.0

    public init(rows: Int = 24, cols: Int = 80) {
        let r = max(1, rows)
        let c = max(1, cols)
        self.rows = r
        self.cols = c
        self.box = TerminalParserBox(rows: r, cols: c)
    }

    /// A consistent copy of the current screen for rendering — pulled once
    /// per frame by the view, not per byte.
    public var screenSnapshot: TerminalScreen { box.snapshot }

    // MARK: - Lifecycle

    /// Spawn the shell (idempotent). `workingDirectory` defaults to home.
    public func start(workingDirectory: URL? = nil) {
        guard !pty.isRunning else { return }
        hasExited = false

        let box = self.box
        pty.onOutput = { [weak self] data in
            // Always feed the parser so scrollback/screen stay current even
            // while backgrounded; only schedule a UI bump when this tab is
            // visible — a backgrounded tab has no mounted observer, so the
            // main-actor hop would be pure waste (TSK-459). The flag is read
            // here, BEFORE the Task hop, to actually skip the spawn.
            box.feed(data)
            if box.isForeground { self?.scheduleBump() }
        }
        pty.onExit = { [weak self] _ in
            Task { @MainActor in self?.hasExited = true }
        }
        _ = pty.start(
            rows: UInt16(clamping: rows),
            cols: UInt16(clamping: cols),
            workingDirectory: workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        )
    }

    /// Hang up the shell + tear down. Safe to call repeatedly.
    public func stop() {
        pty.terminate()
    }

    /// Restart after the shell exited (the `[process exited]` view path).
    public func restart(workingDirectory: URL? = nil) {
        pty.terminate()
        box.reset(rows: rows, cols: cols)
        version &+= 1
        // Re-spawn on the next runloop tick so the prior reap settles.
        Task { @MainActor [weak self] in
            self?.start(workingDirectory: workingDirectory)
        }
    }

    // MARK: - Foreground gating (TSK-459)

    /// Whether this tab's shell is the visible/selected one. Mirrors the
    /// thread-safe flag the PTY callback reads to skip UI bumps off-screen.
    public var isForeground: Bool { box.isForeground }

    /// Mark this terminal foreground (visible) or background (a deselected
    /// tab / closed pane). Backgrounded tabs keep their shell + parser
    /// running but stop scheduling UI bumps no view observes. Returning to
    /// foreground forces one bump so the freshly-shown view picks up
    /// everything that accumulated while hidden, and resets the throttle so
    /// the next live output is a clean leading edge.
    public func setForeground(_ on: Bool) {
        guard on != box.isForeground else { return }
        box.setForeground(on)
        if on {
            throttle = FrameThrottle()
            version &+= 1
        }
    }

    // MARK: - Input

    public func sendInput(_ data: Data) { pty.write(data) }
    public func sendString(_ string: String) { pty.writeString(string) }

    // MARK: - Resize

    /// Re-dimension the grid + tell the PTY. No-op when unchanged.
    public func resize(rows newRows: Int, cols newCols: Int) {
        let r = max(1, newRows)
        let c = max(1, newCols)
        guard r != rows || c != cols else { return }
        rows = r
        cols = c
        box.resize(rows: r, cols: c)
        pty.resize(rows: UInt16(clamping: r), cols: UInt16(clamping: c))
        scheduleBump()
    }

    // MARK: - Throttled UI bump

    /// Coalesce UI bumps. LEADING-EDGE: the first bump after an idle gap
    /// fires IMMEDIATELY (no added latency — what makes interactive typing
    /// feel instant), then a `coalesceInterval` cooldown throttles the
    /// burst that follows and a single trailing bump flushes whatever
    /// arrived during the cooldown. The previous purely trailing throttle
    /// delayed EVERY keystroke echo by a full frame even when the terminal
    /// had been idle — the "typing is slow" report. Safe to call from any
    /// context; hops to the main actor.
    private nonisolated func scheduleBump() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.throttle.requestFrame() == .emitNow { self.emitBump() }
        }
    }

    /// Bump `version` now and open a cooldown window; when it closes, flush
    /// one trailing bump if more output landed meanwhile. MainActor-confined.
    private func emitBump() {
        version &+= 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.coalesceInterval * 1_000_000_000))
            guard let self else { return }
            if self.throttle.cooldownElapsed() { self.emitBump() }
        }
    }
}
