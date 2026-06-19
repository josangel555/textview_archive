import Combine
import Foundation

/// Identity of a single application window in the multi-window model.
///
/// Today `SessionsAppCoordinator` (ViewerUI) is effectively a process
/// singleton over one `SessionsCoordinator` / one mounted `SessionState`.
/// The multi-window epic splits that into N windows, each driving its own
/// active session. This value type is the stable handle the registry hands
/// out so callers don't depend on `NSWindow` identity (which ViewerCore
/// can't import) — a `UUID` is enough to key a binding and survives the
/// real `NSWindow` not yet existing (this foundation slice has no second
/// `NSWindow`; the window id is allocated and tracked purely in the model).
public struct WindowID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: UUID
    public init(raw: UUID = UUID()) { self.raw = raw }
    public var description: String { "WindowID(\(raw.uuidString.prefix(8)))" }
}

/// A value mapping a window identity to the session it currently drives.
///
/// Immutable: a rebind produces a NEW binding rather than mutating in place,
/// so the registry's `bindings` snapshot is always a coherent point-in-time
/// view (no torn reads for an observing UI). `boundAt` records when the
/// session was last (re)attached to this window — useful for diagnostics and
/// a future "most-recently-focused window wins" tiebreak.
public struct WindowSessionBinding: Hashable, Codable, Sendable {
    public let windowID: WindowID
    public let sessionID: UUID
    public let boundAt: Date

    public init(windowID: WindowID, sessionID: UUID, boundAt: Date = Date()) {
        self.windowID = windowID
        self.sessionID = sessionID
        self.boundAt = boundAt
    }
}

/// Why a bind attempt was refused. Surfaced so the UI can tell the user
/// *which* window already owns a session (e.g. "already open in another
/// window — switch to it?") rather than silently no-op'ing.
public enum WindowBindError: Error, Equatable, Sendable {
    /// The session is already leased by a *different* window. Carries the
    /// holder so the caller can offer "reveal the window that has it".
    case sessionAlreadyBound(sessionID: UUID, heldBy: WindowID)
    /// The target window id is unknown to the registry (never allocated, or
    /// already released).
    case unknownWindow(WindowID)
}

/// Tracks which sessions are open in which windows and enforces the
/// **one-window-per-session ownership lease**: a given session may be
/// mutated (tabs/sidebar/scroll/etc.) from at most one window at a time, so
/// two windows can never both write the same `Sessions/<uuid>.json` and
/// clobber each other (and, transitively, `index.json`).
///
/// Layering: lives in `ViewerCore` and is value/model-only — it knows
/// nothing about `NSWindow`, `DocumentModel`, or SwiftUI. The ViewerUI
/// layer owns the real windows and asks this registry to allocate ids +
/// (un)register bindings; ViewerCore stays UI-free (it can't import the UI
/// frameworks). This mirrors the `SessionsCoordinator` (value) ↔
/// `SessionsAppCoordinator` (UI) split already in place.
///
/// **Write serialization (the clobber guard).** The lease alone prevents
/// two *live* windows mutating one session, but a window that has just
/// released a session can still have an in-flight async snapshot write
/// racing the next owner's write. `serializeSave` funnels every
/// per-session persist through a per-session FIFO so a save issued after an
/// earlier save to the same session id always lands after it — independent
/// of which window issued it. `SessionStore` already serializes writes per
/// *file URL*; this adds a model-level ordering seam the multi-window UI can
/// drive without reaching into the store, and lets host tests assert the
/// ordering deterministically.
@MainActor
public final class MultiWindowRegistry: ObservableObject {

    /// Live window → session bindings, newest binding per window. Published
    /// so a future window-switcher / "Window" menu can observe the set.
    @Published public private(set) var bindings: [WindowID: WindowSessionBinding] = [:]

    /// Reverse index: session id → the window that currently leases it.
    /// Kept in lock-step with `bindings` so the ownership check is O(1) and
    /// can't drift from the forward map.
    private var sessionOwner: [UUID: WindowID] = [:]

    /// Monotonic per-session write counter. Each call to `serializeSave`
    /// claims the next sequence number for that session and runs the write
    /// blocks strictly in claim order, so concurrent windows (or a window
    /// handing a session to the next owner) can't reorder snapshot writes.
    private var writeSeq: [UUID: UInt64] = [:]

    public init() {}

    // MARK: Window lifecycle -----------------------------------------

    /// Allocate a fresh, distinct window identity. Does NOT bind a session
    /// yet — the UI typically allocates, then binds once it knows which
    /// session the new window will show.
    @discardableResult
    public func allocateWindow() -> WindowID {
        var id = WindowID()
        // Astronomically unlikely UUID collision, but the registry is the
        // authority on uniqueness, so re-roll rather than overwrite a live
        // window's slot. Insert a placeholder-free marker by reserving the
        // key in `writeSeq` is unnecessary; we just ensure the id is unused.
        while bindings[id] != nil { id = WindowID() }
        // Reserve the slot so a later `bind` for an as-yet-unbound window is
        // distinguishable from a typo'd window id (`unknownWindow`). We
        // model "allocated but unbound" as a key present in `windows` set.
        allocatedWindows.insert(id)
        return id
    }

