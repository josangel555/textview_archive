import Foundation
import os

/// Process-wide performance-signpost facility for the hot path.
///
/// Wraps `OSSignposter` so the open → categorize → load/decode →
/// materialize → highlight → render pipeline can emit Instruments-visible
/// interval and event signposts. This is the native, sampling-friendly
/// alternative to ad-hoc `Date()` timing probes: capture a trace with
/// `xctrace record --instrument 'os_signpost'` (or the Time Profiler +
/// "Points of Interest" lane) and read the named intervals directly —
/// see `docs/PERFORMANCE_PROFILING.md`.
///
/// ## Cost when disabled
/// Gated on the `MDV_SIGNPOSTS=1` environment variable, read ONCE at first
/// touch and cached. When unset (the normal/release case) every API here is
/// a branch-and-return: no `OSSignposter` is constructed, no signpost ID is
/// minted, no string is formatted. `OSSignposter` is itself cheap when no
/// trace is attached, but the env gate guarantees zero overhead (and zero
/// surprise os_signpost spew in Instruments) for users who never asked for
/// profiling.
///
/// ## Why ViewerCore
/// `os.signpost` / `OSSignposter` are Foundation/Darwin, not SwiftUI or
/// AppKit, so this stays inside ViewerCore's "UI-free" boundary. UI-layer
/// call sites (DocumentModel, TextDisplayView) reach it through the same
/// `ViewerCore` import they already use for the loaders and the engine.
///
/// ## Stability of names
/// The `Subsystem`/`Category`/interval-name strings are an Instruments-facing
/// contract — `docs/PERFORMANCE_PROFILING.md` tells a profiler which names to
/// read. Treat renames as a doc-coupled change, not a free refactor.
public enum PerfSignpost {

    /// os_log subsystem all signposts are emitted under. Matches the app's
    /// bundle id so traces filter cleanly in Instruments.
    public static let subsystem = "com.markdownviewer.MarkdownViewer"

    /// Coarse stage of the hot path. Each maps to one `OSLog` category so
    /// Instruments can lane them separately. Raw value is the
    /// Instruments-visible category string (a contract — see doc).
    public enum Stage: String, Sendable, CaseIterable {
        /// `DocumentModel.open` / `openResolved` — the user-facing "open a
        /// file" span, from click to mounted view.
        case open       = "open"
        /// `FileTypeDetector.category` / routing decision.
        case categorize = "categorize"
        /// `DocumentController.open` → loader read + `TextDecoder` decode
        /// (or the binary/native-preview routing that skips the read).
        case load       = "load"
        /// Off-main lazy/large-file materialize (`materializeIfNeeded` /
        /// `openLargeFileOffMain`).
        case materialize = "materialize"
        /// `TreeSitterEngine.tokenize` (+ query compile) — the syntax
        /// highlight pass.
        case highlight  = "highlight"
        /// Final paint: `SourceTextController.apply` (NSTextView attributed
        /// string + layout), `HTMLRenderer`, the CM6 editor bootstrap, the
        /// SQLite/CSV view population.
        case render     = "render"
        /// Scripted navigation interactions (`NavSweep`: tab switch /
        /// sidebar toggle / view-mode toggle). The intervals are ANCHORS
        /// for a Time Profiler capture — they bound the synchronous model
        /// call; the SwiftUI re-render they trigger lands in the samples
        /// immediately AFTER each interval (TSK-603).
        case interact   = "interact"
    }

    /// Set once at first touch from `MDV_SIGNPOSTS`. `nonisolated(unsafe)`:
    /// written exactly once under `enabledOnce` then only read.
    nonisolated(unsafe) private static var _enabled: Bool = false
    private static let enabledOnce: Void = {
        _enabled = ProcessInfo.processInfo.environment["MDV_SIGNPOSTS"] == "1"
        return ()
    }()

    /// Whether signpost emission is on. Cheap (one branch) after the first
    /// call resolves the env var.
    public static var isEnabled: Bool {
        _ = enabledOnce
        return _enabled
    }

    /// Per-stage `OSSignposter`, lazily built only when enabled. Keyed by
    /// stage so each category gets its own logger/lane. Guarded by
    /// `signpostersLock`.
    nonisolated(unsafe) private static var _signposters: [Stage: OSSignposter] = [:]
    private static let signpostersLock = NSLock()

    private static func signposter(for stage: Stage) -> OSSignposter? {
        guard isEnabled else { return nil }
        signpostersLock.lock(); defer { signpostersLock.unlock() }
        if let existing = _signposters[stage] { return existing }
        let log = OSLog(subsystem: subsystem, category: stage.rawValue)
        let sp = OSSignposter(logHandle: log)
        _signposters[stage] = sp
        return sp
    }

    /// An in-flight interval. Returned by `begin`; pass back to `end`.
    /// Carries everything `OSSignposter.endInterval` needs so callers don't
    /// have to retain the signposter. When signposts are disabled this is a
    /// hollow token (`signposter == nil`) and `end` is a no-op.
    public struct Token: Sendable {
        fileprivate let signposter: OSSignposter?
        fileprivate let state: OSSignpostIntervalState?
        fileprivate let name: StaticString
    }

    /// Begin a named interval in `stage`. The `name` is a `StaticString`
    /// (os_signpost requirement) — it's the interval label Instruments
    /// shows. Returns a `Token` to pass to `end`. No-op token when disabled.
    ///
    /// Prefer `withInterval` for scoped work; use the begin/end pair only
    /// when the span crosses a closure / Task boundary (e.g. an async
    /// materialize that begins on the main actor and ends in a detached
    /// completion).
    public static func begin(_ stage: Stage, _ name: StaticString) -> Token {
        guard let sp = signposter(for: stage) else {
            return Token(signposter: nil, state: nil, name: name)
        }
        let id = sp.makeSignpostID()
        let state = sp.beginInterval(name, id: id)
        return Token(signposter: sp, state: state, name: name)
    }

    /// End a previously-begun interval. Safe to call on a disabled token.
    public static func end(_ token: Token) {
        guard let sp = token.signposter, let state = token.state else { return }
        sp.endInterval(token.name, state)
    }

    /// Emit a single point-in-time event (not an interval) in `stage`.
    /// Useful to mark a decision point (e.g. "routed to native preview",
    /// "cache hit") inside a larger interval.
    public static func event(_ stage: Stage, _ name: StaticString) {
        guard let sp = signposter(for: stage) else { return }
        sp.emitEvent(name, id: sp.makeSignpostID())
    }

    /// Run `body` bracketed by a named interval in `stage`, returning its
    /// result. The interval ends even if `body` throws. When signposts are
    /// disabled this is just `try body()` with one extra branch.
    @discardableResult
    @inline(__always)
    public static func withInterval<T>(
        _ stage: Stage,
        _ name: StaticString,
        _ body: () throws -> T
    ) rethrows -> T {
        let token = begin(stage, name)
        defer { end(token) }
        return try body()
    }
}
