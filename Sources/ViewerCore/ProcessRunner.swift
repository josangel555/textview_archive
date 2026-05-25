import Foundation

/// Shared "run a `Process`, drain stdout/stderr concurrently, optionally
/// pipe in stdin, optionally enforce a wall-clock timeout" helper.
///
/// Decision H (2026-05-25): four sites in this codebase open-coded the
/// same recipe — `Process` + `DispatchGroup` + per-pipe drain + box-
/// around-Data shim to keep strict-concurrency quiet. The recipe has a
/// well-known footgun (read both pipes sequentially after exit and you
/// deadlock on the 64 KB pipe buffer when stderr is chatty), so we keep
/// the lesson in one place.
///
/// Callers configure the `Process` themselves — executable URL,
/// arguments, environment, cwd, `nullDevice` stdin — and hand it to
/// `ProcessRunner.run(...)`. We attach pipes, launch, and return the
/// drained buffers. Re-entrancy-safe (no shared state); call from any
/// thread.
///
/// Why this is a `public enum` with one static method instead of a
/// struct: the recipe has zero per-instance state, the call sites are
/// "run once, throw away the box", and Swift's namespacing makes
/// `ProcessRunner.run(...)` read clean at the call site.
///
/// **Not** for `PluginSubprocessHost`. That host streams stdout with a
/// hard cap + overflow flag + SIGKILL escalation, none of which fit
/// the simple "drain to EOF" shape here. Keeping plugin invocation
/// separate is intentional — host hardening is a different surface
/// than viewer-side reads.
public enum ProcessRunner {

    /// Outcome of `run(...)`. `stdout` / `stderr` are always present
    /// (empty on no-output); `timedOut` is true iff we tripped the
    /// `timeout` and called `Process.terminate()`; `terminationStatus`
    /// mirrors `Process.terminationStatus` post-exit (will reflect a
    /// SIGTERM exit code when `timedOut` is true).
    public struct Result: Sendable {
        public let stdout: Data
        public let stderr: Data
        public let terminationStatus: Int32
        public let timedOut: Bool
    }

    /// Errors surfaced from `run(...)`. `processFailedToStart` wraps
    /// the underlying `Foundation.Error` thrown by `Process.run()`;
    /// callers usually surface it as "couldn't spawn …".
    public enum Error: Swift.Error, CustomStringConvertible {
        case processFailedToStart(Swift.Error)
        public var description: String {
            switch self {
            case .processFailedToStart(let e):
                return "subprocess failed to start: \(e)"
            }
        }
    }

    /// Launch `process` (already configured with `executableURL`,
    /// `arguments`, etc.), attach stdout/stderr pipes, optionally write
    /// `stdin` and close, optionally enforce `timeout` seconds, drain
    /// both output pipes concurrently, and return the combined result.
    ///
    /// Contract:
    ///   - The caller MUST NOT have already called `process.run()`.
    ///   - The caller MUST NOT have assigned `process.standardOutput`
    ///     or `process.standardError`; we attach our own pipes.
    ///   - If `stdin` is non-nil, we attach a `Pipe`, write the bytes
    ///     off-thread, close the write end. Pass nil to leave
    ///     `standardInput` at whatever the caller configured (e.g.
    ///     `FileHandle.nullDevice` for git).
    ///   - If `timeout` is non-nil and the process hasn't exited by
    ///     `Date() + timeout`, we call `process.terminate()` (SIGTERM)
    ///     and set `timedOut = true` in the result. We do not
    ///     SIGKILL — callers that want forced kill on hang use
    ///     `PluginSubprocessHost`'s richer surface instead.
    ///
    /// Concurrency: drains stdout + stderr on two background dispatch
    /// queues to avoid the 64 KB pipe-buffer deadlock that bit early
    /// callers when stderr was noisy. The `DispatchGroup` wait ensures
    /// the returned `Data` is whole.
    @discardableResult
    public static func run(
        _ process: Process,
        stdin: Data? = nil,
        timeout: TimeInterval? = nil
    ) throws -> Result {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if stdin != nil {
            let p = Pipe()
            process.standardInput = p
            stdinPipe = p
        } else {
            stdinPipe = nil
        }

        do {
            try process.run()
        } catch {
            throw Error.processFailedToStart(error)
        }

        // Write stdin off-thread and close to signal EOF. Plugins /
        // tools that block on a full read of stdin would deadlock if
        // we wrote inline before draining stdout (a chatty tool can
        // fill its stdout pipe and stall before consuming our stdin
        // payload).
        if let pipe = stdinPipe, let data = stdin {
            DispatchQueue.global(qos: .userInitiated).async {
                try? pipe.fileHandleForWriting.write(contentsOf: data)
                try? pipe.fileHandleForWriting.close()
            }
        }

        // Box wrappers keep strict-concurrency quiet: the dispatch
        // closures aren't `@Sendable`-marked today, but a future
        // toolchain bump that flips them would refuse the `var data =
        // Data()` capture. One write per box, one read after the
        // DispatchGroup completes; no contention to guard against.
        let outBox = _DataBox()
        let errBox = _DataBox()
        let group = DispatchGroup()
        let outQ = DispatchQueue(label: "ProcessRunner.stdout", qos: .userInitiated)
        let errQ = DispatchQueue(label: "ProcessRunner.stderr", qos: .userInitiated)
        group.enter()
        outQ.async {
            outBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        errQ.async {
            errBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        var didTimeOut = false
        if let timeout {
            // Watchdog: if the process is still running at the
            // deadline, send SIGTERM. Drains will then EOF and the
            // group.wait() below unblocks.
            let deadline = DispatchTime.now() + timeout
            let watchdog = DispatchQueue.global(qos: .userInitiated)
            let flagBox = _FlagBox()
            watchdog.asyncAfter(deadline: deadline) { [weak process] in
                guard let process, process.isRunning else { return }
                flagBox.set()
                process.terminate()
            }
            process.waitUntilExit()
            didTimeOut = flagBox.isSet()
        } else {
            process.waitUntilExit()
        }
        group.wait()

        return Result(
            stdout: outBox.data,
            stderr: errBox.data,
            terminationStatus: process.terminationStatus,
            timedOut: didTimeOut
        )
    }
}

/// Mutable Data box used by the drain queues. `@unchecked Sendable`
/// because access is scoped: one closure writes, one read happens
/// after the `DispatchGroup` completes — no concurrent access.
private final class _DataBox: @unchecked Sendable {
    var data = Data()
}

/// Mutable bool box used by the watchdog → main coordination.
/// `@unchecked Sendable` for the same reason as `_DataBox` — at most
/// one write before the surrounding `process.waitUntilExit()` returns,
/// one read after.
private final class _FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
