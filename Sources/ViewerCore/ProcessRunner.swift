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

    /// Opt-in resource caps applied to the child via a `/bin/sh -c
    /// 'ulimit ...; exec ...'` wrapper. The wrapper calls `ulimit` to
    /// set the kernel-enforced rlimits, then `exec`s the original
    /// binary so the parent's `Process.processIdentifier` still points
    /// at the target (SIGTERM from the timeout watchdog lands on the
    /// real child, not on a shell).
    ///
    /// **macOS limit reality (S, 2026-05-29).** On macOS the kernel
    /// only enforces a *subset* of `setrlimit(2)`:
    ///
    ///   - `RLIMIT_CPU` (`ulimit -t`, seconds) — **enforced**. When the
    ///     child's accumulated CPU time crosses the soft cap, the
    ///     kernel sends `SIGXCPU` (default action: terminate). This is
    ///     the cap that actually defends against the "hostile LSP /
    ///     `jq` filter pins a core to the per-request timeout" attack
    ///     this option was added to address.
    ///   - `RLIMIT_FSIZE` (`ulimit -f`, blocks of 512 bytes) —
    ///     **enforced**. Caps the size of any single file the child
    ///     can write; useful against a `jq` filter that fills the
    ///     disk via `output > /tmp/x`.
    ///   - `RLIMIT_NOFILE` (`ulimit -n`) — **enforced**.
    ///   - `RLIMIT_AS` / `RLIMIT_DATA` (`ulimit -v` / `ulimit -d`,
    ///     virtual memory / data segment) — **NOT enforced**. The
    ///     macOS kernel accepts the syscall but never trips the cap.
    ///     `ulimit -v 1048576` on a stock zsh prints "cannot modify
    ///     limit". So there is no portable way to bound a child's
    ///     RSS / VM via `setrlimit` on macOS; if/when we need that,
    ///     the next-cheapest option is `sandbox-exec` (deprecated but
    ///     functional) or a private `posix_spawnattr_setjetsam_ext_np`
    ///     handshake (high-touch). For v1 we accept that "memory cap"
    ///     reduces to "CPU cap + file-size cap" and document it.
    ///
    /// Conservative defaults are chosen per call-site in the call-site
    /// code, NOT here, because "conservative" for `jq` (10s CPU on a
    /// 100 MB JSON) differs from "conservative" for `git log` on a
    /// big repo (could legitimately need 60s+ on cold cache).
    public struct ResourceLimits: Sendable, Equatable {
        /// Soft `RLIMIT_CPU` in seconds. `nil` = no cap (inherits
        /// parent). Hard limit always set equal to soft (kernel sends
        /// `SIGXCPU` on soft, `SIGKILL` on hard).
        public let cpuSeconds: Int?
        /// Soft `RLIMIT_FSIZE` in 512-byte blocks (this is the unit
        /// `ulimit -f` accepts). `nil` = no cap. Default for the call
        /// sites we wire up is 256 MB worth of blocks (524288) — well
        /// above any honest jq / git log output, well below filling
        /// the disk.
        public let fileSizeBlocks: Int?
        /// Soft `RLIMIT_NOFILE`. `nil` = no cap. Most useful for jq,
        /// which shouldn't open files at all; a few hundred fds is
        /// plenty for git / LSP discovery / `--version` probes.
        public let openFiles: Int?

        public init(
            cpuSeconds: Int? = nil,
            fileSizeBlocks: Int? = nil,
            openFiles: Int? = nil
        ) {
            self.cpuSeconds = cpuSeconds
            self.fileSizeBlocks = fileSizeBlocks
            self.openFiles = openFiles
        }

        /// True iff at least one cap is set. Callers that hand in an
        /// "empty" struct get the unwrapped fast path (no `/bin/sh`
        /// wrapper), which keeps the test suite unsurprising.
        var hasAny: Bool {
            cpuSeconds != nil || fileSizeBlocks != nil || openFiles != nil
        }

        /// Compose the shell-prefix string of `ulimit` commands. The
        /// caller appends `; exec "$@"` and passes the real binary as
        /// `$0..$N`.
        func ulimitPrefix() -> String {
            var parts: [String] = []
            if let cpu = cpuSeconds { parts.append("ulimit -t \(cpu)") }
            if let fsize = fileSizeBlocks { parts.append("ulimit -f \(fsize)") }
            if let nofile = openFiles { parts.append("ulimit -n \(nofile)") }
            // `>/dev/null 2>&1` on each: a failure to set a cap (e.g.
            // soft > hard) prints to stderr and would corrupt our
            // stderr drain. We'd rather the cap silently fail than
            // mix `ulimit:` noise into the child's diagnostic output.
            return parts.map { "\($0) 2>/dev/null" }.joined(separator: "; ")
        }
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
        timeout: TimeInterval? = nil,
        limits: ResourceLimits? = nil
    ) throws -> Result {
        // Apply the resource-limit shell wrapper *before* attaching
        // pipes. `exec` in the wrapper replaces the shell image with
        // the target binary in-place, so `process.processIdentifier`
        // continues to point at the real child — the SIGTERM watchdog
        // below still lands cleanly, and `terminationStatus` reflects
        // the child's exit (including `128 + SIGXCPU = 152` if the
        // CPU cap fires). See `ResourceLimits` doc for which caps
        // macOS actually honors.
        if let limits, limits.hasAny {
            try Self.applyLimitsWrapper(to: process, limits: limits)
        }
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

    /// Rewrite `process` so the kernel-level rlimits in `limits` are
    /// applied to the eventual child. We don't use `posix_spawnattr_*`
    /// because macOS doesn't expose an rlimit attribute on spawn, and
    /// we don't ship a C `fork+setrlimit+execve` shim because the
    /// `/bin/sh -c '...; exec "$0" "$@"'` recipe gives us the same
    /// result with zero new build targets and zero extra dependencies.
    ///
    /// Mechanism:
    ///   1. The caller has set `executableURL = /path/to/jq` and
    ///      `arguments = ["."]` (say).
    ///   2. We swap `executableURL = /bin/sh`, then build the script
    ///      `ulimit -t N 2>/dev/null; ulimit -f M 2>/dev/null; exec "$0" "$@"`,
    ///      and pass it via `-c <script> /path/to/jq .`.
    ///   3. `/bin/sh` parses `-c`, sets the ulimits, then `exec`s the
    ///      target. Because `exec` replaces the process image without
    ///      forking, our `process.processIdentifier` continues to
    ///      identify the *real* child — `terminate()`, `waitUntilExit`,
    ///      `terminationStatus` all behave as if there were no wrapper.
    ///
    /// **Why `exec "$0" "$@"` and not `exec "$@"`.** Under
    /// `sh -c <script> <a0> <a1> <a2>`, the shell binds `$0 = <a0>`
    /// and `"$@" = "<a1>" "<a2>"`. So `exec "$@"` would drop `<a0>`
    /// — exactly the binary we want to run. `exec "$0" "$@"` puts
    /// the binary back at the front and prepends the rest of the
    /// args. An earlier draft used `exec "$@"`; tests caught it
    /// (env-propagation test exited 127 = "command not found").
    ///
    /// `currentDirectoryURL` and `environment` on the original
    /// `Process` are not touched: they apply to `/bin/sh` and are
    /// inherited across `exec`, so the target sees the same cwd / env
    /// the caller configured.
    ///
    /// Throws nothing — the only failure mode (missing `/bin/sh`) is
    /// surfaced when `process.run()` itself fails downstream.
    private static func applyLimitsWrapper(
        to process: Process,
        limits: ResourceLimits
    ) throws {
        guard let originalURL = process.executableURL else {
            // Caller broke contract — let the existing `process.run()`
            // call fail loudly rather than silently exec a shell with
            // no target.
            return
        }
        let originalArgs = process.arguments ?? []
        let script = "\(limits.ulimitPrefix()); exec \"$0\" \"$@\""
        // `sh -c <script> <arg0> <arg1> ...` sets `$0` to <arg0> and
        // shifts the rest into `$@`. We put the real binary path at
        // `$0` so `exec "$0" "$@"` re-assembles it as a full
        // `binary arg1 arg2 ...` invocation.
        var wrapped = ["-c", script, originalURL.path]
        wrapped.append(contentsOf: originalArgs)
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = wrapped
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
