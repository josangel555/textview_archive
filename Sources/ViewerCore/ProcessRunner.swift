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
        /// SCALE-2/TD-03/CR-05: true iff the combined stdout+stderr
        /// byte count crossed `maxOutputBytes` and we stopped reading +
        /// terminated the child. `stdout`/`stderr` then hold *at most*
        /// `maxOutputBytes` total — callers must treat the payload as
        /// partial (e.g. don't parse a truncated JSON blob as complete).
        public let truncated: Bool
        /// SCALE-2/TD-03/CR-05: true iff the SIGTERM the watchdog sent
        /// (on timeout or overflow) did not get the child to exit
        /// within the post-SIGTERM grace window and we had to escalate
        /// to `SIGKILL`. Purely diagnostic; the child is dead either way.
        public let killed: Bool

        public init(
            stdout: Data,
            stderr: Data,
            terminationStatus: Int32,
            timedOut: Bool,
            truncated: Bool = false,
            killed: Bool = false
        ) {
            self.stdout = stdout
            self.stderr = stderr
            self.terminationStatus = terminationStatus
            self.timedOut = timedOut
            self.truncated = truncated
            self.killed = killed
        }
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
    ///     `Date() + timeout`, we call `process.terminate()` (SIGTERM),
    ///     set `timedOut = true`, and — if the child ignores SIGTERM —
    ///     escalate to `SIGKILL` after `killGrace` so `waitUntilExit()`
    ///     can never hang on a process that traps SIGTERM (SCALE-2/
    ///     TD-03/CR-05).
    ///   - If `maxOutputBytes` is non-nil, we drain stdout+stderr in
    ///     chunks tracking a *combined* running byte count. The instant
    ///     the count crosses the cap we stop reading, set
    ///     `truncated = true`, and terminate the child (SIGTERM →
    ///     SIGKILL). This bounds the memory a chatty / hostile child
    ///     can make us buffer — `readDataToEndOfFile()` alone would
    ///     happily accumulate gigabytes. `nil` keeps the old
    ///     read-to-EOF behavior.
    ///
    /// Concurrency: drains stdout + stderr on two background dispatch
    /// queues to avoid the 64 KB pipe-buffer deadlock that bit early
    /// callers when stderr was noisy. The `DispatchGroup` wait ensures
    /// the returned `Data` is whole.
    ///
    /// - Parameters:
    ///   - killGrace: seconds to wait after SIGTERM before escalating
    ///     to SIGKILL. Only relevant when `timeout` or `maxOutputBytes`
    ///     can trigger a terminate. Default 2s.
    @discardableResult
    public static func run(
        _ process: Process,
        stdin: Data? = nil,
        timeout: TimeInterval? = nil,
        limits: ResourceLimits? = nil,
        maxOutputBytes: Int? = nil,
        killGrace: TimeInterval = 2.0
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

        // SCALE-2/TD-03/CR-05: a shared running byte counter across both
        // drains plus an overflow flag. When `maxOutputBytes` is set we
        // read in chunks and stop the instant the *combined* total
        // crosses the cap, instead of `readDataToEndOfFile()` which
        // would buffer the whole (possibly unbounded) stream.
        let counter = _ByteCounter(cap: maxOutputBytes)
        // `pid` snapshot for the overflow-triggered SIGTERM. We can't
        // safely touch `process` from the drain queue (Process isn't
        // documented thread-safe), so we signal by pid via `kill(2)`.
        let escalator = _Escalator(process: process, killGrace: killGrace)

        group.enter()
        outQ.async {
            Self.drain(
                stdoutPipe.fileHandleForReading,
                into: outBox, counter: counter, onOverflow: { escalator.terminate() }
            )
            group.leave()
        }
        group.enter()
        errQ.async {
            Self.drain(
                stderrPipe.fileHandleForReading,
                into: errBox, counter: counter, onOverflow: { escalator.terminate() }
            )
            group.leave()
        }

        var didTimeOut = false
        if let timeout {
            // Watchdog: if the process is still running at the
            // deadline, send SIGTERM, then escalate to SIGKILL after
            // `killGrace` if it's still alive. Drains EOF once the
            // child dies and the group.wait() below unblocks.
            let deadline = DispatchTime.now() + timeout
            let watchdog = DispatchQueue.global(qos: .userInitiated)
            watchdog.asyncAfter(deadline: deadline) {
                escalator.terminateOnTimeout()
            }
            process.waitUntilExit()
            didTimeOut = escalator.didTimeOut()
        } else {
            process.waitUntilExit()
        }
        // The child has exited; cancel any pending SIGKILL escalation so
        // we don't fire `kill(pid, SIGKILL)` at a recycled pid.
        escalator.cancelPendingKill()

        // SCALE-2/TD-03/CR-05: `waitUntilExit()` returns when the
        // *direct* child dies, but a child we killed may have left an
        // orphaned grandchild (e.g. `sh -c '... sleep 30'` after the
        // shell is SIGKILLed) that inherited — and still holds open —
        // the write end of our stdout/stderr pipes. The drains'
        // `readDataToEndOfFile()` would then block until that orphan
        // exits, re-introducing the very hang we escalated to prevent.
        // So: if we terminated the child, give the drains a short grace
        // to EOF naturally; if they don't, force-close the read ends to
        // unblock them. `try?` because a handle already at EOF / closed
        // throws on a redundant close.
        if escalator.didTerminate() {
            if group.wait(timeout: .now() + 1.0) == .timedOut {
                try? stdoutPipe.fileHandleForReading.close()
                try? stderrPipe.fileHandleForReading.close()
            }
        }
        group.wait()

        return Result(
            stdout: outBox.data,
            stderr: errBox.data,
            terminationStatus: process.terminationStatus,
            timedOut: didTimeOut,
            truncated: counter.didOverflow(),
            killed: escalator.didKill()
        )
    }

    /// Chunked pipe drain with an optional combined byte cap. Reads
    /// `availableData` (one `read(2)` per call) until EOF or the shared
    /// `counter` reports the cap is exceeded, in which case we invoke
    /// `onOverflow` once (to terminate the child) and stop reading.
    private static func drain(
        _ handle: FileHandle,
        into box: _DataBox,
        counter: _ByteCounter,
        onOverflow: () -> Void
    ) {
        // No cap: keep the cheap, well-trodden read-to-EOF path.
        guard counter.isCapped else {
            box.data = handle.readDataToEndOfFile()
            return
        }
        var buf = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }  // EOF
            buf.append(chunk)
            if counter.add(chunk.count) {
                // Combined total just crossed the cap. Stop reading and
                // ask the escalator to terminate the child; the other
                // drain will EOF as soon as the child dies and closes.
                onOverflow()
                break
            }
        }
        box.data = buf
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

