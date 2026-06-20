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
/// testable; the live fork/exec path is NOT unit-testable on the host
/// without spawning a real shell — but the spawn-plan precompute (shell
/// resolution + argv/env `char**` construction, moved to the PARENT for
/// signal-safety, M4/TSK-979) is factored into pure host-testable helpers
/// (`resolveShell`, `CStringArray.make`).
public final class PTYProcess: @unchecked Sendable {
    /// Called with each raw output chunk from the shell, on `readQueue`
    /// (a background queue — NOT the main actor). Set before `start`. TSK-992:
    /// lock-synchronized so a wiring write can't race the readQueue's invoke
    /// read. Safe from deadlock — the invokes (`onOutput?(…)`/`onExit?(…)`)
    /// happen OUTSIDE the lock, so the getter's snapshot-under-lock won't
    /// re-enter.
    public var onOutput: (@Sendable (Data) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onOutput }
        set { lock.lock(); defer { lock.unlock() }; _onOutput = newValue }
    }
    /// Called once when the child exits / the PTY reaches EOF, on `readQueue`.
    /// Carries the exit status if known. Lock-synchronized (TSK-992).
    public var onExit: (@Sendable (Int32) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onExit }
        set { lock.lock(); defer { lock.unlock() }; _onExit = newValue }
    }
    private var _onOutput: (@Sendable (Data) -> Void)?
    private var _onExit: (@Sendable (Int32) -> Void)?

    private let lock = NSLock()
    private var masterFD: Int32 = -1
    /// Internal getter (TSK-138 test seam): the zombie-reap pin reads
    /// the spawned pid to assert the child is actually COLLECTED after
    /// terminate() (kill(pid,0) → ESRCH), not merely signalled.
    private(set) var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var didExit = false
    /// TSK-992: set under `lock` between claiming the start slot and the fork
    /// completing, so two concurrent `start()` calls can't both fork (the old
    /// guard released the lock BEFORE the fork set `childPID` = a double-fork).
    private var starting = false
    private let readQueue = DispatchQueue(label: "com.markdownviewer.pty.read")
    /// Serial queue for the BLOCKING input drain (TSK-741). The master fd is
    /// blocking, so a large paste into a slow reader (vim) fills the kernel PTY
    /// buffer and Darwin.write PARKS — running it here keeps that off the
    /// (main-actor) caller. Serial → byte order across writes is preserved.
    private let writeQueue = DispatchQueue(label: "com.markdownviewer.pty.write")

    public init() {}

    deinit { terminate() }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return childPID > 0 && !didExit
    }

    /// Atomically claim the single-start slot (TSK-992): returns true + marks
    /// `starting` when no child is up and no start is in flight; false
    /// otherwise. Closes the double-fork window (the old guard released the lock
    /// BEFORE the fork completed). Internal so a host test can exercise the
    /// guard without the non-host-testable real fork.
    func claimStartSlot() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard childPID <= 0 && !starting else { return false }
        starting = true
        return true
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
        guard claimStartSlot() else { return true }   // already running / a start is in flight

        var master: Int32 = 0
        var ws = winsize(
            ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0
        )

        // ───── PRECOMPUTE EVERYTHING IN THE PARENT (signal-safety, M4) ─────
        // The process is heavily multi-threaded (RemoteTransport reader,
        // FSEvents, GCD, WebKit). Between forkpty() and execve() ONLY
        // async-signal-safe syscalls are legal in the child — any malloc
        // (e.g. another thread held the malloc lock at fork time), Swift
        // String bridging, or Dictionary op can DEADLOCK the child. So build
        // the resolved shell path, the env `char**`, and the argv `char**`
        // HERE (all strdup/malloc/String work happens pre-fork), and after
        // the fork the child does only chdir + execve. The plan's C arrays
        // are inherited by the child's copy-on-write address space and leak
        // on exec (the image is replaced) — intentional and correct.
        let plan = Self.SpawnPlan(environment: environment)
        // chdir target as a C string, also precomputed (withCString bridges
        // a String → must not happen in the child).
        let cwdPlan = workingDirectory.map { CStringBox($0.path) }

        // forkpty: allocates a PTY pair, forks, makes the child the
        // session leader with the slave as its controlling terminal, and
        // dup2's slave→0/1/2. Parent gets the master fd back.
        let pid = withUnsafeMutablePointer(to: &ws) { wsPtr in
            forkpty(&master, nil, nil, wsPtr)
        }

        if pid < 0 {
            lock.lock(); starting = false; lock.unlock()   // release the claimed slot
            return false                                   // fork failed
        }

        if pid == 0 {
            // ───── CHILD ─────
            // ASYNC-SIGNAL-SAFE ONLY. No Swift String bridging, no Dictionary
            // ops, no malloc — everything was precomputed in the parent above.
            // On any failure, _exit (never return into the parent's Swift
            // runtime). `chdir`, `execve`, `_exit` are all on the
            // signal-safe list (POSIX async-signal-safe functions).
            if let cwdPlan {
                _ = chdir(cwdPlan.pointer)
            }
            _ = execve(plan.path, plan.argv, plan.envp)
            // execve only returns on failure.
            _exit(127)
        }

        // ───── PARENT ─────
        lock.lock()
        masterFD = master
        childPID = pid
        didExit = false
        starting = false
        lock.unlock()

        startReadLoop()
        return true
    }

    // MARK: - Spawn plan (precomputed in the parent — signal-safety, M4)

    /// A NULL-terminated C string array owning its `strdup`'d members, built
    /// from `[String]` in the PARENT before `forkpty`. Holds the strong C
    /// pointers so they outlive the call and stay valid in the child's
    /// copy-on-write image until `execve` replaces it. We deliberately do NOT
    /// free the members: the child execs (image replaced) and the parent only
    /// uses this transiently around the fork; the strings are tiny and the
    /// box is dropped right after. The factory `CStringArray.make` is a PURE
    /// function of `[String]` → `char**`, host-unit-testable (round-trips back
    /// to `[String]`), which pins the precompute moved out of the child.
    final class CStringArray {
        /// `count`+1 entries: the strdup'd members followed by a NULL terminator.
        private let storage: [UnsafeMutablePointer<CChar>?]
        /// Mutable `char **` view suitable for `execve`'s argv/envp params.
        let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>

        private init(strings: [String]) {
            var buf = strings.map { strdup($0) }
            buf.append(nil)                                 // NULL terminator
            self.storage = buf
            // Allocate a stable backing buffer for the pointer array itself
            // (an `[T]`'s storage address is not guaranteed stable across the
            // value's lifetime), so the `char**` we hand to execve stays valid.
            let p = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
                .allocate(capacity: buf.count)
            p.initialize(from: buf, count: buf.count)
            self.pointer = p
        }

        deinit {
            // Free the array buffer and each strdup'd member. (In the child
            // we never reach here — execve replaces the image; this only runs
            // in the parent after the transient use around fork.)
            var i = 0
            while let s = pointer[i] { free(s); i += 1 }
            pointer.deallocate()
        }

        /// Build a NULL-terminated `char**` from `strings`. Pure: the result
        /// round-trips back to `strings` (see `toStringArray`).
        static func make(_ strings: [String]) -> CStringArray {
            CStringArray(strings: strings)
        }

        /// Read the array back to `[String]` (stops at the NULL terminator).
        /// Host-test seam: proves `make` produced a faithful, correctly
        /// NULL-terminated array.
        func toStringArray() -> [String] {
            var out: [String] = []
            var i = 0
            while let s = pointer[i] { out.append(String(cString: s)); i += 1 }
            return out
        }
    }

    /// A single owned C string (for the `chdir` target). Same ownership model
    /// as `CStringArray` — built in the parent, valid through `execve`.
    final class CStringBox {
        let pointer: UnsafeMutablePointer<CChar>
        init(_ string: String) { self.pointer = strdup(string) }
        deinit { free(pointer) }
    }

    /// All C strings the child's `execve` needs, computed entirely in the
    /// PARENT. After `forkpty` the child references only `path`/`argv`/`envp`
    /// — no Swift, no malloc.
    struct SpawnPlan {
        let path: UnsafePointer<CChar>
        let argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        let envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        // Keep the owning boxes alive for the plan's lifetime.
        private let pathBox: CStringBox
        private let argvBox: CStringArray
        private let envpBox: CStringArray

        init(environment: [String: String]?) {
            let resolved = PTYProcess.resolveShell(environment: environment)
            self.pathBox = CStringBox(resolved.shellPath)
            self.argvBox = CStringArray.make(resolved.argv)
            self.envpBox = CStringArray.make(resolved.envStrings)
            self.path = UnsafePointer(pathBox.pointer)
            self.argv = argvBox.pointer
            self.envp = envpBox.pointer
        }
    }

    /// PURE resolver: given an optional custom env, decide the login shell
    /// path, its `argv` (a single `-<name>` login-shell marker), and the
    /// `KEY=VALUE` env strings (TERM forced to `xterm-256color`). No fork, no
    /// C bridging — host-unit-testable. This is the Swift-String / Dictionary
    /// work that USED to run in the child between forkpty and execve; it now
    /// runs in the parent.
    static func resolveShell(
        environment: [String: String]?
    ) -> (shellPath: String, argv: [String], envStrings: [String]) {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shellPath as NSString).lastPathComponent
        // argv[0] = "-zsh" requests a login shell.
        let argv0 = "-" + shellName

        // If a custom env is supplied use it, otherwise inherit the parent's.
        // Always force a sane TERM so programs negotiate against a capability
        // set we roughly model.
        var env = environment ?? ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        let envStrings = env.map { "\($0.key)=\($0.value)" }

        return (shellPath, [argv0], envStrings)
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
    ///
    /// TSK-741: the master fd is BLOCKING, so a large paste into a slow reader
    /// (vim) fills the kernel PTY buffer and `Darwin.write` PARKS. This used to
    /// run on the caller — `sendInput` is `@MainActor` — beachballing the app
    /// ("Not Responding"). The drain now runs on the serial `writeQueue` so the
    /// caller returns immediately; serial dispatch preserves byte order across
    /// writes. The fd is captured at call time (mirrors the read source); a
    /// write that races a close hits `EBADF` and bails.
    public func write(_ data: Data) {
        lock.lock()
        let fd = masterFD
        lock.unlock()
        guard fd >= 0 else { return }
        writeQueue.async {
            _ = Self.drain(data) { ptr, len in Darwin.write(fd, ptr, len) }
        }
    }

    /// Drain `data` to `writeBytes` (the byte sink), handling partial writes and
    /// `EINTR`/`EAGAIN` retry, bailing on a hard error. Returns the number of
    /// bytes written. The sink is INJECTED (not the fd) so the loop is
    /// unit-testable without a real PTY. (TSK-741.)
    static func drain(_ data: Data, writeBytes: (UnsafeRawPointer, Int) -> Int) -> Int {
        data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var offset = 0
            let total = raw.count
            while offset < total {
                let n = writeBytes(base + offset, total - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && (errno == EINTR || errno == EAGAIN) {
                    continue
                } else {
                    break
                }
            }
            return offset
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
