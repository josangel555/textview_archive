import Foundation
import Darwin

/// Owns a child process running on a pseudo-terminal, spawned via
/// Darwin's `forkpty(3)` — NO third-party dependency (no SwiftTerm). The
/// master side is read asynchronously on a background dispatch queue;
/// bytes are delivered to `onOutput` (called off the main actor —
/// callers re-hop as needed). Input is written with `write(2)`; window
/// size changes go through `ioctl(TIOCSWINSZ)`.
///
/// Lifecycle / safety:
///   • `start(...)` forks the login shell on the PTY and kicks the read
///     loop. Idempotent guard: a second `start` while running is ignored.
///   • The child is reaped with `waitpid` on `terminate()` and when the
///     read loop sees EOF — no zombies.
///   • `terminate()` sends SIGHUP (the controlling-terminal hangup the
///     shell expects), closes the master fd, and joins the read source.
///   • `deinit` calls `terminate()` defensively.
///
/// This type is `@unchecked Sendable`: all mutable state is guarded by
/// `lock`; the read loop runs on its own queue. The PURE screen-buffer
/// model it ultimately feeds lives in `ViewerCore` and is headless-
/// testable; THIS file (the live fork/exec path) is NOT unit-testable on
/// the host without spawning a real shell — see the report's
/// live-verification gap note.
public final class PTYProcess: @unchecked Sendable {
    /// Called with each raw output chunk from the shell, on `readQueue`
    /// (a background queue — NOT the main actor). Set before `start`.
    public var onOutput: (@Sendable (Data) -> Void)?
    /// Called once when the child exits / the PTY reaches EOF, on
    /// `readQueue`. Carries the exit status if known.
    public var onExit: (@Sendable (Int32) -> Void)?

    private let lock = NSLock()
    private var masterFD: Int32 = -1
    /// Internal getter (TSK-138 test seam): the zombie-reap pin reads
    /// the spawned pid to assert the child is actually COLLECTED after
    /// terminate() (kill(pid,0) → ESRCH), not merely signalled.
    private(set) var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var didExit = false
    private let readQueue = DispatchQueue(label: "com.markdownviewer.pty.read")

    public init() {}