/// Shared, lock-guarded combined byte counter for the two drain
/// queues. `add` returns `true` the first time the running total
/// crosses `cap` (and latches `overflow`), so each drain stops as soon
/// as the *combined* stdout+stderr volume exceeds the budget. With a
/// `nil` cap the counter reports `isCapped == false` and the drains
/// take the read-to-EOF fast path. `@unchecked Sendable`: all state is
/// behind `lock`.
private final class _ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let cap: Int?
    private var total = 0
    private var overflow = false

    init(cap: Int?) { self.cap = cap }

    var isCapped: Bool { cap != nil }

    /// Add `n` bytes; returns true iff this push tripped the cap.
    func add(_ n: Int) -> Bool {
        guard let cap else { return false }
        lock.lock(); defer { lock.unlock() }
        total += n
        if total > cap && !overflow {
            overflow = true
            return true
        }
        return false
    }

    func didOverflow() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return overflow
    }
}

/// Owns the terminate → SIGKILL escalation for a running `Process`.
/// Both the timeout watchdog and the byte-cap overflow funnel through
/// here so a child that traps SIGTERM can never wedge `waitUntilExit()`.
///
/// `@unchecked Sendable`: every mutable field is guarded by `lock`. We
/// hold the `Process` only to read `processIdentifier` / `isRunning`
/// and to call `terminate()` (SIGTERM); the SIGKILL escalation goes via
/// `kill(2)` on the captured pid so it works even from the drain queue.
private final class _Escalator: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let killGrace: TimeInterval
    private var terminated = false
    private var timedOut = false
    private var killed = false
    private var cancelled = false
    private var killScheduled = false

    init(process: Process, killGrace: TimeInterval) {
        self.process = process
        self.killGrace = killGrace
    }

    /// SIGTERM the child once (idempotent), then schedule a SIGKILL
    /// after `killGrace` if it's still alive. Used by the byte-cap
    /// overflow path.
    func terminate() {
        sendSIGTERM(markTimeout: false)
    }

    /// Same as `terminate()` but records that the trigger was the
    /// wall-clock timeout, so the `Result` can report `timedOut`.
    func terminateOnTimeout() {
        guard process.isRunning else { return }
        sendSIGTERM(markTimeout: true)
    }

    private func sendSIGTERM(markTimeout: Bool) {
        lock.lock()
        if markTimeout { timedOut = true }
        if terminated || cancelled { lock.unlock(); return }
        terminated = true
        let pid = process.processIdentifier
        lock.unlock()

        // SIGTERM via Process so its bookkeeping stays consistent.
        process.terminate()

        // Escalate to SIGKILL after the grace window if the child is
        // still alive (it trapped / ignored SIGTERM). `kill(2)` by pid
        // works off any queue. We re-check `cancelled` (set when the
        // child exits cleanly first) before firing.
        lock.lock()
        guard !killScheduled, !cancelled else { lock.unlock(); return }
        killScheduled = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + killGrace) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let abort = self.cancelled
                self.lock.unlock()
                // `cancelled` is set the instant `waitUntilExit()`
                // returns (child already dead) — if it's set, the child
                // honored SIGTERM and we must not fire a stray SIGKILL
                // at a possibly-recycled pid. Otherwise the child is
                // still alive past the grace window: force kill.
                //
                // We deliberately do NOT gate on `process.isRunning`
                // here: Foundation's `isRunning` flips to false as soon
                // as `terminate()` is *called*, even for a child that
                // traps/ignores SIGTERM and keeps running — so gating
                // on it would skip the escalation precisely when it's
                // needed. The `cancelled` flag is the authoritative
                // "child actually exited" signal.
                if abort { return }
                if pid > 0 {
                    kill(pid, SIGKILL)
                    self.lock.lock(); self.killed = true; self.lock.unlock()
                }
            }
    }

    /// Called once the child has exited (post-`waitUntilExit`) so a
    /// pending SIGKILL doesn't land on a recycled pid.
    func cancelPendingKill() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func didTimeOut() -> Bool {
        lock.lock(); defer { lock.unlock() }; return timedOut
    }

    func didKill() -> Bool {
        lock.lock(); defer { lock.unlock() }; return killed
    }

    /// True iff we ever sent SIGTERM (timeout or byte-cap overflow).
    /// Used to decide whether to apply the post-exit drain grace +
    /// forced pipe close (only needed when we killed the child and an
    /// orphan may be holding the pipe).
    func didTerminate() -> Bool {
        lock.lock(); defer { lock.unlock() }; return terminated
    }
}