    /// Set of allocated window ids, including those not yet bound to a
    /// session. Separate from `bindings` so we can reject a bind against a
    /// window the registry never handed out.
    private var allocatedWindows: Set<WindowID> = []

    /// True if `id` was allocated and not yet released.
    public func isKnownWindow(_ id: WindowID) -> Bool {
        allocatedWindows.contains(id)
    }

    /// Bind (or rebind) `windowID` to drive `sessionID`, taking the
    /// session's ownership lease.
    ///
    /// Rules:
    ///   - The window must have been `allocateWindow()`'d (else
    ///     `.unknownWindow`).
    ///   - If the session is already leased by ANOTHER window, refuse with
    ///     `.sessionAlreadyBound` (the one-window-per-session invariant).
    ///   - Rebinding the SAME (window, session) pair is idempotent.
    ///   - A window may switch which session it drives: its previous
    ///     session's lease is released first, then the new one is taken.
    @discardableResult
    public func bind(window windowID: WindowID,
                     toSession sessionID: UUID,
                     at when: Date = Date()) throws -> WindowSessionBinding {
        guard allocatedWindows.contains(windowID) else {
            throw WindowBindError.unknownWindow(windowID)
        }
        // Idempotent re-bind of the same pair: refresh the timestamp.
        if let existing = bindings[windowID], existing.sessionID == sessionID {
            let refreshed = WindowSessionBinding(
                windowID: windowID, sessionID: sessionID, boundAt: when)
            bindings[windowID] = refreshed
            return refreshed
        }
        // Ownership: another live window already holds this session.
        if let holder = sessionOwner[sessionID], holder != windowID {
            throw WindowBindError.sessionAlreadyBound(
                sessionID: sessionID, heldBy: holder)
        }
        // This window is switching sessions — release its old lease first.
        if let prior = bindings[windowID] {
            sessionOwner[prior.sessionID] = nil
        }
        let binding = WindowSessionBinding(
            windowID: windowID, sessionID: sessionID, boundAt: when)
        bindings[windowID] = binding
        sessionOwner[sessionID] = windowID
        return binding
    }

    /// Release a window's binding on window-close, freeing its session's
    /// lease so another window may adopt that session. Idempotent: closing
    /// an unbound / already-released window is a clean no-op. The window id
    /// itself is forgotten (a closed window's id is never reused).
    public func releaseWindow(_ windowID: WindowID) {
        if let binding = bindings.removeValue(forKey: windowID) {
            // Only clear ownership if THIS window still holds it (defensive
            // against a stale double-release after a rebind handed the
            // session elsewhere).
            if sessionOwner[binding.sessionID] == windowID {
                sessionOwner[binding.sessionID] = nil
            }
        }
        allocatedWindows.remove(windowID)
    }

    // MARK: Queries --------------------------------------------------

    /// The session currently driven by `windowID`, if any.
    public func session(for windowID: WindowID) -> UUID? {
        bindings[windowID]?.sessionID
    }

    /// The window currently leasing `sessionID`, if any.
    public func window(forSession sessionID: UUID) -> WindowID? {
        sessionOwner[sessionID]
    }

    /// True when `sessionID` is leased by some window (i.e. open & mutable).
    public func isSessionBound(_ sessionID: UUID) -> Bool {
        sessionOwner[sessionID] != nil
    }

    /// Count of windows with a live session binding.
    public var boundWindowCount: Int { bindings.count }

    // MARK: Write serialization --------------------------------------

    /// Run `write` as part of the per-session FIFO so two windows (or a
    /// session handed from one owner to the next) can't reorder snapshot
    /// writes and clobber `index.json` / `<uuid>.json`.
    ///
    /// This foundation slice keeps the seam synchronous + deterministic:
    /// it claims a monotonic sequence number for the session and invokes
    /// `write` inline (callers are already on the MainActor). The returned
    /// sequence number lets a test assert that concurrent saves were
    /// ordered. A later slice can swap the inline call for a real async
    /// per-session serial queue without changing the call site or the
    /// ordering contract.
    @discardableResult
    public func serializeSave(sessionID: UUID,
                              _ write: () -> Void) -> UInt64 {
        let seq = (writeSeq[sessionID] ?? 0) &+ 1
        writeSeq[sessionID] = seq
        write()
        return seq
    }

    /// The last sequence number claimed for `sessionID` (0 if none). Lets a
    /// caller/test confirm the expected number of serialized writes ran.
    public func lastWriteSeq(for sessionID: UUID) -> UInt64 {
        writeSeq[sessionID] ?? 0
    }
}
