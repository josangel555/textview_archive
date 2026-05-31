import Foundation

/// Global install/access point for the process-wide observability sink.
///
/// ViewerCore code far from any dependency-injection seam — `GrammarLoader`
/// (a pure namespace `enum`), `LSPLog`, `MCPServer` — needs to emit
/// without threading a sink handle through every call site. `Obs.shared`
/// is that seam: install a real sink once at app launch, and every
/// emitter funnels through `Obs.shared`.
///
/// Tests swap in a capturing `RingBufferSink` (or any custom sink) via
/// `Obs.install(_:)` in `setUp` and assert against it — the generalised
/// form of the old `LSPLog.captured()` pattern.
///
/// The default is a `NoopObservabilitySink`, so emitting before any
/// install is safe and silent (no surprise stderr/os_log spew in unit
/// tests that never install a sink).
public enum Obs {

    // `nonisolated(unsafe)`: the stored sink is only ever read/written
    // under `installLock`, which provides the mutual exclusion Swift 6's
    // actor model can't statically prove for a global `var`. Audited
    // accessors: `shared` (read), `install` (write), `installIfNeeded`
    // (read+write).
    nonisolated(unsafe) private static var _shared: ObservabilitySink = NoopObservabilitySink()
    private static let installLock = NSLock()

    /// The process-wide sink. Cheap to read (one locked load); call
    /// `Obs.shared.emit(...)` from anywhere in ViewerCore.
    public static var shared: ObservabilitySink {
        installLock.lock(); defer { installLock.unlock() }
        return _shared
    }

    /// Install (or replace) the process-wide sink. Idempotent and safe
    /// to call from any thread. The app installs a `RingBufferSink` at
    /// launch; tests install a capturing sink in `setUp`.
    public static func install(_ sink: ObservabilitySink) {
        installLock.lock(); defer { installLock.unlock() }
        _shared = sink
    }

    /// Install `sink` only if the current sink is still the no-op
    /// default. Lets the app set up a sink at launch without clobbering a
    /// test-installed one (defensive; the app and tests don't normally
    /// race).
    @discardableResult
    public static func installIfNeeded(_ make: () -> ObservabilitySink) -> Bool {
        installLock.lock(); defer { installLock.unlock() }
        guard _shared is NoopObservabilitySink else { return false }
        _shared = make()
        return true
    }

    /// Reset to the no-op default. Test seam (call in `tearDown` so one
    /// test's installed sink doesn't leak into the next).
    public static func resetToNoop() {
        install(NoopObservabilitySink())
    }
}
