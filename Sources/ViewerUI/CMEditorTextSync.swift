import AppKit
import WebKit
import ViewerCore

/// O-6 flush-before-read (owner-confirmed data-loss class, 2026-08-11).
///
/// The CM6 editor debounces its text emission (~200 ms after the last
/// keystroke), so every Swift-side reader of the editor buffers — the ⌘W
/// close-confirm dirty check, the quit hot-exit capture, the session-switch
/// drain, menu-Save — could read a STALE mirror and silently drop the last
/// keystrokes (type → ⌘W within the window → no dirty prompt → edits gone).
///
/// `flushPendingEdits()` closes the window deterministically: dispatch
/// `.flushChanges(nonce:)` to the focused editor page (which force-emits any
/// pending change, THEN acks the nonce — message order guarantees the change
/// landed first), and pump the main runloop until the ack arrives or a
/// bounded timeout. Callers are USER-ACTION paths (menu/keystroke handlers,
/// `applicationWillTerminate`), never layout/commit passes — the nested-
/// runloop-in-`CA::Transaction` trap (TSK-734) does not apply here.
///
/// Headless-safe by construction: no registered editor WebView (unit tests,
/// scenes without an editor) ⇒ immediate no-op return.
@MainActor
public enum CMEditorTextSync {

    /// Bounded wait — generous vs the one JS turn the round-trip needs
    /// (~1–5 ms in practice); small vs a user-perceptible pause.
    public static let defaultTimeout: TimeInterval = 0.25

    /// Flush the FOCUSED editor's pending text into the Swift mirror and
    /// wait (bounded) for the ack. Returns true when the ack arrived (the
    /// mirror is provably current), false on timeout / no live editor —
    /// callers proceed either way (the flush is best-effort belt: the JS
    /// blur/hide listeners already cover most paths).
    @discardableResult
    public static func flushPendingEdits(timeout: TimeInterval = defaultTimeout) -> Bool {
        guard let webView = CodeMirrorEditorRegistry.shared.current() else {
            return true   // no live editor ⇒ nothing pending by definition
        }
        let nonce = CMFlushAckBus.shared.nextNonce()
        let json = CMBridgeCodec.encodeOutboundJSON(.flushChanges(nonce: nonce))
        webView.evaluateJavaScript("window.cmDispatch(\(json));", completionHandler: nil)
        return waitForAck(
            nonce: nonce, timeout: timeout,
            isAcked: { CMFlushAckBus.shared.isReceived($0) },
            pump: {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            })
    }

    /// The bounded wait, isolated from WebKit so the host suite can pin its
    /// semantics (ack-first-pump returns true fast; never-acked returns
    /// false at ~timeout; already-acked returns without pumping).
    static func waitForAck(
        nonce: Int,
        timeout: TimeInterval,
        isAcked: (Int) -> Bool,
        pump: () -> Void
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isAcked(nonce) {
            if Date() >= deadline { return false }
            pump()
        }
        return true
    }
}

/// Receives `flushAck` nonces from every live editor page (the message
/// handler writes here directly — no per-view closure plumbing). Nonces are
/// monotonic per process; the set stays tiny (acks are consumed by the
/// waiter that minted them, and stale entries are pruned on mint).
@MainActor
public final class CMFlushAckBus {
    public static let shared = CMFlushAckBus()

    private var next = 1
    private var received: Set<Int> = []

    public func nextNonce() -> Int {
        // Prune: any nonce below the one we're about to mint can no longer
        // have a live waiter (waiters are synchronous on the main actor).
        received.removeAll()
        defer { next += 1 }
        return next
    }

    public func received(_ nonce: Int) {
        received.insert(nonce)
    }

    public func isReceived(_ nonce: Int) -> Bool {
        received.contains(nonce)
    }
}
