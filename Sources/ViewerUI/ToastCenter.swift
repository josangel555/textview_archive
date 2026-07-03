import Foundation
import Combine
import ViewerCore

// TSK-1436 — the shared toast + long-operation progress surface (usability
// theme #3: long operations give no feedback; failures are silent or
// console-only).
//
// ONE center owns both channels:
//   - TOASTS — transient, non-modal notices (error / success / info), each
//     optionally carrying one action (e.g. "Undo" — TSK-1479 paste feedback).
//     Errors surface the failure REASON the user never saw before.
//   - OPERATIONS — in-flight long work (cross-search, big CSV, converts,
//     feed refresh), determinate (`fraction`) or indeterminate, with a Cancel
//     hook where the engine supports it.
//
// The center is pure model state (host-testable: injectable clock, no UI);
// `ToastOverlayView` renders it bottom-trailing over the content pane.
// Error toasts also emit an `ObsEvent` so the Logs view keeps the durable
// record after the toast expires.

/// One transient notice. Value-typed; the (non-Equatable) action closure
/// lives in the center keyed by id, not on the toast.
public struct Toast: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case info, success, error
    }

    public let id: UUID
    public let kind: Kind
    /// One-line headline ("Pasted as Markdown", "Couldn't refresh 2 feeds").
    public let message: String
    /// Optional second line — the failure reason / affected names.
    public let detail: String?
    /// Label for the toast's single action button (e.g. "Undo"); nil = none.
    public let actionLabel: String?
    /// Absolute expiry on the center's clock; `sweep(now:)` prunes.
    public let expiresAtNanos: UInt64
}

/// One in-flight long operation.
public struct OperationProgress: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// What's running ("Searching 1,204 files…", "Converting image…").
    public let title: String
    /// 0…1 for determinate work; nil = indeterminate spinner.
    public var fraction: Double?
    /// Whether the engine wired a cancel hook.
    public let isCancellable: Bool
}

/// App-wide toast/progress state. Main-actor `ObservableObject`; views observe,
/// engines post. Host tests drive a private instance with a fake clock.
@MainActor
public final class ToastCenter: ObservableObject {
    public static let shared = ToastCenter()

    @Published public private(set) var toasts: [Toast] = []
    @Published public private(set) var operations: [OperationProgress] = []

    /// Newest-first cap — a burst of failures must not wallpaper the screen.
    public static let maxVisibleToasts = 5

    /// Default time-to-live per kind (errors linger longer — they carry the
    /// reason the user needs to read).
    public static func defaultTTL(for kind: Toast.Kind) -> TimeInterval {
        kind == .error ? 8 : 4
    }

    private var actions: [UUID: () -> Void] = [:]
    private var cancelHandlers: [UUID: () -> Void] = [:]
    private let now: () -> UInt64

    /// `now` is the toast clock (nanoseconds, monotonic-ish) — injectable so
    /// host tests control expiry deterministically.
    public init(now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.now = now
    }

    // MARK: - Toasts

