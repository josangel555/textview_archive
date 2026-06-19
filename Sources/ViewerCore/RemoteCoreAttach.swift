import Foundation
import RustCore

/// App-side remote-core attach (TSK-665): when `MDV_REMOTE_SOCKET` names a
/// unix socket (an `ssh -L`-forwarded `mdv-serve` — the tunnel is the trust
/// boundary, per `docs/REMOTE_PROTOCOL.md`), dial it at launch and install
/// the `RemoteTransport` as the process-wide core transport.
///
/// FAIL-SAFE by construction:
///   • any attach failure (no socket, refused, wire-version skew) logs and
///     leaves the in-process FFI installed — never fatal;
///   • a connection LOST after attach auto-reverts the registry to
///     in-process, so a dropped tunnel degrades to local engines instead of
///     stalling every adapter call against the dead socket's deadline.
///
/// v1 is launch-time-only: no reconnect loop (a dropped tunnel stays local
/// until relaunch — reconnect policy is a recorded follow-up).
public enum RemoteCoreAttach {

    /// The result of an attach attempt, for diagnostics/tests.
    public enum Outcome: Equatable {
        /// Env var absent — remote not configured (the default).
        case notConfigured
        /// Attached; the registry now routes the remote core.
        case attached(capabilities: UInt64)
        /// Attach failed; the in-process transport stays installed.
        case failed(String)
    }

    /// Dial + install if configured. Call once at app launch, before any
    /// engine use.
    @discardableResult
    public static func attachIfConfigured(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        _transportForTest: RemoteTransport? = nil
    ) -> Outcome {
        guard let path = environment["MDV_REMOTE_SOCKET"], !path.isEmpty else {
            return .notConfigured
        }
        do {
            let remote = try _transportForTest ?? RemoteTransport(socketPath: path)
            // Resilience: a lost connection reverts to local engines. The
            // handler runs on the transport's reader thread; the registry
            // setter is lock-guarded.
            remote.onClose = { failure in
                CoreTransportRegistry.resetToInProcess()
                Obs.shared.emit(
                    .warn,
                    "rust-core",
                    "remote core connection lost — reverted to in-process engines",
                    fields: ["socket": path, "error": failure.map { "\($0)" } ?? "eof"])
            }
            CoreTransportRegistry.current = remote
            // TSK-1010: if the connection died during the init→install window
            // (onClose may not have fired — it was set just above), revert. An
            // installed dead transport would make every adapter call throw
            // against the closed socket instead of using the in-process engines.
            if remote.isClosed {
                CoreTransportRegistry.resetToInProcess()
                Obs.shared.emit(
                    .warn, "rust-core",
                    "remote core closed during attach — staying in-process",
                    fields: ["socket": path])
                return .failed("connection closed during attach")
            }
            Obs.shared.emit(
                .info,
                "rust-core",
                "remote core attached",
                fields: [
                    "socket": path,
                    "capabilities": String(remote.capabilities, radix: 2),
                ])
            return .attached(capabilities: remote.capabilities)
        } catch {
            Obs.shared.emit(
                .warn,
                "rust-core",
                "remote core attach FAILED — staying in-process",
                fields: ["socket": path, "error": "\(error)"])
            return .failed("\(error)")
        }
    }
}