    deinit { terminate() }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return childPID > 0 && !didExit
    }

    // MARK: - Spawn

    /// Fork the login shell on a fresh PTY sized `rows × cols` and start
    /// reading. Returns false if the fork failed.
    @discardableResult
    public func start(
        rows: UInt16,
        cols: UInt16,
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil
    ) -> Bool {
        lock.lock()
        guard childPID <= 0 else { lock.unlock(); return true }   // already running
        lock.unlock()

        var master: Int32 = 0
        var ws = winsize(
            ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0
        )

        // forkpty: allocates a PTY pair, forks, makes the child the
        // session leader with the slave as its controlling terminal, and
        // dup2's slave→0/1/2. Parent gets the master fd back.
        let pid = withUnsafeMutablePointer(to: &ws) { wsPtr in
            forkpty(&master, nil, nil, wsPtr)
        }

        if pid < 0 {
            return false                                   // fork failed
        }

        if pid == 0 {
            // ───── CHILD ─────
            // Only async-signal-safe work here. Set cwd, env, then exec
            // the login shell. On any failure, _exit (never return into
            // the parent's Swift runtime).
            if let cwd = workingDirectory?.path {
                _ = cwd.withCString { chdir($0) }
            }
            execLoginShell(environment: environment)
            // execLoginShell only returns on failure.
            _exit(127)
        }

        // ───── PARENT ─────
        lock.lock()
        masterFD = master
        childPID = pid
        didExit = false
        lock.unlock()

        startReadLoop()
        return true
    }

    /// `execvp` the user's login shell as an interactive login shell
    /// (`-` prefixed argv[0] is the historical "login shell" marker). Only
    /// reached in the child; must stay async-signal-safe-ish (we allocate
    /// C strings, which is acceptable post-fork pre-exec on Darwin here
    /// because we immediately exec).
    private func execLoginShell(environment: [String: String]?) {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shellPath as NSString).lastPathComponent
        // argv[0] = "-zsh" requests a login shell.
        let argv0 = "-" + shellName

        // Build the env array. If a custom env is supplied use it,
        // otherwise inherit the parent's. Always force a sane TERM so
        // programs negotiate against a capability set we roughly model.
        var env = environment ?? ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"

        let envStrings = env.map { "\($0.key)=\($0.value)" }

        // Convert to C arrays. These leak on exec (the address space is
        // replaced) — intentional and correct.
        let cArgv: [UnsafeMutablePointer<CChar>?] =
            [strdup(argv0), nil]
        let cEnv: [UnsafeMutablePointer<CChar>?] =
            envStrings.map { strdup($0) } + [nil]

        _ = shellPath.withCString { path in
            cArgv.withUnsafeBufferPointer { argvBuf in
                cEnv.withUnsafeBufferPointer { envBuf in
                    execve(
                        path,
                        UnsafeMutablePointer(mutating: argvBuf.baseAddress),
                        UnsafeMutablePointer(mutating: envBuf.baseAddress)
                    )
                }
            }
        }
        // execve only returns on failure.
    }

    // MARK: - Read loop

    private func startReadLoop() {
        lock.lock()
        let fd = masterFD
        lock.unlock()
        guard fd >= 0 else { return }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let n = buffer.withUnsafeMutableBytes { ptr -> Int in
                read(fd, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                let data = Data(buffer[0..<n])
                self.onOutput?(data)
            } else if n == 0 {
                // EOF — shell exited.
                self.handleEOF()
            } else {
                // n < 0: EAGAIN is spurious (level-triggered source
                // re-fires); EIO is the canonical "slave closed" on
                // macOS when the child exits.
                if errno != EAGAIN && errno != EINTR {
                    self.handleEOF()
                }
            }
        }
        source.setCancelHandler { [weak self] in
            // Close THIS source's master fd exactly once, when the source is
            // fully cancelled (avoids closing an fd the event handler is
            // mid-read on). Close the captured `fd` by value rather than
            // re-reading `self.masterFD`: on the restart path a fresh
            // `start()` may already have installed a NEW master fd into
            // `masterFD`, and clearing it here (the old behaviour) would
            // clobber the live fd of the respawned shell. Only clear the
            // stored field if it still points at the fd we own.
            guard fd >= 0 else { return }
            if let self {
                self.lock.lock()
                if self.masterFD == fd { self.masterFD = -1 }
                self.lock.unlock()
            }
            close(fd)
        }
        lock.lock()
        readSource = source
        lock.unlock()
        source.resume()
    }

    private func handleEOF() {
        lock.lock()
        if didExit { lock.unlock(); return }
        didExit = true
        let pid = childPID
        // Reset the pid sentinel so a subsequent `start()` passes the
        // line-62 guard and `forkpty` re-runs (restart after self-exit).
        childPID = -1
        let source = readSource
        readSource = nil
        lock.unlock()

        // Reap the child (no zombie). We're already on `readQueue` here and
        // EOF means the slave side closed, so the child is at (or about to
        // reach) zombie — a single non-blocking reap is the common case, but
        // poll briefly to cover the read-EOF-before-exit window.
        let status = Self.reapChild(pid)

        source?.cancel()
        onExit?(status)
    }

    /// Bounded, blocking reap of `pid` so the child never lingers as a
    /// zombie. SIGHUP delivery + the shell's exit are asynchronous, so a
    /// single `WNOHANG` immediately after the signal reliably misses;
    /// instead poll `waitpid(WNOHANG)` on a short cadence, escalate to
    /// SIGKILL if the shell ignores the hangup, then do a final blocking
    /// reap. Mirrors `LSPClient.shutdown()`'s teardown ladder; MUST be
    /// called off the main thread (it can block up to ~200ms) — both
    /// callers run it on `readQueue`. Returns the child's exit status (0
    /// if `pid <= 0` or the reap could not collect it).
    ///
    /// `static` so the `readQueue.async` dispatch in `terminate()` captures
    /// nothing of `self` (only the `pid` value) — safe to fire from `deinit`.
    @discardableResult
    private static func reapChild(_ pid: pid_t) -> Int32 {
        guard pid > 0 else { return 0 }
        var status: Int32 = 0
        // Poll for a clean exit: ~10 x 20ms = ~200ms.
        for _ in 0..<10 {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { return status }   // reaped
            if r < 0 { return status }      // ECHILD: already reaped elsewhere
            usleep(20_000)                  // r == 0: still alive, wait a beat
        }
        // Still alive after the hangup grace — escalate and block once.
        kill(pid, SIGKILL)
        waitpid(pid, &status, 0)
        return status
    }

    // MARK: - Write

    /// Write input bytes to the shell. No-op if the PTY is closed.
    public func write(_ data: Data) {
        lock.lock()
        let fd = masterFD
        lock.unlock()
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            let total = raw.count
            while offset < total {
                let n = Darwin.write(fd, base + offset, total - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && (errno == EINTR || errno == EAGAIN) {
                    continue
                } else {
                    break
                }
            }
        }
    }

    public func writeString(_ string: String) {
        write(Data(string.utf8))
    }

    // MARK: - Resize

    /// Tell the kernel + child the new window size. The child receives
    /// SIGWINCH; the shell + any TUI re-layout to the new dimensions.
    public func resize(rows: UInt16, cols: UInt16) {
        lock.lock()
        let fd = masterFD
        lock.unlock()
        guard fd >= 0 else { return }
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, TIOCSWINSZ, &ws)
    }

    // MARK: - Terminate

    /// Hang up the shell (SIGHUP), reap it, and tear down the read source.
    /// Idempotent.
    public func terminate() {
        lock.lock()
        if didExit && readSource == nil && masterFD < 0 {
            lock.unlock()
            return
        }
        let pid = childPID
        let source = readSource
        readSource = nil
        didExit = true
        // Reset the pid sentinel so a subsequent `start()` passes the
        // line-62 guard and `forkpty` re-runs (the "Restart shell" path).
        childPID = -1
        lock.unlock()

        if pid > 0 {
            // SIGHUP is the controlling-terminal hangup the shell expects.
            kill(pid, SIGHUP)
            // Reap off the main thread: the bounded poll + final blocking
            // wait can take up to ~200ms, and `terminate()` is reached from
            // the main actor (restart button, applicationWillTerminate).
            // The closure captures only `pid` (a value) — no `self` — so it
            // is safe to fire from `deinit`.
            readQueue.async { PTYProcess.reapChild(pid) }
        }
        if let source {
            // The source's cancel handler owns the fd close (it closes the
            // captured fd exactly once and clears `masterFD` only if it still
            // points at that fd). Don't also close `masterFD` here — that
            // would double-close, and on the restart path it could close the
            // freshly-spawned shell's fd.
            source.cancel()
        } else {
            // No source (start never completed / already torn down). Close any
            // open fd ourselves.
            lock.lock()
            let m = masterFD
            masterFD = -1
            lock.unlock()
            if m >= 0 { close(m) }
        }
    }
}