    /// Post a toast. Returns its id (callers rarely need it). `ttl` overrides
    /// the kind default. `action` + `actionLabel` wire the single button.
    @discardableResult
    public func post(
        _ kind: Toast.Kind,
        _ message: String,
        detail: String? = nil,
        actionLabel: String? = nil,
        action: (() -> Void)? = nil,
        ttl: TimeInterval? = nil
    ) -> UUID {
        let id = UUID()
        let life = ttl ?? Self.defaultTTL(for: kind)
        let toast = Toast(
            id: id, kind: kind, message: message, detail: detail,
            actionLabel: action != nil ? actionLabel : nil,
            expiresAtNanos: now() &+ UInt64(max(0, life) * 1_000_000_000))
        if let action { actions[id] = action }
        toasts.append(toast)
        // FIFO cap — drop the oldest beyond the cap.
        while toasts.count > Self.maxVisibleToasts {
            let dropped = toasts.removeFirst()
            actions[dropped.id] = nil
        }
        // Self-scheduled expiry (one Task per post; +50ms slack so the sweep
        // lands after the deadline). No view-side timer — a re-rendering
        // parent can't starve it, and tests drive `sweep(now:)` directly.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, life) * 1_000_000_000) &+ 50_000_000)
            self?.sweep()
        }
        if kind == .error {
            // Durable record for after the toast expires (Logs view).
            Obs.shared.emit(ObsEvent(
                level: .error, subsystem: "ui.toast",
                message: detail.map { "\(message) — \($0)" } ?? message))
        }
        return id
    }

    /// Convenience: surface a failure (message = what failed, detail = why).
    @discardableResult
    public func postError(_ message: String, reason: String? = nil) -> UUID {
        post(.error, message, detail: reason)
    }

    public func dismiss(_ id: UUID) {
        toasts.removeAll { $0.id == id }
        actions[id] = nil
    }

    /// Run the toast's action (if any) and dismiss it.
    public func runAction(for id: UUID) {
        let action = actions[id]
        dismiss(id)
        action?()
    }

    /// Prune expired toasts. The overlay drives this on a coarse timer; tests
    /// call it with a fake `now`.
    public func sweep(now nowNanos: UInt64? = nil) {
        let t = nowNanos ?? now()
        for toast in toasts where toast.expiresAtNanos <= t {
            actions[toast.id] = nil
        }
        toasts.removeAll { $0.expiresAtNanos <= t }
    }

    /// Soonest expiry among visible toasts (drives the overlay's sweep timer).
    public var nextExpiryNanos: UInt64? {
        toasts.map(\.expiresAtNanos).min()
    }

    // MARK: - Long operations

    /// Register a long operation. Returns the handle used by update/end.
    /// `onCancel` non-nil ⇒ the overlay shows a Cancel button wired to it.
    @discardableResult
    public func beginOperation(
        _ title: String,
        fraction: Double? = nil,
        onCancel: (() -> Void)? = nil
    ) -> UUID {
        let id = UUID()
        if let onCancel { cancelHandlers[id] = onCancel }
        operations.append(OperationProgress(
            id: id, title: title, fraction: fraction,
            isCancellable: onCancel != nil))
        return id
    }

    /// Update a determinate operation's progress (clamped to 0…1).
    public func updateOperation(_ id: UUID, fraction: Double) {
        guard let i = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[i].fraction = min(max(fraction, 0), 1)
    }

    public enum OperationOutcome: Equatable, Sendable {
        /// Optional success toast ("Converted 3 files").
        case success(String? = nil)
        /// Failure ALWAYS surfaces — message is the reason.
        case failure(String)
        /// Quiet removal (user cancelled; they already know).
        case cancelled
    }

    /// Remove the operation and surface its outcome.
    public func endOperation(_ id: UUID, outcome: OperationOutcome = .success()) {
        guard let i = operations.firstIndex(where: { $0.id == id }) else { return }
        let op = operations.remove(at: i)
        cancelHandlers[id] = nil
        switch outcome {
        case .success(let message?):
            post(.success, message)
        case .success(nil), .cancelled:
            break
        case .failure(let reason):
            postError("\(op.title) failed", reason: reason)
        }
    }

    /// Invoke the operation's cancel hook (the operation stays visible until
    /// its owner calls `endOperation(_, outcome: .cancelled)` — cancellation
    /// is asynchronous and the engine confirms it).
    public func requestCancel(_ id: UUID) {
        cancelHandlers[id]?()
    }

    #if DEBUG
    /// Test seam: whether an action/cancel handler is registered (closures
    /// aren't visible through the value-typed rows).
    public func _test_hasAction(for id: UUID) -> Bool { actions[id] != nil }
    public func _test_hasCancelHandler(for id: UUID) -> Bool { cancelHandlers[id] != nil }
    #endif
}
